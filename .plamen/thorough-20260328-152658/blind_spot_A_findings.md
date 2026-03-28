# Blind Spot Scanner A Findings — Tokens & Parameters

**Scanner**: Blind Spot Scanner A
**Scope**: CoveredVaultWrapper.sol, CoveredVaultAccrual.sol, CoveredVaultAdmin.sol, CoveredVaultStorage.sol, BasePolicyInteractions.sol
**Exclusion**: All 55 findings in findings_inventory.md excluded by root cause.

---

## CHECK 1: External Token Coverage

### Token Flow Matrix Cross-Reference

| External Token | Analyzed by Agent? | Finding IDs | Dimensions Covered (R11) | Missing Dimensions |
|----------------|-------------------|-------------|--------------------------|-------------------|
| Underlying asset (USDC/ERC-20) | YES | CS-2, PC1-1, TF-3, TF-7, OZ-3 | D1 (donation: TF-3), D2 (accounting: CS-2, PC1-1), D3 (op blocking: TF-7) | D4 N/A (no loops), D5 PARTIAL (see BLIND-A-2) |
| Morpho V2 shares | YES | TF-3, CS-3, OZ-3 | D1 (TF-3), D2 (CS-3, OZ-3), D3 (gate blocks) | D4 N/A, D5 (yield compounding — by design) |
| Payout token from insurance | YES | TF-6 (positive), TF-4, TF-5 | D1 (TF-6 balance-diff), D2 (TF-4 slippage), D3 (policy gate) | D4 N/A, D5 PARTIAL |
| Collateral tokens | YES | TF-5 | D2 (TF-5 fee-on-transfer) | D3, D4, D5 — out of scope (ClaimManager) |

### R11 Dimension Coverage Gate

| External Token | R11-D1: Transferability | R11-D2: Accounting | R11-D3: Op Blocking | R11-D4: Loop/Gas | R11-D5: Side Effects | Dimensions Covered |
|----------------|------------------------|--------------------:|--------------------:|-----------------|---------------------|-------------------|
| Underlying asset | ✓ TF-3 | ✓ CS-2, PC1-1 | ✓ TF-7 | N/A | PARTIAL (see BLIND-A-2) | 3/5 applicable |
| Morpho V2 shares | ✓ TF-3 | ✓ CS-3, OZ-3 | ✓ gate | N/A | covered (try/catch design) | 4/4 applicable |

**PARTIAL BLIND SPOT**: Underlying asset D5 — `collectPremium()` transfer to `premiumRecipient` has no protection if recipient cannot receive ERC-20 tokens (blocklisted in USDC, contract without ERC-20 receive, etc.). See BLIND-A-2.

---

## CHECK 2: Governance-Changeable Parameter Coverage

| Parameter | Setter Function | Can Affect Active Operations? | Analyzed by Agent? | Finding ID |
|-----------|----------------|-------------------------------|-------------------|------------|
| premiumRatePerSecond | setPremiumRate / executePremiumRate | YES — affects all ongoing accruals | YES | CS-4 (retroactive increase harms users) |
| maxCoverableLossBps | setMaxCoverableLossBps / executeMaxCoverableLossBps | YES — changes insurance cap and depositCap | PARTIAL | CS-5 (retroactive); BLIND-A-1 (depositCap decrease direction) |
| deductibleBps | setDeductibleBps / executeDeductibleBps | YES — changes deductible on all future claims | YES | CS-5 |
| premiumRecipient | setPremiumRecipient / executePremiumRecipient | YES — redirects pending + future premium | PARTIAL | BLIND-A-2 (recipient blocking) |
| morphoGateActive | setMorphoGateActive | YES — pauses accrual, extends grace period | YES | CS-1, AC-4, PC1-4 |
| depositCap (derived) | via executeMaxCoverableLossBps / onPolicyBound | YES — gates new deposits | PARTIAL | CS-9 (reopening); BLIND-A-1 |

### Rule 13 Bidirectional Analysis

**`maxCoverableLossBps` DECREASE**: Less coverage for users → harms users. Covered by CS-5.
**`maxCoverableLossBps` INCREASE**: More coverage for users → reduces `depositCap` → may block new deposits. NOT COVERED. → **BLIND-A-1**

**`premiumRatePerSecond` INCREASE**: Harms users (pay more). Covered by CS-4.
**`premiumRatePerSecond` DECREASE to 0**: Premium stops. Existing liability persists. No operational harm to users.

**`deductibleBps` INCREASE**: Users absorb more loss before insurance kicks in → harms users. Covered by CS-5.
**`deductibleBps` DECREASE**: Better coverage for users. No harm.

**`premiumRecipient` change**: Redirects future premiums. If new recipient cannot receive ERC-20 (blocklisted/non-receiver contract), `collectPremium()` is permanently DOSed. → **BLIND-A-2** (though `pendingPremium` recovery exists via owner changing the recipient again)

## CHECK 2b: Native Value in Loops

No `msg.value` usage in scope contracts. N/A.

## CHECK 2c: Unbounded Return Data (returnbomb)

| External Call Site | Return Data Bounded? | Copy Method | Gap? |
|-------------------|---------------------|-------------|------|
| `try claimManager.fileClaim(...)` (CoveredVaultWrapper.sol:365) | NO — bare `catch {}` | EVM copies `returndatasize()` bytes | LOW risk — ClaimManager is SEMI_TRUSTED; unbounded revert data could inflate gas cost |

No new finding warranted — ClaimManager is SEMI_TRUSTED; CompromisedClaimManager can cause full protocol failures anyway.

## CHECK 2d: Relay/Meta-tx Gas Griefing

No relay functions in scope contracts. N/A.

---

## Findings

---

## Finding [BLIND-A-1]: maxCoverableLossBps Increase Silently Reduces depositCap Below totalPrincipal, Blocking All New Deposits

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4 | ✗5(informational impact only)
**Rules Applied**: [R13:✓, R14:✓, R10:✓, R4:✗(clear), R5:✓, R6:✓, R8:✗(single-step execute), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:maxCoverableLossBps 1000→5000 with totalPrincipal=8000, coverageLimit=1000 → depositCap=2000 → maxDeposit()=0], [TRACE:executeMaxCoverableLossBps() → depositCap = coverageLimit*10000/newBps < totalPrincipal → maxDeposit() returns 0 until withdrawals reduce totalPrincipal]
**Severity**: Low
**Location**: CoveredVaultAdmin.sol:57-69 (`executeMaxCoverableLossBps`), CoveredVaultWrapper.sol:467-469 (`maxDeposit`)

**Description**:
When the owner increases `maxCoverableLossBps` (providing more insurance coverage per unit of deposit), `depositCap` is recomputed via `depositCap = coverageLimit * BPS_DENOMINATOR / maxCoverableLossBps`. Since `depositCap` is inversely proportional to `maxCoverableLossBps`, an increase in the coverage percentage causes a proportional decrease in the maximum TVL the vault can accept.

If the new `depositCap < totalPrincipal` (existing deposits exceed the new cap), then `maxDeposit()` returns 0 immediately after `executeMaxCoverableLossBps()` executes. This is a silent state change: ERC-4626 integrators, aggregators, and on-chain strategies monitoring `maxDeposit()` would see a sudden drop from a positive value to 0 without any explicit "cap reached" event.

```solidity
// CoveredVaultAdmin.sol:57-68
function executeMaxCoverableLossBps() external override onlyOwner {
    _requireTimelockReady(pendingMaxCoverableLossTimestamp);
    uint16 newBps = pendingMaxCoverableLossBps;
    require(newBps > deductibleBps, IA.InvalidMaxCoverableLoss());
    ...
    if (policyBoundExecuted) {
        depositCap = (coverageLimit * BPS_DENOMINATOR) / uint256(newBps);  // decreases if newBps > oldBps
    }
    maxCoverableLossBps = newBps;
    ...
}

// CoveredVaultWrapper.sol:467-469
function maxDeposit(address) public view override ... {
    if (!policyBoundExecuted) return 0;
    return depositCap > totalPrincipal ? depositCap - totalPrincipal : 0;  // returns 0 when depositCap < totalPrincipal
}
```

**Concrete example**: `coverageLimit = 1,000,000 USDC`, `maxCoverableLossBps = 1000 (10%)` → `depositCap = 10,000,000`. With `totalPrincipal = 8,000,000`, `maxDeposit = 2,000,000`.
Owner increases to `maxCoverableLossBps = 5000 (50%)` → `depositCap = 2,000,000`. Since `totalPrincipal = 8,000,000 > depositCap = 2,000,000`, `maxDeposit() = 0`. All new deposits blocked instantly.

**Impact**:
- New depositors cannot add positions until existing users withdraw to reduce `totalPrincipal` below the new `depositCap`.
- ERC-4626 integrators that cache or rely on `maxDeposit()` > 0 would silently fail on `deposit()` calls with `ERC4626ExceededMaxDeposit` error.
- Yield aggregators and vault routers that query `maxDeposit()` for position-building would route capital elsewhere, potentially causing unintended TVL reduction.
- No event emitted that explicitly signals "deposits now blocked" — only the `MaxCoverableLossBpsExecuted` event is emitted, which does not alert consumers to the deposit cap consequence.
- **Why breadth agents missed this**: CS-9 covers the `depositCap` reopening direction (after withdrawals). CS-5 covers retroactive impact on insurance terms. Neither covers the specific harm direction to NEW depositors from the maxCoverableLossBps INCREASE path.

**Evidence**:
```solidity
// depositCap formula: inversely proportional to maxCoverableLossBps
depositCap = (coverageLimit * BPS_DENOMINATOR) / uint256(newBps);  // CoveredVaultAdmin.sol:63
// maxDeposit uses depositCap directly
return depositCap > totalPrincipal ? depositCap - totalPrincipal : 0;  // CoveredVaultWrapper.sol:469
```

### Postcondition Analysis
**Postconditions Created**: `maxDeposit() == 0`, `maxMint() == 0`; new deposits revert with `ERC4626ExceededMaxDeposit`
**Postcondition Types**: [STATE]
**Who Benefits**: Nobody — this is an operational disruption; owner can recover by decreasing `maxCoverableLossBps` back or by waiting for existing users to withdraw

---

## Finding [BLIND-A-2]: pendingPremium Stuck When premiumRecipient Cannot Accept ERC-20 Transfers — No Rescue Path

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4 | ✗5(no role required)
**Rules Applied**: [R13:✓, R10:✓, R4:✗(clear), R5:✗(single flow), R6:✓, R8:✓, R11:✓, R12:✓, R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:collectPremium() → safeTransfer(premiumRecipient, pending) revert → pendingPremium not cleared → accumulates permanently], [BOUNDARY:premiumRecipient=blocklisted address → all collectPremium() calls revert], [VARIATION:rescueTokens(asset, x, to) → require(amount <= balance - pendingPremium) → 0 sweepable (pendingPremium cannot be rescued)]
**Severity**: Low
**Location**: CoveredVaultAccrual.sol:70-78 (`collectPremium`), CoveredVaultAdmin.sol:196-213 (`rescueTokens`)

**Description**:
`collectPremium()` transfers all accumulated `pendingPremium` (underlying asset) to `premiumRecipient` via `IERC20(asset()).safeTransfer(premiumRecipient, pending)`. If `premiumRecipient` cannot accept ERC-20 transfers — for example, if the underlying asset is USDC and the recipient is a USDC-blocklisted address, or if the recipient is a contract that reverts on token receipt — `safeTransfer` reverts and `pendingPremium` is never cleared.

The `rescueTokens` function explicitly PROTECTS `pendingPremium` from being swept:

```solidity
// CoveredVaultAdmin.sol:198-204
if (token == asset()) {
    uint256 balance = IERC20(token).balanceOf(address(this));
    uint256 reserved = pendingPremium;
    uint256 sweepable = balance >= reserved ? balance - reserved : 0;
    require(amount <= sweepable, IA.InvalidParameters());
}
```

This means `pendingPremium` is both (a) unclaimable (recipient reverts) and (b) unrescuable (explicitly reserved). The funds are effectively locked in the vault until the `premiumRecipient` is changed via `executePremiumRecipient()` — a 2-day timelock.

During the 2-day recovery window:
1. `pendingPremium` accumulates further from each user withdrawal.
2. `collectPremium()` reverts on every call.
3. Premium owed to the protocol accumulates in the vault without being forwarded.

**Important**: The `premiumRecipient` validation at `setPremiumRecipient()` only checks `newRecipient != address(0)`. No check verifies the address can receive the token.

```solidity
// CoveredVaultAdmin.sol:92-97
function setPremiumRecipient(address newRecipient) external override onlyOwner {
    require(newRecipient != address(0), IA.ZeroAddress());  // only zero check
    ...
}
```

**Impact**:
- `pendingPremium` (protocol revenue) accumulates in the vault and cannot be forwarded to the premium recipient for up to 2 days (timelock on recipient change).
- During the blockage window, no premiums flow to the protocol's revenue address.
- If the underlying asset is a regulated token like USDC with account blocklisting, an address can become blocked after being set as `premiumRecipient` without the vault owner's knowledge, creating an unexpected operational disruption.
- The reserved protection in `rescueTokens` (which prevents sweeping `pendingPremium` as emergency rescue) means there is no fast-path recovery — only the 2-day `executePremiumRecipient()` path.
- Existing user withdrawals are NOT affected — they still work normally. Only protocol revenue collection is blocked.
- **Why breadth agents missed this**: R11-D5 (ERC-20 side effects) for the underlying asset was not fully analyzed for the `collectPremium()` path. Token-level risks (blocklisting) on the recipient were not evaluated against the missing `rescueTokens` emergency path.

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:70-77
function collectPremium() external override nonReentrant {
    _accruePremium();
    uint256 pending = pendingPremium;
    if (pending > 0) {
        pendingPremium = 0;
        IERC20(asset()).safeTransfer(premiumRecipient, pending);  // REVERTS if recipient can't receive
        emit IE.PremiumCollected(premiumRecipient, pending);
    }
}
```

### Precondition Analysis
**Missing Precondition**: `premiumRecipient` must be able to receive the underlying ERC-20 token
**Precondition Type**: EXTERNAL
**Why This Blocks**: USDC blocklisting or contract recipient without `receive` logic causes `safeTransfer` revert

### Postcondition Analysis
**Postconditions Created**: `pendingPremium` is non-zero and unclaimable; all calls to `collectPremium()` revert; protocol revenue stuck for up to 2-day recovery window
**Postcondition Types**: [STATE, EXTERNAL]
**Who Benefits**: Nobody — pure operational disruption with 2-day recovery window

---

## Finding [BLIND-A-3]: Missing Validation of Policy Start Time — Vault Can Accrue Premium Before Policy Starts

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4 | ✗5(catch-up prevention exists for future deposits)
**Rules Applied**: [R13:✓, R10:✓, R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:lastPremiumAccrualTime < meta.startTime AND block.timestamp < meta.startTime → _activeElapsedFrom returns full block.timestamp - lastPremiumAccrualTime in _isPolicyActive branch], [BOUNDARY:policy not yet started (block.timestamp < startTime) → _isPolicyActive() returns false], [VARIATION:_isPolicyActive branch vs catch-up branch in _activeElapsedFrom]
**Severity**: Low
**Location**: CoveredVaultAccrual.sol:116-136 (`_activeElapsedFrom`), CoveredVaultAccrual.sol:153-159 (`_isPolicyActive`)

**Description**:
`_activeElapsedFrom()` selects between two paths:
1. If `_isPolicyActive()` → returns `block.timestamp - checkpoint` (full elapsed window)
2. If `policyId != 0` and policy expired → returns `effectiveMaturity - activeStart` (catch-up window)

`_isPolicyActive()` returns `true` only if `block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity`. Before the policy starts (`block.timestamp < startTime`), `_isPolicyActive()` returns `false`.

However, the catch-up branch (path 2) in `_activeElapsedFrom` does check `block.timestamp >= uint256(meta.startTime)` at line 127:

```solidity
// CoveredVaultAccrual.sol:125-133
if (
    meta.buyer != address(0) && effectiveMaturity > checkpoint && block.timestamp >= uint256(meta.startTime)
) {
    uint256 activeStart = checkpoint > uint256(meta.startTime) ? checkpoint : uint256(meta.startTime);
    if (effectiveMaturity > activeStart) {
        return effectiveMaturity - activeStart;
    }
}
```

This correctly gates the catch-up branch. However, PC1-2 already covers the stale catch-up window when `lastPremiumAccrualTime` predates policy start. The specific scenario for this finding is different: what happens if `_accruePremium()` is called EXACTLY at `block.timestamp == startTime`?

At `block.timestamp == startTime`:
- `_isPolicyActive()` checks `block.timestamp >= metadata.startTime` → TRUE
- Returns path 1: `block.timestamp - checkpoint = startTime - checkpoint`

If `checkpoint < startTime` (last accrual was before the policy started), this returns an elapsed window that includes the pre-policy period. However, `_isPolicyActive()` returning true means the policy IS active, and the elapsed window since `checkpoint` would be computed from `checkpoint`, not from `startTime`.

So if `checkpoint = T0 < startTime = T1` and `_accruePremium()` is called at `T1`:
- `elapsed = T1 - T0` (includes pre-start period)
- But no premium should have accrued during `[T0, T1)`

This is the same finding as PC1-2 (phantom premium for pre-policy period). Checking coverage: PC1-2 is "Low - _activeElapsedFrom Returns Stale Catch-Up Window When lastPremiumAccrualTime Predates Policy Start". This covers the case where `_isPolicyActive() = false` (expired policy path).

But **what about when `_isPolicyActive() = true`?** At the exact moment `block.timestamp == startTime`, path 1 fires: `elapsed = block.timestamp - checkpoint = startTime - T0`. If `T0 < startTime`, this elapsed period includes the pre-policy gap, and premium DOES accrue for that gap via path 1. This is the bug: **the active-policy path does not clamp `checkpoint` to `max(checkpoint, startTime)`**.

The catch-up path correctly uses `activeStart = max(checkpoint, startTime)`, but the active path uses raw `checkpoint`.

**Impact**:
- Users who deposit before the policy starts (`lastPremiumAccrualTime` set to deposit time < `startTime`) will accrue premium for the pre-policy gap when the policy first becomes active.
- The phantom premium is bounded: at most `startTime - lastDeposit` seconds × `premiumRatePerSecond` — for a policy that starts shortly after deposit, this is small.
- No insurance coverage exists for this phantom premium (premium accrues without coverage).
- **Partial because** the pre-policy accrual only happens on the FIRST `_accruePremium()` call after the policy starts (thereafter `checkpoint = lastPremiumAccrualTime >= startTime`). The exposure window is `[lastPremiumAccrualTime, startTime)` — at most the period between the last interaction and policy start.
- **Why breadth agents missed this**: PC1-2 covers the expired-policy catch-up path (`_isPolicyActive() = false`). The active-policy path (`_isPolicyActive() = true`) with a stale checkpoint was not analyzed as a separate scenario.

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:116-118 — active path does NOT clamp to startTime
function _activeElapsedFrom(uint256 checkpoint) internal view returns (uint256) {
    if (_isPolicyActive()) {
        return block.timestamp - checkpoint;  // uses raw checkpoint, not max(checkpoint, startTime)
    }
    // ... catch-up path correctly clamps to max(checkpoint, startTime)
    uint256 activeStart = checkpoint > uint256(meta.startTime) ? checkpoint : uint256(meta.startTime);
}
```

### Precondition Analysis
**Missing Precondition**: `lastPremiumAccrualTime >= startTime` required for no phantom pre-policy premium
**Precondition Type**: STATE / TIMING
**Why This Blocks**: The active path fires at the exact moment `block.timestamp == startTime`, using the full elapsed since last checkpoint without clamping to startTime

---

## Finding [BLIND-A-4]: acceptOwnership Clears Timelock Timestamps But Not Pending Values — Stale Pending State Invisible to New Owner

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4 | ✗5(low exploitability — no financial harm)
**Rules Applied**: [R13:✓, R10:✓, R4:✗(clear), R5:✗(single entity), R6:✓, R8:✓, R12:✗(no dangerous precondition), R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:acceptOwnership() → clears timestamps to 0 → execute* reverts NoPendingChange → stale pending values persist in storage], [BOUNDARY:pendingPremiumRate storage = MAX_PREMIUM_RATE_PER_SECOND after old-owner's setPremiumRate call + acceptOwnership by new owner → stale value in storage but unexecutable], [VARIATION:new owner calls setPremiumRate(X) → pendingPremiumRate = X overwrites stale value → safe recovery]
**Severity**: Informational
**Location**: CoveredVaultAdmin.sol:116-124 (`acceptOwnership`)

**Description**:
When ownership is transferred via `acceptOwnership()`, all pending timelock timestamps are cleared to 0:

```solidity
// CoveredVaultAdmin.sol:116-124
function acceptOwnership() public override {
    super.acceptOwnership();
    pendingPremiumRateTimestamp = 0;
    pendingDeductibleTimestamp = 0;
    pendingMaxCoverableLossTimestamp = 0;
    pendingUpgradeTimestamp = 0;
    pendingImplementation = address(0);  // only this pending VALUE is also cleared
    pendingPremiumRecipientTimestamp = 0;
}
```

However, the following pending VALUES are NOT cleared:
- `pendingPremiumRate` — retains old owner's proposed rate
- `pendingDeductibleBps` — retains old owner's proposed deductible
- `pendingMaxCoverableLossBps` — retains old owner's proposed coverage BPS
- `pendingPremiumRecipient` — retains old owner's proposed recipient

Since `execute*` functions first check `_requireTimelockReady(timestamp)` and `timestamp == 0` reverts with `NoPendingChange`, these stale pending values cannot be executed. However, they remain visible in public storage variables (`pendingDeductibleBps`, `pendingPremiumRecipient`, etc.) and may mislead:
- Off-chain monitoring tools that read pending state from storage
- New owners inspecting contract state during governance handover
- Auditors reviewing the contract post-transfer

The only exception is `pendingImplementation` which IS cleared (set to `address(0)`) because the `_authorizeUpgrade` check reads `newImplementation == pendingImplementation` — if this persisted, a new owner could potentially execute a pre-approved upgrade from the old owner's era by calling `executeUpgrade()`. However, since `pendingUpgradeTimestamp = 0`, this path is blocked.

**Impact**:
- Storage contains stale pending values from the previous owner that will never be executed.
- A new owner may be confused by non-zero `pendingPremiumRate` or `pendingPremiumRecipient` in storage while seeing NoPendingChange on execute calls.
- Off-chain monitoring and governance tooling may display "pending parameter changes" that don't actually apply.
- **No financial harm** — the stale values cannot be executed due to timestamp = 0.
- Recovery: the new owner's first `set*` call overwrites the stale pending value.
- **Partially by design**: `pendingImplementation` is correctly cleared because it creates an additional authorization check. The other values were seemingly overlooked.
- **Why breadth agents missed this**: AC-7 covers ownership transfer as a positive finding (timelocks cleared, two-step ownership). The storage hygiene gap (pending values not cleared) was not analyzed as a separate concern.

**Evidence**:
```solidity
// Not cleared on acceptOwnership():
uint256 public override pendingPremiumRate;     // CoveredVaultStorage.sol:148
uint16 public pendingDeductibleBps;             // CoveredVaultStorage.sol:127
uint16 public pendingMaxCoverableLossBps;       // CoveredVaultStorage.sol:132
address public pendingPremiumRecipient;         // CoveredVaultStorage.sol:153
```

### Precondition Analysis
**Missing Precondition**: Pending values require clearance on ownership transfer to maintain consistent state
**Precondition Type**: STATE
**Why This Blocks**: Timestamp = 0 prevents execution, but stale values remain in storage

---

## Finding [BLIND-A-5]: _activeElapsedFrom Checks _isPolicyActive() Twice Per Accrual Cycle — External Call Duplication Increases DoS Surface

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3 | ✗4(gas cost), ✗5(informational — gas/architecture)
**Rules Applied**: [R13:✗(not design), R10:✓, R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:_accruePremium() → _activeElapsedFrom(checkpoint) → _isPolicyActive() [external call 1] → returns elapsed; separately _accruedPremiumFor() → _activeElapsedFrom() → _isPolicyActive() [external call 2] within same totalAssets() call]
**Severity**: Informational
**Location**: CoveredVaultAccrual.sol:41 (`_accruePremium`), CoveredVaultAccrual.sol:95-103 (`_accruedPremiumFor`), CoveredVaultAccrual.sol:116-136 (`_activeElapsedFrom`), CoveredVaultAccrual.sol:153-159 (`_isPolicyActive`)

**Description**:
`_isPolicyActive()` makes an external call to `_policyManager.policyMetadata(policyId)` every time it is invoked. `_activeElapsedFrom()` calls `_isPolicyActive()` internally. Each invocation of `totalAssets()` results in TWO separate external calls to `PolicyManager`:

1. `totalAssets()` → `_accruedPremiumFor()` → `_activeElapsedFrom()` → `_isPolicyActive()` → `policyManager.policyMetadata()`
2. If policy not active: `_activeElapsedFrom()` → `_policyManager.policyMetadata()` (catch-up branch)

Additionally, within a single deposit or withdrawal transaction, `_accruePremium()` calls `_activeElapsedFrom()` (which may call `policyMetadata()` twice — once via `_isPolicyActive()` and once in the catch-up branch). Then `_settleWithdrawalTransfer` → `_computeInsurance` → `_isPolicyActive()` calls it AGAIN.

The `totalAssets()` function (called from ERC-4626 share price calculations, previews, and OZ base) triggers these external calls on every view operation. Since OZ-6 already notes "external call on every deposit/withdraw," this finding extends that to view calls that integrators would run frequently.

**Impact**:
- If `PolicyManager` is unavailable (DoS or paused), ALL calls to `totalAssets()`, `previewDeposit()`, `previewWithdraw()`, `previewRedeem()`, `maxWithdraw()`, `maxRedeem()`, `userShortfall()`, `calculateShortfall()` that trigger `_accruedPremiumFor()` will fail.
- The actual deposit/withdraw path has explicit `try/catch` on `fileClaim` and `Morpho.redeem`, but NOT on `_isPolicyActive()`. A PolicyManager DoS would break ALL view functions AND the actual `_accruePremium()` call within `_deposit`/`_withdraw`.
- TF-7 covers `_accruePremium` blocking deposits/withdrawals when PolicyManager is unavailable — this finding confirms the same DoS also affects ALL view functions.
- This extends the TF-7 blast radius to read-only monitoring: off-chain scripts, front-ends, and aggregators would all see reverts on `totalAssets()` during PolicyManager downtime.
- **Why breadth agents missed this**: OZ-6 focused on gas cost. TF-7 focused on deposit/withdrawal blocking. Neither identified the cross-contamination of PolicyManager DoS into view functions via `_accruedPremiumFor()`.

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:106-110 — totalAssets calls _accruedPremiumFor
function totalAssets() public view override ... {
    uint256 mv = _morphoValue();
    uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);  // external call chain
    return mv > totalLiability ? mv - totalLiability : 0;
}

// CoveredVaultAccrual.sol:95-103 — _accruedPremiumFor calls _activeElapsedFrom
function _accruedPremiumFor(uint256 morphoVal) internal view returns (uint256) {
    ...
    uint256 elapsed = _activeElapsedFrom(lastPremiumAccrualTime);  // may call policyMetadata()
    ...
}

// CoveredVaultAccrual.sol:116-118 — _activeElapsedFrom calls _isPolicyActive
function _activeElapsedFrom(uint256 checkpoint) internal view returns (uint256) {
    if (_isPolicyActive()) {  // external call to PolicyManager
        return block.timestamp - checkpoint;
    }
    if (policyId != 0) {
        IPolicyManager.PolicyMetadata memory meta = _policyManager.policyMetadata(policyId);  // 2nd external call
        ...
    }
}
```

---

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|--------------------:|---------|----------|-------------------|-------------------|
| BLIND-A-1 | CoveredVaultAdmin.sol:57-69, CoveredVaultWrapper.sol:467-469 | maxCoverableLossBps increase reduces depositCap below totalPrincipal, blocking all new deposits | CONFIRMED | Low | STATE | STATE (maxDeposit=0) |
| BLIND-A-2 | CoveredVaultAccrual.sol:70-78, CoveredVaultAdmin.sol:196-213 | premiumRecipient receiving blocked ERC-20 (e.g., USDC blocklist) causes pendingPremium lockup with no fast rescue path | CONFIRMED | Low | EXTERNAL | STATE (stuck premium, 2d recovery) |
| BLIND-A-3 | CoveredVaultAccrual.sol:116-136 | Active policy path in _activeElapsedFrom does not clamp checkpoint to startTime, causing phantom pre-start premium accrual | PARTIAL | Low | STATE / TIMING | STATE (overcollected premium) |
| BLIND-A-4 | CoveredVaultAdmin.sol:116-124 | acceptOwnership clears timestamps but not pending values, leaving stale state visible in storage | PARTIAL | Informational | STATE | STATE (stale storage, no execution risk) |
| BLIND-A-5 | CoveredVaultAccrual.sol:116-136, CoveredVaultWrapper.sol:106-110 | _activeElapsedFrom calls _isPolicyActive() twice per call path, extending PolicyManager DoS blast radius to all view functions | CONFIRMED | Informational | EXTERNAL | STATE (all view functions break on PolicyManager DoS) |

---

DONE: 5 blind spots — Check1: 2 token gaps (underlying asset D5 partial, payout token extended blast radius), Check2: 3 parameter gaps (maxCoverableLossBps increase direction, premiumRecipient blocking, pending state hygiene)
