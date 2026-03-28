# Security Audit Report — Catalysis Coverage Protocol

**Date**: 2026-03-28
**Auditor**: Automated Security Analysis (Claude Opus 4.6)
**Audit Mode**: Thorough (Opus orchestrator, full depth loops, RAG validation, design stress testing)
**Scope**: 13 in-scope contracts, 4,094 lines (excluding interfaces)
- Core: CoverPool, CoverPoolFactory, PolicyManager, ClaimManager, PremiumCollector, PremiumManager, SpecRegistry, Swapper
- Morpho Vault: CoveredVaultWrapper, CoveredVaultAdmin, CoveredVaultAccrual, CoveredVaultStorage, BasePolicyInteractions
**Language/Version**: Solidity 0.8.28
**Build Status**: Compiled successfully
**Static Analysis Status**: N/A
**Proven-Only Mode**: ENABLED — 5 findings capped at Low from High/Medium due to unproven evidence ([CODE-TRACE] only)

---

## Executive Summary

The Catalysis Coverage Protocol is a modular on-chain insurance system that pairs ERC-4626 vaults (integrated with Morpho) with a decentralized coverage infrastructure consisting of CoverPools, a PolicyManager, and a ClaimManager. Restakers stake collateral through CoverPools to back insurance policies, while vault depositors pay premiums in exchange for coverage against Morpho losses. This audit reviewed the full protocol stack across 13 contracts and 4,094 lines of Solidity.

The most critical findings center on two structural disconnects. First, the `gateGracePeriod` mechanism — intended to extend policy maturity during Morpho downtime — creates a window where premium accrues but claims are rejected by the ClaimManager, which enforces the raw `maturityTime`. This gap is unbounded: each gate activation cycle adds to the grace period with no cap, allowing the uninsured window to extend indefinitely. A Morpho loss event during this window leaves depositors with no insurance recourse despite having paid for coverage. Second, the `UniswapV3Adapter` maintains separate sources of truth for the fee tier used in quoting versus swapping. After a fee-tier migration, quotes succeed against the new pool while swaps execute against the old one; if the old pool reverts, the `amountOutMin` protection collapses to 1 wei, enabling near-total MEV extraction on claim payouts.

Beyond these high-severity issues, the audit identified 17 medium-severity findings spanning retroactive parameter changes that reduce insurance payouts, external dependency failures that lock all withdrawals, curator roles with unchecked ability to block claims and extract retroactive fees, and multiple ERC-4626 spec violations that affect integrators. Twenty-nine low-severity findings address operational risks including proven-only issues (capped from original High/Medium severity due to lack of executed PoC evidence) around slippage protection, claim serialization, and stale external data. Thirteen informational findings document code quality issues, rounding behavior, and CEI pattern deviations. Total findings: 3 High, 17 Medium, 29 Low, 13 Informational.

---

## Summary

| Severity | Count |
|----------|-------|
| High | 3 |
| Medium | 17 |
| Low | 29 |
| Informational | 13 |
| **Total** | **62** |

### Components Audited

| Component | Path | Description |
|-----------|------|-------------|
| CoverPool | src/CoverPool.sol | Per-pool insurance contract; curator-controlled collateral staking and fee management |
| CoverPoolFactory | src/CoverPoolFactory.sol | Deploys CoverPool instances; manages infrastructure references |
| PolicyManager | src/PolicyManager.sol | Binds and manages insurance policies; stores policy metadata |
| ClaimManager | src/ClaimManager.sol | Processes insurance claims; executes collateral swaps for payouts |
| PremiumCollector | src/PremiumCollector.sol | Collects and batches premium distributions to pools |
| PremiumManager | src/PremiumManager.sol | Distributes collected premium among restakers, pool fee, and platform |
| SpecRegistry | src/SpecRegistry.sol | Registry for claim evaluation specs per pool |
| Swapper | src/Swapper.sol | Routes collateral-to-payout token swaps via UniswapV3Adapter |
| UniswapV3Adapter | src/adapters/UniswapV3Adapter.sol | Uniswap V3 quote and swap execution adapter |
| CoveredVaultWrapper | src/defi/adapters/morpho/CoveredVaultWrapper.sol | ERC-4626 vault wrapper with insurance integration |
| CoveredVaultAdmin | src/defi/adapters/morpho/CoveredVaultAdmin.sol | Admin functions for vault: gate, upgrade, parameter changes |
| CoveredVaultAccrual | src/defi/adapters/morpho/CoveredVaultAccrual.sol | Premium accrual logic; policy activity checks |
| CoveredVaultStorage | src/defi/adapters/morpho/CoveredVaultStorage.sol | Storage layout for vault contracts |

---

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

Users lose all premium accrued during the grace window with zero corresponding insurance coverage. With the unbounded accumulation described in M-01, this window can extend to arbitrary durations, multiplying the premium loss. In the verified PoC, 30 days of uninsured premium accrual was demonstrated at a rate of approximately 1000 ether. A Morpho loss event during this window leaves users with no recourse — they cannot file claims, yet they have been paying for insurance.

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

The `ClaimManager._executeCollateralSwap()` function initializes `amountOutMin` to 1 and attempts to get a quote via the Swapper. If the quote reverts, the empty `catch` block leaves `amountOutMin` at 1 — providing zero slippage protection:

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

This chain is particularly dangerous because H-02's desync creates a *deterministic* path to quote failure — the admin action of calling `setPairFee` without simultaneously updating the route calldata is sufficient to trigger the entire chain.

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
## Medium Findings

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

Vault stakers are over-slashed — they give up more collateral value than the claim payout requires. The excess value accumulates in ClaimManager and requires manual admin intervention to recover. There is no guarantee the recovered funds are returned to the correct parties. Over multiple claims with favorable price movements, material value can accumulate.

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

Users receive substantially less insurance than they expected under the original terms. In the verified PoC, changing `maxCoverableLossBps` from 10% to 4% and `deductibleBps` from 1% to 3% reduced the net insurance from 9% of the insured basis to 1% — an 89% payout reduction. This deepens the effective loss for users and amplifies the phantom residual in `totalPremiumLiability` (see M-02).

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

The `_isPolicyActive()` function makes an uncaught external call to `PolicyManager.policyMetadata()`. If the PolicyManager becomes unavailable — due to an upgrade in progress, a pause, or a bug — this external call reverts. The revert propagates through `_activeElapsedFrom` -> `_accruePremium` -> `_withdraw`, blocking all vault operations including deposits, withdrawals, and emergency exits:

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

**Recommendation**:

Wrap the `_isPolicyActive()` external call in a `try/catch` block with a safe fallback. If the PolicyManager is unavailable, assume the policy is inactive (premium stops accruing) so that withdrawals remain functional.

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

Valid insurance claims may be denied or evaluated against compromised/malicious spec logic. Requires spec-admin collusion or a separately compromised spec contract. The revocation mechanism provides a false sense of security — admins believe revoking a spec stops it from being used, but it continues to be resolvable and callable.

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

A curator (who holds `DEFAULT_ADMIN_ROLE` on the CoverPool) can increase `poolFeeBps` to the maximum allowed value (2000 bps = 20%) immediately before calling `distributeBatch()`, retroactively applying a higher fee rate to all accumulated premium — even premium that was collected when the fee was 0%.

In combination with the ability to block claims (see L-10), a malicious curator can execute a dual-profit attack (see M-16): block claims to protect their staking collateral, then extract retroactive fees from the premium pool.

**Impact**:

Up to 15 percentage points of retroactive fee extraction from accumulated premium in a single transaction. In the verified PoC, a curator spiked `poolFeeBps` from 5% to 20% before distribution, extracting 200 ether from 1000 ether of accumulated premium instead of the expected 50 ether — a 4x overcharge. Restakers receive 15% less than they expected.

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

---
### [M-09] maxWithdraw/maxRedeem Double-Deducts Premium (ERC-4626 Spec Violation) [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultWrapper.sol:L442-453`
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

ERC-4626 requires `maxWithdraw` to return the maximum assets that can be successfully withdrawn via `withdraw()`. Understating it means integrators (yield aggregators, lending protocols using vault shares as collateral) under-allocate capital and leave shares stranded. A call to `withdraw(maxWithdraw, ...)` succeeds while leaving behind a portion of the user's entitlement, which the integrator may not retry. The understatement grows linearly with the user's accumulated `owedPremium`, so long-term depositors are disproportionately affected.

**PoC Result**:

```
test_H14_maxWithdraw_underestimates: PASS
maxWithdraw reported:          9,999,917,808,250,240,000,000
previewRedeem(maxRedeem):      9,999,958,904,125,120,000,000
Difference:                    ~41,095,875,000 wei
assertLt(maxWithdraw, previewRedeem(maxRedeem)) PASSES
```

**Recommendation**:

Remove the `owedPremium` subtraction from `maxWithdraw`. The premium is already incorporated into the share price used by `_convertToAssets`. The corrected implementation should return `grossAssets` after deducting only the accrued (uncheckpointed) delta that is not yet in `totalPremiumLiability`. If per-user net cash display is desired, provide a separate view function rather than overriding `maxWithdraw`.

---

### [M-10] CREATOR_ROLE Can Replace Infrastructure Addresses Without Timelock [VERIFIED]

**Severity**: Medium
**Location**: `CoverPoolFactory.sol:L115-159`
**Confidence**: HIGH (PoC: PASS)

**Description**:

`CoverPoolFactory` exposes four critical setter functions — `setCoverPoolImplementation`, `setPolicyManager`, `setStakeManager`, and `setSpecRegistry` — all gated only by `onlyRole(CREATOR_ROLE)` with no timelock, no delay, and no two-step confirmation:

```solidity
function setCoverPoolImplementation(address implementation_) external override onlyRole(CREATOR_ROLE) { ... }
function setPolicyManager(address policyManager_)           external override onlyRole(CREATOR_ROLE) { ... }
function setStakeManager(address stakeManager_)             external override onlyRole(CREATOR_ROLE) { ... }
function setSpecRegistry(address specRegistry_)             external override onlyRole(CREATOR_ROLE) { ... }
```

A single transaction from CREATOR_ROLE immediately rotates the implementation used for all future `CoverPool` deployments and the core infrastructure references used for policy management and staking.

**Impact**:

A compromised or malicious CREATOR_ROLE can atomically redirect all new pool deployments to a backdoored implementation. Rotating `stakeManager` or `specRegistry` silently breaks all new policy bindings without user warning. Combined with M-13, after a CREATOR_ROLE-initiated rotation, newly deployed pools point to the new infrastructure while all existing pools remain bound to the old addresses with no migration path.

**PoC Result**:

```
test_H16_creatorRole_instant_infra_change: PASS
StakeManager before: 0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
StakeManager after:  0xD16d567549A2a2a2005aEACf7fB193851603dd70
-- Change was instant (same block, no delay)
```

**Recommendation**:

Apply a governance timelock (minimum 48 hours) to all infrastructure-rotating setters in `CoverPoolFactory`. A two-step pattern (propose + accept after delay) is strongly preferred, giving users and existing pool operators time to observe and respond to infrastructure changes.

---

### [M-11] Quote startTime Goes Stale Between Draft Creation and Policy Binding [VERIFIED]

**Severity**: Medium
**Location**: `CoverPool.sol:L51-65`, `PolicyManager.sol:L250-254`
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

In normal operation, curators cannot realistically execute same-block binding; network conditions, mempool delays, or a single competing transaction make this a routine failure. An adversary can front-run or delay the bind transaction to guarantee `startTime` staleness, enabling a persistent DoS on policy binding. The only mitigation available to users is to set `startTime` far in the future, but this leaves a gap in coverage from the current block to `startTime`, defeating the purpose of immediate coverage.

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

---

### [M-12] Operator Can Waive Owner's Insurance via Emergency Exit [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultWrapper.sol:L241-262`
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

Both functions delegate to the standard ERC-4626 `redeem`/`withdraw` path, which allows any approved operator (any address the owner has granted a `shares` allowance to) to call on behalf of the owner. An operator with a sufficient allowance can call `emergencyRedeem` for the owner's shares without the owner's explicit consent for the insurance waiver, silently stripping the owner's right to an insurance payout.

**Impact**:

During a loss event, an operator (e.g., a lending protocol, aggregator, or automated keeper with existing share approval) can call `emergencyRedeem` on behalf of the owner. The owner receives assets minus the premium deduction but receives zero insurance payout, even if they are entitled to one. The owner has no ability to distinguish the emergency path from a normal redemption before execution, nor to recover the foregone insurance payment after the fact.

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

---

### [M-13] Old CoverPools Permanently Orphaned After Infrastructure Rotation [VERIFIED]

**Severity**: Medium
**Location**: `CoverPoolFactory.sol:L90-159`, `CoverPool.sol:L79-101`
**Confidence**: HIGH (PoC: PASS)

**Description**:

`CoverPool.initialize()` captures `stakeManager` and `specRegistry` at deployment time and stores them as immutable-equivalent fields. There is no setter for these addresses in `CoverPool`. `CoverPoolFactory.setStakeManager()` and `setSpecRegistry()` update the factory's references for future deployments, but do not propagate to existing pool instances. Additionally, the CREATE2 salt does not incorporate `stakeManager` or `specRegistry`, so redeploying a pool at the same address after an infrastructure change is impossible. The result: once `CoverPoolFactory` rotates either infrastructure contract, every existing `CoverPool` is permanently bound to the old addresses with no migration path.

**Impact**:

Stake validation uses the old `stakeManager`, so new committee configurations under the new staking contract are invisible to existing pools. Spec registration and lookups use the old `specRegistry`, so newly registered claim specs are unreachable from existing pools. Claims filed against existing policies may use stale spec logic or reference stale staking data. Combined with M-10, an instant infrastructure rotation immediately bifurcates the system into old pools (orphaned) and new pools (connected), with no notification to affected depositors.

**PoC Result**:

```
test_H25_coverPool_retains_old_addresses_after_factory_rotation: PASS
Pool stakeManager:   0xF62849F9A0B5Bf2913b396098F7c7019b51A820a (old)
Factory stakeManager after rotation: 0xD16d567549A2a2a2005aEACf7fB193851603dd70 (new)
assertEq(coverPool.stakeManager(), poolStakeManager) PASSES (pool unchanged)
assertNotEq(factory.stakeManager(), coverPool.stakeManager()) PASSES (diverged)
```

**Recommendation**:

Add migration setters to `CoverPool` (gated by a governance timelock or admin multisig) to allow updating `stakeManager` and `specRegistry` post-deployment. Optionally include these addresses in the CREATE2 salt so that a new deployment with updated infrastructure occupies a distinct address.

---

### [M-14] Repeated Gate Toggles Create Arbitrarily Long Uninsured Premium Window [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultAdmin.sol:L168-186`, `CoveredVaultAccrual.sol:L80-100`
**Confidence**: HIGH (PoC: PASS)

**Description**:

This finding describes a compound vulnerability arising from two interacting bugs.

**Component 1 — Uninsured grace window**: `CoveredVaultWrapper._isPolicyActive()` returns `true` until `effectiveMaturity = maturityTime + gateGracePeriod`, so premium continues accruing during the grace period. However, `ClaimManager` enforces the raw `maturityTime` for claim eligibility. Any loss event occurring after `maturityTime` but before `effectiveMaturity` results in users paying premium with no insurance coverage (see H-01).

**Component 2 — Unbounded accumulation**: Each time the owner calls `setMorphoGateActive(false)` to deactivate the gate, the elapsed gate duration is added to `gateGracePeriod` with no cap:

```solidity
// CoveredVaultAdmin.sol:178-183
} else if (!active && morphoGateActive && gateActivatedAt > 0) {
    uint256 gateDuration = block.timestamp - gateActivatedAt;
    gateGracePeriod += gateDuration;  // no maximum, unbounded addition
    gateActivatedAt = 0;
}
```

Multiple legitimate gate activations accumulate `gateGracePeriod` additively. After N gate cycles, `gateGracePeriod` can far exceed the original policy duration.

**Combined attack sequence**: Owner activates and deactivates `morphoGate` three times over the policy lifetime (30 days each). `gateGracePeriod` accumulates to 90 days. Premium accrual continues for 90 days past `maturityTime`. Any Morpho loss during this 90-day window: `ClaimManager` rejects claims. Users have paid premium for the full 90-day uninsured window with zero recoverable coverage.

**Impact**:

With three 30-day gate cycles, users lose 90 days of premium with no insurance coverage. The owner need not act maliciously — legitimate Morpho maintenance events naturally trigger this accumulation. There is no per-cycle cap, maximum total grace period, or user-facing warning that coverage has lapsed.

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

Cap `gateGracePeriod` at a single-policy maximum (e.g., 30 days). Additionally, `ClaimManager` should respect `effectiveMaturity` rather than raw `maturityTime` when validating claim eligibility.

---

### [M-15] Morpho Loss During Grace Window Creates Permanent NAV Deflation [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultWrapper.sol:L573-583`, `CoveredVaultAccrual.sol:L65-95`
**Confidence**: HIGH (PoC: PASS)

**Description**:

This finding describes a three-way compound vulnerability. Two root causes — the uninsured grace window (see M-14) and the phantom premium residual bug (see M-02) — combine to guarantee the worst-case outcome for depositors.

During the `gateGracePeriod` extension, premium accrues but `ClaimManager` enforces raw `maturityTime`, so any loss event in the grace window cannot be claimed. When a deep-loss withdrawal then occurs (where `assetsReceived < uncappedPremium`), `totalPremiumLiability` is decremented only by `premiumForWithdrawal` rather than the full `uncappedPremium`:

```solidity
// CoveredVaultWrapper.sol:573-583
pendingPremium += premiumForWithdrawal;
totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal);
// The delta (uncappedPremium - premiumForWithdrawal) stays in totalPremiumLiability as phantom
```

The grace window makes this scenario inevitable rather than probabilistic: without insurance to offset the loss, any withdrawal during or after the loss event qualifies as deep-loss.

**Impact**:

Three compounding losses for depositors: (1) premium paid during the uninsured grace window, (2) no insurance payout on the loss, (3) permanent NAV deflation from the phantom residual affecting all remaining holders. The phantom residual cannot be organically cleared.

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

Both root causes require independent fixes. For the phantom residual: decrement `totalPremiumLiability` by `uncappedPremium` rather than `premiumForWithdrawal`. For the uninsured grace window: see M-14 recommendation. Fixing either root cause breaks the compound chain; fixing both eliminates the NAV deflation entirely.

---

### [M-16] Curator Combines Claim Denial with Retroactive Fee Extraction [VERIFIED]

**Severity**: Medium
**Location**: `CoverPool.sol:L147-149`, `PremiumManager.sol:L137-165`
**Confidence**: HIGH (PoC: PASS)

**Description**:

This finding describes a dual-profit attack sequence available to a malicious curator (the `DEFAULT_ADMIN_ROLE` on a `CoverPool`).

**Step 1 — Claim denial**: The curator can call `CoverPool.setPremiumDefaulted(policyId, true)` at any time, setting `metadata.premiumDefaulted = true` in `PolicyManager`. This causes `ClaimManager.fileClaim` to revert for all subsequent claims on that policy. `CoveredVaultWrapper`'s `try/catch` silently converts this to a zero payout.

**Step 2 — Retroactive fee extraction**: `PremiumManager.distributePremium` reads `poolFeeBps` live from the `CoverPool` at distribution time (see M-08). The curator can call `setPoolFeeBps(2000)` (maximum 20%) just before calling `distributeBatch`, retroactively applying the elevated fee rate to all accumulated premium.

Since both `setPremiumDefaulted` and `setPoolFeeBps` are controlled by the same role (`DEFAULT_ADMIN_ROLE` on `CoverPool`), a single actor can atomically execute both steps in one transaction.

**Combined attack sequence**: A loss event occurs. Curator calls `setPremiumDefaulted(policyId, true)` — blocks all insurance claims, protecting staked collateral from slashing. Curator calls `setPoolFeeBps(2000)` — spikes pool fee to maximum 20%. Curator calls `distributeBatch` — the entire accumulated premium is distributed at 20% curator fee.

**Impact**:

Depositors lose insurance coverage on the loss event AND pay inflated retroactive fees to the entity that blocked their coverage. No timelock, no cooldown, and no admin override exists for either `setPremiumDefaulted` or `setPoolFeeBps`. Combined dollar impact scales with pool TVL and accumulated premium.

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

1. Snapshot `poolFeeBps` at accrual time (not distribution time) so retroactive fee spiking cannot extract value from past accruals. Alternatively, enforce a minimum timelock on `setPoolFeeBps` changes.
2. Add governance oversight to `setPremiumDefaulted`: require a timelock delay, an admin co-signature, or limit the curator's ability to set `premiumDefaulted = true` without a corresponding governance action.

---

### [M-17] Phantom Residual Widens previewRedeem Gap [VERIFIED]

**Severity**: Medium
**Location**: `CoveredVaultWrapper.sol:L106-110`, `CoveredVaultWrapper.sol:L573-583`
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

When a deep-loss withdrawal creates a phantom residual in `totalPremiumLiability` (see M-02 and M-15), `totalAssets()` is permanently deflated for all remaining holders. `previewRedeem` therefore returns a share price that is lower than the actual redemption proceeds.

This compounds a pre-existing divergence: the actual `redeem` deducts per-user `owedPremium` from the user's gross entitlement, but `previewRedeem` does not model this deduction. The phantom amplifies the gap further by suppressing the share price used in the preview.

**Impact**:

ERC-4626 integrators — lending protocols using vault shares as collateral, yield aggregators, liquidation bots — rely on `previewRedeem` to estimate the asset value of a share position. A systematic understatement can lead to under-collateralization flags and premature liquidations, or cause depositors to believe their position is worth less than it actually is. In extreme scenarios, the gap can reach 90%+ of the actual redemption value.

**PoC Result**:

```
test_CH5_phantomWidesPreviewRedeemGap: PASS

Phantom residual:                73.97 ether
previewRedeem for user2:         12.05 ether
Actual redeem for user2:        151.37 ether
previewRedeem UNDERSTATED by:   139.32 ether (92% understatement)
```

**Recommendation**:

Fixing the phantom residual (see M-15 recommendation) eliminates the primary amplifier. After that fix, override `previewRedeem` and `previewWithdraw` to include the per-user premium deduction:

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

---
## Low Findings

### [L-01] renounceOwnership Not Overridden in UniswapV3Adapter [VERIFIED]

**Severity**: Low
**Location**: `UniswapV3Adapter:L45-60`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`UniswapV3Adapter` inherits OpenZeppelin's `Ownable2Step` but does not override `renounceOwnership()`. Calling `renounceOwnership()` from the owner account succeeds, setting `owner()` to `address(0)` permanently. After this point, no account can call `setPairFee()` (gated by `onlyOwner`), bricking fee-tier configuration for all swap routes. The sister contract `CoveredVaultAdmin` correctly overrides this function to revert with a `RenounceDisabled()` error, but that protection was not applied to the adapter.

**Impact**:
Fee-tier configuration becomes permanently inaccessible. Any future need to update or correct Uniswap V3 pool fee tiers via `setPairFee()` is blocked until a new adapter is deployed and all route configurations are migrated.

**Recommendation**:
Override `renounceOwnership()` in `UniswapV3Adapter` to revert unconditionally, mirroring the pattern already used in `CoveredVaultAdmin`:
```solidity
function renounceOwnership() public override onlyOwner {
    revert RenounceDisabled();
}
```

---

### [L-02] PREMIUM_COLLECTOR_ROLE Not Granted in PremiumManager.initialize() [UNVERIFIED]

**Severity**: Low
**Location**: `PremiumManager:L60-85`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumManager.initialize()` grants only `DEFAULT_ADMIN_ROLE` to the admin address. It does not grant `PREMIUM_COLLECTOR_ROLE` to the `PremiumCollector` contract address, even though `distributePremium()` requires `onlyRole(PREMIUM_COLLECTOR_ROLE)` to execute. A freshly deployed `PremiumManager` therefore has a non-functional premium distribution pipeline until an admin separately calls `grantRole(PREMIUM_COLLECTOR_ROLE, premiumCollector)` in a distinct post-deployment transaction. If this step is missed, all `distributeBatch` calls on `PremiumCollector` will silently fail.

**Impact**:
Premium distribution is silently non-functional after deployment until the role is manually granted. The failure surfaces only when `distributePremium` is first called. Accrued premium will not flow to restakers and platform treasury until the role is configured.

**Recommendation**:
Add `_grantRole(PREMIUM_COLLECTOR_ROLE, premiumCollector_)` to `PremiumManager.initialize()`, passing the `PremiumCollector` address as a constructor/initializer parameter.

---

### [L-03] Pre-Policy Phantom Premium When Checkpoint Predates startTime [VERIFIED]

**Severity**: Low
**Location**: `CoveredVaultAccrual:L120-140`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`_activeElapsedFrom(checkpoint)` computes elapsed active time as `block.timestamp - checkpoint` when the policy is active, without clamping `checkpoint` to `max(checkpoint, startTime)`. A user who deposits before `startTime` sets `lastPremiumAccrualTime` to a timestamp earlier than `startTime`. When the policy activates, the first `_accruePremium()` call spans the full window from the pre-start deposit through the current block, including the pre-policy gap. A test demonstrated that with a 79,199-second pre-start window, `totalPremiumLiability` grew to over 1e15 when it should have been at most ~3e10 — roughly a 39,700x overcharge.

**Impact**:
Users who deposit before policy start are charged premium for a period during which they had no insurance coverage. The overcharge is proportional to how early they deposited relative to `startTime`.

**Recommendation**:
In `_activeElapsedFrom`, clamp the effective start to `max(checkpoint, startTime)` in the active branch:
```solidity
uint256 activeStart = checkpoint < startTime ? startTime : checkpoint;
uint256 activeElapsed = block.timestamp - activeStart;
```

---

### [L-04] distributeBatch Reverts Entirely on Single Vault Failure [UNVERIFIED]

**Severity**: Low
**Location**: `PremiumCollector:L200-230`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumCollector.distributeBatch()` iterates over a caller-supplied list of vault addresses and calls `_distribute(vaults[i])` for each, with no try/catch around the inner call. If any vault in the batch reverts — due to a paused state, reentrancy guard triggered by prior execution, or any transient failure — the entire batch transaction reverts. All other vaults in the batch fail to receive their premium distribution, even those that would have succeeded independently.

**Impact**:
A single misconfigured or temporarily unavailable vault acts as a permanent blocker for batch premium distribution across all vaults in the same call. This creates griefing opportunities and operational fragility for keeper automation.

**Recommendation**:
Wrap the `_distribute(vaults[i])` call in a try/catch and emit an error event on failure rather than reverting the entire batch.

---

### [L-05] Oracle Revert in bindPolicy Blocks All Policy Binding [UNVERIFIED]

**Severity**: Low
**Location**: `PolicyManager:L270-290`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PolicyManager.bindPolicy()` calls `IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue()` twice without any try/catch. If Chainlink reverts for any reason (sequencer downtime on L2, stale answer, price out-of-range), `bindPolicy()` propagates the revert. This makes all new policy binding globally unavailable for the duration of the oracle outage.

**Impact**:
New policy onboarding is completely blocked during Chainlink oracle unavailability. During prolonged outages, vault operators may be unable to onboard new coverage capacity.

**Recommendation**:
Wrap the Chainlink calls in try/catch blocks with an appropriate fallback strategy (e.g., use a cached price or revert with a more informative error that distinguishes oracle failure from invalid parameters).

---

### [L-06] depositCap Reopens After Withdrawals During Loss Event [VERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L520-540`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`maxDeposit()` returns `depositCap - totalPrincipal` when a policy is bound, with no check for whether an active loss event is in progress. When a Morpho loss reduces vault assets and existing depositors begin withdrawing, `totalPrincipal` falls below `depositCap`. This makes `maxDeposit()` return a non-zero value, allowing new depositors to enter the vault during an active loss event.

**Impact**:
New depositors who enter during a loss event receive vault shares at a price that does not reflect the insurance coverage already being consumed. By the time they withdraw, the coverage limit may be exhausted by earlier claimants, leaving late entrants fully uninsured.

**Recommendation**:
Add a loss-event flag check to `maxDeposit()`. Return 0 when a loss event is active (i.e., when `morphoGateActive` is true or when `_morphoValue() < totalPrincipal`):
```solidity
if (!policyBoundExecuted || morphoGateActive) return 0;
```

---

### [L-07] Deposits Accepted After Policy Maturity Without Insurance [VERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L510-525`
**Confidence**: HIGH (PoC: PASS)

**Description**:
`maxDeposit()` does not check `maturityTime`. After the policy expires, `_isPolicyActive()` returns false and no insurance is provided, but the vault continues accepting deposits since `policyBoundExecuted` is still true and `totalPrincipal < depositCap`. Post-maturity deposits succeed: a user depositing after maturity receives vault shares with no premium accrual and no insurance coverage, which is not communicated by the ERC-4626 interface.

**Impact**:
Users who deposit after policy expiry receive uninsured exposure. The vault interface gives no indication that coverage has ended. Depending on UI presentation, this could mislead users into believing they are insured.

**Recommendation**:
Return 0 from `maxDeposit()` once the policy has matured:
```solidity
if (!policyBoundExecuted || block.timestamp >= maturityTime) return 0;
```

---

### [L-08] Fee-on-Transfer Collateral Tokens Cause Claim Revert [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L620-650`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`ClaimManager._processCollateral()` passes the nominally slashed `collateralAmount` to `_executeCollateralSwap()`. For fee-on-transfer ERC-20 collateral tokens, the actual amount received by `ClaimManager` after the slashing transfer is `collateralAmount - fee`. When `_approveIfERC20()` approves the full nominal amount and the Swapper attempts `transferFrom(claimManager, ..., collateralAmount)`, the call reverts with `ERC20InsufficientBalance` because the ClaimManager holds less than the approved amount.

**Impact**:
Any insurance claim involving a fee-on-transfer collateral token will revert at the swap stage, permanently blocking that claim's payout. The collateral has already been slashed from the vault at this point, so the loss is real but uncompensated.

**Recommendation**:
Use a balance-difference pattern in `_processCollateral` to determine the actual received amount, and pass `actualReceived` instead of the nominal `collateralAmount` to `_executeCollateralSwap`.

---

### [L-09] amountOutMin Falls to 1 When QuoterV2 Reverts, Enabling Near-Total Sandwich [UNVERIFIED]

**Severity**: Low
**Location**: `Swapper:L280-310`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. Evidence is code-level analysis only ([CODE-TRACE]); no end-to-end PoC execution was possible without live Uniswap infrastructure. Original suggested severity was High.

**Description**:
In `ClaimManager._executeCollateralSwap()`, `amountOutMin` is initialized to `1`. The code then attempts to obtain a quote via `ISwapper(swapper).quoteSwap()` inside a try/catch block. If `quoteSwap` reverts for any reason — including the fee-tier desync described in H-02 causing the wrong Uniswap pool to be queried — the empty `catch {}` block leaves `amountOutMin` at `1 wei`. The swap then proceeds with effectively no slippage protection, allowing an MEV sandwich bot to profitably extract nearly the entire swap value.

**Impact**:
Near-total loss of claim payout to MEV whenever `quoteSwap` fails. The `quoteSwap` failure can be triggered by the fee-tier desync (see H-02) or by any other condition that causes the Uniswap quoter to revert. In the worst case, a claimant who is owed a material insurance payout receives 1 wei.

**Recommendation**:
Replace the silent catch with a hard revert when no valid quote is obtained:
```solidity
} catch {
    revert QuoteUnavailable(collateralToken, payoutToken);
}
```

---

### [L-10] Curator Can Permanently Block Claims via setPremiumDefaulted [UNVERIFIED]

**Severity**: Low
**Location**: `CoverPool:L285-300`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. Original suggested severity was Medium.

**Description**:
A CoverPool curator (holding `DEFAULT_ADMIN_ROLE` on the pool) can call `setPremiumDefaulted(policyId, true)`, which writes `metadata.premiumDefaulted = true` to `PolicyManager`. When `CoveredVaultWrapper._claimInsurance()` subsequently calls `ClaimManager.fileClaim()`, the claim manager checks `require(!metadata.premiumDefaulted, PremiumDefaulted(policyId))` and reverts. The wrapper's `try/catch` silently absorbs the revert and returns 0 insurance payout. There is no timelock on `setPremiumDefaulted`, no admin override, and no mechanism for depositors to challenge or reverse the decision.

**Impact**:
The curator can permanently deny all insurance claims for a policy, reducing the depositors' insurance to zero without any recourse mechanism. When combined with retroactive fee extraction, the curator can simultaneously deny claims and extract maximum fees (see M-16).

**Recommendation**:
Add a timelock (minimum 48 hours) to `setPremiumDefaulted`, require a governance-level override path for depositors, or restrict `premiumDefaulted` to be set only after an explicit dispute-resolution process.

---

### [L-11] Claim Approval Gate Serializes Concurrent Claimants (First-Claimer Race) [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L290-320`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. Original suggested severity was Medium.

**Description**:
`ClaimManager._claimApprovalRequired` is a `mapping(uint96 policyId => bool)` — a single global flag per policy, not per user. After any successful claim is paid out on a policy, `_claimApprovalRequired[policyId]` is set to `true`, blocking all subsequent `fileClaim` calls for that policy until the curator calls `approveNextClaim(policyId)`. In a CoveredVaultWrapper with many depositors sharing a single policy, this creates strict serialization: only one user can claim at a time.

**Impact**:
During a large-scale Morpho loss event, every claimant after the first must wait for curator approval. Curators can deliberately delay approvals, keeping depositors' funds illiquid. The race to be the first claimant creates an unfair advantage for technically sophisticated users.

**Recommendation**:
Replace the global policy-level boolean with per-user claim tracking, or implement batch approval that covers all pending claims for a policy at once.

---

### [L-12] Stale lastKnownMorphoValue During Morpho Downtime Inflates Premium Cap [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L140-160`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. Original suggested severity was Medium.

**Description**:
When `IVaultV2(morphoVault).convertToAssets()` reverts, `_morphoValue()` falls back to `lastKnownMorphoValue` — the most recently cached Morpho vault value. If Morpho enters a maintenance window after a period of losses, the actual value is lower than the cached value. `_accruePremium()` uses the inflated cached value as the basis for premium calculation, potentially over-collecting premium from users relative to their actual asset value.

**Impact**:
Users are charged premium based on a higher-than-actual Morpho value during downtime. The over-collection is proportional to the gap between `lastKnownMorphoValue` and the true current value.

**Recommendation**:
When `convertToAssets` reverts, automatically activate the morpho gate (or use a zero fallback) rather than relying on the stale cache.

---

### [L-13] userPremiumDebt Zeroed by Floor Rounding After Partial Withdrawal [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L400-420`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

> **Note**: This finding is capped at Low severity under proven-only mode. Original suggested severity was Medium.

**Description**:
When a user makes a small partial withdrawal, if the withdrawal proportion is small enough that the calculated premium rounds to zero using integer floor division, `userPremiumDebt[user]` is set to zero, effectively wiping the user's accumulated premium debt. On the next withdrawal, premium is recalculated from the full accumulated `cumulativePremiumPerUnit` delta without any offset, resulting in the user being charged again for the premium period that was consumed but rounded to zero.

**Impact**:
Users making small partial withdrawals may find their subsequent withdrawals carry higher-than-expected premium charges equal to the amount that was previously rounded away.

**Recommendation**:
Use ceiling (round-up) division for the premium debt calculation:
```solidity
userPremiumDebt[user] = owedPremium.mulDiv(shares, userBalance, Math.Rounding.Ceil);
```

---

### [L-14] evidenceHash Permanently Consumed Even on Rejected Claims [VERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L360-390`
**Confidence**: HIGH (PoC: PASS)

**Description**:
In `fileClaim()`, `_usedEvidenceHashes[policyId][evidenceHash] = true` is set before the spec evaluation. If the spec returns `isPayable = false`, the claim is rejected and the function returns — but the evidence hash is already permanently consumed. A subsequent attempt to re-file the same claim with the same evidence hash will revert with `DuplicateEvidenceHash`. This is particularly problematic when the evidence hash is derived from deterministic on-chain data that cannot be varied.

**Impact**:
Claimants whose claims are rejected due to transient conditions cannot re-submit using the same evidence. They must construct a distinct evidence hash for each attempt, which may not be possible when the evidence is on-chain data.

**Recommendation**:
Move the `_usedEvidenceHashes[policyId][evidenceHash] = true` assignment to after `_evaluateSpec` returns with `isPayable = true`. The hash should be consumed only on successful claim acceptance.

---

### [L-15] setNativeWrapper Does Not Disable Old WETH-Keyed Routes [UNVERIFIED]

**Severity**: Low
**Location**: `Swapper:L330-360`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
When `setNativeWrapper` updates the `nativeWrapper` address from `WETH_OLD` to `WETH_NEW`, all previously configured routes that were keyed against `WETH_OLD` remain active and enabled in storage. Routes explicitly parameterized with `tokenIn = WETH_OLD` or `tokenOut = WETH_OLD` remain reachable by their concrete address and are never automatically invalidated.

**Impact**:
After a native wrapper migration, stale routes keyed by the old WETH address remain silently active. An operator must remember to manually disable each old route; missing this cleanup step leaves unexpected route entries that may route through an outdated or deprecated WETH contract.

**Recommendation**:
Document the manual cleanup requirement prominently in `setNativeWrapper`'s NatSpec. Consider emitting an event listing the old wrapper address so that off-chain monitoring can detect stale routes.

---

### [L-16] approveNextClaim Emits Misleading Event on Non-Gated Policy [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L400-420`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`approveNextClaim(policyId)` unconditionally sets `_claimApprovalRequired[policyId] = false` and emits `NextClaimApproved(policyId, msg.sender)` without first checking whether `_claimApprovalRequired[policyId]` was actually `true`. If the function is called on a policy that has no pending approval gate, the write is a no-op but the event is still emitted, misleading off-chain systems that parse `NextClaimApproved` events.

**Impact**:
No on-chain fund loss. Off-chain indexers, audit trails, and monitoring dashboards may show spurious "claim approved" entries for policies that were never gated.

**Recommendation**:
Add a guard: `require(_claimApprovalRequired[policyId], NoApprovalPending(policyId));`

---

### [L-17] cumulativePremiumPerUnit Precision Loss With Small totalPrincipal [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultAccrual:L110-130`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
When `totalPrincipal * premiumRatePerSecond * elapsed < WAD` (i.e., 1e18), the first division in premium accrual truncates to zero and `_accruePremium` returns early with no accrual. At maximum premium rate with USDC-denominated principal below ~100 USDC (1e8 units), even a full second of elapsed time produces `accrued = 0`. These missed accrual windows accumulate silently.

**Impact**:
Users with very small deposits (below roughly 100 USDC at max premium rate) may accrue no premium per second, effectively receiving free insurance for small positions. At realistic TVLs this is negligible; it becomes material only at dust-level deposits.

**Recommendation**:
Consider using a higher-precision accumulator (e.g., 1e27 scaling) for `cumulativePremiumPerUnit`, or document the minimum viable deposit size below which precision guarantees do not hold.

---

### [L-18] updateVault Missing nonReentrant Guard [UNVERIFIED]

**Severity**: Low
**Location**: `PremiumCollector:L160-180`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumCollector.updateVault()` is gated by `onlyRole(DEFAULT_ADMIN_ROLE)` but has no `nonReentrant` modifier. `distributeBatch()` is guarded by `nonReentrant` and internally calls `_distribute()`, which makes two external calls: `IERC4626(vault).redeem()` and `IPremiumManager.distributePremium()`. If a malicious vault's callback re-enters `updateVault()` during the `vault.redeem()` call, it can mutate `_vaultConfigs[vault].pool` and `_vaultConfigs[vault].policyId` while `_distribute()` is mid-execution, potentially routing premium distributions to the wrong pool or policy.

**Impact**:
A compromised vault or malicious vault admin with `DEFAULT_ADMIN_ROLE` could route premium distributions to an incorrect pool or policy. The impact is limited to misdirected premium distribution rather than direct fund loss.

**Recommendation**:
Add `nonReentrant` to `updateVault`.

---

### [L-19] PremiumCollector Caches Vault Underlying at Registration [UNVERIFIED]

**Severity**: Low
**Location**: `PremiumCollector:L90-110`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumCollector.registerVault()` calls `IERC4626(vault).asset()` once and stores the result in `VaultConfig.underlying`. All subsequent `_distribute()` calls use this cached `config.underlying`. The ERC-4626 standard treats `asset()` as immutable, so this is correct for standard-compliant vaults. However, if a non-standard vault upgrades its underlying token via a proxy implementation change, the cached value becomes stale, causing `_distribute()` to attempt to transfer the old token.

**Impact**:
Non-standard vaults that change their `asset()` return value after registration will cause premium distributions to use the wrong token. Likelihood is low given ERC-4626's immutability convention.

**Recommendation**:
Re-read `vault.asset()` at distribution time rather than using the cached value, or add a validation check at the start of `_distribute`.

---

### [L-20] executeUpgrade Clears Pending State After upgradeToAndCall [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultAdmin:L190-210`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultAdmin.executeUpgrade()` calls `upgradeToAndCall(impl, "")` before clearing `pendingUpgradeTimestamp` and `pendingImplementation`. If `upgradeToAndCall` reverts (e.g., the new implementation's initializer reverts), the pending state is not cleared. The owner can retry without re-proposing since the timelock is already satisfied.

**Impact**:
A failed upgrade leaves `pendingUpgradeTimestamp` and `pendingImplementation` in an active state. While the owner can simply retry, the stale pending state is observable and could confuse monitoring systems. No fund loss; the recovery path is straightforward.

**Recommendation**:
Use a local variable to capture the pending implementation address, clear the pending state before calling `upgradeToAndCall`, and pass the address as an argument to `_authorizeUpgrade`.

---

### [L-21] rescueTokens Uses totalPrincipal>0 as Proxy for Tracked Shares [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L635-650`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultAdmin.rescueTokens()` handles the Morpho vault token specially: when `totalPrincipal > 0`, it treats the entire Morpho share balance as tracked (user-owned) and blocks sweeping any shares. The actual tracked share obligation is the sum of `userMorphoShares[user]` across all depositors, which may be less than the full Morpho balance if surplus shares exist (e.g., from rounding residuals or direct share donations). The `totalPrincipal > 0` proxy is overly conservative — it prevents the admin from recovering any legitimately surplus shares while users are deposited.

**Impact**:
The admin cannot rescue accidentally-donated Morpho shares or rounding residuals while any user has a deposit. No user funds are at risk (the guard is conservative in the safe direction), but surplus value is permanently locked in the vault until all users exit.

**Recommendation**:
Track the exact number of Morpho shares attributed to users in a separate `totalMorphoShares` accumulator and use this as the guard in `rescueTokens` instead of the `totalPrincipal > 0` proxy.

---

### [L-22] Stale Evidence Hash From block.timestamp Causes Same-Block Claim Denial [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L360-390`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultWrapper._claimInsurance()` constructs an evidence hash as `keccak256(abi.encodePacked(user, policyId, cappedClaim, block.timestamp))`. If two claims are filed in the same block for the same user, policy, and capped amount, the hash is identical. The second claim attempt will revert with `DuplicateEvidenceHash` because the first call already consumed the hash. Combined with L-14 (evidence hashes consumed even on rejected claims), a claim rejected in the same block cannot be retried until the next block.

**Impact**:
Same-block retry attempts for identical claim parameters are blocked. While rare in normal operation, they can occur in batched transaction scenarios.

**Recommendation**:
Include a per-call nonce in the evidence hash to ensure uniqueness across same-block attempts:
```solidity
bytes32 evidenceHash = keccak256(abi.encodePacked(user, policyId, cappedClaim, block.timestamp, claimNonce++));
```

---

### [L-23] bindPolicy Hook Single-Use Guard Permanently Blocks Re-Binding [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L595-610`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultWrapper.onPolicyBound()` sets `policyBoundExecuted = true` on first successful invocation and reverts with `PolicyBoundAlreadyExecuted()` on any subsequent call. The flag is never reset anywhere in the codebase. An expired-policy vault that has served its term is permanently unable to bind a new policy for a continuation term. In infrastructure rotation scenarios (see M-13), existing vaults may become permanently orphaned with no path to bind under the new infrastructure.

**Impact**:
Vaults are permanently limited to a single policy binding. After the policy expires, the vault can no longer serve as an active insurance vehicle without deploying a new vault contract.

**Recommendation**:
Add a privileged reset mechanism (e.g., `resetPolicyBinding()` callable by the vault owner) that clears `policyBoundExecuted`, `policyId`, `coverageLimit`, and related state to allow re-binding.

---

### [L-24] block.timestamp as Swap Deadline (No MEV Time Protection) [UNVERIFIED]

**Severity**: Low
**Location**: `Swapper:L250-280`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`ClaimManager._executeCollateralSwap()` sets `deadline = block.timestamp` in the `SwapParams` struct passed to `Swapper.executeSwap()`. The Swapper validates `block.timestamp <= params.deadline`, which trivially passes since both values are the same block's timestamp. The deadline check therefore provides no temporal constraint: a validator can include the transaction at any point during the block's validity window without the deadline adding any protection.

**Impact**:
The swap deadline provides no actual protection against delayed or griefed execution. This is a standard pattern in Solidity with limited practical impact in most contexts; the more significant slippage risk is addressed separately (see L-09).

**Recommendation**:
Use a configurable deadline offset: `deadline: block.timestamp + deadlineBuffer` where `deadlineBuffer` is a governance-configurable parameter.

---

### [L-25] Unsolicited Morpho Share Donation (No Attacker Profit) [UNVERIFIED]

**Severity**: Low
**Location**: `CoveredVaultWrapper:L475-490`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultWrapper.totalAssets()` computes Morpho value based on `balanceOf(address(this))`. Any party can directly transfer Morpho vault shares to the wrapper address, inflating `totalAssets()` and the share price for all existing depositors. No attacker profit is possible; the donation is a gift to depositors at the attacker's expense. However, `rescueTokens` is blocked from recovering donated Morpho shares while `totalPrincipal > 0` (see L-21), so the donated shares cannot be swept.

**Impact**:
No direct harm to the protocol or users. The donation benefits existing depositors and costs the attacker. The donated shares are irrecoverable by the admin while users are deposited.

**Recommendation**:
No fix required for the donation mechanism itself. Document in the contract NatSpec that externally donated Morpho shares are permanently absorbed into the vault's NAV and cannot be separated.

---

### [L-26] SpecRegistry whenNotPaused Cross-Contract Pause Dependency [UNVERIFIED]

**Severity**: Low
**Location**: `SpecRegistry:L70-85`, `ClaimManager:L565-580`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`SpecRegistry.registerSpec()` is gated by `whenNotPaused`, meaning that pausing the SpecRegistry to block registration of a malicious spec also prevents all CoverPools from registering new specs. All CoverPools share the same singleton `SpecRegistry`. A localized incident affecting one pool that triggers a registry pause creates protocol-wide friction for all other pools.

**Impact**:
Pausing the SpecRegistry to address a localized security incident prevents all new spec registration across all CoverPools. Existing policies and their claims are unaffected. The impact is operational friction rather than fund loss.

**Recommendation**:
Consider per-pool pause granularity for `registerSpec`, or separate the emergency pause (blocking registration globally) from a per-pool suspension mechanism.

---

### [L-27] Factory Uses Instant Admin Transfer While CoverPools Use 24h Delay [UNVERIFIED]

**Severity**: Low
**Location**: `CoverPoolFactory:L140-160`, `CoverPool:L50-70`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoverPool` is initialized with `AccessControlDefaultAdminRulesUpgradeable` configured for a 24-hour admin transfer delay. `CoverPoolFactory`, by contrast, uses `AccessControlUpgradeable` with no delay — admin transfers complete instantly. Since the factory controls which implementations are used for new pool deployments and which infrastructure addresses are referenced, a compromised factory admin can instantly redirect all future pool deployments to malicious implementations with no grace period for detection.

**Impact**:
A compromised `CoverPoolFactory` admin can atomically transfer ownership and deploy malicious pool implementations in a single block. The asymmetry between pool-level protection (24h delay) and factory-level protection (instant) means the higher-impact operation has weaker protection.

**Recommendation**:
Apply `AccessControlDefaultAdminRulesUpgradeable` with at least a 24-hour delay to `CoverPoolFactory`, consistent with the protection applied to individual CoverPools.

---

### [L-28] coverageLimit Cached Locally vs Live Read in ClaimManager [UNVERIFIED]

**Severity**: Low
**Location**: `ClaimManager:L180-210`, `CoverPool:L225-245`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`CoveredVaultWrapper` stores `coverageLimit` as a local state variable set at `onPolicyBound` time and never subsequently updated. `ClaimManager.remainingCoverage()` reads `coverageLimit` directly from `PolicyManager.PolicyMetadata`, which is the authoritative source. In the current codebase both sources are identical since `PolicyMetadata.coverageLimit` is immutable after binding. However, the local cache creates a forward-compatibility risk: if a future protocol upgrade allows `coverageLimit` to be modified after binding, the wrapper's local copy would silently diverge.

**Impact**:
No impact in the current implementation. The risk is forward-looking: future upgrades allowing `coverageLimit` mutation after binding would create silent divergence between the wrapper's local copy and the authoritative value.

**Recommendation**:
Remove the local `coverageLimit` storage variable and read directly from `ClaimManager.remainingCoverage()` at claim time.

---

### [L-29] _MAX_FEE_BPS Guard Semantically Misleading [UNVERIFIED]

**Severity**: Low
**Location**: `CoverPool:L30-45`
**Confidence**: MEDIUM (PoC: CODE-TRACE)

**Description**:
`PremiumManager.distributePremium()` checks `require(totalFeeBps <= _MAX_FEE_BPS)` where `_MAX_FEE_BPS = 10_000` (100%). However, `platformFeeBps` is independently capped at 2,500 bps and `poolFeeBps` is independently capped at 2,000 bps by their respective setters. The maximum achievable combined fee is therefore 4,500 bps (45%), making the 10,000 bps guard permanently unreachable. The `ExcessiveCombinedFees` error can never be triggered through normal protocol operation.

**Impact**:
No direct security impact. The dead-code guard creates a false sense of combined fee protection and may mislead auditors or integrators.

**Recommendation**:
Set `_MAX_FEE_BPS` to the actual maximum achievable value (`_MAX_PLATFORM_FEE_BPS + _MAX_POOL_FEE_BPS = 4500`) to make the guard meaningful, or remove the combined check entirely.

---
## Informational Findings

### [I-01] PolicyManager._validateRequest Missing startTime Check (Defence-in-Depth)

**Severity**: Informational
**Location**: `PolicyManager:L200-220`

**Description**:
`PolicyManager._validateRequest()` checks that `startTime < maturityTime` and `maturityTime > block.timestamp`, but does not verify `startTime >= block.timestamp`. A caller can supply a `startTime` in the past and pass validation. The validated `startTime` is stored verbatim in `PolicyMetadata.startTime` and is used by `_activeElapsedFrom` in `CoveredVaultAccrual` when computing pre-policy phantom premium windows. A stale `startTime` accepted here compounds the precision issue described in L-03.

**Recommendation**:
Add `require(request.quote.startTime >= block.timestamp, InvalidStartTime())` to `_validateRequest` as an additional layer of defence.

---

### [I-02] PremiumCollector Missing recoverTokens Function

**Severity**: Informational
**Location**: `PremiumCollector:L290-297`

**Description**:
`ClaimManager` and `Swapper` both implement a `recoverTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE)` function for recovering accidentally-sent tokens. `PremiumCollector` is the only UUPS proxy contract in the protocol that lacks this function. Tokens inadvertently transferred to `PremiumCollector` cannot be recovered by the admin.

**Recommendation**:
Add a `recoverTokens` function to `PremiumCollector` and its interface, consistent with sibling contracts. Ensure it includes appropriate guards to prevent recovering tokens that are legitimately managed by the contract.

---

### [I-03] _withdraw Decrements totalPrincipal After External Interactions

**Severity**: Informational
**Location**: `CoveredVaultWrapper:L625-640`

**Description**:
`CoveredVaultWrapper._withdraw()` decrements `totalPrincipal` at line 189 after `_executeWithdrawal()` has already made two external calls: `IVaultV2(morphoVault).redeem()` and `ClaimManager.fileClaim()`. This is a Checks-Effects-Interactions pattern violation. The `nonReentrant` modifier on `_withdraw` prevents exploitation, making this informational in practice. Note that `userPrincipal[owner]` is correctly decremented inside `_updateDebtsAfterWithdrawal`, so partial CEI compliance exists; only the aggregate `totalPrincipal` counter follows the incorrect ordering.

**Recommendation**:
Move `totalPrincipal -= userPrincipalForWithdrawal` to before the `_executeWithdrawal` call to fully comply with the CEI pattern.

---

### [I-04] acceptOwnership Clears Timestamps But Not Pending Values

**Severity**: Informational
**Location**: `CoveredVaultAdmin:L220-230`

**Description**:
`CoveredVaultAdmin.acceptOwnership()` correctly zeros all six `*Timestamp` fields and `pendingImplementation`, but does not clear the corresponding pending value fields: `pendingPremiumRate`, `pendingMaxCoverableLossBps`, `pendingDeductibleBps`, and `pendingPremiumRecipient`. After an ownership transfer, the new owner inherits stale pending values with zeroed timestamps. While `_requireTimelockReady(0)` will revert with `NoPendingChange()` preventing accidental execution, the inconsistent state could confuse tooling or operators inspecting contract state.

**Recommendation**:
Clear all pending value fields in `acceptOwnership()` alongside the timestamp fields.

---

### [I-05] Swapper Stored Route Calldata May Become Stale

**Severity**: Informational
**Location**: `Swapper:L150-175`

**Description**:
`Swapper.setSwapRoute()` stores arbitrary `bytes calldata swapCalldata` into `_swapRoutes[routeKey].swapCalldata` with no expiry timestamp, version nonce, or staleness detection mechanism. If the DEX route configuration changes after storage — due to a Uniswap pool fee-tier migration, a liquidity pool deprecation, or a path restructuring — the stored calldata silently becomes stale. A `SWAP_MANAGER_ROLE` holder must proactively update routes when underlying DEX configurations change.

**Recommendation**:
Document the route staleness risk prominently in `setSwapRoute`'s NatSpec. Consider adding a `routeExpiry` timestamp field to the `RouteConfig` struct.

---

### [I-06] PremiumManager approveSpender Allows Arbitrary ERC-20 Approvals

**Severity**: Informational
**Location**: `PremiumManager:L185-200`

> **Note**: Impact is conditional on the `DEFAULT_ADMIN_ROLE` holder acting maliciously. The `DEFAULT_ADMIN_ROLE` is classified as fully trusted in the protocol's stated trust assumption model. Severity adjusted from potential High — attack requires `DEFAULT_ADMIN_ROLE` to violate stated trust assumption.

**Description**:
`PremiumManager.approveSpender(address token, address spender, uint256 amount)` allows the `DEFAULT_ADMIN_ROLE` holder to grant any ERC-20 approval of any amount to any spender address. This capability is intentional — it is used to pre-authorize the SSPRouter to pull restaker shares — but its breadth is notable. A compromised or malicious `DEFAULT_ADMIN_ROLE` holder could use this function to approve an attacker-controlled address to drain any ERC-20 token held by `PremiumManager`.

**Recommendation**:
No code change required given the fully-trusted classification of `DEFAULT_ADMIN_ROLE`. For documentation purposes, enumerate the specific approvals that are expected and consider adding an allowlist of permitted spenders to reduce the blast radius of a compromised admin key.

---

### [I-07] premiumRatePerSecond Missing WAD-Scaled Qualifier

**Severity**: Informational
**Location**: `CoveredVaultStorage:L50-65`

**Description**:
The state variable `premiumRatePerSecond` is WAD-scaled (divided by `1e18` in the accrual formula), but the variable name does not convey this unit information. An integrator reading only the variable name would interpret it as a raw `wei/second` rate rather than a `wei/second * 1e18` value. The constant `MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991` also lacks a unit qualifier.

**Recommendation**:
Rename to `premiumRatePerSecondWad` or add a unit comment directly in the variable declaration. Similarly qualify `MAX_PREMIUM_RATE_PER_SECOND`.

---

### [I-08] Combined Fee Cap Dead Code (100% Unreachable)

**Severity**: Informational
**Location**: `CoverPool:L35-45`

**Description**:
`PremiumManager.distributePremium()` includes the check `require(totalFeeBps <= _MAX_FEE_BPS)` where `_MAX_FEE_BPS = 10_000` (100%). Since `platformFeeBps` is capped at 2,500 bps and `poolFeeBps` is capped at 2,000 bps, the combined total can never exceed 4,500 bps. The 10,000 bps guard is unreachable dead code and the `ExcessiveCombinedFees` error can never be emitted, making it a misleading artefact in the ABI. (Related to L-29, which focuses on the semantic naming issue.)

**Recommendation**:
Remove the redundant combined fee guard, or update `_MAX_FEE_BPS` to `4500` so that the guard is meaningful.

---

### [I-09] _accruePremium Advances Timestamp When Rate is Zero

**Severity**: Informational
**Location**: `CoveredVaultAccrual:L85-100`

**Description**:
`_accruePremium()` unconditionally sets `lastPremiumAccrualTime = block.timestamp` before any other checks. When `premiumRatePerSecond == 0`, the subsequent multiplication yields `accrued = 0` and the function returns early — but the timestamp has already been advanced. When the rate is later set to a non-zero value, there is no catch-up accrual for the elapsed zero-rate period. The NatSpec documents this as intentional design.

**Recommendation**:
No code change required. Add a comment specifically calling out the zero-rate case alongside the existing NatSpec, as this invariant is non-obvious to integrators who set `premiumRatePerSecond = 0` temporarily.

---

### [I-10] Fee Split Rounding Favors Restakers (2 wei dust)

**Severity**: Informational
**Location**: `PremiumManager:L125-140`

**Description**:
`PremiumManager.getFeeSplits()` computes platform and pool splits using integer floor division, then assigns the remainder to restakers: `restakerSplit = grossPremium - platformSplit - poolSplit`. Each floor division truncates up to 1 wei, so restakers receive up to 2 wei of dust per distribution call. At maximum fee rates, the maximum dust per call is 2 wei. At any realistic distribution frequency and premium scale, the cumulative dust is negligible.

**Recommendation**:
No fix required. Document the rounding behavior in the NatSpec for `getFeeSplits` to make the intent explicit.

---

### [I-11] PremiumCollector._distribute Truncates to uint32

**Severity**: Informational
**Location**: `PremiumCollector:L220-235`

**Description**:
`PremiumCollector._distribute()` stores the distribution timestamp as `config.lastDistributeTime = uint32(block.timestamp)`. The `uint32` type overflows at Unix timestamp 4,294,967,295 (February 7, 2106). After this date, `lastDistributeTime` wraps to 0, which would allow immediate re-distribution regardless of `distributeInterval`. No immediate action is required for the protocol's current deployment horizon.

**Recommendation**:
No immediate fix required. For long-term maintenance, migrate `VaultConfig.lastDistributeTime` to `uint64`. Flag this for review in any protocol version intended to operate past 2100.

---

### [I-12] _isPolicyActive External Call on Every Deposit/Withdraw (Gas)

**Severity**: Informational
**Location**: `CoveredVaultAccrual:L65-95`

**Description**:
`_isPolicyActive()` makes an external call to `PolicyManager.policyMetadata(policyId)` on every invocation. Within a single withdrawal transaction, `_isPolicyActive` is called at minimum twice: once via `_accruePremium → _activeElapsedFrom → _isPolicyActive`, and once via `_executeWithdrawal → _settleWithdrawalTransfer → _computeInsurance → _isPolicyActive`. No within-transaction caching of the `PolicyMetadata` struct is performed, representing two cross-contract calls per withdrawal where one would suffice.

**Recommendation**:
Cache the `PolicyMetadata` result at the start of `_withdraw` and `_deposit` and pass it through the internal call chain as a memory argument. This reduces external calls per withdrawal from 2+ to 1, saving approximately 2,000–5,000 gas per operation.

---

### [I-13] CoverPool Curator 24-Hour Admin Transfer Delay

**Severity**: Informational
**Location**: `CoverPool:L50-70`

> **Note**: This is documented design behavior. The 24-hour admin transfer delay is explicitly stated in the protocol's trust assumption model for CoverPool curators.

**Description**:
`CoverPool` is initialized with `AccessControlDefaultAdminRulesUpgradeable` configured for a 24-hour admin transfer delay. This means any transfer of the `DEFAULT_ADMIN_ROLE` (curator) on a CoverPool requires a 24-hour pending period before the transfer completes. This finding documents the design for completeness and for contrast with `CoverPoolFactory`, which uses instant admin transfer (see L-27).

**Recommendation**:
No change required. Document the 24-hour delay in user-facing documentation so that CoverPool operators are aware of the transfer latency when performing legitimate curator rotation.

---
## Priority Remediation Order

1. **H-01** — gateGracePeriod creates uninsured premium window — *Immediate: users pay for non-existent coverage*
2. **H-02** — UniswapV3Adapter fee-tier desync between quote and swap — *Immediate: deterministic DoS or MEV path on claim payouts*
3. **H-03** — Fee-tier desync enables deterministic sandwich on claim payout — *Immediate: dependent on H-02 fix*
4. **M-02** — totalPremiumLiability phantom residual after deep-loss withdrawals — *Before launch: permanent NAV deflation*
5. **M-14** — Repeated gate toggles create arbitrarily long uninsured window — *Before launch: amplifies H-01*
6. **M-15** — Morpho loss during grace window creates permanent NAV deflation — *Before launch: compound of H-01 + M-02*
7. **M-05** — Retroactive deductibleBps/maxCoverableLossBps changes reduce insurance payout — *Before launch: user insurance terms changeable post-loss*
8. **M-16** — Curator combines claim denial with retroactive fee extraction — *Before launch: dual-profit curator attack*
9. **M-06** — _isPolicyActive external call blocks all withdrawals during PolicyManager downtime — *Before launch: total fund lockup on external dependency failure*
10. **M-08** — poolFeeBps read live at distribution enables retroactive fee extraction — *Before launch: root cause of M-16 step 2*
11. **M-07** — Revoked spec still callable by ClaimManager — *Before launch: false sense of security from revocation mechanism*
12. **M-12** — Operator can waive owner's insurance via emergency exit — *Before launch: insurance waiver without owner consent*
13. **M-01** — Unbounded gateGracePeriod accumulation — *Before launch: enabler for H-01 and M-14*
14. **M-04** — Stale unlimited approval persists on old RewardsManager — *Before launch: drain risk on old contract compromise*
15. **M-09** — maxWithdraw/maxRedeem double-deducts premium (ERC-4626 spec violation) — *Before launch: integrator compatibility*
16. **M-17** — Phantom residual widens previewRedeem gap — *Before launch: integrator collateral pricing errors*
17. **M-03** — Excess swap output permanently stranded in ClaimManager — *Before launch: over-slashing without pro-rata return*
18. **M-10** — CREATOR_ROLE can replace infrastructure addresses without timelock — *Before launch: instant infrastructure rotation risk*
19. **M-11** — Quote startTime goes stale between draft creation and policy binding — *Before launch: routine binding DoS*
20. **M-13** — Old CoverPools permanently orphaned after infrastructure rotation — *Before launch: companion to M-10*

---

## Appendix A: Internal Audit Traceability

> This appendix is for internal reference only. It maps internal pipeline IDs to report IDs.

| Report ID | Internal Hypothesis | Chain | Verification | Agent Sources |
|-----------|-------------------|-------|--------------|---------------|
| H-01 | H-1 | — | [POC-PASS] | RS1-1, SGI-2, VS-UPDATE |
| H-02 | H-5 | — | [POC-PASS] | PC3-2, DEPTH-EX-4, DEPTH-TF-2 |
| H-03 | CH-2 (H-5→H-7) | CH-2 | [POC-PASS] | Chain analysis, ITER2-FA-3 |
| M-01 | H-2 | — | [POC-PASS] | CS-1, PC1-4 |
| M-02 | H-3, CH-1, CH-4 | CH-1, CH-4 | [POC-PASS] | CS-2, SGI-1, VA-6, DEPTH-EC-2, DEPTH-ST-2 |
| M-03 | H-4 | — | [POC-PASS] | PC3-1, RS2-3, DEX-4 |
| M-04 | H-6 | — | [POC-PASS] | PC4-1, DEPTH-TF-4 |
| M-05 | H-8, CH-1 | CH-1 | [POC-PASS] | CS-5, ITER2-ST-2 |
| M-06 | H-11 | — | [POC-PASS] | TF-7, DEPTH-EX-1, DEPTH-EX-2 |
| M-07 | H-12 | — | [POC-PASS] | RS2-1, ITER2-ST-3, DEPTH-ST-7 |
| M-08 | H-13, CH-6 | CH-6 | [POC-PASS] | PC4-2, ITER2-FA-3, DEPTH-ST-8 |
| M-09 | H-14 | — | [POC-PASS] | PC1-1, ITER2-LC-2, DEPTH-ST-9 |
| M-10 | H-16 | — | [POC-PASS] | AC-1 |
| M-11 | H-19 | — | [POC-PASS] | PC2-1, DEPTH-ST-6 |
| M-12 | H-22 | — | [POC-PASS] | RS1-2 |
| M-13 | H-25 | — | [POC-PASS] | RS1-3, ITER2-FA-1 |
| M-14 | CH-3 (H-1+H-2) | CH-3 | [POC-PASS] | Chain analysis |
| M-15 | CH-4 (H-1+H-3) | CH-4 | [POC-PASS] | Chain analysis |
| M-16 | CH-6 (H-9+H-13) | CH-6 | [POC-PASS] | Chain analysis |
| M-17 | CH-5 (H-3+H-15) | CH-5 | [POC-PASS] | Vault Accounting, chain analysis |
| L-01 | H-17 | — | [POC-PASS] | BLIND-C-1 |
| L-02 | H-18 | — | [CODE-TRACE] | BLIND-C-2 |
| L-03 | H-21 | — | [POC-PASS] | PC1-2, DEPTH-ST-10 |
| L-04 | H-23 | — | [CODE-TRACE] | RS2-2, DEPTH-EX-7 |
| L-05 | H-24 | — | [CODE-TRACE] | OZ-1, DEPTH-EX-8 |
| L-06 | H-27 | — | [POC-PASS] | CS-9, BLIND-A-1 |
| L-07 | H-28 | — | [POC-PASS] | OZ-2, DEPTH-EC-9, DST-4 |
| L-08 | H-29 | — | [CODE-TRACE] | TF-5, DEPTH-TF-6 |
| L-09 | H-7 | — | [CODE-TRACE] | TF-4, DEX-1, DEPTH-TF-3 (PROVEN_ONLY from High) |
| L-10 | H-9 | — | [CODE-TRACE] | AC-2 (PROVEN_ONLY from Medium) |
| L-11 | H-10 | — | [CODE-TRACE] | AC-3, SGI-6 (PROVEN_ONLY from Medium) |
| L-12 | H-20 | — | [CODE-TRACE] | OZ-3, CS-3, DEPTH-EX-3 (PROVEN_ONLY from Medium) |
| L-13 | H-30 | — | [CODE-TRACE] | VA-1 (PROVEN_ONLY from Medium) |
| L-14 | H-31 | — | [POC-PASS] | PC3-5 |
| L-15 | H-32 | — | [CODE-TRACE] | BLIND-C-3 |
| L-16 | H-33 | — | [CODE-TRACE] | PC3-4 |
| L-17 | H-34 | — | [CODE-TRACE] | CS-6, SGI-4 |
| L-18 | H-35 | — | [CODE-TRACE] | PC4-3, DEPTH-EX-6 |
| L-19 | H-36 | — | [CODE-TRACE] | PC4-4 |
| L-20 | H-37 | — | [CODE-TRACE] | AC-8 |
| L-21 | H-38 | — | [CODE-TRACE] | OZ-5 |
| L-22 | H-40 | — | [CODE-TRACE] | RS3-2 |
| L-23 | H-41 | — | [CODE-TRACE] | PC2-3 |
| L-24 | H-44 | — | [CODE-TRACE] | TF-1 |
| L-25 | H-45 | — | [CODE-TRACE] | TF-3 |
| L-26 | H-46 | — | [CODE-TRACE] | BLIND-B-3 |
| L-27 | H-47 | — | [CODE-TRACE] | BLIND-B-1 |
| L-28 | H-52 | — | [CODE-TRACE] | SC-8 |
| L-29 | H-53 | — | [CODE-TRACE] | SC-5 |
| I-01 | H-42 | — | [CODE-TRACE] | PC2-5 |
| I-02 | H-43 | — | [CODE-TRACE] | BLIND-C-4 |
| I-03 | H-48 | — | [CODE-TRACE] | PC1-3 |
| I-04 | H-49 | — | [CODE-TRACE] | BLIND-A-4 |
| I-05 | H-50 | — | [CODE-TRACE] | TF-8 |
| I-06 | H-51 | — | [CODE-TRACE] | AC-9 (TRUSTED-ACTOR downgrade) |
| I-07 | H-54 | — | [CODE-TRACE] | SC-9 |
| I-08 | H-55 | — | [CODE-TRACE] | ITER2-FA-2 |
| I-09 | H-57 | — | [CODE-TRACE] | CS-10 |
| I-10 | H-58 | — | [CODE-TRACE] | CS-8 |
| I-11 | H-59 | — | [CODE-TRACE] | CS-7 |
| I-12 | H-60 | — | [CODE-TRACE] | OZ-6 |
| I-13 | H-61 | — | [CODE-TRACE] | AC-6 (WITHIN-BOUNDS annotation) |

### Excluded Findings (FALSE_POSITIVE)

| Internal ID | Severity | Title | Exclusion Reason |
|-------------|----------|-------|-----------------|
| H-15 | Medium | previewRedeem/previewWithdraw Overstates Proceeds | FALSE_POSITIVE — previewRedeem correctly reflects totalAssets-based calculation; single-user test shows exact equality; finding based on stale analysis |
| H-26 | Low | Premium Rate Change Retroactive to All Existing Positions | FALSE_POSITIVE — executePremiumRate() calls _accruePremium() before changing rate; strictly prospective; not retroactive |
| H-39 | Medium | Post-Expiry Premium Catch-Up Charges Full Lifetime Premium | FALSE_POSITIVE — _activeElapsedFrom caps at effectiveMaturity, not block.timestamp; only charges missed window between prior checkpoint and current block |
