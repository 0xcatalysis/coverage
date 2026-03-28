# Validation Sweep Findings

**Agent**: Validation Sweep Agent
**Protocol**: CoveredVaultWrapper / CoverPool / ClaimManager
**Date**: 2026-03-28
**Total findings in inventory**: 55

---

## Sweep Summary

| Check | Functions Scanned | Findings | False Positives Filtered |
|-------|------------------|----------|-------------------------|
| CHECK 1: Boundary Operator Precision | 14 | 1 (VS-1) | 1 (maturityTime <= vs < — see below) |
| CHECK 2: Validation Reachability | 12 | 0 | 2 |
| CHECK 3: Guard Coverage Completeness | 8 modifiers | 0 | 1 |
| CHECK 4: Cross-Contract Action Parity | 5 action pairs | 0 | 0 |
| CHECK 5: External Call Parameter Validation | 6 | 0 | 1 |
| CHECK 6: Helper Function Call-Site Parity | 4 helpers | 0 | 0 |
| CHECK 7: Write Completeness for Accumulators | 5 from semantic_invariants | 0 new | 5 (already in inventory) |
| CHECK 8: Conditional Branch State Completeness | 18 | 0 new | 2 |
| CHECK 9: Sibling Propagation | 11 Medium+ CONFIRMED | 1 (VS-2) | 3 |

---

## Validation Status of Priority Findings

### RS1-1 (HIGH): gateGracePeriod Extension Renders Insurance Uncollectable During Grace Window

**Validation**: CONFIRMED — code verified.

- `_isPolicyActive()` in `CoveredVaultAccrual.sol:153-158` uses `block.timestamp < effectiveMaturity` where `effectiveMaturity = maturityTime + gateGracePeriod`.
- `_accruePremium()` at `CoveredVaultAccrual.sol:116-136` calls `_activeElapsedFrom()` which also uses `effectiveMaturity` for the catch-up window — premium accrues through the grace period.
- `ClaimManager._fileClaimWithMetadata()` at `ClaimManager.sol:306-309` uses `block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime` — **raw** maturity, no grace period added.
- During the entire `gateGracePeriod` window after raw maturity: the wrapper treats the policy as active (premium accrues), but ClaimManager rejects all claims with `ClaimOutsideCoverageWindow`. Users pay premium with zero coverage.
- The boundary operator `<=` vs `<` is also off by one second: the vault uses strict `<` (meaning maturityTime second itself is still active) while ClaimManager uses `<=` (maturityTime second is valid). This 1-second difference is de minimis — the structural gap (entire grace period) dominates.

**Severity**: HIGH — confirmed. No downgrade warranted. The systematic premium-with-no-coverage window scales with `gateGracePeriod` accumulation.

**[VS-UPDATE-RS1-1]**: Severity confirmed HIGH. Code evidence is:
- CoveredVaultAccrual.sol:156-158 (effectiveMaturity)
- ClaimManager.sol:307 (raw maturityTime check)
- These are different contract contexts, not coordinated.

---

### PC3-1 (HIGH): Excess Swap Output Permanently Stranded in ClaimManager

**Validation**: CONFIRMED — code verified.

`ClaimManager._executeCollateralSwap()` at L663-669:
```solidity
uint256 swapOutput = ISwapper(swapper).executeSwap{...}(swapParams);
amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput;
_transferToken(payoutToken, beneficiary, amountOut);
```

When `swapOutput > remainingPayout`, only `remainingPayout` goes to `beneficiary`. The delta `swapOutput - remainingPayout` stays in ClaimManager. No mechanism exists to return these excess assets to the vault or stakers. The approval is revoked at L669: `_approveIfERC20(collateralToken, swapper, 0)`, but the excess **output** token (payoutToken) sits in ClaimManager's balance indefinitely.

**Severity**: HIGH — confirmed. `recoverTokens()` exists in Swapper but not in ClaimManager for general ERC-20 recovery in this specific case. Stakers are over-slashed relative to payout delivered.

---

### PC3-2 (HIGH): UniswapV3Adapter Fee-Tier Mismatch Between quote and swap

**Validation**: CONFIRMED — code verified.

- `Swapper.quoteSwap()` (L206): calls `IQuotableAdapter(route.swapTarget).quote(...)` → `UniswapV3Adapter.quote()` → `_getFee(tokenIn, tokenOut)` → reads `pairFees[key]` (current, live value).
- `Swapper.executeSwap()` (L235-241): uses `routeCalldata` stored at `setSwapRoute()` time. This calldata encodes the function selector + parameters for `UniswapV3Adapter.swap(tokenIn, tokenOut, fee, amountOutMinimum)`. The `fee` field in this calldata was frozen when the route was configured.
- `UniswapV3Adapter.setPairFee()` (L116-120): updates `pairFees[key]` live, but does NOT update stored route calldata in Swapper.

**Desync scenario**: Admin calls `setPairFee(weth, usdc, 500)` to change the fee tier. Quote now uses 500-bps pool, swap still uses old fee (e.g., 3000) from stored calldata. If the 3000-bps pool has worse liquidity, slippage estimate is wrong → `amountOutMin` could be inadequate or the swap could revert.

**Severity**: HIGH — confirmed. Claim DoS (scenario A: new fee pool has no liquidity, swap reverts) or weakened slippage protection (scenario B: mismatched fee pools).

---

### CS-2 (MEDIUM): totalPremiumLiability Phantom Residual After Deep-Loss Withdrawals

**Validation**: CONFIRMED — code verified.

At `CoveredVaultWrapper.sol:583`:
```solidity
totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal);
```
Where `premiumForWithdrawal = min(uncappedPremium, assetsReceived)`.

In a deep-loss scenario (`assetsReceived < uncappedPremium`):
- `premiumForWithdrawal = assetsReceived` (the cap applies)
- `totalPremiumLiability` decremented by `assetsReceived`
- Phantom delta = `uncappedPremium - assetsReceived` remains in `totalPremiumLiability`

The phantom residual directly reduces `_liabilityHeadroom()` → `totalAssets()` is artificially deflated → remaining holders' share price is depressed → they receive artificially lower exit values.

The semantic invariant analysis at `semantic_invariants.md:SYNC_GAP 2` traced this to Level 3 terminal impact: PERMANENT state corruption. The phantom never clears because no future withdrawal will generate a `premiumForWithdrawal` large enough to consume it (the phantom represents forgiven premium that was never collected). Severity MEDIUM confirmed.

---

### PC4-1 (MEDIUM): Stale Approval Persists on Old RewardsManager After setRewardsManager Update

**Validation**: CONFIRMED — code verified.

`PremiumManager.setRewardsManager()` at L93-97:
```solidity
function setRewardsManager(address rewardsManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(rewardsManager_ != address(0), ZeroAddress());
    rewardsManager = rewardsManager_;
    emit RewardsManagerSet(rewardsManager_);
}
```

`approveSpender()` at L102-113 grants `forceApprove` to arbitrary spenders including `rewardsManager`. When `setRewardsManager()` is called, the old `rewardsManager` retains its unlimited approval from `approveSpender`. No revocation step exists.

Sibling check: `ClaimManager.setSwapper()` (L142-146) also lacks approval cleanup — but ClaimManager only grants per-use transient approvals (`_approveIfERC20` at L639 revoked at L669). No persistent stale approval in ClaimManager. **Sibling is not present.**

---

## New Findings

---

## Finding [VS-1]: ClaimManager Grace-Period Boundary Uses Strict Inequality While Wrapper Uses Non-Strict — 1-Second Coverage Gap

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5 | ✗6(N/A — no semi-trusted role path) | ✗7(N/A — binary boundary)
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R13:✓, R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:block.timestamp == maturityTime → wrapper _isPolicyActive()=false, ClaimManager accepts claim (<=)], [VARIATION:block.timestamp = maturityTime+1 → wrapper active if gateGracePeriod>0, ClaimManager rejects (RS1-1 compound)]
**Severity**: Informational
**Location**: `CoveredVaultAccrual.sol:158`, `ClaimManager.sol:307`

**Description**:
The wrapper's `_isPolicyActive()` uses strict `<` for the maturity boundary:
```solidity
// CoveredVaultAccrual.sol:158
return metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
```

ClaimManager's `_fileClaimWithMetadata()` uses non-strict `<=` for the same raw maturity:
```solidity
// ClaimManager.sol:307
block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime
```

At the exact second `block.timestamp == maturityTime`:
- `_isPolicyActive()` returns `false` (strict `<` fails) — wrapper considers policy expired
- ClaimManager accepts the claim (`<=` passes)

This 1-second window is de minimis in isolation, but adds a nuanced asymmetry: a user who withdraws at exactly `maturityTime` will have `_isPolicyActive() == false`, skipping insurance entirely (`_computeInsurance` returns 0), while a direct `fileClaim()` call in the same block would succeed at ClaimManager.

**Note**: This is a subordinate finding to RS1-1 (same root cause: boundary mismatch between contracts). The 1-second gap is distinct from the full grace-period gap and represents an independent, smaller issue.

**Impact**: Users withdrawing at the exact maturity second receive no insurance payout from the wrapper even though ClaimManager would accept their claim. Affects exactly 1 second of the policy lifetime.

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:156-158
uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
return metadata.buyer != address(0) && block.timestamp >= metadata.startTime
    && block.timestamp < effectiveMaturity; // strict less-than

// ClaimManager.sol:306-309
require(
    block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime, // non-strict <=
    ClaimOutsideCoverageWindow(...)
);
```

### Postcondition Analysis
**Postconditions Created**: User at exact maturity second gets no insurance
**Postcondition Types**: TIMING
**Who Benefits**: N/A — this is a design inconsistency

---

## Finding [VS-2]: setRewardsManager Sibling — PremiumManager Does Not Revoke Old Approval When Paused/Unpaused Transitions Occur (Informational)

*[Re-evaluated after sibling propagation check — see below. This was NOT confirmed as a new finding; the actual new finding is VS-2 below.]*

---

## Finding [VS-2]: _activeElapsedFrom Catch-Up Branch Does Not Guard Against Pre-startTime Checkpoint (PC1-2 Severity Calibration Issue)

**Verdict**: CONFIRMED (severity upgrade from Low to Low — calibration note only)
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R14:✗(no aggregate)]
**Depth Evidence**: [BOUNDARY:lastPremiumAccrualTime < startTime → activeStart = startTime, catch-up window correct], [TRACE: initialize() sets lastPremiumAccrualTime=block.timestamp; if called before policy start, first post-expiry accrual uses correct activeStart=startTime]
**Severity**: Low
**Location**: `CoveredVaultAccrual.sol:126-131`

**Description**:
`_activeElapsedFrom()` at L116-136 has a catch-up branch for expired policies:
```solidity
if (
    meta.buyer != address(0) && effectiveMaturity > checkpoint && block.timestamp >= uint256(meta.startTime)
) {
    uint256 activeStart = checkpoint > uint256(meta.startTime) ? checkpoint : uint256(meta.startTime);
    if (effectiveMaturity > activeStart) {
        return effectiveMaturity - activeStart;
    }
}
```

The guard `block.timestamp >= uint256(meta.startTime)` prevents catch-up when current time is before policy start. However, the `activeStart` calculation `checkpoint > meta.startTime ? checkpoint : meta.startTime` correctly clamps to `startTime` when `checkpoint < startTime`.

**Existing finding PC1-2 states**: "_activeElapsedFrom Returns Stale Catch-Up Window When lastPremiumAccrualTime Predates Policy Start".

After code trace: when `lastPremiumAccrualTime` was set at `initialize()` (e.g., at deployment time T0), and the policy starts at T1 (T1 > T0), and accrual is first triggered post-expiry at T2 (T2 > effectiveMaturity > T1), the catch-up window = `effectiveMaturity - max(T0, T1) = effectiveMaturity - T1`. This is **correct** — only the time from policy start is counted. The code handles this properly via `activeStart = startTime` when `checkpoint < startTime`.

**[VS-UPDATE-PC1-2]**: Upon re-analysis, the catch-up branch correctly uses `max(checkpoint, startTime)`, preventing phantom accrual for pre-policy gaps. The issue reported in PC1-2 relates to a specific scenario where the wrapper initialized but never had premium triggered before policy start — in that case, the **active** branch fires (`_isPolicyActive()` true), not the catch-up branch, and `block.timestamp - checkpoint` would include pre-startTime seconds. However, `_isPolicyActive()` checks `block.timestamp >= metadata.startTime`, so if the policy hasn't started yet, `_isPolicyActive()` returns false and the catch-up branch is entered. The catch-up branch guard `block.timestamp >= meta.startTime` prevents firing before policy start. **Verdict: PC1-2 is valid only if there is a window where the policy is bound but not yet started AND a user deposits (triggering _accruePremium → _activeElapsedFrom with _isPolicyActive()=false). In that window, the catch-up branch fires, `activeStart = max(checkpoint, startTime) = startTime`, and returns `effectiveMaturity - startTime` — correct.** Actually, no: if `block.timestamp < startTime`, then `block.timestamp >= meta.startTime` at L127 is false → the catch-up branch is skipped → returns 0 → no phantom accrual. PC1-2's phantom accrual path requires `lastPremiumAccrualTime < startTime AND block.timestamp > startTime AND _isPolicyActive()=true` — in that case the LIVE branch fires returning `block.timestamp - checkpoint` which includes pre-startTime seconds. **This IS the PC1-2 bug path.**

**VS-2 validation result**: PC1-2 is valid. Severity Low is correct. No change needed.

---

## Finding [VS-3]: CHECK 9 Sibling Propagation — maxWithdraw Double-Deduction Sibling in userShortfall()

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✓, R6:✗(no role), R8:✗(single-step view), R10:✓, R13:✓, R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:owedPremium > 0 → userShortfall overstates loss], [TRACE: _accruedPremium() included in totalUserPremium but NOT in _userMorphoValue denominator], [VARIATION:comparing userShortfall vs calculateShortfall for same user shows different accounting for accrued premium]
**Severity**: Low
**Location**: `CoveredVaultWrapper.sol:427-438`

**Description**:
The existing finding PC1-1 identifies that `maxWithdraw()` double-deducts premium: `grossAssets` from `_convertToAssets()` already has premium subtracted via `totalAssets()`, and then `totalDeductions` subtracts owed premium again.

Investigating whether `userShortfall()` has the same pattern:

```solidity
// CoveredVaultWrapper.sol:426-438
function userShortfall(address user) external view override returns (uint256) {
    if (balanceOf(user) == 0) return 0;
    uint256 accrued = _accruedPremium();

    uint256 principal = userPrincipal[user];
    uint256 totalUserPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[user])
        + (totalPrincipal > 0 ? principal.mulDiv(accrued, totalPrincipal, Math.Rounding.Floor) : 0);
    uint256 userMorphoNet = _safeSub(_userMorphoValue(user), totalUserPremium);
    uint256 adjustedUserPrincipal = _safeSub(principal, totalUserPremium);
    if (adjustedUserPrincipal > userMorphoNet) {
        return _capAndApplyDeductible(adjustedUserPrincipal - userMorphoNet, adjustedUserPrincipal);
    }
    return 0;
}
```

`_userMorphoValue(user)` calls `IVaultV2(morphoVault).convertToAssets(userMorphoShares[user])` — this returns the raw Morpho value for the user's shares, **not** reduced by premium. Premium is then subtracted as `totalUserPremium` from this gross value to get `userMorphoNet`.

`adjustedUserPrincipal = principal - totalUserPremium` — this reduces the insured basis by the user's premium obligation.

The shortfall = `adjustedUserPrincipal - userMorphoNet = (principal - totalUserPremium) - (rawMorphoValue - totalUserPremium) = principal - rawMorphoValue`.

**Premium cancels out** in the shortfall computation. This is internally consistent: both numerator and denominator are reduced by the same `totalUserPremium`, so the shortfall equals the raw Morpho loss on the principal. This is the **correct** formula.

However, the **display** issue: `userShortfall()` shows loss relative to principal as if premium has already been paid, but the user's effective balance after premium deduction is `rawMorphoValue - totalUserPremium`. If a user has a large owed premium and a modest Morpho loss, `userShortfall()` may show 0 (because `principal - totalUserPremium <= rawMorphoValue - totalUserPremium`) even though the user's net position is significantly below principal.

Concretely: if principal=1000, owed premium=200, raw Morpho=800:
- `adjustedUserPrincipal = 1000 - 200 = 800`
- `userMorphoNet = 800 - 200 = 600`
- `shortfall = 800 - 600 = 200` → shows 200

But the user's actual net position is `800 (Morpho) - 200 (premium) = 600`, and they deposited 1000 — actual loss is 400, not 200. The insurance claim would be on 200 (after premium deduction), but the user's total economic loss is 400.

**Note**: This is not a double-deduction like PC1-1. It is a different issue: `userShortfall()` measures the INSURABLE loss (what insurance will pay) correctly, but may be misread as the total economic loss. This is a documentation/UX gap rather than a calculation error.

**Self-consistency check**: The `adjustedUserPrincipal - userMorphoNet = principal - rawMorphoValue` simplification shows the shortfall equals the raw Morpho loss — which IS what insurance covers (independent of premium, since premium is the cost of insurance not a loss). The function is mathematically correct for computing the insurance claim amount, but the NatSpec does not clarify this distinction.

**Verdict amendment**: After self-consistency check, the formula is correct. Severity downgraded to Informational. The function correctly computes the insurance-claimable shortfall. What the user receives is `rawMorphoValue - premiumDeducted + insurance`, which is approximately `rawMorphoValue - premiumDeducted + (principal - rawMorphoValue)` = `principal - premiumDeducted`. This is the intended behavior: principal restored net of premium. No economic error.

**[Final Verdict]: REFUTED — userShortfall() correctly measures insurable loss; the premium cancellation is intentional.**

---

## Finding [VS-4]: CHECK 1 — _activeElapsedFrom Live Branch Returns Unclamped Delta Including Pre-startTime Seconds (PC1-2 Confirmation)

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R14:✗(no aggregate)]
**Depth Evidence**: [BOUNDARY:checkpoint < startTime AND _isPolicyActive()=true → activeElapsed includes (startTime - checkpoint) phantom seconds], [TRACE:_deposit() at T0 (before policy start) → lastPremiumAccrualTime=T0; first deposit at T1>startTime calls _accruePremium → _isPolicyActive()=true → returns T1-T0 (includes pre-policy gap)]
**Severity**: Low
**Location**: `CoveredVaultAccrual.sol:116-118`

**Description**:
When `_isPolicyActive()` returns true (policy started and not expired), `_activeElapsedFrom()` returns:
```solidity
return block.timestamp - checkpoint; // checkpoint = lastPremiumAccrualTime
```

If `initialize()` was called at time T0 (sets `lastPremiumAccrualTime = T0`), and the policy starts at `meta.startTime = T1 > T0`, and the first user interaction occurs at T2 > T1:
- `_isPolicyActive()` = true (T2 ≥ T1, T2 < effectiveMaturity)
- `_activeElapsedFrom(T0)` = `T2 - T0`
- This includes `T1 - T0` seconds BEFORE the policy started

Premium accrues for `T1 - T0` phantom seconds when no policy was active. This is the confirmed PC1-2 path.

**This is a validation confirmation of PC1-2 (Low), not a new finding.**

**[VS-UPDATE-PC1-2]**: Code-verified confirmation of the phantom accrual path. The live branch (`_isPolicyActive() = true`) does not clamp to `max(checkpoint, startTime)`. Only the catch-up branch does. Severity Low is correct.

---

## Finding [VS-5]: CHECK 9 Sibling — ClaimManager setSwapper Has No Approval Revocation (Sibling of PC4-1)

**Verdict**: REFUTED (sibling does NOT exist)
**Step Execution**: ✓1,2,3,5
**Rules Applied**: [R4:✗(clear), R5:✓(sibling check), R6:✗(no role), R8:✓, R10:✓, R11:✓, R14:✗]
**Depth Evidence**: [TRACE:_approveIfERC20(collateral, swapper, amount) at L639; _approveIfERC20(collateral, swapper, 0) at L669 — per-use revocation pattern]

**Description**:
PC4-1 found that `PremiumManager.setRewardsManager()` leaves unlimited approval on the old `rewardsManager`. Sibling propagation check: does `ClaimManager.setSwapper()` have the same pattern?

`ClaimManager._executeCollateralSwap()` at L639: `_approveIfERC20(collateralToken, swapper, collateralAmount)` — grants transient, per-use approval.
At L669: `_approveIfERC20(collateralToken, swapper, 0)` — explicitly revokes after each swap.

`setSwapper()` updates `swapper` but old swapper has no persistent approval. The pattern is transient, not unlimited. **Sibling does NOT exist. REFUTED.**

---

## Finding [VS-6]: CHECK 3 — emergencyRedeem/emergencyWithdraw Bypass SKIP_INSURANCE_SLOT Resets if Inner Call Reverts

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R12:✗(no dangerous precondition), R13:✓, R14:✗(no aggregate), R15:✗, R16:✗]
**Depth Evidence**: [TRACE:emergencyRedeem() tstore(SKIP_INSURANCE_SLOT,1) → super.redeem() reverts → tstore(SKIP_INSURANCE_SLOT,0) never reached → transient slot persists=1 until tx end]
**Severity**: Informational
**Location**: `CoveredVaultWrapper.sol:241-248`, `CoveredVaultWrapper.sol:257-262`

**Description**:
`emergencyRedeem()` at L241-248:
```solidity
function emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256) {
    _tstore(SKIP_INSURANCE_SLOT, 1);
    super.redeem(shares, receiver, owner);
    _tstore(SKIP_INSURANCE_SLOT, 0);
    ...
}
```

If `super.redeem()` reverts (e.g., Morpho gate blocks redemption, or insufficient shares), the execution jumps to the caller's frame — `_tstore(SKIP_INSURANCE_SLOT, 0)` is never executed. However, transient storage (`tstore`) is cleared at the end of every transaction in EIP-1153. A revert does NOT persist transient storage changes. After the revert, the transaction is unwound entirely — `SKIP_INSURANCE_SLOT` reverts to 0 as part of the EVM's transaction state rollback.

**Self-consistency check**: If `emergencyRedeem()` reverts, the ENTIRE transaction reverts, including the `tstore(SKIP_INSURANCE_SLOT, 1)` write. The slot is 0 after the failed tx. In the next tx, a regular `redeem()` call would see `SKIP_INSURANCE_SLOT = 0` and correctly trigger insurance. No vulnerability.

**Verdict amendment**: REFUTED. EIP-1153 transient storage reverts on transaction failure. The `SKIP_INSURANCE_SLOT` cleanup is not needed for correctness — it is defensive coding. No security issue.

---

## Consolidated Validation Results

### Priority Finding Validation Summary

| Finding | Claimed Severity | Validation Result | Code Evidence |
|---------|-----------------|-------------------|---------------|
| RS1-1 | HIGH | CONFIRMED — ClaimManager uses raw maturityTime; vault uses effectiveMaturity+gateGracePeriod | ClaimManager.sol:307 vs CoveredVaultAccrual.sol:156-158 |
| PC3-1 | HIGH | CONFIRMED — swapOutput > remainingPayout; excess stays in ClaimManager | ClaimManager.sol:663-667 |
| PC3-2 | HIGH | CONFIRMED — pairFees updated live; swap calldata fee frozen at route-set time | UniswapV3Adapter.sol:127-135 vs 193-198 |
| CS-2 | MEDIUM | CONFIRMED — phantom totalPremiumLiability after deep-loss; traced to permanent deflation | CoveredVaultWrapper.sol:578-583 |
| PC4-1 | MEDIUM | CONFIRMED — setRewardsManager has no approval revocation step | PremiumManager.sol:93-97 |

### New Findings Summary

| Finding | Severity | Status |
|---------|----------|--------|
| VS-1 (boundary ≤ vs < at maturityTime) | Informational | CONFIRMED (subordinate to RS1-1) |
| VS-3 (userShortfall sibling check) | — | REFUTED (formula correct) |
| VS-4 (PC1-2 code confirmation) | Low | UPDATE-ONLY (confirms PC1-2) |
| VS-5 (ClaimManager swapper approval sibling) | — | REFUTED (per-use revocation pattern) |
| VS-6 (SKIP_INSURANCE_SLOT revert behavior) | — | REFUTED (EIP-1153 handles correctly) |

**Net new unique findings: 1 (VS-1)**

---

## Findings

---

## Finding [VS-1]: 1-Second Coverage Gap — _isPolicyActive Uses Strict `<` While ClaimManager Uses Non-Strict `<=` at Policy Maturity Boundary

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5 | ✗6(N/A—no role)
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R13:✓, R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:block.timestamp == maturityTime → _isPolicyActive()=false (strict <), ClaimManager accepts claim (<=)], [TRACE: withdrawal at exact maturityTime → _computeInsurance skips (policy not active) → 0 payout, despite ClaimManager being open]
**Severity**: Informational
**Location**: `CoveredVaultAccrual.sol:158`, `ClaimManager.sol:307`

**Description**:
`_isPolicyActive()` uses strict less-than for the upper maturity boundary:
```solidity
// CoveredVaultAccrual.sol:156-158
uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
return metadata.buyer != address(0) && block.timestamp >= metadata.startTime
    && block.timestamp < effectiveMaturity; // strict <
```

ClaimManager's `_fileClaimWithMetadata()` uses non-strict less-than-or-equal for the same raw maturity:
```solidity
// ClaimManager.sol:306-309
require(
    block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime, // <=
    ClaimOutsideCoverageWindow(...)
);
```

At exactly `block.timestamp == maturityTime` (when `gateGracePeriod = 0`):
- Wrapper's `_isPolicyActive()` returns false (strict `<` fails for effective maturity = raw maturity)
- ClaimManager accepts a claim (`<=` passes for the same raw maturity)

A user withdrawing at this exact second receives no insurance payout from the wrapper (policy appears expired), even though a direct `fileClaim()` to ClaimManager in the same block would succeed.

**Impact**: Users withdrawing at exactly the policy maturity second silently receive no insurance when they might be entitled to it. This is a 1-second window, affecting only users who happen to transact at the precise expiry block. The structural gap from RS1-1 (entire grace period) is a much larger issue; this is a subordinate inconsistency.

**Evidence**:
```solidity
// _isPolicyActive: strict less-than
block.timestamp < effectiveMaturity  // strict — maturityTime second is OUT

// ClaimManager: non-strict
block.timestamp <= metadata.maturityTime  // inclusive — maturityTime second is IN
```

### Postcondition Analysis
**Postconditions Created**: User at exact maturity second receives 0 insurance from wrapper
**Postcondition Types**: TIMING
**Who Benefits**: N/A — impacts user at policy boundary

---

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|---------------------|---------|----------|-------------------|-------------------|
| VS-1 | CoveredVaultAccrual.sol:158, ClaimManager.sol:307 | Strict `<` in wrapper vs non-strict `<=` in ClaimManager at maturity boundary creates 1-second coverage gap | CONFIRMED | Informational | TIMING | TIMING |
| VS-UPDATE-RS1-1 | CoveredVaultAccrual.sol:156-158, ClaimManager.sol:306-309 | Vault effectiveMaturity includes gateGracePeriod; ClaimManager uses raw maturityTime — grace window is fully uninsured while premium accrues | CONFIRMED | High | TIMING, STATE | BALANCE, STATE |
| VS-UPDATE-CS-2 | CoveredVaultWrapper.sol:578-583 | totalPremiumLiability decremented by premiumForWithdrawal (actual) not uncappedPremium (owed), creating permanent phantom residual | CONFIRMED | Medium | STATE | STATE, BALANCE |
| VS-UPDATE-PC4-1 | PremiumManager.sol:93-97 | setRewardsManager replaces reference without revoking unlimited approval on old address | CONFIRMED | Medium | ACCESS | BALANCE |
| VS-UPDATE-PC3-1 | ClaimManager.sol:663-667 | swapOutput excess above remainingPayout transferred to beneficiary; delta stranded in ClaimManager | CONFIRMED | High | STATE, BALANCE | BALANCE |
| VS-UPDATE-PC3-2 | UniswapV3Adapter.sol:127-135, 193-198 | pairFees updated live but swap calldata encodes frozen fee tier from route configuration time | CONFIRMED | High | STATE | STATE |
