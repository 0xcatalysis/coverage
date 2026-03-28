# Verification Batch H — Informational Hypotheses

Hypotheses verified: H-42, H-43, H-48, H-49, H-50, H-51, H-54, H-55, H-57, H-58, H-59, H-60, H-61

---

## H-42: PolicyManager._validateRequest Missing startTime Check

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`PolicyManager._validateRequest` (PolicyManager.sol:358-373):

```solidity
require(
    request.quote.startTime < request.quote.maturityTime && request.quote.maturityTime > block.timestamp,
    InvalidCoverageWindow(request.quote.startTime, request.quote.maturityTime)
);
```

The check confirms `maturityTime > block.timestamp` and `startTime < maturityTime`, but does NOT verify `startTime >= block.timestamp`. A caller can supply a `startTime` in the past and pass validation. The defence-in-depth guard is absent: `bindPolicy` (L253-255) computes `maturityTime - startTime == draft.duration` and stores `boundPolicy.startTime` directly into `PolicyMetadata.startTime` without a floor check.

### Verdict

The `_validateRequest` function lacks a `startTime >= block.timestamp` check. A stale `startTime` passes validation and is stored verbatim in `PolicyMetadata`, silently creating a phantom pre-policy premium window that _activeElapsedFrom may accrue against. Confirmed as a defence-in-depth gap.

---

## H-43: PremiumCollector Missing recoverTokens Function

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

Sibling contracts with `recoverTokens`:
- `ClaimManager.sol:169` — `function recoverTokens(address token, address to, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE)`
- `Swapper.sol:132` — `function recoverTokens(address token, address to, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE)`

`PremiumCollector.sol` public/external functions: `pause`, `unpause`, `registerVault`, `removeVault`, `updateVault`, `distributeBatch`, `setDistributeInterval`, `setPremiumManager`, `setCoverPoolFactory`, `getRegisteredVaults`, `getVaultConfig`, `getAccruedShares`, `getDistributableVaults`. No `recoverTokens` function exists.

`IPremiumCollector.sol` interface also does not declare `recoverTokens`.

### Verdict

PremiumCollector is the only UUPS proxy contract in the protocol that lacks a `recoverTokens` function. Tokens accidentally sent to PremiumCollector (e.g., by a misconfigured vault or keeper) cannot be recovered by the admin. The absence is inconsistent with sibling contracts.

---

## H-48: _withdraw Decrements totalPrincipal After External Interactions

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`CoveredVaultWrapper._withdraw` (CoveredVaultWrapper.sol:163-196):

```solidity
function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
    internal override nonReentrant
{
    _accruePremium();
    // ...
    uint256 actualOut = _executeWithdrawal(owner, receiver, shares, userPrincipalForWithdrawal, ownerBalance);
    // ↑ _executeWithdrawal contains:
    //   - IVaultV2(morphoVault).redeem(...)   ← external call #1
    //   - _settleWithdrawalTransfer → _claimInsurance → claimManager.fileClaim(...)  ← external call #2

    totalPrincipal -= userPrincipalForWithdrawal;  // ← state update AFTER external calls
    // ...
}
```

The CEI violation: `totalPrincipal` is decremented at L189 after `_executeWithdrawal` (L187), which performs two external calls (Morpho redeem at CoveredVaultWrapper.sol:563, ClaimManager fileClaim at CoveredVaultWrapper.sol:365). A reentrancy guard (`nonReentrant`) is present, but the violation remains a pattern issue.

Note: `userPrincipal[owner]` is correctly decremented inside `_updateDebtsAfterWithdrawal` (called within `_executeWithdrawal`), so partial CEI compliance exists. Only `totalPrincipal` remains post-external-call.

### Verdict

The CEI pattern violation is confirmed: `totalPrincipal` is decremented after external calls (Morpho redeem and ClaimManager fileClaim). The `nonReentrant` guard prevents exploitation, making this informational. The recommendation is to move `totalPrincipal -= userPrincipalForWithdrawal` before `_executeWithdrawal`.

---

## H-49: acceptOwnership Clears Timestamps But Not Pending Values

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`CoveredVaultAdmin.acceptOwnership` (CoveredVaultAdmin.sol:116-124):

```solidity
function acceptOwnership() public override {
    super.acceptOwnership();
    pendingPremiumRateTimestamp = 0;
    pendingDeductibleTimestamp = 0;
    pendingMaxCoverableLossTimestamp = 0;
    pendingUpgradeTimestamp = 0;
    pendingImplementation = address(0);
    pendingPremiumRecipientTimestamp = 0;
}
```

Cleared: all `*Timestamp` fields and `pendingImplementation`.
NOT cleared:
- `pendingPremiumRate` (CoveredVaultStorage.sol:148) — stores the pending rate value
- `pendingMaxCoverableLossBps` (CoveredVaultStorage.sol:133) — stores the pending bps value
- `pendingDeductibleBps` (CoveredVaultStorage.sol:127) — stores the pending bps value
- `pendingPremiumRecipient` (CoveredVaultStorage.sol:153) — stores the pending address

Impact: After ownership transfer, the new owner finds stale pending values with zeroed timestamps. Calling `_requireTimelockReady(0)` reverts with `NoPendingChange()` (CoveredVaultAdmin.sol:221), so the stale values cannot be executed directly. However, the new owner proposing the same parameter will overwrite the stale value, making the inconsistency cosmetic. The incomplete cleanup is nonetheless a hygiene issue.

### Verdict

`acceptOwnership` correctly zeros all timestamp slots but leaves the corresponding pending value fields populated. The stale values cannot be executed (zeroed timestamps block `_requireTimelockReady`) but the inconsistent state is a code quality concern.

---

## H-50: Swapper Stored Route Calldata May Become Stale

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`Swapper.setSwapRoute` (Swapper.sol:146-173) stores arbitrary `bytes calldata swapCalldata` into `_swapRoutes[routeKey].swapCalldata` with no expiry or validity metadata:

```solidity
route.swapCalldata = swapCalldata;
```

`Swapper.executeSwap` (Swapper.sol:240) uses stored calldata as fallback:

```solidity
bytes memory effectiveCalldata = params.swapCalldata.length > 0 ? params.swapCalldata : routeCalldata;
```

There is no staleness check, expiry timestamp, or nonce on the stored calldata. If the DEX route changes (e.g., Uniswap pool fee tier change, path update, or pool migration), the stored calldata silently becomes stale. This is the static-calldata model described in the contract NatSpec.

### Verdict

The Swapper stores route calldata statically with no expiry mechanism. A SWAP_MANAGER_ROLE must manually update routes when pool configurations change. The risk is operational (missed update leads to failed or suboptimal swaps) rather than a direct fund-loss vector.

---

## H-51: PremiumManager approveSpender Allows Arbitrary ERC-20 Approvals

**Final Verdict**: CONFIRMED — [ASSUMPTION-DEP: TRUSTED-ACTOR] tag is CORRECT
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`PremiumManager.approveSpender` (PremiumManager.sol:102-113):

```solidity
function approveSpender(address token, address spender, uint256 amount)
    external override onlyRole(DEFAULT_ADMIN_ROLE)
{
    require(token != address(0) && spender != address(0), ZeroAddress());
    IERC20(token).forceApprove(spender, amount);
    emit SpenderApproved(token, spender, amount);
}
```

The function is restricted to `DEFAULT_ADMIN_ROLE`. Per the trust assumption table (design_context.md entry #1), `DEFAULT_ADMIN_ROLE` holders are classified as `FULLY_TRUSTED`: "Can upgrade implementations, pause/unpause, set critical contract addresses... Complete control over protocol operation." The SSPRouter uses a pre-set approval to pull restaker shares (design_context.md "Notable Design Patterns").

The [ASSUMPTION-DEP: TRUSTED-ACTOR] tag is appropriate: the capability (arbitrary approval of any ERC-20 to any spender) requires a fully-trusted actor to misuse and is an intentional design choice for SSPRouter integration.

### Verdict

`approveSpender` is correctly gated behind `DEFAULT_ADMIN_ROLE` (FULLY_TRUSTED). The [ASSUMPTION-DEP: TRUSTED-ACTOR] tag is confirmed correct. This is an informational observation about the breadth of admin power, not an exploitable bug.

---

## H-54: premiumRatePerSecond Missing WAD-Scaled Qualifier

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`CoveredVaultStorage.sol:93`:

```solidity
/// @notice Premium rate per second (WAD-scaled)
uint256 public override premiumRatePerSecond;
```

The NatSpec comment says "WAD-scaled" but the variable name `premiumRatePerSecond` does not convey the WAD scaling. By contrast, `WAD` is explicitly defined at L50 (`uint256 internal constant WAD = 1e18`) and `MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991` (L54) does not include a unit qualifier in the name.

Accrual formula in CoveredVaultAccrual.sol:54:
```solidity
uint256 accrued = _totalPrincipal.mulDiv(premiumRatePerSecond * activeElapsed, WAD, Math.Rounding.Floor);
```

The division by WAD confirms WAD-scaling. An integrator reading only the variable name `premiumRatePerSecond` without the NatSpec would not know the unit is `wei/second * 1e18` rather than raw `wei/second`.

### Verdict

The variable name lacks a WAD unit qualifier, reducing readability and increasing integration risk. The NatSpec does document this, partially mitigating the concern.

---

## H-55: Combined Fee Cap Dead Code (100% Unreachable)

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`PremiumManager.sol`:
- `_MAX_FEE_BPS = 10_000` (L33) — 100%
- `_MAX_PLATFORM_FEE_BPS = 2500` (L34) — 25%

`CoverPool.sol`:
- `_MAX_POOL_FEE_BPS = 2000` (L36) — 20%

Maximum achievable combined fee: `2500 + 2000 = 4500 bps` (45%).

`PremiumManager.distributePremium` (L159-160):
```solidity
uint16 totalFeeBps = platformFeeBps + poolFeeBps;
require(totalFeeBps <= _MAX_FEE_BPS, ExcessiveCombinedFees(platformFeeBps, poolFeeBps, totalFeeBps));
```

The require checks `totalFeeBps <= 10_000` (100%). Since `platformFeeBps` is capped at 2500 and `poolFeeBps` is capped at 2000 by their respective setters, the sum can never exceed 4500, making the 10,000 cap dead code. The `ExcessiveCombinedFees` error can never be triggered through normal protocol operation.

### Verdict

The combined fee cap `_MAX_FEE_BPS = 10_000` is unreachable given the individual fee caps of 2500 and 2000 bps. The guard and its associated error type are dead code. The actual combined cap is 4500 bps; the guard should use that value or the individual caps should be the sole enforcement mechanism.

---

## H-57: _accruePremium Advances Timestamp When Rate is Zero

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`CoveredVaultAccrual._accruePremium` (CoveredVaultAccrual.sol:27-67):

```solidity
function _accruePremium() internal {
    uint256 checkpointTime = lastPremiumAccrualTime;

    // Always advance the timestamp unconditionally...
    lastPremiumAccrualTime = block.timestamp;  // L32 — UNCONDITIONAL

    if (block.timestamp == checkpointTime) return;
    if (morphoGateActive) return;  // L38 — returns but timestamp already advanced

    uint256 activeElapsed = _activeElapsedFrom(checkpointTime);
    if (activeElapsed == 0) return;

    uint256 morphoValue = _morphoValue();
    uint256 _totalPrincipal = totalPrincipal;

    uint256 accrued = _totalPrincipal > 0
        ? _totalPrincipal.mulDiv(premiumRatePerSecond * activeElapsed, WAD, Math.Rounding.Floor)
        : 0;

    if (accrued == 0) return;  // L56 — exits when rate=0 (accrued=0), but timestamp is already updated
    // ...
}
```

When `premiumRatePerSecond == 0`, the multiplication at L54 yields 0, the `if (accrued == 0) return` at L56 exits, but `lastPremiumAccrualTime` was already set to `block.timestamp` at L32. This prevents any catch-up accrual when the rate is later set non-zero: the elapsed time while rate=0 is silently consumed.

The NatSpec at L30-32 documents this as intentional: "Always advance the timestamp unconditionally so that when a new policy is later bound, there is no catch-up accrual for the inactive gap period." The same logic applies to the zero-rate case.

### Verdict

The timestamp advancement when `premiumRatePerSecond == 0` is confirmed. This is intentional by-design behavior (documented in comments) that prevents catch-up accrual. The informational finding is valid as a documentation gap — the zero-rate behavior is a notable invariant that integrators may not anticipate.

---

## H-58: Fee Split Rounding Favors Restakers (2 wei dust)

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`PremiumManager.getFeeSplits` (PremiumManager.sol:193-206):

```solidity
function getFeeSplits(uint256 grossPremium, uint16 platformFeeBps_, uint16 poolFeeBps_)
    public pure override
    returns (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit)
{
    platformSplit = (grossPremium * platformFeeBps_) / _BPS_DENOMINATOR;  // floor division
    poolSplit = (grossPremium * poolFeeBps_) / _BPS_DENOMINATOR;           // floor division
    restakerSplit = grossPremium - platformSplit - poolSplit;               // remainder
}
```

Both `platformSplit` and `poolSplit` use integer floor division. The remainder (up to 2 wei from 2 floor divisions) flows to `restakerSplit`. Example with 10001 gross, platformFeeBps=2500, poolFeeBps=2000:
- platformSplit = 10001 * 2500 / 10000 = 2500 (floor, lost 1/4 of 1 wei)
- poolSplit = 10001 * 2000 / 10000 = 2000 (floor, lost 1/5 of 1 wei)
- restakerSplit = 10001 - 2500 - 2000 = 3501 (gets the full remainder including dust)

Maximum dust per call: 2 wei (1 from each floor division). Negligible at production scale.

### Verdict

Rounding direction confirmed: floor division on platform and pool splits means restakers receive up to 2 wei of dust per distribution. This is the expected outcome of a remainder-based split and is negligible in practice.

---

## H-59: PremiumCollector._distribute Truncates to uint32

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`PremiumCollector._distribute` (PremiumCollector.sol:289):

```solidity
config.lastDistributeTime = uint32(block.timestamp);
```

`VaultConfig.lastDistributeTime` is stored as `uint32` (implicit from the struct, confirmed by the assignment). `uint32` max value: `4,294,967,295` = Unix timestamp 2106-02-07. The truncation is safe for the foreseeable future but will overflow in 2106, at which point `lastDistributeTime` would wrap to 0, allowing immediate re-distribution regardless of `distributeInterval`.

### Verdict

The `uint32` truncation of `block.timestamp` is confirmed. Safe until February 2106. No immediate action required; note for long-lived protocol versions.

---

## H-60: _isPolicyActive External Call on Every Deposit/Withdraw (Gas)

**Final Verdict**: CONFIRMED
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`CoveredVaultAccrual._isPolicyActive` (CoveredVaultAccrual.sol:153-159):

```solidity
function _isPolicyActive() internal view returns (bool) {
    if (policyId == 0) return false;
    IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
    // ...
}
```

Call chain on each deposit/withdraw:
1. `_deposit`/`_withdraw` → `_accruePremium` → `_activeElapsedFrom` → `_isPolicyActive` (external call #1 to PolicyManager)
2. `_withdraw` → `_executeWithdrawal` → `_settleWithdrawalTransfer` → `_computeInsurance` → `_isPolicyActive` (external call #2 to PolicyManager)

Additionally, `_activeElapsedFrom` itself calls `_policyManager.policyMetadata(policyId)` again at line 121 (when policy is not active) for the catch-up branch. Each `_isPolicyActive` call makes an external call to PolicyManager. No caching of the metadata occurs within a single transaction.

### Verdict

Confirmed: `_isPolicyActive` makes an external call to `PolicyManager.policyMetadata()` on every invocation with no within-transaction caching. On a standard withdrawal, this occurs at minimum twice. This is a gas optimization opportunity, not a security issue.

---

## H-61: CoverPool Curator 24-Hour Admin Transfer Delay

**Final Verdict**: CONFIRMED — [ASSUMPTION-DEP: WITHIN-BOUNDS] tag is CORRECT
**Severity**: Informational
**Evidence**: [CODE-TRACE]

### Evidence

`CoverPool.sol:93`:

```solidity
__AccessControlDefaultAdminRules_init(24 hours, curator_);
```

This initializes `AccessControlDefaultAdminRulesUpgradeable` with a 24-hour admin transfer delay. The 24-hour delay is hardcoded at initialization.

Design context (design_context.md, Trust Assumption #2):
> "CoverPool Curator — SEMI_TRUSTED(bounds: pool-scoped operations, 24h admin transfer delay)"

The 24-hour delay is an explicit design choice documented in the trust assumption table as part of the curator's stated operational bounds.

### Verdict

The 24-hour admin transfer delay in CoverPool is confirmed as intentional design, documented in the trust assumption table. The [ASSUMPTION-DEP: WITHIN-BOUNDS] tag is correct. The informational finding documents the design for auditors comparing against CoverPoolFactory which uses instant admin transfer (H-47).

---

## Summary

| Hypothesis | Verdict | Notes |
|------------|---------|-------|
| H-42 | CONFIRMED | Missing `startTime >= block.timestamp` in _validateRequest |
| H-43 | CONFIRMED | PremiumCollector lacks recoverTokens present in ClaimManager and Swapper |
| H-48 | CONFIRMED | totalPrincipal decremented after external calls (Morpho + ClaimManager) |
| H-49 | CONFIRMED | acceptOwnership zeros timestamps but leaves pending values stale |
| H-50 | CONFIRMED | Static route calldata has no expiry or staleness detection |
| H-51 | CONFIRMED | approveSpender is FULLY_TRUSTED gated; [ASSUMPTION-DEP: TRUSTED-ACTOR] correct |
| H-54 | CONFIRMED | premiumRatePerSecond name lacks WAD unit qualifier |
| H-55 | CONFIRMED | Combined fee cap 10000 bps unreachable; max achievable is 4500 bps |
| H-57 | CONFIRMED | Timestamp advances when rate=0, consuming elapsed time silently |
| H-58 | CONFIRMED | Floor division on platform/pool splits; restakers receive up to 2 wei dust |
| H-59 | CONFIRMED | uint32 timestamp truncation safe until 2106 |
| H-60 | CONFIRMED | External call to PolicyManager on every deposit/withdraw, no caching |
| H-61 | CONFIRMED | 24h delay is stated design; [ASSUMPTION-DEP: WITHIN-BOUNDS] correct |
