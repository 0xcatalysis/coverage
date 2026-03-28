## High Findings

### [H-01] gateGracePeriod Renders Grace Window Fully Uninsured While Premium Accrues [VERIFIED]

**Severity**: High
**Location**: `CoveredVaultAccrual.sol:L153-159`, `ClaimManager.sol:L306-308`
**Confidence**: HIGH (3 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

The Morpho gate mechanism introduces a maturity desync between the CoveredVaultWrapper (which extends the policy window via `gateGracePeriod`) and the ClaimManager (which enforces the raw `maturityTime`). When the Morpho gate is activated and later deactivated, `gateGracePeriod` accumulates, extending `effectiveMaturity` used by `_isPolicyActive()`. Premium continues accruing during this extended window because the vault considers the policy active. However, the ClaimManager enforces the raw `maturityTime` from PolicyManager metadata, rejecting all claims filed after that timestamp.

In `CoveredVaultAccrual._isPolicyActive()`, the effective maturity includes the grace period:

```solidity
function _isPolicyActive() internal view returns (bool) {
    if (policyId == 0) return false;
    IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
    uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
    return
        metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
}
```

But `ClaimManager._fileClaimWithMetadata()` enforces the raw maturity:

```solidity
require(
    block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime,
    ClaimOutsideCoverageWindow(policyId, metadata.startTime, metadata.maturityTime, uint32(block.timestamp))
);
```

During the grace window (between `maturityTime` and `effectiveMaturity`), users pay premium but cannot file claims. This constitutes payment for insurance coverage that does not exist.

**Impact**:

Users lose all premium accrued during the grace window with zero corresponding insurance coverage. With the unbounded accumulation described in M-01, this window can extend to arbitrary durations, multiplying the premium loss. In the verified PoC, 30 days of uninsured premium accrual was demonstrated at a rate of approximately 1000 ether. A Morpho loss event during this window leaves users with no recourse -- they cannot file claims, yet they have been paying for insurance.

**PoC Result**:

```
[PASS] test_H1_gracePeriodInsuranceGap() (gas: 227795)
  Raw maturityTime: 3592000
  effectiveMaturity: 4196800
  Current time: 3678400
  _isPolicyActive (vault logic): true
  ClaimManager window check: false
  Premium accruing: true
  Claims accepted: false
```

The test mechanically proves the desync: `_isPolicyActive()` returns `true` (premium accrues) while the ClaimManager's window check returns `false` (claims rejected) during the grace period.

**Recommendation**:

Either (a) clamp `effectiveMaturity` to raw `maturityTime` for premium accrual purposes so users do not pay premium during the grace window, or (b) pass `effectiveMaturity` to the ClaimManager so that claims are accepted during the grace window, ensuring users receive insurance for the premium they pay.

---

### [H-02] UniswapV3Adapter Fee-Tier Desync Between Quote and Swap [VERIFIED]

**Severity**: High
**Location**: `UniswapV3Adapter.sol:L116-120, L127-133, L155-161, L193-199`, `Swapper.sol:L164-171`
**Confidence**: HIGH (3 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

The `UniswapV3Adapter` uses two separate sources of truth for the Uniswap V3 fee tier: the `pairFees` mapping (for quoting) and the stored route calldata (for swapping). When an admin calls `setPairFee()` to migrate to a different fee tier, the `pairFees` mapping is updated but the stored swap route calldata in the Swapper contract is not. This creates a fee-tier desync between the quote and swap execution paths.

The `quote()` function reads the fee from the live `pairFees` mapping:

```solidity
function quote(address tokenIn, address tokenOut, uint256 amountIn) external override returns (uint256 amountOut) {
    uint24 fee = _getFee(tokenIn, tokenOut);  // reads pairFees mapping
    (amountOut,,,) = QUOTER.quoteExactInputSingle(
        IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
        })
    );
}
```

The `swap()` function receives the fee as a parameter from stored calldata:

```solidity
function swap(
    address tokenIn,
    address tokenOut,
    uint24 fee,          // from stored calldata, frozen at setSwapRoute time
    uint256 amountOutMinimum
) ...
```

After `setPairFee(tokenA, tokenB, 500)`, `quote()` uses fee=500 (new pool) while `swap()` still uses fee=3000 (old pool from stored calldata). This leads to two attack scenarios:

1. **DoS**: If the old fee-tier pool has been drained of liquidity after migration, swaps revert, permanently blocking all claim payouts.
2. **Slippage/MEV**: If the old pool has poor liquidity, swap execution is significantly worse than what the quote predicted, enabling MEV sandwich extraction (see H-03).

**Impact**:

Insurance claim payouts can be permanently blocked (DoS) or suffer significant value extraction via MEV sandwich attacks. Since `setPairFee` and `setSwapRoute` are separate calls on separate contracts with potentially different admin roles, there is no atomic mechanism to update both simultaneously, making the desync window unavoidable.

**PoC Result**:

```
[PASS] test_H5_feeTierDesync() (gas: 375624)
  Initial quote result: 1000
  Fee changed to: 500
  Quote uses fee from pairFees: 500
  Swap uses fee from calldata: 3000
  Desync confirmed: true
```

**Recommendation**:

Store the fee tier alongside the route calldata and update both atomically when either changes. Alternatively, have the `swap()` path read `pairFees` directly (via `_getFee`) instead of relying on the fee encoded in stored calldata.

---

### [H-03] Fee-Tier Desync Enables Deterministic Sandwich on Claim Payout [VERIFIED]

**Severity**: High
**Location**: `ClaimManager.sol:L638-667`, `UniswapV3Adapter.sol:L116-120, L127-133`
**Confidence**: HIGH (2 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

This finding describes a multi-step attack chain where the fee-tier desync from H-02 creates a deterministic path to near-total MEV extraction on insurance claim payouts.

The `ClaimManager._executeCollateralSwap()` function initializes `amountOutMin` to 1 and attempts to get a quote via the Swapper. If the quote reverts, the empty `catch` block leaves `amountOutMin` at 1 -- providing zero slippage protection:

```solidity
uint256 amountOutMin = 1;
try ISwapper(swapper).quoteSwap(collateralToken, payoutToken, collateralAmount) returns (uint256 quoted) {
    if (quoted > 0) {
        amountOutMin = quoted * (10_000 - maxSwapSlippageBps) / 10_000;
        if (amountOutMin == 0) {
            amountOutMin = 1;
        }
    }
} catch {}  // amountOutMin remains 1 on revert
```

The complete attack sequence:

1. Admin calls `setPairFee(tokenA, tokenB, 500)` to migrate to a new fee tier on `UniswapV3Adapter`. The route calldata in Swapper still encodes `fee=3000`.
2. A user files an insurance claim. `ClaimManager._executeCollateralSwap` calls `Swapper.quoteSwap()`, which internally calls `UniswapV3Adapter.quote()` with `fee=500` (from the live `pairFees` mapping).
3. If the fee=500 pool has insufficient liquidity, the QuoterV2 call reverts. The `quoteSwap` try/catch catches the revert and returns 0.
4. `amountOutMin` is set to `max(0, 1) = 1`.
5. A MEV bot observes the pending swap with `amountOutMin=1` and sandwiches it, extracting nearly all claim proceeds.
6. The claimant receives approximately 1 wei instead of their expected insurance payout.

This chain is particularly dangerous because H-02's desync creates a *deterministic* path to quote failure -- the admin action of calling `setPairFee` without simultaneously updating the route calldata is sufficient to trigger the entire chain.

**Impact**:

Near-total loss of insurance claim payout value to MEV extraction. Any claimant filing during the desync window loses nearly their entire insurance payment. For a meaningful claim (e.g., 100 ETH coverage), the claimant would receive approximately 1 wei while MEV bots extract the rest.

**PoC Result**:

```
[PASS] test_CH2_feeTierDesyncBetweenQuoteAndSwap() (gas: 925511)
  Step 3: Verified pairFees[key] = 500
  Step 4: Fee in stored route calldata: 3000
  Step 4: Fee used by quote (live pairFees): 500
  === CONFIRMED: Fee desync exists ===
  Step 5: Quote reverts for fee=500 (no liquidity)
  Step 6: amountOutMin = 1 (enables sandwich)
```

**Recommendation**:

1. Fix the fee-tier desync (see H-02 recommendation) to eliminate the deterministic path to quote failure.
2. In `_executeCollateralSwap`, revert the claim if `quoteSwap` returns 0 rather than proceeding with `amountOutMin=1`. Alternatively, implement a configurable minimum floor based on the expected claim payout amount (e.g., requiring at least 90% of the oracle-estimated value).

---

## Medium Findings (Critical+High Tier)

### [M-01] Unbounded gateGracePeriod Accumulation via Repeated Gate Toggles [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultAdmin.sol:L168-186`
**Confidence**: HIGH (2 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

The `setMorphoGateActive()` function in `CoveredVaultAdmin` accumulates `gateGracePeriod` on every gate deactivation cycle with no upper bound. Each `true -> false` toggle adds the full gate duration to `gateGracePeriod`:

```solidity
function setMorphoGateActive(bool active) external override onlyOwner {
    _accruePremium();
    if (active && !morphoGateActive) {
        gateActivatedAt = block.timestamp;
        // ... cache Morpho value
    } else if (!active && morphoGateActive && gateActivatedAt > 0) {
        uint256 gateDuration = block.timestamp - gateActivatedAt;
        gateGracePeriod += gateDuration;  // no cap
        gateActivatedAt = 0;
    }
    morphoGateActive = active;
    emit IE.MorphoGateStatusUpdated(active);
}
```

Over multiple legitimate gate activations (responding to real Morpho issues), `gateGracePeriod` grows unboundedly. This directly amplifies H-01 by extending the uninsured grace window to arbitrary durations.

**Impact**:

Three gate cycles of 30 days each create a 90-day uninsured grace window. The owner (semi-trusted) can deliberately or inadvertently accumulate this value, extending the period during which users pay premium without insurance coverage (see H-01). The owner can also exploit this to create an arbitrarily long post-maturity premium accrual period.

**PoC Result**:

```
[PASS] test_H2_unboundedGateGracePeriodAccumulation() (gas: 168492)
  gateGracePeriod after 3 x 1-day cycles: 259200

[PASS] testFuzz_H2_gracePeriodLinearlyAccumulates(uint8,uint32) (runs: 250)
```

The fuzz variant confirms linear accumulation with no cap across 250 runs with 1-10 cycles and 1-604800 second durations.

**Recommendation**:

Cap `gateGracePeriod` at a maximum value (e.g., 30 days) or reset it on each new activation instead of accumulating. Alternatively, limit the number of gate activation cycles per policy.

---

### [M-02] totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultWrapper.sol:L573-584`
**Confidence**: HIGH (6 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

When a user withdraws during a deep-loss event (where Morpho assets received are less than the premium owed), `totalPremiumLiability` is decremented by `premiumForWithdrawal` (capped at the actual assets received) rather than by the full `uncappedPremium` (the amount the user theoretically owed). The delta between these values remains permanently in `totalPremiumLiability` as a "phantom residual" that no remaining user actually owes:

```solidity
pendingPremium += premiumForWithdrawal;
// Decrement totalPremiumLiability by premiumForWithdrawal (actually collected) rather than
// a.uncappedPremium (intended amount). In deep-loss scenarios where assetsReceived < uncappedPremium,
// the forgiven delta was never collected into pendingPremium and should not reduce the liability tracker,
// otherwise totalAssets() is inflated for remaining holders by the forgiven amount.
totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal);
```

Since `totalAssets() = morphoValue - totalPremiumLiability - accruedPremium`, the phantom residual permanently depresses `totalAssets()` and the share price for all remaining holders.

This finding has multiple compounding impacts:

- **Retroactive parameter changes amplify the phantom**: If the owner reduces `maxCoverableLossBps` after a loss event but before withdrawals (see M-05), the insurance payout cap is lowered, meaning users receive even fewer assets. This widens the gap between `uncappedPremium` and `premiumForWithdrawal`, creating a larger phantom residual.
- **Grace window guarantees maximum phantom**: If a Morpho loss occurs during the uninsured grace window described in H-01, users cannot file insurance claims. Without insurance offset, `assetsReceived` is severely reduced while `uncappedPremium` remains the full accrued amount, creating the maximum possible phantom residual.
- **NAV deflation is permanent**: No mechanism exists to clear the phantom residual once created. It persists indefinitely, compounding across multiple deep-loss withdrawals.

**Impact**:

Permanent NAV deflation for remaining vault depositors. In the verified PoC with an 80% Morpho loss, a phantom residual of 73.97 ether was created (13.5% of the pre-withdrawal total premium liability), reducing `totalAssets()` to 12.05 ether for the remaining user. The phantom residual cannot be cleared without subsequent users overpaying premium.

**PoC Result**:

```
[PASS] test_H3_phantomLiabilityAfterDeepLossWithdrawal() (gas: 728997)
  totalPremiumLiability before loss: 547.95 ether
  Morpho value after 80% loss: 400 ether
  totalPremiumLiability after user1 withdraw: 347.95 ether
  User2 owed premium: 273.97 ether
  Phantom residual: 73.97 ether
  totalAssets after: 12.05 ether (deflated by phantom)

[PASS] testFuzz_phantomLiabilityOnLoss(uint8) (runs: 250)
```

**Recommendation**:

Decrement `totalPremiumLiability` by `uncappedPremium` (the full obligation) regardless of how much was actually collected from the withdrawal proceeds. Track the forgiven premium separately if needed for accounting purposes.

---

### [M-03] Excess Swap Output Permanently Stranded in ClaimManager [VERIFIED]

**Severity**: Medium
**Location**: `ClaimManager.sol:L663-667`
**Confidence**: HIGH (3 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

When collateral is swapped to the payout token during a claim settlement, the swap may produce more output than the `remainingPayout` required. In this case, only `remainingPayout` is transferred to the beneficiary, while the surplus remains locked in the ClaimManager contract:

```solidity
uint256 swapOutput =
    ISwapper(swapper).executeSwap{value: collateralToken == _NATIVE_ETH ? collateralAmount : 0}(swapParams);

amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput;
_transferToken(payoutToken, beneficiary, amountOut);
```

The ClaimManager has a `recoverTokens` function (line 169) that allows `DEFAULT_ADMIN_ROLE` holders to extract stranded tokens, so the funds are not permanently lost. However, the surplus rightfully belongs to the slashed vaults (which were over-slashed), not the admin. There is no mechanism to automatically return the surplus to the correct slashed vaults pro-rata.

**Impact**:

Vault stakers are over-slashed -- they give up more collateral value than the claim payout requires. The excess value accumulates in ClaimManager and requires manual admin intervention to recover. There is no guarantee the recovered funds are returned to the correct parties. Over multiple claims with favorable price movements, material value can accumulate.

**PoC Result**:

```
[PASS] test_H4_excessSwapOutputStranded() (gas: 680387)
  Requested payout: 100 ether
  Swap output: 150 ether
  Beneficiary received: 100 ether
  Stranded in ClaimManager: 50 ether
```

**Recommendation**:

Transfer the surplus (`swapOutput - remainingPayout`) back to the beneficiary (simplest), return to slashed vaults pro-rata (most accurate), or document the `recoverTokens` process with a requirement that recovered funds are returned to affected stakers.

---

### [M-04] Stale Unlimited Approval Persists on Old RewardsManager [VERIFIED]

**Severity**: Medium
**Location**: `PremiumManager.sol:L93-97`
**Confidence**: HIGH (2 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

When `PremiumManager.setRewardsManager()` is called to replace the `rewardsManager` address, it updates the storage pointer but does not revoke the unlimited ERC-20 approval previously granted to the old address. The old `rewardsManager` retains `type(uint256).max` allowance on the PremiumManager's token balance:

```solidity
function setRewardsManager(address rewardsManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(rewardsManager_ != address(0), ZeroAddress());
    rewardsManager = rewardsManager_;  // no approval revocation on old address
    emit RewardsManagerSet(rewardsManager_);
}
```

If the old `rewardsManager` contract is compromised or contains a vulnerability, it can call `transferFrom` to drain the PremiumManager's entire token balance.

**Impact**:

Complete drain of PremiumManager's token balance by a compromised old RewardsManager. The risk escalates with each `setRewardsManager` call, as each replaced contract retains unlimited approval. Severity is Medium because exploitation requires the old contract to be compromised.

**PoC Result**:

```
[PASS] test_H6_staleApprovalPersistsOnOldRewardsManager() (gas: 2258719)
  Old RM allowance after setRewardsManager: type(uint256).max  (unchanged)
```

**Recommendation**:

Revoke the approval on the old `rewardsManager` before setting the new one:

```solidity
function setRewardsManager(address rewardsManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(rewardsManager_ != address(0), ZeroAddress());
    if (rewardsManager != address(0)) {
        IERC20(premiumToken).safeApprove(rewardsManager, 0);  // revoke old
    }
    rewardsManager = rewardsManager_;
    emit RewardsManagerSet(rewardsManager_);
}
```

---

### [M-05] Retroactive deductibleBps/maxCoverableLossBps Changes Reduce Insurance Payout [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultWrapper.sol:L630-635`
**Confidence**: HIGH (2 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

The `_capAndApplyDeductible()` function reads `maxCoverableLossBps` and `deductibleBps` directly from live storage at withdrawal time. These parameters are changeable by the owner via a 2-day timelock. If the owner modifies them after a loss event occurs but before users withdraw, the insurance payout is retroactively reduced:

```solidity
function _capAndApplyDeductible(uint256 shortfall, uint256 basis) private view returns (uint256) {
    uint256 maxInsurance = basis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR, Math.Rounding.Floor);
    uint256 capped = shortfall > maxInsurance ? maxInsurance : shortfall;
    uint256 deductibleAmt = basis.mulDiv(deductibleBps, BPS_DENOMINATOR, Math.Rounding.Floor);
    return capped > deductibleAmt ? capped - deductibleAmt : 0;
}
```

A simultaneous deductible increase and maxCoverableLoss decrease can compound to reduce insurance payout by up to 75%. The 2-day timelock provides some protection, but in a crisis scenario users may not react within 2 days. The retroactive parameter change also amplifies the phantom residual described in M-02 by deepening the gap between `uncappedPremium` and `premiumForWithdrawal`.

**Impact**:

Users receive substantially less insurance than they expected under the original terms. In the verified PoC, changing `maxCoverableLossBps` from 10% to 4% and `deductibleBps` from 1% to 3% reduced the net insurance from 9% of the insured basis to 1% -- an 89% payout reduction. This deepens the effective loss for users and amplifies the phantom residual in `totalPremiumLiability` (see M-02).

**PoC Result**:

```
[PASS] test_H8_retroactiveParamChangesReducePayout() (gas: 530442)
  Assets received: 807.2 ether
  CONFIRMED: live param read enables retroactive payout reduction (9%->1%)
```

**Recommendation**:

Snapshot `deductibleBps` and `maxCoverableLossBps` at loss-event time or at policy binding, so users know their insurance terms cannot be changed retroactively after a loss has occurred.

---

### [M-06] _isPolicyActive External Call Blocks All Withdrawals During PolicyManager Downtime [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultAccrual.sol:L153-159`
**Confidence**: HIGH (3 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

The `_isPolicyActive()` function makes an uncaught external call to `PolicyManager.policyMetadata()`. If the PolicyManager becomes unavailable -- due to an upgrade in progress, a pause, or a bug -- this external call reverts. The revert propagates through `_activeElapsedFrom` -> `_accruePremium` -> `_withdraw`, blocking all vault operations including deposits, withdrawals, and emergency exits:

```solidity
function _isPolicyActive() internal view returns (bool) {
    if (policyId == 0) return false;
    IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);  // NO try/catch
    uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
    return
        metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
}
```

Since `_accruePremium()` is called by every deposit, withdrawal, and premium-related operation, a single external dependency failure cascades to total fund lockup.

**Impact**:

Complete denial-of-service on all vault operations during PolicyManager downtime. Users' funds are locked until the PolicyManager is restored. Emergency exit paths are also affected because they must pass through `_accruePremium()`. Even a brief PolicyManager upgrade window blocks all activity.

**PoC Result**:

```
[PASS] test_H11_isPolicyActiveBlocksWithdrawalOnPMRevert() (gas: 7642584)
  Replaced _policyManager at slot: 1
  CONFIRMED: withdrawal reverts on PolicyManager downtime
```

The test replaced the `_policyManager` storage with a reverting mock, confirming that `redeem()` reverts when `policyMetadata()` is unavailable.

**Recommendation**:

Wrap the `_isPolicyActive()` external call in a `try/catch` block with a safe fallback. If the PolicyManager is unavailable, assume the policy is inactive (premium stops accruing) so that withdrawals remain functional. This provides a graceful degradation path rather than total lockup.

---

### [M-07] Revoked Spec Still Callable by ClaimManager for Existing Policies [VERIFIED]

**Severity**: Medium
**Location**: `SpecRegistry.sol:L127-131`, `ClaimManager.sol:L560-590`
**Confidence**: HIGH (3 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

The `SpecRegistry.resolveSpec()` function returns a registered spec without checking the `_approvedSpecs` flag. When an admin calls `revokeSpec(spec)`, the spec is removed from `_approvedSpecs` but is NOT removed from the `_specs[pool][specId]` mapping. Subsequent calls to `resolveSpec()` by the ClaimManager return the revoked spec, allowing claim evaluation against logic that was intentionally revoked:

```solidity
function resolveSpec(address coverPool, bytes32 specId) external view override returns (ISpec spec) {
    spec = _specs[coverPool][specId];
    require(address(spec) != address(0), SpecNotRegistered(coverPool, specId));
    return spec;  // no check against _approvedSpecs
}
```

This enables two attack paths:
1. A spec admin and curator can collude to deny valid claims by revoking the legitimate spec and registering a new one at the same ID that rejects all claims.
2. A spec with a discovered vulnerability continues evaluating claims even after it has been revoked for security reasons.

**Impact**:

Valid insurance claims may be denied or evaluated against compromised/malicious spec logic. Requires spec-admin collusion or a separately compromised spec contract. The revocation mechanism provides a false sense of security -- admins believe revoking a spec stops it from being used, but it continues to be resolvable and callable.

**PoC Result**:

```
[PASS] test_H12_revokedSpecStillResolvable() (gas: 1541402)
  isSpecApproved(fakeSpec) after revokeSpec: false
  resolveSpec(pool, specId) after revokeSpec: address(fakeSpec)  (STILL returns revoked spec)
```

**Recommendation**:

Have `resolveSpec()` check the `_approvedSpecs` flag before returning, or snapshot the spec address at policy binding time so that subsequent revocations do not affect in-flight policies.

---

### [M-08] poolFeeBps Read Live at Distribution Enables Retroactive Fee Extraction [VERIFIED]

**Severity**: Medium
**Location**: `PremiumManager.sol:L154`, `CoverPool.sol:L123-129`
**Confidence**: HIGH (3 agents confirmed, Static Analysis: N/A, PoC: PASS)

**Description**:

`PremiumManager.distributePremium()` reads `poolFeeBps` live from the CoverPool at distribution time, not at the time premium was accrued:

```solidity
uint16 poolFeeBps = ICoverPool(pool).poolFeeBps();  // live read at distribution time
```

A curator (who holds `DEFAULT_ADMIN_ROLE` on the CoverPool) can increase `poolFeeBps` to the maximum allowed value (2000 bps = 20%) immediately before calling `distributeBatch()`, retroactively applying a higher fee rate to all accumulated premium -- even premium that was collected when the fee was 0%.

In combination with the ability to block claims (see L-10), a malicious curator can execute a dual-profit attack (see M-16): block claims to protect their staking collateral, then extract retroactive fees from the premium pool.

**Impact**:

Up to 15 percentage points of retroactive fee extraction from accumulated premium in a single transaction. In the verified PoC, a curator spiked `poolFeeBps` from 5% to 20% before distribution, extracting 200 ether from 1000 ether of accumulated premium instead of the expected 50 ether -- a 4x overcharge. Restakers receive 15% less than they expected.

**PoC Result**:

```
[PASS] test_H13_poolFeeBpsLiveReadEnablesRetroactiveFeeExtraction() (gas: 2504768)
  Pool fee paid: 200 ether
  Expected at original 5%: 50 ether
  Expected at new 20%: 200 ether
  CONFIRMED: poolFeeBps live read enables retroactive fee extraction
```

**Recommendation**:

Snapshot `poolFeeBps` at premium accrual time so that fees are calculated based on the rate in effect when the premium was earned, not when it was distributed. Alternatively, enforce a timelock on `poolFeeBps` changes.
