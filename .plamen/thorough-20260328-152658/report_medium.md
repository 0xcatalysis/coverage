## Medium Findings

---

### [M-09] maxWithdraw/maxRedeem Double-Deducts Premium (ERC-4626 Spec Violation) [VERIFIED]

**Severity**: Medium
**Location**: `src/defi/adapters/morpho/CoveredVaultWrapper.sol:L442-L453`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`maxWithdraw` computes a user's gross asset entitlement via `_convertToAssets(shares)`, which internally calls `totalAssets()`. That function already deducts the entire vault's premium liability (`totalPremiumLiability + _accruedPremiumFor(mv)`) before pricing shares. `maxWithdraw` then also subtracts `owedPremium` — the user's individual share of that same liability — from the result:

```solidity
// CoveredVaultWrapper.sol:442-452
function maxWithdraw(address owner) public view override returns (uint256) {
    uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
    // ...
    uint256 owedPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[owner]);
    uint256 totalDeductions = owedPremium + _accruedPremiumFor(mv).mulDiv(fraction, WAD);
    return _safeSub(grossAssets, totalDeductions);  // premium deducted a second time
}
```

Because `grossAssets` already reflects a share price derived from post-premium-deduction `totalAssets()`, subtracting `owedPremium` again causes `maxWithdraw` to return a value strictly lower than what the user can actually withdraw.

**Impact**:
ERC-4626 requires `maxWithdraw` to return the maximum assets that can be successfully withdrawn via `withdraw()`. Understating it means:
- Integrators (yield aggregators, lending protocols using vault shares as collateral) under-allocate capital and leave shares stranded.
- A call to `withdraw(maxWithdraw, ...)` succeeds while leaving behind a portion of the user's entitlement, which the integrator may not retry.
- The understatement grows linearly with the user's accumulated `owedPremium`, so long-term depositors are disproportionately affected.

**PoC Result**:
```
test_H14_maxWithdraw_underestimates: PASS
maxWithdraw reported:          9,999,917,808,250,240,000,000
previewRedeem(maxRedeem):      9,999,958,904,125,120,000,000
Difference:                    ~41,095,875,000 wei
assertLt(maxWithdraw, previewRedeem(maxRedeem)) PASSES
```

The user can redeem more assets than `maxWithdraw` reports, confirming the double-deduction.

**Recommendation**:
Remove the `owedPremium` subtraction from `maxWithdraw`. The premium is already incorporated into the share price used by `_convertToAssets`. The corrected implementation should return `grossAssets` after deducting only the accrued (uncheckpointed) delta that is not yet in `totalPremiumLiability`:

```solidity
function maxWithdraw(address owner) public view override returns (uint256) {
    uint256 shares = balanceOf(owner);
    if (shares == 0) return 0;
    return _convertToAssets(shares, Math.Rounding.Floor);
    // totalAssets() already nets out totalPremiumLiability; no further deduction needed
}
```

If the intent is to show the net cash the user will receive (including the premium deduction at redemption time), consider a separate view function rather than overriding `maxWithdraw`, which must conform to the ERC-4626 invariant.

---

### [M-10] CREATOR_ROLE Can Replace Infrastructure Addresses Without Timelock [VERIFIED]

**Severity**: Medium
**Location**: `src/CoverPoolFactory.sol:L115-L159`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`CoverPoolFactory` exposes four critical setter functions — `setCoverPoolImplementation`, `setPolicyManager`, `setStakeManager`, and `setSpecRegistry` — all gated only by `onlyRole(CREATOR_ROLE)` with no timelock, no delay, and no two-step confirmation:

```solidity
// CoverPoolFactory.sol:115-159
function setCoverPoolImplementation(address implementation_) external override onlyRole(CREATOR_ROLE) { ... }
function setPolicyManager(address policyManager_)           external override onlyRole(CREATOR_ROLE) { ... }
function setStakeManager(address stakeManager_)             external override onlyRole(CREATOR_ROLE) { ... }
function setSpecRegistry(address specRegistry_)             external override onlyRole(CREATOR_ROLE) { ... }
```

A single transaction from CREATOR_ROLE immediately rotates the implementation used for all future `CoverPool` deployments and the core infrastructure references used for policy management and staking.

**Impact**:
- A compromised or malicious CREATOR_ROLE can atomically redirect all new pool deployments to a backdoored implementation.
- Rotating `stakeManager` or `specRegistry` silently breaks all new policy bindings without user warning.
- Combined with M-13 (Old CoverPools Permanently Orphaned After Infrastructure Rotation): after a CREATOR_ROLE-initiated rotation, newly deployed pools point to the new infrastructure while all existing pools remain bound to the old addresses with no migration path. The system splits into two incompatible generations of pools with no bridge.
- Users observing the infrastructure have no window to react before the change takes effect.

**PoC Result**:
```
test_H16_creatorRole_instant_infra_change: PASS
StakeManager before: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
StakeManager after:  0xD16d567549A2a2a2005aEACf7fB193851603dd70
-- Change was instant (same block, no delay)
assertEq(stakeManagerAfter, address(newStakeManager)) PASSES
assertEq(specRegistryAfter, address(newSpecRegistry)) PASSES
```

**Recommendation**:
Apply a governance timelock (minimum 48 hours) to all infrastructure-rotating setters in `CoverPoolFactory`. A two-step pattern (propose + accept after delay) is strongly preferred:

```solidity
// Propose
function proposeStakeManager(address newStakeManager_) external onlyRole(CREATOR_ROLE) {
    pendingStakeManager = newStakeManager_;
    pendingStakeManagerEta = block.timestamp + TIMELOCK_DELAY;
    emit StakeManagerProposed(newStakeManager_, pendingStakeManagerEta);
}

// Execute after delay
function acceptStakeManager() external onlyRole(CREATOR_ROLE) {
    require(block.timestamp >= pendingStakeManagerEta, TooEarly());
    stakeManager = pendingStakeManager;
    // ...
}
```

This gives users and existing pool operators time to observe and respond to infrastructure changes.

---

### [M-11] Quote startTime Goes Stale Between Draft Creation and Policy Binding [VERIFIED]

**Severity**: Medium
**Location**: `src/CoverPool.sol:L51-L65`, `src/PolicyManager.sol:L250-L254`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`CoverPool.validateQuote` enforces `quote.startTime >= block.timestamp` at the time of binding:

```solidity
// CoverPool.sol:59-61
uint256 currentTimestamp = block.timestamp;
require(quote.startTime >= currentTimestamp,
    InvalidStartTime(quote.startTime, uint32(currentTimestamp)));
```

A quote is typically created off-chain (or in an earlier transaction) with `startTime = block.timestamp` at the time of the request. Any positive delay between quote creation and the call to `bindPolicyForRequest` — even a single block — causes `startTime` to be in the past relative to the bind block, causing the transaction to revert with `InvalidStartTime`.

**Impact**:
- In normal operation, curators cannot realistically execute same-block binding; network conditions, mempool delays, or a single competing transaction make this a routine failure.
- An adversary can front-run or delay the bind transaction to guarantee `startTime` staleness, effectively enabling a persistent DoS on policy binding for any quote that uses `startTime = now`.
- The only mitigation available to users is to set `startTime` far in the future, but this leaves a gap in coverage from the current block to `startTime` — defeating the purpose of immediate coverage.
- Repeated bind failures increase gas costs and operational friction for curators.

**PoC Result**:
```
test_H19_startTime_stale_on_bind: PASS
startTime:            1  (block.timestamp at quote creation)
block.timestamp:      1
After 1 second warp:  2
bindPolicyForRequest() -> vm.expectRevert() -> PASSES
H-19 CONFIRMED: bindPolicy reverts when startTime < block.timestamp
```

**Recommendation**:
Allow a tolerance window (e.g., 5 minutes) so that quotes created near the current time remain valid after typical network delays:

```solidity
uint256 BIND_TOLERANCE = 5 minutes;
require(
    quote.startTime + BIND_TOLERANCE >= currentTimestamp,
    InvalidStartTime(quote.startTime, uint32(currentTimestamp))
);
```

Alternatively, allow the curator to pass an explicit `startTime` override at bind time (clamped to `max(quote.startTime, block.timestamp)`), decoupling the requested start from the on-chain execution timestamp.

---

### [M-12] Operator Can Waive Owner's Insurance via Emergency Exit [VERIFIED]

**Severity**: Medium
**Location**: `src/defi/adapters/morpho/CoveredVaultWrapper.sol:L241-L262`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`emergencyRedeem` and `emergencyWithdraw` set a transient flag (`SKIP_INSURANCE_SLOT`) that causes `_computeInsurance` to return zero, bypassing the insurance payout for the entire withdrawal:

```solidity
// CoveredVaultWrapper.sol:241-248
function emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256) {
    _tstore(SKIP_INSURANCE_SLOT, 1);
    super.redeem(shares, receiver, owner);   // uses msg.sender allowance check via ERC-4626
    _tstore(SKIP_INSURANCE_SLOT, 0);
    // ...
}
```

Both functions delegate to the standard ERC-4626 `redeem`/`withdraw` path, which allows any approved operator (i.e., any address the owner has granted a `shares` allowance to) to call on behalf of the owner. An operator with a sufficient allowance can therefore call `emergencyRedeem` for the owner's shares without the owner's explicit consent for the insurance waiver, silently stripping the owner's right to an insurance payout.

While the verification confirmed that a completely unapproved third party cannot execute this (the ERC-4626 allowance check blocks them), any existing allowance granted for a different purpose — such as a DeFi protocol that received share approval to execute a routine withdrawal — is sufficient to invoke the emergency path.

**Impact**:
- During a loss event, an operator (e.g., a lending protocol, aggregator, or automated keeper with existing share approval) can call `emergencyRedeem` on behalf of the owner.
- The owner receives assets minus the premium deduction but receives zero insurance payout, even if they are entitled to one.
- The owner has no ability to distinguish the emergency path from a normal redemption before execution, nor to recover the foregone insurance payment after the fact.
- This is particularly harmful when the operator acts under a routine automation script that does not distinguish between normal and emergency market conditions.

**PoC Result**:
```
test_H22_owner_waives_insurance_via_emergency: PASS
Emergency redeem out: 8,499,958,904,125,120,000,000  (~8,500 ether)
depositAmount:        10,000 ether
15% Morpho loss: 8,500 ether received without insurance payout
assertLt(actualReceived, depositAmount) PASSES

test_H22_operator_cannot_call_without_allowance:
vm.expectRevert() -> PASSES (operator blocked by allowance check)
```

**Recommendation**:
Require that `emergencyRedeem` and `emergencyWithdraw` can only be called by `owner` themselves, not by an approved operator:

```solidity
function emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256) {
    require(msg.sender == owner, NotOwner());  // no operator delegation for insurance waiver
    _tstore(SKIP_INSURANCE_SLOT, 1);
    super.redeem(shares, receiver, owner);
    _tstore(SKIP_INSURANCE_SLOT, 0);
    // ...
}
```

This preserves the intent of the emergency path (explicit user opt-out of insurance) while preventing operators from unilaterally waiving a depositor's coverage.

---

### [M-13] Old CoverPools Permanently Orphaned After Infrastructure Rotation [VERIFIED]

**Severity**: Medium
**Location**: `src/CoverPoolFactory.sol:L90-L159`, `src/CoverPool.sol:L79-L101`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`CoverPool.initialize()` captures `stakeManager` and `specRegistry` at deployment time and stores them as immutable-equivalent fields:

```solidity
// CoverPool.sol:79-101
function initialize(
    // ...
    address stakeManager_,
    address specRegistry_,
    // ...
) external initializer {
    // ...
    stakeManager = stakeManager_;
    specRegistry = specRegistry_;
}
```

There is no setter for these addresses in `CoverPool`. Separately, `CoverPoolFactory.setStakeManager()` and `setSpecRegistry()` update the factory's references for future deployments, but do not propagate to existing pool instances. Additionally, the CREATE2 salt does not incorporate `stakeManager` or `specRegistry`, so redeploying a pool at the same address after an infrastructure change is impossible (the address would collide with the existing pool).

The result: once `CoverPoolFactory` rotates either infrastructure contract, every existing `CoverPool` is permanently bound to the old addresses with no migration path.

**Impact**:
- Stake validation uses the old `stakeManager`, so new committee configurations under the new staking contract are invisible to existing pools.
- Spec registration and spec lookups use the old `specRegistry`, so newly registered claim specs are unreachable from existing pools.
- Claims filed against existing policies may use stale spec logic or reference stale staking data that does not reflect the post-migration state.
- There is no emergency fix: the CREATE2 address collision prevents re-deploying the same pool, and `CoverPool` has no upgrade path for these addresses.
- Combined with M-10 (CREATOR_ROLE Can Replace Infrastructure Addresses Without Timelock): an instant infrastructure rotation immediately bifurcates the system into old pools (orphaned) and new pools (connected), with no notification to affected depositors.

**PoC Result**:
```
test_H25_coverPool_retains_old_addresses_after_factory_rotation: PASS
Pool stakeManager:   0xF62849F9A0B5Bf2913b396098F7c7019b51A820a (old)
Factory stakeManager after rotation: 0xD16d567549A2a2a2005aEACf7fB193851603dd70 (new)
assertEq(coverPool.stakeManager(), poolStakeManager) PASSES (pool unchanged)
assertNotEq(factory.stakeManager(), coverPool.stakeManager()) PASSES (diverged)
```

**Recommendation**:
Two complementary fixes are needed:

1. **Add migration setters to `CoverPool`** (gated by a governance timelock or admin multisig) to allow updating `stakeManager` and `specRegistry` post-deployment:
   ```solidity
   function setStakeManager(address newStakeManager) external onlyRole(DEFAULT_ADMIN_ROLE) {
       stakeManager = newStakeManager;
       emit StakeManagerUpdated(newStakeManager);
   }
   ```

2. **Optionally**, include `stakeManager` and `specRegistry` in the CREATE2 salt so that a new deployment with updated infrastructure occupies a distinct address:
   ```solidity
   bytes32 salt = keccak256(abi.encode(params.owner, params.underlying, stakeManager, specRegistry));
   ```

The migration setters approach is preferred because it keeps existing policy commitments valid and allows in-place upgrades.

---

### [M-14] Repeated Gate Toggles Create Arbitrarily Long Uninsured Premium Window [VERIFIED]

**Severity**: Medium
**Location**: `src/defi/adapters/morpho/CoveredVaultAdmin.sol:L168-L186`, `src/defi/adapters/morpho/CoveredVaultAccrual.sol:L80-L100`
**Confidence**: HIGH (PoC: PASS)

**Description**:
This finding describes a compound vulnerability arising from two interacting bugs.

**Component 1 — Uninsured grace window**: `CoveredVaultWrapper._isPolicyActive()` returns `true` until `effectiveMaturity = maturityTime + gateGracePeriod`, so premium continues accruing during the grace period. However, `ClaimManager` enforces the raw `maturityTime` for claim eligibility. Any loss event occurring after `maturityTime` but before `effectiveMaturity` results in users paying premium with no insurance coverage.

**Component 2 — Unbounded accumulation**: Each time the owner calls `setMorphoGateActive(false)` to deactivate the gate, the elapsed gate duration is added to `gateGracePeriod` with no cap:

```solidity
// CoveredVaultAdmin.sol:178-183
} else if (!active && morphoGateActive && gateActivatedAt > 0) {
    uint256 gateDuration = block.timestamp - gateActivatedAt;
    gateGracePeriod += gateDuration;  // no maximum, unbounded addition
    gateActivatedAt = 0;
}
```

Multiple legitimate gate activations (e.g., each time Morpho undergoes maintenance) accumulate `gateGracePeriod` additively. After N gate cycles, `gateGracePeriod` can far exceed the original policy duration.

**Combined attack sequence**:
1. Owner activates and deactivates `morphoGate` three times over the policy lifetime (30 days each, for legitimate Morpho downtime).
2. `gateGracePeriod` accumulates to 90 days. `effectiveMaturity = maturityTime + 90 days`.
3. Premium accrual continues for 90 days past `maturityTime`.
4. Any Morpho loss during this 90-day window: `ClaimManager` rejects claims (enforces raw `maturityTime`).
5. Users have paid premium for the full 90-day uninsured window with zero recoverable coverage.

**Impact**:
- With three 30-day gate cycles, users lose 90 days of premium with no insurance coverage.
- The amount is proportional to the accumulated grace period and the premium rate. At typical premium rates, this represents a material loss for all depositors.
- The owner need not act maliciously — legitimate Morpho maintenance events naturally trigger this accumulation.
- There is no per-cycle cap, maximum total grace period, or user-facing warning that coverage has lapsed.

**PoC Result**:
```
test_CH3_repeatedGateTogglesAccumulateGracePeriod: PASS
testFuzz_CH3_gateToggleAccumulation: PASS (250 runs)

gateGracePeriod after cycle 1: 2,592,000 (30 days)
gateGracePeriod after cycle 2: 5,184,000 (60 days)
gateGracePeriod after cycle 3: 7,776,000 (90 days)
effectiveMaturity:              maturityTime + 90 days
Premium accrued during 30d grace window: 1,000 ether
ClaimManager would reject at maturityTime+1: YES
```

**Recommendation**:
Apply a cap on `gateGracePeriod` to prevent unbounded accumulation, for example a single-policy maximum of 30 days:

```solidity
uint256 constant MAX_GATE_GRACE_PERIOD = 30 days;

} else if (!active && morphoGateActive && gateActivatedAt > 0) {
    uint256 gateDuration = block.timestamp - gateActivatedAt;
    uint256 newGrace = gateGracePeriod + gateDuration;
    gateGracePeriod = newGrace > MAX_GATE_GRACE_PERIOD ? MAX_GATE_GRACE_PERIOD : newGrace;
    gateActivatedAt = 0;
}
```

Additionally, `ClaimManager` should respect `effectiveMaturity` rather than raw `maturityTime` when validating claim eligibility, so that the grace period either serves its protective purpose or premium accrual during it is suppressed.

---

### [M-15] Morpho Loss During Grace Window Creates Permanent NAV Deflation [VERIFIED]

**Severity**: Medium
**Location**: `src/defi/adapters/morpho/CoveredVaultWrapper.sol:L573-L583`, `src/defi/adapters/morpho/CoveredVaultAccrual.sol:L65-L95`
**Confidence**: HIGH (PoC: PASS)

**Description**:
This finding describes a three-way compound vulnerability. Two root causes — the uninsured grace window and the phantom premium residual bug — combine to guarantee the worst-case outcome for depositors.

**Root cause 1 (uninsured grace window)**: During the `gateGracePeriod` extension, premium accrues but `ClaimManager` enforces raw `maturityTime`, so any loss event in the grace window cannot be claimed. See M-14 for details.

**Root cause 2 (phantom residual)**: During a deep-loss withdrawal (where `assetsReceived < uncappedPremium`), `totalPremiumLiability` is decremented only by `premiumForWithdrawal = min(assetsReceived, uncappedPremium)` rather than the full `uncappedPremium`:

```solidity
// CoveredVaultWrapper.sol:573-583
pendingPremium += premiumForWithdrawal;
totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal);
// The delta (uncappedPremium - premiumForWithdrawal) stays in totalPremiumLiability as phantom
```

Since `totalAssets() = morphoValue - totalPremiumLiability - accruedPremium`, the phantom residual permanently deflates the NAV for all remaining holders.

**Combined attack sequence**:
1. Gate is active during a Morpho downtime event; `gateGracePeriod` accumulates.
2. A Morpho loss event occurs during the grace window.
3. Users attempt to file claims — `ClaimManager` rejects all of them (block.timestamp > raw maturityTime).
4. Users are forced to withdraw without any insurance offset. For a 50% Morpho loss with substantial accrued premium, `assetsReceived` may be far less than `uncappedPremium`.
5. `totalPremiumLiability` is decremented by the small `premiumForWithdrawal` (capped at the low `assetsReceived`). The remainder — the phantom — stays permanently in `totalPremiumLiability`.
6. Remaining depositors face deflated `totalAssets()` (from the phantom) on top of the actual Morpho loss.

The grace window makes this scenario inevitable rather than probabilistic: without insurance to offset the loss, any withdrawal during or after the loss event qualifies as deep-loss.

**Impact**:
- Three compounding losses for depositors: (1) premium paid during the uninsured grace window, (2) no insurance payout on the loss, (3) permanent NAV deflation from the phantom residual affecting all remaining holders.
- The phantom residual cannot be organically cleared — it persists indefinitely unless subsequent depositors overpay premium.
- The magnitude scales with grace period length (amplified by M-14's unbounded accumulation) and Morpho loss depth.

**PoC Result**:
```
test_CH4_graceWindowLossCreatesPhantomLiability: PASS
testFuzz_CH4_phantomLiabilityOnLoss: PASS (250 runs, loss 20-80%)

User1 deposit:                         1,000 ether
Morpho loss:                           50%
User1 received after redeem:           45 ether
totalPremiumLiability before:          2,000 ether
totalPremiumLiability after User1:     1,500 ether
Expected if no phantom (User2 only):   ~1,000 ether
Phantom residual:                      ~500 ether
```

**Recommendation**:
Both root causes require independent fixes. For the phantom residual specifically: decrement `totalPremiumLiability` by `uncappedPremium` rather than `premiumForWithdrawal`. Track forgiven premium in a separate accounting variable if needed:

```solidity
// Instead of:
totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal);

// Use:
totalPremiumLiability = _safeSub(totalPremiumLiability, uncappedPremium);
// forgiven = uncappedPremium - premiumForWithdrawal  (already handled by premium cap logic)
```

For the uninsured grace window, see the recommendation in M-14. Fixing either root cause breaks the compound chain; fixing both eliminates the NAV deflation entirely.

---

### [M-16] Curator Combines Claim Denial with Retroactive Fee Extraction [VERIFIED]

**Severity**: Medium
**Location**: `src/CoverPool.sol:L147-L149`, `src/PremiumManager.sol:L137-L165`
**Confidence**: HIGH (PoC: PASS)

**Description**:
This finding describes a dual-profit attack sequence available to a malicious curator (the `DEFAULT_ADMIN_ROLE` on a `CoverPool`).

**Step 1 — Claim denial**: The curator can call `CoverPool.setPremiumDefaulted(policyId, true)` at any time:

```solidity
// CoverPool.sol:147-149
function setPremiumDefaulted(uint96 policyId, bool defaulted)
    external override onlyRole(DEFAULT_ADMIN_ROLE) { ... }
```

This sets `metadata.premiumDefaulted = true` in `PolicyManager`, causing `ClaimManager.fileClaim` to revert for all subsequent claims on that policy. `CoveredVaultWrapper`'s `try/catch` silently converts this to a zero payout — depositors can still withdraw but receive no insurance coverage.

**Step 2 — Retroactive fee extraction**: `PremiumManager.distributePremium` reads `poolFeeBps` live from the `CoverPool` at distribution time, not at accrual time:

```solidity
// PremiumManager.sol:154
uint16 poolFeeBps = ICoverPool(pool).poolFeeBps();
```

The curator can call `setPoolFeeBps(2000)` (the maximum 20%) just before calling `distributeBatch`, retroactively applying the elevated fee rate to all premium that accrued while the fee was lower (or zero).

Since both `setPremiumDefaulted` and `setPoolFeeBps` are controlled by the same role (`DEFAULT_ADMIN_ROLE` on `CoverPool`), a single actor can atomically execute both steps in one transaction.

**Combined attack sequence**:
1. A loss event occurs on the Morpho vault.
2. Curator calls `setPremiumDefaulted(policyId, true)` — blocks all insurance claims, protecting their staked collateral from slashing.
3. Curator calls `setPoolFeeBps(2000)` — spikes pool fee to maximum 20%.
4. Curator (or premium distributor) calls `distributeBatch` — the entire accumulated premium (weeks or months of accrual at the original lower rate) is distributed at 20% curator fee.
5. Curator profits twice: (a) staked collateral protected from insurance payouts, (b) inflated fee on accumulated premium.

**Impact**:
- Depositors lose insurance coverage on the loss event AND pay inflated retroactive fees to the entity that blocked their coverage.
- The curator's economic incentive (protect staking collateral) directly enables the fee extraction step: blocking claims leaves premium accrued but undistributed, providing a larger pool to extract fees from.
- No timelock, no cooldown, and no admin override exists for either `setPremiumDefaulted` or `setPoolFeeBps`.
- Combined dollar impact scales with pool TVL and accumulated premium; for a meaningful pool, this can substantially exceed the curator's legitimate fee income.

**PoC Result**:
```
test_CH6_curatorBlocksClaimsAndExtractsRetroactiveFees: PASS
testFuzz_CH6_retroactiveFeeExtraction: PASS (250 runs, fee 1-2000 bps)

premiumDefaulted:                         true
Original poolFeeBps:                      0
New poolFeeBps:                           2000 (20%)
Pool split at new fee (100 ether premium): 20 ether
Same actor controls both actions:          YES (DEFAULT_ADMIN_ROLE)
```

**Recommendation**:
Two independent fixes are needed:

1. **Snapshot `poolFeeBps` at accrual time** (not distribution time) so retroactive fee spiking cannot extract value from past accruals:
   ```solidity
   // Store poolFeeBps in the accrual record and use it at distribution
   struct AccrualRecord { uint96 policyId; uint16 poolFeeBps; uint256 amount; }
   ```
   Alternatively, enforce a minimum timelock (e.g., 48 hours) on `setPoolFeeBps` changes.

2. **Add governance oversight to `setPremiumDefaulted`**: require a timelock delay, an admin co-signature, or limit the curator's ability to set `premiumDefaulted = true` without a corresponding governance action.

---

### [M-17] Phantom Residual Widens previewRedeem Gap [VERIFIED]

**Severity**: Medium
**Location**: `src/defi/adapters/morpho/CoveredVaultWrapper.sol:L106-L110`, `src/defi/adapters/morpho/CoveredVaultWrapper.sol:L573-L583`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`previewRedeem` (inherited from OpenZeppelin's `ERC4626Upgradeable`) computes the expected output for a given share count using `totalAssets()` as the share-pricing basis:

```solidity
// CoveredVaultWrapper.sol:106-110
function totalAssets() public view override returns (uint256) {
    uint256 mv = _morphoValue();
    uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);
    return mv > totalLiability ? mv - totalLiability : 0;
}
```

When a deep-loss withdrawal creates a phantom residual in `totalPremiumLiability` (see M-15), `totalAssets()` is permanently deflated for all remaining holders. `previewRedeem` therefore returns a share price that is lower than the actual redemption proceeds, because the actual `redeem` path can recover insurance payouts that are not visible in `totalAssets()`.

This compounds a pre-existing divergence: the actual `redeem` deducts per-user `owedPremium` from the user's gross entitlement, but `previewRedeem` does not model this deduction (it prices at the aggregate level). The phantom amplifies the gap further by suppressing the share price used in the preview.

**Impact**:
ERC-4626 integrators — lending protocols using vault shares as collateral, yield aggregators, liquidation bots — rely on `previewRedeem` to estimate the asset value of a share position. A systematic understatement creates the following risks:
- Lending protocols using vault shares as collateral may compute collateral values below the true redemption proceeds, leading to under-collateralization flags and premature liquidations.
- A vault depositor who trusts `previewRedeem` before deciding to redeem may choose not to exit, believing their position is worth less than it actually is.
- Integrators that pre-approve based on `previewRedeem` will observe a larger-than-expected shortfall when they also subtract the per-user premium — a compounding gap that can be 90%+ of the actual redemption value in extreme scenarios.

**PoC Result**:
```
test_CH5_phantomWidesPreviewRedeemGap: PASS

Phantom residual:                73.97 ether
previewRedeem for user2:         12.05 ether
Actual redeem for user2:        151.37 ether
previewRedeem UNDERSTATED by:   139.32 ether (92% understatement)
```

**Recommendation**:
Fixing the phantom residual (see M-15 recommendation) eliminates the primary amplifier. After that fix, `previewRedeem` will price shares at the correct `totalAssets()` basis.

For the remaining divergence (per-user premium not modeled in preview), override `previewRedeem` and `previewWithdraw` to include the per-user premium deduction:

```solidity
function previewRedeem(uint256 shares) public view override returns (uint256) {
    uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
    address caller = msg.sender;
    uint256 owedPremium = _calcOwedDebt(
        userPrincipal[caller],
        cumulativePremiumPerUnit,
        userPremiumDebt[caller]
    );
    return grossAssets > owedPremium ? grossAssets - owedPremium : 0;
}
```

Note: `previewRedeem` and `previewWithdraw` overrides that use `msg.sender` are non-standard but are compatible with ERC-4626's allowance for implementations that "perform user-specific calculations." Document this deviation clearly.
