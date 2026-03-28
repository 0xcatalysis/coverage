# Depth Analysis: External Dependencies
# Agent: depth-external
# Iteration 1

---

## Finding [DEPTH-EX-1]: PolicyManager Revert DoS Applies to ALL Exit Paths Including emergencyRedeem/emergencyWithdraw

**Verdict**: CONFIRMED (upgrades TF-7 from PARTIAL to CONFIRMED)
**Step Execution**: ✓1,2,3,5,6 | ✗4(N/A—no cross-entity)
**Rules Applied**: [R4:✓, R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R12:✓, R16:✗(no oracle)]
**Depth Evidence**: [TRACE:emergencyRedeem → super.redeem() → _withdraw() → _accruePremium() → _activeElapsedFrom() → _isPolicyActive() → _policyManager.policyMetadata() → REVERT if PM down], [BOUNDARY:policyId=0 → returns early at L154 (safe); policyId≠0 → external call to _policyManager always executes at L155], [VARIATION:morphoGateActive=true → _accruePremium returns early at L38 (safe path exists)]
**Severity**: Medium
**Location**: CoveredVaultAccrual.sol:153-159 (_isPolicyActive), CoveredVaultWrapper.sol:241-262 (emergencyRedeem/emergencyWithdraw), CoveredVaultAccrual.sol:27-41 (_accruePremium)

**Description**:
Both `emergencyRedeem` (L241) and `emergencyWithdraw` (L257) invoke `super.redeem()`/`super.withdraw()` which route to `_withdraw()` (L163). `_withdraw()` calls `_accruePremium()` unconditionally at its first line (L174). `_accruePremium()` calls `_activeElapsedFrom(checkpointTime)` at L41, which calls `_isPolicyActive()` at L117. `_isPolicyActive()` makes an unbounded external call to `_policyManager.policyMetadata(policyId)` at L155 with no try/catch wrapper.

The SKIP_INSURANCE_SLOT transient flag (set by emergency paths) is only read inside `_computeInsurance()` (L326), which is downstream of `_accruePremium()` — it does NOT protect against the `_accruePremium()` revert.

**Execution trace** (no try/catch exists on this path):
```
emergencyRedeem() → super.redeem() → _withdraw() → _accruePremium()
  → _activeElapsedFrom() → _isPolicyActive()
    → _policyManager.policyMetadata(policyId)  ← REVERTS if PolicyManager down
```

**Single safe bypass**: If `morphoGateActive == true`, `_accruePremium()` returns early at L38 BEFORE calling `_activeElapsedFrom()`. This is the ONLY condition under which emergency exits bypass the PolicyManager dependency. However, the gate is an owner-toggled state unrelated to PolicyManager availability — when PolicyManager fails due to upgrade or outage, `morphoGateActive` is likely false (normal operation).

**Impact**: If PolicyManager is paused, undergoing a UUPS upgrade, or experiencing an outage:
- All user withdrawals are blocked (confirmed in TF-7, PARTIAL)
- `emergencyRedeem` and `emergencyWithdraw` are ALSO blocked, defeating their stated purpose ("Use when ClaimManager is unavailable")
- Users with positions at risk cannot exit even at the cost of waiving insurance
- The only available escape valve is for the vault owner to activate `morphoGateActive` (L36-38 early return), but this is a manual owner action requiring owner availability

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:241-248
function emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256) {
    _tstore(SKIP_INSURANCE_SLOT, 1);
    super.redeem(shares, receiver, owner);  // → _withdraw() → _accruePremium()
    ...
}

// CoveredVaultAccrual.sol:27-41
function _accruePremium() internal {
    ...
    if (morphoGateActive) return;   // Only bypass: owner must toggle gate
    uint256 activeElapsed = _activeElapsedFrom(checkpointTime);  // calls _isPolicyActive()
    ...
}

// CoveredVaultAccrual.sol:153-159 — NO try/catch
function _isPolicyActive() internal view returns (bool) {
    if (policyId == 0) return false;
    IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
    ...
}
```

### Postcondition Analysis
**Postconditions Created**: PolicyManager unavailability creates a state where ALL user fund recovery paths are blocked simultaneously.
**Postcondition Types**: [EXTERNAL, TIMING]
**Who Benefits**: Chain finding — combines with any finding that can cause PolicyManager downtime (paused, upgrade window, governance attack).

---

## Finding [DEPTH-EX-2]: _activeElapsedFrom Makes a Second _policyManager Call Not Wrapped in Try/Catch

**Verdict**: CONFIRMED (additional detail supplementing DEPTH-EX-1)
**Step Execution**: ✓1,2,3,5
**Rules Applied**: [R4:✓, R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓]
**Depth Evidence**: [TRACE:_accruePremium → _activeElapsedFrom → (1) _isPolicyActive → _policyManager.policyMetadata, then (2) _policyManager.policyMetadata again at L121 — TWO external calls with no try/catch], [BOUNDARY:_isPolicyActive returns false AND policyId≠0 → second call fires at L121]
**Severity**: Low (incremental to DEPTH-EX-1; same root cause)
**Location**: CoveredVaultAccrual.sol:116-136

**Description**:
`_activeElapsedFrom()` makes NOT ONE but TWO distinct calls to PolicyManager per `_accruePremium()` invocation when the policy is not currently active (post-expiry catch-up logic):

1. Line 117: `_isPolicyActive()` → `_policyManager.policyMetadata(policyId)` (first call)
2. Line 121: `_policyManager.policyMetadata(policyId)` again, directly (second call)

If the first call succeeds but the PolicyManager becomes unavailable mid-execution (e.g., partial upgrade state), the second call can revert. More practically, this doubles gas cost on the catch-up path and confirms the dependency on PM for BOTH active and expired policy states. Neither call has a try/catch.

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:116-136
function _activeElapsedFrom(uint256 checkpoint) internal view returns (uint256) {
    if (_isPolicyActive()) {                                    // Call 1 (inside _isPolicyActive)
        return block.timestamp - checkpoint;
    }
    if (policyId != 0) {
        IPolicyManager.PolicyMetadata memory meta = _policyManager.policyMetadata(policyId);  // Call 2
        ...
    }
    return 0;
}
```

**Impact**: Gas cost and additional revert surface. The deeper issue (complete DoS including emergency paths) is captured in DEPTH-EX-1. This finding documents that fix requires wrapping BOTH calls.

---

## Finding [DEPTH-EX-3]: Stale lastKnownMorphoValue Window — Quantified Exposure Timeline

**Verdict**: REFINED (OZ-3 from PARTIAL to CONFIRMED with quantified timeline)
**Step Execution**: ✓1,2,3,5
**Rules Applied**: [R4:✓, R5:✗(single entity), R6:✓, R8:✓, R10:✓, R16:✗(not Chainlink oracle)]
**Depth Evidence**: [TRACE:convertToAssets reverts at T=0 → lastKnownMorphoValue frozen → accrual uses frozen value until owner calls setMorphoGateActive → stale window = owner_response_time], [VARIATION:lastKnownMorphoValue=100, morphoValue_at_T1=50 → _liabilityHeadroom uses 100 instead of 50 → over-accrual of premium possible], [BOUNDARY:morphoValue=0 at T=1, lastKnownMorphoValue=100 → headroom=100 → uncapped premium accrual for up to owner_response_time duration]
**Severity**: Medium
**Location**: CoveredVaultAccrual.sol:139-147 (_morphoValue), CoveredVaultAccrual.sol:59-61 (headroom check), CoveredVaultAdmin.sol:168-186 (gate toggle)

**Description**:
`_morphoValue()` uses a try/catch around `convertToAssets()`. On revert, it returns `lastKnownMorphoValue`. This cached value is used by `_liabilityHeadroom(morphoValue)` to cap premium accrual.

**Stale window exposure**:
1. Morpho vault enters a distressed state: `convertToAssets()` begins reverting at T=0
2. `lastKnownMorphoValue` is frozen at its pre-distress value (e.g., 1000 USDC)
3. Actual vault value drops (e.g., to 500 USDC due to bad debt or pause)
4. `_liabilityHeadroom()` uses frozen 1000 → allows premium accrual up to 1000 - existingLiability
5. Owner sees alerts and calls `setMorphoGateActive(true)` at T=X (response time)
6. During [T=0, T=X], premium accrues against a stale (inflated) cap

**Quantified impact**: If `lastKnownMorphoValue` = 1000 and `totalPremiumLiability` = 200, stale headroom = 800. Real headroom = 300 (actual value 500). Over-accrual possible up to 500 additional units during response window. Premium is owed to `premiumRecipient` — if collected, leaves vault undercollateralized relative to true Morpho value.

**Additional concern** — no staleness timestamp: The protocol stores `lastKnownMorphoValue` but NOT when it was last updated. There is no mechanism for users or integrators to assess how stale the cached value is. A user calling `totalAssets()` during Morpho downtime sees a value computed from stale data with no warning.

**Impact**: During Morpho downtime without owner gate activation: users who deposit during this window receive shares priced against stale (inflated) Morpho value; premium over-accrues against inflated headroom; users who withdraw get a share of a smaller actual Morpho pool than reflected in `totalAssets()`. Real-value loss depends on owner response time and Morpho downtime duration.

**Evidence**:
```solidity
// CoveredVaultAccrual.sol:139-147
function _morphoValue() internal view returns (uint256) {
    try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (
        uint256 val
    ) {
        return val;
    } catch {
        return lastKnownMorphoValue;  // No staleness check; frozen indefinitely until owner acts
    }
}
```

### Precondition Analysis
**Missing Precondition**: Owner must NOT have activated `morphoGateActive` yet (or the gate was not activated promptly)
**Precondition Type**: TIMING / EXTERNAL
**Why This Blocks**: Gate activation triggers early return in `_accruePremium()`, halting accrual against the stale value

---

## Finding [DEPTH-EX-4]: UniswapV3Adapter Fee Tier Encoding — Confirmed Fee-Tier Mismatch (PC3-2 Confirmed)

**Verdict**: CONFIRMED (DEX injectable Question 1 — confirms PC3-2)
**Step Execution**: ✓1,2,3,5
**Rules Applied**: [R4:✓, R5:✓, R6:✗(no role), R8:✓, R10:✓]
**Depth Evidence**: [VARIATION:pairFees[key]=500 via setPairFee, but stored calldata uses fee=3000 → quote uses 500bps pool, swap uses 3000bps pool → slippage calc based on wrong pool price], [TRACE:quoteSwap → UniswapV3Adapter.quote() → _getFee() reads pairFees mapping → QUOTER.quoteExactInputSingle(fee=500) → amountOutMin=A; executeSwap → stored calldata `swap(tokenIn,tokenOut,3000,amountOutMin=A)` → pool 3000 has different price → amountOutMin potentially not met or over-met], [BOUNDARY:fee=0 in pairFees → _getFee returns DEFAULT_FEE=3000 (safe default); fee=10000 in pairFees but calldata uses fee=500 → maximum divergence]
**Severity**: High (already confirmed as PC3-2; this is corroboration with DEX-specific trace)
**Location**: UniswapV3Adapter.sol:127-135 (quote), UniswapV3Adapter.sol:155-188 (swap), Swapper.sol:146-173 (setSwapRoute)

**Description**:
The UniswapV3Adapter uses TWO separate mechanisms to determine the fee tier for a token pair:

1. **For quoting** (`quote()` function, L127): Calls `_getFee(tokenIn, tokenOut)` which reads `pairFees[keccak256(tokenIn, tokenOut)]`, defaulting to `DEFAULT_FEE=3000` if not set.

2. **For swapping** (`swap()` function, L155): Accepts `fee` as a parameter (L158), which is passed directly from the **stored route calldata** set via `Swapper.setSwapRoute()`.

The calldata stored in `Swapper._swapRoutes[routeKey].swapCalldata` encodes the fee tier statically at route configuration time (L164-172 in Swapper.sol). The `UniswapV3Adapter.setPairFee()` function (L116) updates `pairFees` for future quote calls but does NOT update the stored calldata in Swapper.

**Attack scenario (Scenario A — Claim DoS)**:
1. Route configured with fee=3000 in calldata (most liquid pool)
2. Admin calls `setPairFee(tokenIn, tokenOut, 500)` to improve quote accuracy for a thin-liquidity pool
3. Future quotes use 500bps pool → returns price P500
4. Actual swap uses 3000bps pool (from calldata) → price P3000 differs from P500
5. If 3000bps pool has lower liquidity: `amountOut < amountOutMin` → swap REVERTS → claim payout fails

**Attack scenario (Scenario B — Weakened slippage)**:
1. If 3000bps pool price is better than 500bps (coincidentally higher output)
2. `amountOutMin` computed from 500bps quote is LOWER than actual fair price
3. Slippage protection is weaker than intended; MEV sandwich possible in the gap

**SWAP_MANAGER_ROLE vector (DEX injectable Question 4)**:
The `SWAP_MANAGER_ROLE` can call `setSwapRoute()` to set arbitrary calldata, including any fee tier. A misconfigured or malicious SWAP_MANAGER can set calldata with fee=100 (non-standard, very thin pool) while `pairFees` has fee=3000. Quote uses deep 3000bps pool → high `amountOutMin`; swap uses shallow 100bps pool → likely fails. This achieves claim DoS without requiring any direct access to ClaimManager.

**Evidence**:
```solidity
// UniswapV3Adapter.sol:127-135 — quote uses pairFees mapping
function quote(address tokenIn, address tokenOut, uint256 amountIn) external override returns (uint256 amountOut) {
    uint24 fee = _getFee(tokenIn, tokenOut);  // reads pairFees[key]
    (amountOut,,,) = QUOTER.quoteExactInputSingle(
        IQuoterV2.QuoteExactInputSingleParams({..., fee: fee, ...})
    );
}

// UniswapV3Adapter.sol:155-188 — swap uses fee from calldata parameter
function swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountOutMinimum) external returns (uint256 amountOut) {
    ...
    IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
        ..., fee: fee, ...  // fee comes from stored calldata, NOT from pairFees
    });
}
```

---

## Finding [DEPTH-EX-5]: Failed executeSwap Does NOT Leave Partial State — ClaimManager is Clean

**Verdict**: REFUTED (DEX injectable Question 2/3)
**Step Execution**: ✓1,2,3
**Rules Applied**: [R4:✓, R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓]
**Depth Evidence**: [TRACE:executeSwap REVERTS → entire _processCollateral transaction reverts → approval set via forceApprove before swap is cleared by OZ's forceApprove(0) at L669 OR reverted atomically], [BOUNDARY:amountOutMin=1, swap reverts → _executeCollateralSwap propagates revert to _slashAndDistribute → entire fileClaim() reverts → no state persists]
**Severity**: N/A (Refuted)
**Location**: ClaimManager.sol:629-670

**Description**:
DEX injectable Question 2/3 asked whether a failed swap leaves partial state (collateral transferred, swap failed, payout not sent).

**Trace**:
```
fileClaim() → _capAndExecutePayout() → _executeSlashingAndPayout() → _slashAndDistribute()
  → for each collateral token: _processCollateral() → _executeCollateralSwap()
    → _approveIfERC20(collateralToken, swapper, collateralAmount)  [forceApprove]
    → ISwapper.executeSwap(swapParams)
      → Swapper._performSwap() → swapTarget.call(swapCalldata)
        → if revert: SwapFailed() propagates
    → REVERT propagates back through entire call chain
```

The `executeSwap()` function reverts on `InsufficientOutputAmount` or `SwapFailed`. This revert propagates atomically through `_processCollateral` → `_slashAndDistribute` → back to `fileClaim()`. Because `fileClaim()` uses `nonReentrant` and has no try/catch around the payout execution path, the entire transaction reverts.

The approval set by `_approveIfERC20(collateralToken, swapper, collateralAmount)` at L639 is reverted along with the transaction. Even if the swap call itself fails mid-execution (after partial state changes in the DEX), the Swapper contract's `executeSwap()` reverts cleanly (line 312: `require(success, SwapFailed(returnData))`), and `_approveIfERC20(collateralToken, swapper, 0)` at L669 is only reached on success.

**Conclusion**: No partial state is left. The one concern is that `_policyClaims[policyId].totalPaidOut += cappedAmount` is incremented at L349 before the swap executes, but L354 decrements it by `cappedAmount - totalPayout` if `totalPayout < cappedAmount`. On complete revert, the increment is rolled back atomically.

### Precondition Analysis
**Missing Precondition**: None — the defense is atomicity of EVM transactions
**Precondition Type**: N/A
**Why This Blocks**: EVM reverts are atomic; no partial state persists

---

## Finding [DEPTH-EX-6]: PremiumCollector.updateVault Reentrancy — Real Impact Assessment

**Verdict**: CONFIRMED with downgrade to Low (PC4-3 confirmed, impact analysis)
**Step Execution**: ✓1,2,3,5
**Rules Applied**: [R4:✓, R5:✗(single vault), R6:✓, R8:✓, R10:✓, R11:✗(no external tokens)]
**Depth Evidence**: [TRACE:distributeBatch → _distribute(vault) → IERC4626(vault).redeem() → vault.collectPremium() → updateVault(vault, newPool, newPolicyId) → config.pool/policyId updated → returns → _distribute continues → IERC20(config.underlying).safeTransfer(premiumManager, assets) with ORIGINAL underlying → IPremiumManager.distributePremium(NEW_POOL, NEW_POLICY_ID, original_underlying, assets)], [BOUNDARY:updateVault called with different policyId mid-flight → assets distributed to wrong policy], [VARIATION:config.pool=oldPool before reentrance; config.pool=newPool after → distributePremium called with newPool but assets from oldPool redeem]
**Severity**: Low
**Location**: PremiumCollector.sol:147-158 (updateVault), PremiumCollector.sol:265-296 (_distribute)

**Description**:
`updateVault()` is protected by `onlyRole(DEFAULT_ADMIN_ROLE)` but lacks `nonReentrant`. During `_distribute()`, `IERC4626(vault).redeem()` at L283 transfers execution to the vault. If the vault's `redeem()` implementation calls back to `PremiumCollector.updateVault()` (possible if vault is a non-standard implementation or if the vault's asset transfer hooks are controllable), the following sequence can occur:

```
_distribute(vault):
  shares = vault.balanceOf(this)          [= 100 shares]
  assets = vault.redeem(100, this, this)  [vault calls back updateVault]
    updateVault(vault, newPool, newPolicyId)
      config.pool = newPool
      config.policyId = newPolicyId
      [returns]
  [back in _distribute after reentrance]
  config.lastDistributeTime = block.timestamp
  IERC20(config.underlying).safeTransfer(premiumManager, assets)
  IPremiumManager(premiumManager).distributePremium(config.pool, config.policyId, ...)
    → Uses newPool/newPolicyId instead of oldPool/oldPolicyId
```

**Why this is Low (not Medium)**:
- The reentrancy path requires `DEFAULT_ADMIN_ROLE` to execute `updateVault()` — this is admin action within `_distribute()`, which is a trust violation by the admin
- No funds are lost from PremiumCollector — assets are correctly transferred to premiumManager
- Impact is premium routing to wrong policy/pool (premium accounting mismatch)
- Vault must support callbacks on `redeem()` — standard ERC-4626 does not

**Why it is still Low (not Info)**:
- The design explicitly targets "Gelato Web3 Functions" automation, meaning `distributeBatch` is called by keepers — admin action and keeper action could be concurrent
- If the vault is a CoveredVaultWrapper (circular dependency), its `redeem()` has multiple external calls that create opportunities
- The `lastDistributeTime` update at L289 happens AFTER the external call, so a reentrant `updateVault` can also corrupt the timing invariant

**Evidence**:
```solidity
// PremiumCollector.sol:147-158 — no nonReentrant
function updateVault(address vault, address pool, uint96 policyId) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    ...
    config.pool = pool;
    config.policyId = policyId;
    emit VaultUpdated(vault, pool, policyId);
}

// PremiumCollector.sol:282-293 — external call before config write
function _distribute(address vault) private {
    ...
    uint256 assets = IERC4626(vault).redeem(shares, address(this), address(this));  // External call
    ...
    config.lastDistributeTime = uint32(block.timestamp);  // Written AFTER external call
    IERC20(config.underlying).safeTransfer(premiumManager, assets);
    IPremiumManager(premiumManager).distributePremium(config.pool, config.policyId, config.underlying, assets);
}
```

---

## Finding [DEPTH-EX-7]: PremiumCollector.distributeBatch Error Isolation — Batch DoS Confirmed

**Verdict**: CONFIRMED (RS2-2 — additional depth on external call behavior)
**Step Execution**: ✓1,2,3,5
**Rules Applied**: [R4:✓, R5:✓, R6:✗(no role), R8:✗(single-step), R10:✓]
**Depth Evidence**: [TRACE:distributeBatch([v1,v2,v3]) → _distribute(v1) → vault.redeem() REVERTS → entire distributeBatch() reverts → v2 and v3 also skip distribution], [BOUNDARY:1 failing vault in batch of N → all N vaults miss distribution window], [VARIATION:distributeInterval=86400 → if batch fails, entire day of premium deferred for all vaults in batch]
**Severity**: Low (confirming RS2-2)
**Location**: PremiumCollector.sol:163-168 (distributeBatch), PremiumCollector.sol:265-296 (_distribute)

**Description**:
`distributeBatch()` calls `_distribute()` for each vault in sequence within the same transaction. `_distribute()` makes three external calls (L276, L283, L293) with no try/catch. If any external call reverts (vault paused, premiumManager unavailable, etc.), the entire `distributeBatch()` reverts.

The automation model (Gelato keeper calling `getDistributableVaults()` then `distributeBatch()`) means a single bad vault blocks all healthy vaults from receiving premium distribution.

**External calls vulnerable to revert**:
1. `vault.balanceOf(address(this))` at L276 — view call, unlikely to revert but possible with malicious vault
2. `vault.redeem(shares, address(this), address(this))` at L283 — can revert if vault paused or Morpho gated
3. `IERC20(config.underlying).safeTransfer(premiumManager, assets)` at L290 — transfer can fail
4. `IPremiumManager.distributePremium(...)` at L293 — can revert if premiumManager paused

If a CoveredVaultWrapper vault hits the Morpho gate (which blocks `redeem()`), that vault will DoS all other vaults in any batch that includes it.

**Evidence**:
```solidity
// PremiumCollector.sol:163-168 — no per-vault error isolation
function distributeBatch(address[] calldata vaults) external override nonReentrant whenNotPaused {
    uint256 length = vaults.length;
    for (uint256 i = 0; i < length; ++i) {
        _distribute(vaults[i]);  // No try/catch around this call
    }
}
```

---

## Finding [DEPTH-EX-8]: Oracle Revert DoS on bindPolicy — PARTIAL Confirmed, Mitigated by Admin Replaceability

**Verdict**: CONFIRMED (OZ-1 — confirming PARTIAL classification, noting mitigation)
**Step Execution**: ✓1,2,3
**Rules Applied**: [R4:✓, R5:✗(single oracle), R6:✗(no role), R8:✗(single-step), R10:✓, R16:✓]
**Depth Evidence**: [TRACE:bindPolicy → for each token: getUSDValue(tokens[i], tokenStakes[i]) at L269 → no try/catch → revert propagates], [VARIATION:1 staked token with stale/paused Chainlink feed → entire binding fails → policy draft stranded], [BOUNDARY:tokens.length=0 → totalStakeUSD=0 → require(totalStakeUSD >= coverageLimitUSD) fails — different failure mode]
**Severity**: Low
**Location**: PolicyManager.sol:266-274

**Description**:
`PolicyManager.bindPolicy()` iterates over all tokens staked in the committee and calls `IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue()` without try/catch. If the Chainlink feed is stale, paused, or the price falls to zero, the call reverts and policy binding fails.

The mitigation noted in the finding inventory is valid: `DEFAULT_ADMIN_ROLE` can call `setChainlinkPriceFeed()` to replace the feed. However, this requires admin action and creates a window where all new policy bindings are blocked.

More importantly, this DoS is limited to the `bindPolicy` path only — active policies are unaffected (Chainlink is not used at claim time, per design context).

**Additional concern**: The loop at L266-270 iterates over ALL staked tokens. If any ONE token's feed is unavailable, the entire binding fails regardless of whether that token's contribution to `totalStakeUSD` is marginal.

---

## Chain Summary

| Finding ID | Location | Root Cause (1-line) | Verdict | Severity | Precondition Type | Postcondition Type |
|------------|----------|---------------------|---------|----------|-------------------|--------------------|
| DEPTH-EX-1 | CoveredVaultAccrual.sol:153-159, CoveredVaultWrapper.sol:241-262 | emergencyRedeem/emergencyWithdraw call _accruePremium which calls _isPolicyActive with no try/catch | CONFIRMED | Medium | EXTERNAL (PolicyManager availability) | TIMING (all exits blocked during PM downtime) |
| DEPTH-EX-2 | CoveredVaultAccrual.sol:116-136 | _activeElapsedFrom makes two external PolicyManager calls, neither wrapped | CONFIRMED | Low | EXTERNAL | N/A (same as DEPTH-EX-1) |
| DEPTH-EX-3 | CoveredVaultAccrual.sol:139-147, CoveredVaultAdmin.sol:168-186 | lastKnownMorphoValue frozen during Morpho downtime until owner manually gates; stale cap enables over-accrual | CONFIRMED | Medium | TIMING (owner response delay) | STATE (inflated totalPremiumLiability) |
| DEPTH-EX-4 | UniswapV3Adapter.sol:127-135,155-188 | quote() uses pairFees mapping while swap() uses fee from stored calldata; desync after setPairFee call | CONFIRMED | High | EXTERNAL (route configuration) | EXTERNAL (claim DoS or weakened slippage) |
| DEPTH-EX-5 | ClaimManager.sol:629-670 | Failed executeSwap reverts entire fileClaim atomically; no partial state | REFUTED | N/A | N/A | N/A |
| DEPTH-EX-6 | PremiumCollector.sol:147-158, 265-296 | updateVault lacks nonReentrant; external vault.redeem() can reenter to corrupt pool/policyId routing | CONFIRMED | Low | ACCESS (requires admin to violate trust) | STATE (premium routed to wrong policy) |
| DEPTH-EX-7 | PremiumCollector.sol:163-168 | distributeBatch has no per-vault try/catch; one failing vault reverts entire batch | CONFIRMED | Low | EXTERNAL (any vault's redeem failure) | TIMING (all vaults miss distribution window) |
| DEPTH-EX-8 | PolicyManager.sol:266-274 | Chainlink getUSDValue has no try/catch in bindPolicy loop; stale feed blocks all new bindings | CONFIRMED | Low | EXTERNAL (Chainlink feed availability) | TIMING (new policy binding blocked) |
