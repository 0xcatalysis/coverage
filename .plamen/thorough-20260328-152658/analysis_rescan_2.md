# Re-Scan Agent 2: Second-Pass Analysis Findings

**Analysis Date**: 2026-03-28
**Scope**: src/ (ClaimManager.sol, BasePolicyInteractions.sol, Swapper.sol, UniswapV3Adapter.sol, PremiumCollector.sol, PremiumManager.sol, SpecRegistry.sol)
**Pass**: Second pass — focused on cross-function state inconsistencies, asymmetric operations, boundary conditions, and interaction gaps missed by first pass.

---

## Finding [RS2-1]: SpecRegistry.revokeSpec Does Not Prevent Existing Policies From Using Revoked Specs

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✓, R6:✓, R8:✗(single-step setter), R10:✓, R12:✓, R13:✓, R14:✗(no aggregate)]
**Severity**: Medium
**Location**: SpecRegistry.sol:84-88, SpecRegistry.sol:127-130

**Description**:
`SpecRegistry.revokeSpec` only clears the `_approvedSpecs[spec]` flag but does NOT remove the spec from the `_specs[coverPool][specId]` mapping. The `resolveSpec` function, which ClaimManager calls during every claim evaluation, looks up `_specs[coverPool][specId]` directly — it does not check `_approvedSpecs` at resolution time.

```solidity
// SpecRegistry.sol:84-88
function revokeSpec(address spec) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(spec != address(0), InvalidSpec());
    _approvedSpecs[spec] = false;   // <-- only clears approval flag
    emit SpecRevoked(spec);
    // _specs mapping is NOT cleared
}

// SpecRegistry.sol:127-130
function resolveSpec(address coverPool, bytes32 specId) external view override returns (ISpec spec) {
    spec = _specs[coverPool][specId];                        // does NOT check _approvedSpecs
    require(address(spec) != address(0), SpecNotRegistered(coverPool, specId));
    return spec;
}
```

The `_approvedSpecs` check only occurs at registration time in `registerSpec` (line 118: `require(_approvedSpecs[address(spec)], SpecNotApproved(address(spec)))`). Once a spec is registered to a `(coverPool, specId)` pair, it is permanently bound regardless of any subsequent revocation.

**Impact**:
- If a Spec implementation is discovered to have a bug (e.g., always returns `isPayable = true`), the admin cannot prevent ongoing claims from using it via `revokeSpec`. Claims against all active policies bound to that (pool, specId) will continue to use the compromised spec.
- This breaks the intended emergency mechanism. The only recourse is to pause ClaimManager (blocking ALL claims across all policies) rather than surgically blocking the compromised spec.
- Admin may believe revocation is effective and not escalate to the full ClaimManager pause, leaving the system exposed.

**Evidence**:
```solidity
// registerSpec: only checks _approvedSpecs at write-time
require(_approvedSpecs[address(spec)], SpecNotApproved(address(spec)));  // line 118
_specs[coverPool][specId] = spec;                                         // line 120

// resolveSpec: reads from _specs with no approval re-check
spec = _specs[coverPool][specId];                                         // line 128
require(address(spec) != address(0), SpecNotRegistered(coverPool, specId)); // line 129
```

### Precondition Analysis
**Missing Precondition**: None - this is a design gap in the revocation mechanism, not a conditional attack.
**Precondition Type**: N/A

### Postcondition Analysis
**Postconditions Created**: Revocation gives false confidence that compromised specs cannot be used; admin inaction is encouraged.
**Postcondition Types**: [STATE, ACCESS]
**Who Benefits**: Anyone who needs claims evaluated via a buggy spec (claimer) or who wants to confuse the admin about system state.

---

## Finding [RS2-2]: PremiumCollector.distributeBatch Has No Per-Vault Error Isolation

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✓, R6:✗(no role), R8:✗(single-step), R10:✓, R12:✗(no dangerous precondition), R13:✓]
**Severity**: Low
**Location**: PremiumCollector.sol:163-168, PremiumCollector.sol:265-296

**Description**:
`distributeBatch` iterates over a caller-provided array of vault addresses and calls `_distribute(vault)` for each. The inner `_distribute` function performs multiple external calls without a try/catch wrapper at the batch level: it redeems vault shares, transfers underlying to PremiumManager, and then calls `PremiumManager.distributePremium`. If ANY of these steps fails for ANY vault in the batch, the entire transaction reverts — no prior vault's distribution is committed.

```solidity
// PremiumCollector.sol:163-168
function distributeBatch(address[] calldata vaults) external override nonReentrant whenNotPaused {
    uint256 length = vaults.length;
    for (uint256 i = 0; i < length; ++i) {
        _distribute(vaults[i]);  // no try/catch — any revert bubbles up
    }
}
```

`_distribute` can revert if:
1. `IERC4626(vault).redeem(...)` reverts (vault-side issue or insufficient shares)
2. `IERC20(config.underlying).safeTransfer(premiumManager, assets)` reverts (PremiumManager is zero address or token transfer fails)
3. `IPremiumManager(premiumManager).distributePremium(...)` reverts because:
   - PremiumManager is paused (`whenNotPaused`)
   - `hasBoundPolicy(policyId)` returns false (policy unbound)
   - `rewardsManager.distributeRewards(...)` reverts

When condition (3) is triggered for a single vault, all other vaults in the same batch call lose their distribution attempt. The keeper (Gelato) would need to retry each vault individually or recompose the batch excluding the failing vault.

**Impact**:
- Premium distribution to restakers is delayed until the failing vault's condition is resolved (e.g., PremiumManager unpaused, policy re-bound).
- A single misconfigured or paused downstream contract blocks premium flow for all healthy vaults sharing a batch.
- Premium accrual to restakers is deferred; if `distributeInterval` is daily, the delay is at minimum one full interval per incident.
- No fund loss directly — the vault shares are retained (redeem reverts atomically), and `lastDistributeTime` is not updated (since the storage write at line 289 also reverts).

**Evidence**:
```solidity
// PremiumCollector.sol:265-296 — _distribute (no try/catch):
function _distribute(address vault) private {
    // ...
    uint256 assets = IERC4626(vault).redeem(shares, address(this), address(this));  // can revert
    // ...
    config.lastDistributeTime = uint32(block.timestamp);
    IERC20(config.underlying).safeTransfer(premiumManager, assets);         // can revert
    IPremiumManager(premiumManager).distributePremium(config.pool, config.policyId, config.underlying, assets);  // can revert
}
```

### Postcondition Analysis
**Postconditions Created**: No state changes committed when revert occurs — vault shares are retained by PremiumCollector; premium distributions for all batch vaults are deferred.
**Postcondition Types**: [STATE, TIMING]
**Who Benefits**: No direct beneficiary — this is a robustness / liveness issue.

---

## Finding [RS2-3]: Excess Collateral Stranded in ClaimManager When Same-Token Payout Exceeds Remaining Coverage

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R11:✓, R13:✓, R15:✗(no flash-loan)]
**Severity**: Informational
**Location**: ClaimManager.sol:599-613

**Description**:
In `_processCollateral`, when the collateral token and payout token resolve to the same underlying (e.g., WETH collateral and WETH payout, or NATIVE_ETH collateral and WETH payout), the code caps the transfer at `remainingPayout`:

```solidity
// ClaimManager.sol:602-613
if (resolvedCollateral == resolvedPayout) {
    uint256 transferAmount = collateralAmount > remainingPayout ? remainingPayout : collateralAmount;
    if (collateralToken != payoutToken) {
        if (collateralToken == _NATIVE_ETH) {
            IWETH(resolvedPayout).deposit{value: transferAmount}();   // only wraps transferAmount
        } else {
            IWETH(resolvedCollateral).withdraw(transferAmount);       // only unwraps transferAmount
        }
    }
    _transferToken(payoutToken, beneficiary, transferAmount);
    amountOut = transferAmount;
}
```

When `collateralAmount > remainingPayout`, only `transferAmount = remainingPayout` is processed. The difference `collateralAmount - transferAmount` remains stuck in ClaimManager:
- If `collateralToken == _NATIVE_ETH`: the excess native ETH (from `SlashingManager.executeSlashing`) stays in ClaimManager as native ETH.
- If `collateralToken == nativeWrapper (WETH)`: only `transferAmount` WETH is unwrapped to ETH; the remaining WETH stays in ClaimManager.
- If `collateralToken == payoutToken` (same ERC-20): the excess tokens stay in ClaimManager.

The slashed restakers are penalized for the full `collateralAmount` (per `vaultSlashes[i].amount` computed in `_computeVaultSlashes`), but only `transferAmount` reaches the beneficiary. The excess collateral requires admin rescue via `recoverTokens`.

**Impact**:
- Restakers are over-slashed relative to the actual payout delivered. The protocol extracts more from restakers than the beneficiary receives.
- Excess collateral accumulates in ClaimManager and requires periodic admin recovery via `recoverTokens`.
- The magnitude of over-slashing is bounded by `maxSwapSlippageBps` inflation applied in `_inflateForSlippage`, but in the same-token path (no slippage inflation), any over-slashing arises from integer rounding in `_calculateVaultSlash` (small rounding dust) or from multi-vault coverage exhaustion where one vault is slashed for more than its pro-rata share fills the remaining payout.

**Evidence**:
```solidity
// ClaimManager.sol:533: slashAmount = (tokenStake * requestedAmount) / totalPayoutEquivalent
// tokenStake is fully committed; transferAmount may be capped below this
```

The issue is structural: the same-token path computes `vaultSlashes` before knowing that `collateralAmount > remainingPayout` (because remaining coverage may change between `_capAndExecutePayout`'s cap and the actual per-vault processing in `_slashAndDistribute`).

---

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|-----------|----------|---------------------|---------|----------|-------------------|-------------------|
| RS2-1 | SpecRegistry.sol:84-88,127-130 | `revokeSpec` clears `_approvedSpecs` but not `_specs`; `resolveSpec` only checks `_specs` so revocation is a no-op for existing policies | CONFIRMED | Medium | ACCESS | STATE |
| RS2-2 | PremiumCollector.sol:163-168,265-296 | `distributeBatch` has no try/catch per vault; single vault revert collapses the entire batch | CONFIRMED | Low | EXTERNAL | TIMING |
| RS2-3 | ClaimManager.sol:599-613 | Same-token path caps transferred amount at `remainingPayout` but slashes full `collateralAmount`; excess stays in ClaimManager | CONFIRMED | Informational | STATE | BALANCE |
