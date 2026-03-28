# Per-Contract Agent #1: CoveredVaultWrapper Cluster

**Scope**: CoveredVaultWrapper.sol, CoveredVaultAccrual.sol, CoveredVaultStorage.sol, CoveredVaultAdmin.sol, BasePolicyInteractions.sol
**Pass**: Per-contract deep analysis — maximum depth on narrow scope

---

## Finding [PC1-1]: maxWithdraw() Double-Deducts Premium, Systematically Understating Maximum Withdrawable Assets

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear, no externals), R5:✓, R6:✗(no role), R8:✗(single-step view), R10:✓, R11:✗(no external tokens), R12:✗(no dangerous precondition), R13:✓, R14:✗(no aggregate variables), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:shares_A=allShares, owedPremium=365 → maxWithdraw returns 477 but actual out = 660], [VARIATION:premium aged from 0→365 → understatement grows linearly with owed premium], [TRACE:withdraw(maxWithdraw()) → withdraws less than redeem(allShares) → 28% shortfall for long-standing depositor]
**Severity**: Low
**Location**: `CoveredVaultWrapper.sol:442-453`

**Description**:
The `maxWithdraw(owner)` function computes a gross asset estimate using `_convertToAssets(shares, Floor)`, which is the user's proportional share of `totalAssets()`. `totalAssets()` already nets out the global premium liability (`totalPremiumLiability + _accruedPremiumFor`), so `grossAssets` reflects a premium-adjusted vault value. However, `maxWithdraw` then subtracts the user's personal `owedPremium` and their share of pending `_accruedPremiumFor` again:

```solidity
// CoveredVaultWrapper.sol:442-453
function maxWithdraw(address owner) public view override returns (uint256) {
    uint256 shares = balanceOf(owner);
    if (shares == 0) return 0;
    uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
    uint256 principal = userPrincipal[owner];
    uint256 fraction = totalPrincipal > 0 ? principal.mulDiv(WAD, totalPrincipal) : 0;
    uint256 owedPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[owner]);
    uint256 mv = _morphoValue();
    uint256 totalDeductions = owedPremium + _accruedPremiumFor(mv).mulDiv(fraction, WAD);
    return _safeSub(grossAssets, totalDeductions);
}
```

**Concrete trace (single user)**:
- `principal = 1000`, deposited at `cumulativePremiumPerUnit=0`
- After 1 year: `totalPremiumLiability = 365`, `morphoValue = 1010`
- `totalAssets() = 1010 - 365 = 645`
- `grossAssets = 645` (user owns 100% of shares)
- `owedPremium = 365`
- `maxWithdraw = 645 - 365 = 280`

But calling `redeem(allShares)` actually returns:
- Morpho redeems `1010`, premium deducted `365`, `netAssetsReceived = 645`
- Insurance may add more, but even without insurance, `totalOut = 645`

The returned value `280` is `645 - 365 = 280` — the function subtracts premium once via `totalAssets()` and again via `owedPremium`, returning a value 365 lower than the true maximum.

**Two-user trace showing per-user divergence**:
- User A: `principal=1000`, deposited 1 year ago, `owedPremium = 365`
- User B: `principal=1000`, deposited 1 day ago, `owedPremium = 1`
- `totalPremiumLiability = 366`, `morphoValue = 2050`, `totalAssets() = 1684`
- `grossAssets_A = 842`, `owedPremium_A = 365`
- `maxWithdraw_A = 842 - 365 = 477` ← understated by 365
- `grossAssets_B = 842`, `owedPremium_B = 1`
- `maxWithdraw_B = 842 - 1 = 841` ← understated by only 1
- Actual `redeem(allShares_A)` gives `660`; actual `redeem(allShares_B)` gives `660`

The understatement grows proportionally to the user's accumulated owed premium. Long-standing depositors experience the worst under-reporting.

**Impact**:
- ERC-4626 specification requires `maxWithdraw` to return the maximum assets transferable from `owner` through a `withdraw` call. The returned value systematically underestimates this amount, violating the spec.
- Off-chain integrators and smart contracts that read `maxWithdraw()` to determine maximum withdrawal sizes will compute incorrect amounts. Protocols built on top of this vault (e.g., for leveraged strategies or aggregators) will under-utilize deposited capital.
- A user calling `withdraw(maxWithdraw())` will withdraw significantly less than their actual maximum, requiring them to rediscover the shortfall and call `redeem()` instead.
- The understatement worsens linearly with time (proportional to `owedPremium`), meaning long-standing depositors are most affected.

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:106-109
function totalAssets() public view override returns (uint256) {
    uint256 mv = _morphoValue();
    uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);
    return mv > totalLiability ? mv - totalLiability : 0;  // premium already netted here
}

// CoveredVaultWrapper.sol:442-453
function maxWithdraw(address owner) public view override returns (uint256) {
    uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);  // uses totalAssets()
    // ...
    uint256 owedPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[owner]);
    uint256 totalDeductions = owedPremium + _accruedPremiumFor(mv).mulDiv(fraction, WAD);
    return _safeSub(grossAssets, totalDeductions);  // subtracts premium AGAIN
}
```

### Postcondition Analysis
**Postconditions Created**: `maxWithdraw()` returns a value `owedPremium` lower than the ERC-4626 compliant maximum. Gap grows proportionally to `owedPremium` accumulation.
**Postcondition Types**: STATE
**Who Benefits**: N/A (no attacker profit — this is a view function accuracy issue)

---

## Finding [PC1-2]: `_activeElapsedFrom` Returns Stale Catch-Up Window When `lastPremiumAccrualTime` Predates Policy Start

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R11:✗(no external tokens), R12:✗(no dangerous precondition), R13:✗(not design-related), R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:checkpoint=T0(pre-startTime), effectiveMaturity=T3 → returns T3-T1(startTime) correctly], [VARIATION:checkpoint before vs after startTime → branch diverges at activeStart computation], [TRACE:_accruePremium after policy expiry with checkpoint=T0 → accrues full T1-T3 window even if T0-T1 period already elapsed without accrual before policy start]]
**Severity**: Low
**Location**: `CoveredVaultAccrual.sol:116-136`

**Description**:
In `_activeElapsedFrom(checkpoint)`, the catch-up branch (for expired policies) correctly bounds the active window to `[max(checkpoint, startTime), effectiveMaturity]`. This handles the case where `checkpoint` predates the policy start time:

```solidity
// CoveredVaultAccrual.sol:116-136
function _activeElapsedFrom(uint256 checkpoint) internal view returns (uint256) {
    if (_isPolicyActive()) {
        return block.timestamp - checkpoint;  // ← BUG: no clamp to policy startTime
    }
    if (policyId != 0) {
        IPolicyManager.PolicyMetadata memory meta = _policyManager.policyMetadata(policyId);
        uint256 effectiveMaturity = uint256(meta.maturityTime) + gateGracePeriod;
        if (meta.buyer != address(0) && effectiveMaturity > checkpoint && block.timestamp >= uint256(meta.startTime)) {
            uint256 activeStart = checkpoint > uint256(meta.startTime) ? checkpoint : uint256(meta.startTime);
            if (effectiveMaturity > activeStart) {
                return effectiveMaturity - activeStart;
            }
        }
    }
    return 0;
}
```

The catch-up branch uses `activeStart = max(checkpoint, startTime)`, correctly preventing pre-policy accrual. However, the **active policy branch** (`if (_isPolicyActive())`) returns `block.timestamp - checkpoint` without any clamp to `meta.startTime`.

**Scenario where this triggers**:
1. `initialize()` sets `lastPremiumAccrualTime = block.timestamp` = T0 (before policy is bound)
2. Policy is bound: `startTime` = T1 > T0 (policy starts in the future)
3. `_accruePremium()` is NOT called between T0 and T1 (no deposits, no withdrawals)
4. At T1+ε: policy becomes active. `_isPolicyActive()` returns `true`.
5. A deposit triggers `_accruePremium()`: `checkpoint = T0`, `_isPolicyActive() = true`
6. Returns `block.timestamp - T0 = (T1+ε - T0)` — includes pre-policy period `T0` to `T1`

For the `initialize` → policy binding → first deposit flow, `T0 = block.timestamp` at initialization and T1 = `meta.startTime`. The interval `T1 - T0` could be hours or days. Accrual over this pre-policy window inflates `totalPremiumLiability` with spurious premium.

**Quantification**: If `premiumRatePerSecond = 15e9` (max), `totalPrincipal = 1e18` (1e18 wei), pre-policy gap = 1 day (86400 seconds):
Extra accrual = `1e18 * 15e9 * 86400 / 1e18 = 1.296e9` (about 1.3 billion wei = ~1.3e-9 ETH). At larger principal this becomes material.

Note: the catch-up branch CORRECTLY handles this by clamping to `startTime`. The inconsistency is that the active-policy branch does not apply the same clamping, and it is reachable when `lastPremiumAccrualTime` was set before `startTime` and no accrual was triggered between `lastPremiumAccrualTime` and `startTime`.

The NatSpec for `_accruePremium` says: "Always advance the timestamp unconditionally so that when a new policy is later bound, there is no catch-up accrual for the inactive gap period." The advance occurs but the timestamp (`T0`) predates `startTime` (`T1`), so there IS still a catch-up accrual for `T1 - T0`.

**Impact**:
- Depositors pay phantom premium for the pre-policy period (`T0` to `T1`), which increases `totalPremiumLiability` without corresponding coverage.
- `totalAssets()` is artificially deflated for all depositors by the phantom premium amount.
- The effect only manifests on the FIRST call to `_accruePremium()` after `startTime` if no calls were made between `initialize` and `startTime`. Subsequent calls are unaffected.
- Severity bounded by `premiumRatePerSecond * (startTime - initializeTime) * totalPrincipal / WAD`. In a typical setup (hours between initialize and policy start, modest TVL), this is small but non-zero.

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:117-118 — active branch does NOT clamp to startTime
if (_isPolicyActive()) {
    return block.timestamp - checkpoint;  // checkpoint may predate policy startTime
}

// Catch-up branch (expired policy) CORRECTLY clamps to startTime:
uint256 activeStart = checkpoint > uint256(meta.startTime) ? checkpoint : uint256(meta.startTime);
return effectiveMaturity - activeStart;  // bounded by startTime

// CoveredVaultAccrual.sol:27-33 — timestamp always advanced
function _accruePremium() internal {
    uint256 checkpointTime = lastPremiumAccrualTime;
    lastPremiumAccrualTime = block.timestamp;  // advances even before policy starts
    if (block.timestamp == checkpointTime) return;
}
```

### Precondition Analysis
**Missing Precondition**: `lastPremiumAccrualTime` must be set BEFORE `meta.startTime` AND `_accruePremium()` must not be called between T0 and T1.
**Precondition Type**: TIMING
**Why This Blocks**: In practice, if any deposit or withdrawal happens between initialize and policy startTime, `_accruePremium` would advance `lastPremiumAccrualTime` to block.timestamp, and the next call after `startTime` would correctly start from after the pre-start period.

### Postcondition Analysis
**Postconditions Created**: Phantom `totalPremiumLiability` accrual for pre-policy period. `cumulativePremiumPerUnit` slightly inflated.
**Postcondition Types**: STATE, BALANCE
**Who Benefits**: `premiumRecipient` receives slightly more premium (when collected) at depositors' expense

---

## Finding [PC1-3]: `_withdraw` Decrements `totalPrincipal` After External Interactions, Creating Transient Invariant Break During Morpho/ClaimManager Callbacks

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear, externals have trust), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R11:✗(no external tokens), R12:✓, R13:✗(not design), R14:✓, R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:_withdraw→_executeWithdrawal→_claimInsurance→fileClaim→evaluate() while totalPrincipal still includes withdrawn user's principal], [BOUNDARY:totalPrincipal=1000, userPrincipalForWithdrawal=1000 → totalPrincipal=1000 during evaluate() then 0 after return], [VARIATION:evaluate() reads policyId/PENDING_CLAIM_AMOUNT only → not affected by stale totalPrincipal]]
**Severity**: Informational
**Location**: `CoveredVaultWrapper.sol:186-195`, `CoveredVaultWrapper.sol:583-584`

**Description**:
In `_withdraw()`, `totalPrincipal` is decremented AFTER `_executeWithdrawal()` returns:

```solidity
// CoveredVaultWrapper.sol:186-195
uint256 actualOut = _executeWithdrawal(owner, receiver, shares, userPrincipalForWithdrawal, ownerBalance);
totalPrincipal -= userPrincipalForWithdrawal;  // ← decremented AFTER external calls
```

Inside `_executeWithdrawal()`, the sequence is:
1. `userPrincipal[owner_]` updated to `newPrincipal` via `_updateDebtsAfterWithdrawal`
2. Morpho `redeem()` called (external)
3. `_claimInsurance()` called, which calls `claimManager.fileClaim()` (external)
4. ClaimManager calls back into vault's `evaluate()` (external callback)
5. Control returns to `_withdraw()` which decrements `totalPrincipal`

During steps 2-4, `totalPrincipal` is stale: it still includes `userPrincipalForWithdrawal` that belongs to the user whose shares have already been burned. The invariant `totalPrincipal == sum(userPrincipal[all users])` is temporarily violated between `_updateDebtsAfterWithdrawal` (which sets `userPrincipal[owner_] = newPrincipal`) and the `totalPrincipal` decrement.

At present, none of the external callbacks (`evaluate()`, `_morphoValue()`) read `totalPrincipal` during this window. The `nonReentrant` guard prevents reentrant calls that could observe the stale value via state-changing paths. However, the stale `totalPrincipal` IS observable via view calls (e.g., `calculateShortfall()`, `userShortfall()`) from any external contract during the `fileClaim` callback window if the ClaimManager's `fileClaim` makes external staticcalls.

**Impact**:
- Currently: no material impact because `evaluate()` only reads `PENDING_CLAIM_AMOUNT_SLOT` and `policyId`.
- Future risk: if `evaluate()` is modified or ClaimManager is upgraded to read `totalPrincipal` (e.g., for a protocol-level invariant check), the stale value would produce incorrect results.
- `calculateShortfall()` observed via a staticcall during the callback window returns a higher-than-actual shortfall (stale totalPrincipal includes withdrawing user's principal).
- This is a **design hygiene issue** rather than an exploitable bug given current external contract implementations.

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:586-601 — userPrincipal updated first
function _updateDebtsAfterWithdrawal(address owner_, uint256 principal_, ...) private {
    uint256 newPrincipal = principal_ - principalForWithdrawal_;
    // ...
    userPrincipal[owner_] = newPrincipal;  // ← updated here
}

// CoveredVaultWrapper.sol:189 — totalPrincipal updated AFTER external callbacks
totalPrincipal -= userPrincipalForWithdrawal;  // ← after Morpho redeem + fileClaim returns
```

### Precondition Analysis
**Missing Precondition**: External callback (evaluate() or future ClaimManager upgrade) must read `totalPrincipal` during the window between `_updateDebtsAfterWithdrawal` and `totalPrincipal` decrement.
**Precondition Type**: EXTERNAL
**Why This Blocks**: Current `evaluate()` implementation (CoveredVaultWrapper.sol:383-403) only reads `PENDING_CLAIM_AMOUNT_SLOT` and `policyId`. No current codepath reads `totalPrincipal` during this window.

---

## Finding [PC1-4]: `setMorphoGateActive` Allows Multiple Activations Without Corresponding Deactivations, Unboundedly Growing `gateGracePeriod` Without Audit Trail

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✓, R8:✓, R10:✓, R11:✗(no external tokens), R12:✓, R13:✓, R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [BOUNDARY:gateActivatedAt=T1, deactivate at T2, gateGracePeriod=T2-T1; re-activate T3, deactivate T4 → gateGracePeriod=(T2-T1)+(T4-T3) unbounded], [VARIATION:10 gate cycles of 1 day each → gateGracePeriod=10 days, policy extends 10 days post-maturity → premium accrues 10 extra days], [TRACE:_isPolicyActive after maturity → returns true during gateGracePeriod window → _claimInsurance→fileClaim→ClaimOutsideCoverageWindow (RS1-1)]]
**Severity**: Low
**Location**: `CoveredVaultAdmin.sol:168-186`, `CoveredVaultAccrual.sol:116-136`, `CoveredVaultStorage.sol:160-161`

**Description**:
The `setMorphoGateActive` function accumulates `gateGracePeriod` on every deactivation without any cap or governance timelock. Each gate cycle adds `(deactivateTime - activateTime)` to `gateGracePeriod`:

```solidity
// CoveredVaultAdmin.sol:168-186
function setMorphoGateActive(bool active) external override onlyOwner {
    _accruePremium();
    if (active && !morphoGateActive) {
        gateActivatedAt = block.timestamp;
        // ...
    } else if (!active && morphoGateActive && gateActivatedAt > 0) {
        uint256 gateDuration = block.timestamp - gateActivatedAt;
        gateGracePeriod += gateDuration;  // ← unbounded accumulation, no cap
        gateActivatedAt = 0;
    }
    morphoGateActive = active;
}
```

**Compound effect with RS1-1 (already found)**:
The `gateGracePeriod` extension causes `_isPolicyActive()` to return `true` during `[maturityTime, maturityTime + gateGracePeriod]`. However, `ClaimManager._fileClaimWithMetadata` rejects all claims with `block.timestamp > maturityTime`. The result is:
1. `_isPolicyActive()` returns `true` during grace window → premium accrues
2. Insurance claims revert at ClaimManager → users pay premium with zero coverage
3. `gateGracePeriod` can span days or weeks if gates are frequently toggled

**Additional dimension NOT in RS1-1**: Beyond the ClaimManager mismatch, the unbounded `gateGracePeriod` also means:
- `lastPremiumAccrualTime` advances during gate-active periods (by design), but when gate is lifted, `_activeElapsedFrom` catch-up only covers `[lastCheckpoint, effectiveMaturity]`. If `gateGracePeriod` is very large, premium accrual continues for an extended window post-maturity.
- The owner can strategically toggle the gate to extend the policy's effective maturity indefinitely (each deactivation adds to grace period), keeping `_isPolicyActive()` true and premium accrual running long after the policy's nominal maturity.

**Impact**:
- Owner can extend the vault's "active" premium accrual period indefinitely by toggling the Morpho gate
- Combined with RS1-1: each accumulated gate cycle extends the window where users pay premium but receive zero insurance
- No cap, no governance timelock, no maximum `gateGracePeriod` enforced anywhere
- Users have no way to audit the accumulated grace period without reading chain state

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:153-158
function _isPolicyActive() internal view returns (bool) {
    uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;  // no cap
    return metadata.buyer != address(0) && block.timestamp >= metadata.startTime
        && block.timestamp < effectiveMaturity;
}
```

### Postcondition Analysis
**Postconditions Created**: Policy effective maturity extended by total gate duration. Premium accrues through extended window. Insurance claims during extended window rejected by ClaimManager (RS1-1).
**Postcondition Types**: STATE, TIMING
**Who Benefits**: `premiumRecipient` receives premium for days/weeks post-policy-maturity

---

## Finding [PC1-5]: `_executeWithdrawal` Burns Wrapper Shares Before Morpho Redeem Succeeds, Leaving User With Zero Shares If Morpho Reverts After Successful Burn

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R11:✗(no external tokens), R12:✗(no dangerous precondition post-analysis), R13:✗(not design), R14:✗(no aggregate), R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:_burn(owner, shares)→IVaultV2.redeem()→revert MorphoRedeemReverted()→entire tx reverts→burn rolled back], [BOUNDARY:Morpho gate active → MorphoRedeemReverted → Solidity revert propagates up → nonReentrant lock released via revert → _burn rolled back by EVM]]
**Severity**: N/A (refuted)
**Location**: `CoveredVaultWrapper.sol:548-570`

**Description**:
On initial inspection, `_executeWithdrawal` burns the owner's wrapper shares (line 548: `_burn(owner_, shares_)`) BEFORE the Morpho redeem call (line 563). If Morpho's `redeem()` reverts (e.g., gate active), the concern is that the user loses shares permanently.

However, the Morpho `redeem()` call is NOT wrapped in a try/catch for success — rather, on catch it emits a diagnostic event and then calls `revert MorphoRedeemReverted()`:

```solidity
// CoveredVaultWrapper.sol:563-570
try IVaultV2(morphoVault).redeem(redeemShares, address(this), address(this)) returns (uint256 received) {
    assetsReceived = received;
    lastKnownMorphoValue = _morphoValue();
} catch {
    emit IE.MorphoRedeemFailed(redeemShares);
    revert MorphoRedeemReverted();  // ← re-reverts, rolling back entire tx including _burn
}
```

Since `revert MorphoRedeemReverted()` propagates up through the call stack, the ENTIRE transaction reverts, including the `_burn` call. EVM reverts all state changes atomically. The user retains their shares.

The emit before revert is a Slither false positive pattern (documented with `slither-disable-next-line reentrancy-events`) — the event is emitted but if the tx reverts, the event is also not recorded.

**Status**: REFUTED. The share burn is safely rolled back via the outer transaction revert.

### Precondition Analysis
**Missing Precondition**: A path where `_burn` succeeds but Morpho reverts WITHOUT the whole transaction reverting.
**Precondition Type**: EXTERNAL
**Why This Blocks**: `revert MorphoRedeemReverted()` is unconditional on Morpho failure. There is no try/catch around `_burn` that would leave partial state.

---

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|-----------|----------|---------------------|---------|----------|-------------------|-------------------|
| PC1-1 | CoveredVaultWrapper.sol:442-453 | `maxWithdraw` subtracts `owedPremium` from `grossAssets` which already excludes it via `totalAssets()`, double-deducting premium | CONFIRMED | Low | STATE | STATE |
| PC1-2 | CoveredVaultAccrual.sol:116-136 | Active-policy branch of `_activeElapsedFrom` returns `block.timestamp - checkpoint` without clamping to `meta.startTime`, enabling pre-policy premium accrual | CONFIRMED | Low | TIMING | STATE, BALANCE |
| PC1-3 | CoveredVaultWrapper.sol:186-195 | `totalPrincipal` decremented after `_executeWithdrawal` returns, leaving stale value observable during Morpho/ClaimManager callbacks | PARTIAL | Informational | EXTERNAL | STATE |
| PC1-4 | CoveredVaultAdmin.sol:168-186 | `gateGracePeriod` accumulates unboundedly across gate cycles, extending effective maturity and enabling owner to run premium accrual indefinitely post-expiry with zero insurance coverage | CONFIRMED | Low | ACCESS | STATE, TIMING |
| PC1-5 | CoveredVaultWrapper.sol:548-570 | Share burn occurs before Morpho redeem — REFUTED because unconditional revert on Morpho failure rolls back entire tx | REFUTED | N/A | N/A | N/A |
