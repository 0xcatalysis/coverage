# Depth Token Flow Findings

## DEPTH ANALYSIS: Token Flow

### Target 1: Excess Swap Output Stranded in ClaimManager

**Source Finding(s)**: PC3-1, RS2-3
**Breadth Claim**: Swap output exceeding `remainingPayout` is permanently stranded in ClaimManager; vault stakers are over-slashed.

#### Analysis

Traced the full token flow through `_executeCollateralSwap` (ClaimManager.sol:629-670):

1. **Entry**: `_processCollateral` at L587 is called from `_slashAndDistribute` (L420-435) in a loop over all collateral tokens. `remainingPayout` starts at `requestedAmount` and is decremented by each iteration's `amountOut`.

2. **Swap flow**: At L663-664, the Swapper executes the swap and returns `swapOutput`. At L666, the code caps: `amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput`. At L667, only `amountOut` (the capped amount) is transferred to `beneficiary`.

3. **Surplus fate**: If `swapOutput > remainingPayout`, the difference `swapOutput - remainingPayout` remains in the ClaimManager contract as the payout token. This is NOT an intermediate token -- it is the final payout token sitting in ClaimManager.

4. **Rescue path**: ClaimManager has `recoverTokens` at L169-174, callable by `DEFAULT_ADMIN_ROLE`. This CAN recover stranded tokens. [CODE] at L169-174.

5. **Who is harmed**: The vault stakers (restakers) are slashed for the full `collateralAmount` via `executeSlashing`, but only `amountOut` (capped at `remainingPayout`) reaches the beneficiary. The surplus is excess collateral converted to payout token but stranded. It belongs economically to the restakers, but is held by ClaimManager until admin recovery.

6. **When does this happen**: The `_inflateForSlippage` function (L555-573) intentionally over-slashes to account for DEX slippage. With `maxSwapSlippageBps = 200` (2%), the slash amount can be inflated by up to ~2.04% above the proportional amount (L568: `baseSlash * 10_000 / (10_000 - 200) = baseSlash * 1.0204`). If actual slippage is less than anticipated, the swap produces MORE output than needed.

[BOUNDARY: maxSwapSlippageBps=200 -> max inflation factor = 10000/9800 = 1.0204x]
[TRACE: _executeCollateralSwap -> swapOutput > remainingPayout -> surplus = swapOutput - amountOut -> stays in ClaimManager -> recoverable via recoverTokens by admin]
[VARIATION: slippage 0% actual vs 2% anticipated -> ~2% surplus stranded per swap]

#### Real Constants
| Constant | Value | Source Line |
|----------|-------|-------------|
| maxSwapSlippageBps (initial) | 200 (2%) | ClaimManager.sol:104 |
| _MAX_SLIPPAGE_BPS | 10_000 | ClaimManager.sol:47 |
| Max inflation formula | baseSlash * 10000 / (10000 - maxSwapSlippageBps) | ClaimManager.sol:568 |

#### Verdict
- [x] REFINED: Breadth finding was partially correct. The surplus IS stranded temporarily, and restakers ARE over-slashed relative to what the beneficiary receives. However, the surplus is NOT permanently lost -- `recoverTokens` (admin-gated) provides a rescue path. The real issue is: (a) admin must notice and act, (b) there's no automatic refund to the over-slashed restakers, (c) the admin could send recovered tokens anywhere, not necessarily back to restakers. The severity should be refined from HIGH to MEDIUM because the funds are admin-recoverable, but the lack of automatic restaker refund is a design gap.

**Severity**: Medium (fund lockup with admin recovery, not permanent loss)
**Impact**: Restakers are over-slashed by up to ~2% per cross-token claim. Surplus stays in ClaimManager until admin manually recovers it. No guarantee surplus returns to the rightful restakers.

---

## Finding [DEPTH-TF-1]: Excess Swap Output Stranded in ClaimManager Without Automatic Restaker Refund

**Verdict**: CONFIRMED
**Step Execution**: checkmark1,2,3,4,5 | ?6(admin recovery timing uncertain)
**Rules Applied**: [R4:checkmark, R5:checkmark(multi-vault), R6:checkmark(admin recovery), R8:checkmark(multi-step slash+swap+cap), R10:checkmark, R11:checkmark(external swap), R12:checkmark, R13:checkmark(not by design)]
**Depth Evidence**: [BOUNDARY:maxSwapSlippageBps=200 -> max 2.04% over-slash], [TRACE:_executeCollateralSwap->cap->surplus stranded->recoverTokens by admin], [VARIATION:actual slippage 0% vs anticipated 2% -> 2% surplus per swap]
**Severity**: Medium
**Location**: ClaimManager.sol:L663-L669
**Description**: When collateral tokens are swapped to the payout token during claim execution, the `_inflateForSlippage` function over-slashes restakers by up to maxSwapSlippageBps (default 2%) to compensate for anticipated DEX slippage. If actual slippage is less than anticipated, the swap produces more output than `remainingPayout`. The excess is capped at L666 and not transferred to the beneficiary, leaving it stranded in ClaimManager. While `recoverTokens` (admin-gated) can rescue these funds, there is no automatic mechanism to return them to the over-slashed restakers.

**Impact**:
- Restakers lose up to ~2% of their slashed collateral per cross-token claim when actual slippage < anticipated slippage
- Surplus accumulates in ClaimManager across multiple claims
- Admin must manually identify, quantify, and distribute stranded surplus -- no on-chain tracking exists
- In a high-volume protocol with many cross-token claims, significant value could accumulate without automated accounting

**Evidence**:
```solidity
// ClaimManager.sol:663-669
uint256 swapOutput =
    ISwapper(swapper).executeSwap{value: collateralToken == _NATIVE_ETH ? collateralAmount : 0}(swapParams);

amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput; // surplus capped here
_transferToken(payoutToken, beneficiary, amountOut); // only capped amount sent
// surplus (swapOutput - amountOut) stays in ClaimManager
```

### Postcondition Analysis
**Postconditions Created**: Payout token balance accumulates in ClaimManager beyond what's needed for beneficiary payouts
**Postcondition Types**: BALANCE
**Who Benefits**: Admin (via recoverTokens) -- but not automatically restakers who were over-slashed

---

### Target 2: UniswapV3Adapter Fee-Tier Mismatch Between quote and swap

**Source Finding(s)**: PC3-2
**Breadth Claim**: `pairFees` (used by quoteSwap) and stored calldata fee tier (used by executeSwap) are independently managed, creating desync scenarios.

#### Analysis

Traced the two independent fee-tier paths:

**Quote path** (used by `_computeVaultSlashes` and `_executeCollateralSwap` for slippage):
1. ClaimManager calls `ISwapper(swapper).quoteSwap(token, payoutToken, stake)` (L501, L565, L643)
2. Swapper.quoteSwap (L178-211) calls `IQuotableAdapter(route.swapTarget).quote(actualTokenIn, actualTokenOut, amountIn)` (L206)
3. UniswapV3Adapter.quote (L127-135) uses `_getFee(tokenIn, tokenOut)` which reads `pairFees[key]`, defaulting to DEFAULT_FEE (3000 = 0.3%)

**Swap path** (actual execution):
1. ClaimManager calls `ISwapper(swapper).executeSwap(swapParams)` (L663-664)
2. Swapper.executeSwap (L216-248) gets `routeCalldata` from stored route OR uses `params.swapCalldata` if provided (L240)
3. ClaimManager passes `swapCalldata: ""` (L658), so the stored route calldata is used
4. Swapper calls `swapTarget.call(swapCalldata)` (L311) -- this calldata encodes `UniswapV3Adapter.swap(tokenIn, tokenOut, fee, amountOutMinimum)` where `fee` was baked in at `setSwapRoute` time
5. UniswapV3Adapter.swap (L155-188) uses the `fee` parameter from calldata, NOT from `pairFees`

**Desync scenario**:
- Admin calls `adapter.setPairFee(WETH, USDC, 500)` to update quote to use 0.05% pool
- But forgets (or cannot simultaneously) update `swapper.setSwapRoute(WETH, USDC, adapter, true, newCalldata)` to encode fee=500
- Now quote uses 0.05% pool (lower slippage estimate) but swap uses 0.3% pool (higher slippage in reality)

**Impact analysis**:
- If quote fee < swap fee: Quote overestimates output -> amountOutMin is set too high -> swap reverts -> DoS on claims
- If quote fee > swap fee: Quote underestimates output -> amountOutMin is set too low -> sandwich attack possible but limited by maxSwapSlippageBps (the slippage floor is `max(1, quoted * (10000 - maxSwapSlippageBps) / 10000)`)

**Who controls what**:
- `setPairFee`: UniswapV3Adapter owner (L116)
- `setSwapRoute`: Swapper SWAP_MANAGER_ROLE (L155)
- These are different roles/entities

[TRACE: quoteSwap -> Swapper.quoteSwap -> adapter.quote -> _getFee(pairFees) vs executeSwap -> Swapper.executeSwap -> stored calldata -> adapter.swap(fee from calldata)]
[VARIATION: pairFees=500 but calldata fee=3000 -> quote overestimates -> swap reverts -> DoS]
[VARIATION: pairFees=3000 but calldata fee=500 -> quote underestimates -> weaker slippage protection]

#### Real Constants
| Constant | Value | Source Line |
|----------|-------|-------------|
| DEFAULT_FEE | 3000 (0.3%) | UniswapV3Adapter.sol:66 |
| maxSwapSlippageBps (initial) | 200 (2%) | ClaimManager.sol:104 |
| Valid Uni V3 fee tiers | 100, 500, 3000, 10000 | UniswapV3Adapter.sol:111 (docs) |

#### Verdict
- [x] CONFIRMED: The fee tier desync is real. Two independent admin paths control the fee used for quoting vs execution. If pairFees is updated to a lower-fee pool but route calldata still encodes the old higher-fee pool, the quote will overestimate output, causing amountOutMin to be set too high for the actual swap pool, resulting in a revert. This is a DoS on insurance claim payouts.

---

## Finding [DEPTH-TF-2]: UniswapV3Adapter Fee-Tier Desync Between Quote and Swap Paths

**Verdict**: CONFIRMED
**Step Execution**: checkmark1,2,3,4,5,6
**Rules Applied**: [R4:checkmark, R5:checkmark(multi-contract), R6:checkmark(two admin roles), R8:checkmark(stored external state: pairFees + route calldata), R10:checkmark, R11:checkmark(external DEX), R12:checkmark, R13:x(not design), R14:checkmark(two independently-settable parameters for same operation)]
**Depth Evidence**: [TRACE:quoteSwap reads pairFees, executeSwap reads stored calldata -> independent fee paths], [VARIATION:pairFees=500 calldata=3000 -> DoS; pairFees=3000 calldata=500 -> weaker slippage], [BOUNDARY:fee tier mismatch 100 vs 10000 -> 100x price impact difference]
**Severity**: High
**Location**: UniswapV3Adapter.sol:L127-L135 (quote), Swapper.sol:L146-L173 (setSwapRoute), UniswapV3Adapter.sol:L116-L120 (setPairFee)
**Description**: The UniswapV3Adapter uses two independent fee tier sources: `pairFees[key]` for quoting (read by `quote()`) and the `fee` parameter encoded in the Swapper's stored route calldata for actual swap execution. These are managed by different admin roles (`adapter.owner` for `setPairFee`, `SWAP_MANAGER_ROLE` for `setSwapRoute`). When one is updated without the other, the quote and swap operate on different Uniswap V3 pools with different liquidity depths.

When the quote fee is lower than the swap fee (e.g., quote uses 0.05% pool but swap uses 0.3% pool), the quote returns a higher expected output. The `amountOutMin` computed from this optimistic quote becomes too high for the actual swap pool, causing the swap to revert. This creates a DoS on all insurance claim payouts that use this token pair.

**Impact**:
- **DoS scenario** (quote fee < swap fee): All claims requiring this token pair's swap are blocked until the desync is resolved by the correct admin
- **Slippage weakening** (quote fee > swap fee): amountOutMin is set too low, enabling sandwich attacks on claim swaps
- Two separate admin entities must coordinate updates atomically, with no on-chain enforcement of consistency

**Evidence**:
```solidity
// UniswapV3Adapter.sol:127-135 — quote uses pairFees
function quote(address tokenIn, address tokenOut, uint256 amountIn) external override returns (uint256 amountOut) {
    uint24 fee = _getFee(tokenIn, tokenOut); // reads pairFees[key]
    (amountOut,,,) = QUOTER.quoteExactInputSingle(...fee: fee...);
}

// UniswapV3Adapter.sol:155-188 — swap uses calldata fee parameter
function swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountOutMinimum) external returns (uint256) {
    // fee comes from stored route calldata, NOT from pairFees
    ...SWAP_ROUTER.exactInputSingle(...fee: fee...);
}

// Swapper.sol:240 — stored route calldata is used when ClaimManager passes empty swapCalldata
bytes memory effectiveCalldata = params.swapCalldata.length > 0 ? params.swapCalldata : routeCalldata;
```

### Postcondition Analysis
**Postconditions Created**: Claims DoS when fee tiers are desynced; weakened slippage protection when desync is in opposite direction
**Postcondition Types**: STATE, EXTERNAL
**Who Benefits**: MEV bots (sandwich attacks when slippage is weakened); nobody benefits from DoS

---

### Target 3: quoteSwap Returns 0 on Route Failure Leading to amountOutMin=1

**Source Finding(s)**: TF-4
**Breadth Claim**: If quoteSwap returns 0 (route disabled, target not whitelisted, etc.), the amountOutMin falls to 1, enabling near-total sandwich.

#### Analysis

Traced the quoteSwap failure modes in Swapper.sol:178-211:
1. `amountIn == 0` -> returns 0 (L187-189) -- not applicable here, amountIn is collateralAmount > 0
2. `actualTokenIn == actualTokenOut` -> returns 0 (L193-195) -- not applicable, same-token path handled earlier
3. `!route.enabled || route.swapTarget == address(0)` -> returns 0 (L199-201) -- possible if route disabled
4. `!whitelistedTargets[route.swapTarget]` -> returns 0 (L202-204) -- possible if target de-whitelisted
5. `IQuotableAdapter.quote() reverts` -> returns 0 (L206-210) -- possible on QuoterV2 revert

In ClaimManager._executeCollateralSwap (L639-670):
```solidity
uint256 amountOutMin = 1;
try ISwapper(swapper).quoteSwap(...) returns (uint256 quoted) {
    if (quoted > 0) {
        amountOutMin = quoted * (10_000 - maxSwapSlippageBps) / 10_000;
        if (amountOutMin == 0) amountOutMin = 1;
    }
} catch {}
```

If quoteSwap returns 0 (any of failure modes 3-5), the `if (quoted > 0)` check is false, so `amountOutMin` stays at 1. The swap then executes with effectively zero slippage protection.

**Critical question: Can executeSwap succeed if quoteSwap fails?**

If the route is disabled or target de-whitelisted, then `executeSwap` at Swapper L216-248 will also revert:
- L235-236: `_validateAndGetSwapTarget` reads the same route and checks `route.enabled` (L359) and `whitelistedTargets[swapTarget]` (L363)

So failure modes 3 and 4 cause BOTH quoteSwap AND executeSwap to fail. The claim would revert at L312.

**Remaining failure mode**: QuoterV2 reverts (mode 5) but the actual swap succeeds. This can happen because:
- QuoterV2 uses simulation-based quoting that can fail due to gas limits, pool state inconsistency, or temporary conditions
- The actual swap router uses a different code path

If QuoterV2 reverts, quoteSwap returns 0, amountOutMin becomes 1, and the actual swap proceeds with no slippage protection. An MEV bot can sandwich the swap for nearly 100% extraction (minus the 1 wei minimum).

However, the quoteSwap call itself could also throw at the Swapper level (before reaching the adapter), in which case the outer `try...catch {}` in ClaimManager catches it and amountOutMin stays at 1.

[TRACE: quoteSwap returns 0 when QuoterV2 reverts -> amountOutMin=1 -> executeSwap succeeds -> sandwich extracts nearly 100% of swap value]
[BOUNDARY: amountOutMin=1 -> attacker extracts (swapOutput - 1) from the trade]
[VARIATION: QuoterV2 reverts but SwapRouter succeeds -> legitimate failure mode that enables sandwich]

#### Real Constants
| Constant | Value | Source Line |
|----------|-------|-------------|
| amountOutMin fallback | 1 | ClaimManager.sol:641 |
| maxSwapSlippageBps | 200 (2%) | ClaimManager.sol:104 |

#### Verdict
- [x] CONFIRMED: The finding is correct. When the Uniswap V3 QuoterV2 reverts but the actual swap router succeeds (a known production scenario due to their different execution models), the amountOutMin falls to 1, enabling near-total MEV extraction from the claim swap. The quoteSwap failure is silently caught and the swap proceeds unprotected.

---

## Finding [DEPTH-TF-3]: quoteSwap Failure Silently Degrades Slippage to amountOutMin=1

**Verdict**: CONFIRMED
**Step Execution**: checkmark1,2,3,4,5,6
**Rules Applied**: [R4:checkmark(adversarial MEV), R5:checkmark(multi-entity: quoter+router+MEV), R6:x(no role), R8:checkmark(external state: QuoterV2 vs Router), R10:checkmark, R11:checkmark(external DEX), R12:checkmark, R15:checkmark(flash loan can amplify sandwich), R16:checkmark(QuoterV2 is effectively an oracle)]
**Depth Evidence**: [TRACE:QuoterV2 reverts -> quoteSwap returns 0 -> amountOutMin=1 -> sandwich], [BOUNDARY:amountOutMin=1 -> extraction=(swapOutput-1)], [VARIATION:QuoterV2 reverts but SwapRouter succeeds -> known production behavior]
**Severity**: Medium
**Location**: ClaimManager.sol:L639-L650
**Description**: When `quoteSwap` returns 0 due to QuoterV2 revert (gas limit, pool state issue, temporary condition), the `amountOutMin` in `_executeCollateralSwap` defaults to 1. The actual swap can still succeed through the SwapRouter, which uses a different execution model than QuoterV2's simulation-based quoting. This creates a window where MEV bots can sandwich the swap for near-total value extraction, as the minimum output required is effectively zero.

**Impact**:
- Near-total value extraction from claim swaps when QuoterV2 is temporarily unavailable
- The loss comes from restaker collateral that was slashed for the claim -- the beneficiary receives far less than their claim entitlement
- QuoterV2 failures are not rare in production (gas spikes, pool rebalancing, temporary liquidity removal)

**Evidence**:
```solidity
// ClaimManager.sol:641-650
uint256 amountOutMin = 1;  // fallback: effectively zero protection
try ISwapper(swapper).quoteSwap(collateralToken, payoutToken, collateralAmount) returns (uint256 quoted) {
    if (quoted > 0) {
        amountOutMin = quoted * (10_000 - maxSwapSlippageBps) / 10_000;
        if (amountOutMin == 0) { amountOutMin = 1; }
    }
} catch {}  // silent catch -- no event, no revert, swap proceeds unprotected
```

### Postcondition Analysis
**Postconditions Created**: Swap executes with amountOutMin=1 when QuoterV2 fails
**Postcondition Types**: EXTERNAL, BALANCE
**Who Benefits**: MEV bots; restakers and beneficiaries both lose

---

### Target 4: Stale Approval Persists on Old RewardsManager

**Source Finding(s)**: PC4-1
**Breadth Claim**: `setRewardsManager` updates pointer but leaves unlimited allowance on old rewardsManager; old contract can drain PremiumManager balances.

#### Analysis

Traced the approval lifecycle in PremiumManager:

1. **Approval setup**: Admin calls `approveSpender(token, rewardsManager, type(uint256).max)` (L102-113) to allow the RewardsManager to pull premium tokens during `distributePremium` (L175-177).

2. **Rotation**: Admin calls `setRewardsManager(newRewardsManager)` (L93-97). This ONLY updates the `rewardsManager` state variable. No approval cleanup occurs.

3. **Stale approval**: The old RewardsManager address retains its unlimited ERC-20 allowance from PremiumManager. If the old RewardsManager has a `transferFrom` capability (which it must, to pull premium tokens), it can still pull tokens from PremiumManager.

4. **Exploitability assessment**: The old RewardsManager is a contract -- to exploit the stale approval, someone must be able to call functions on the old RewardsManager that trigger `transferFrom(PremiumManager, ...)`. The key question is: who controls the old RewardsManager and can they abuse it?

5. **Defense assessment**: The admin has `approveSpender(token, oldRewardsManager, 0)` available as a manual cleanup step. However, this requires the admin to remember to execute two transactions atomically (setRewardsManager + approveSpender revoke). There is no on-chain enforcement.

6. **Devil's advocate**: The old RewardsManager is a protocol-deployed contract, not an arbitrary EOA. If the old RewardsManager is a fixed implementation without arbitrary transfer capabilities, the stale approval may not be exploitable. However, if the old RewardsManager is upgradeable (UUPS), the new implementation could be malicious. This is a trust assumption issue -- the old RewardsManager's admin/upgrader could weaponize the stale approval.

[TRACE: setRewardsManager(new) -> rewardsManager=new, but IERC20.allowance(PremiumManager, old) unchanged -> old can pull tokens]
[BOUNDARY: allowance = type(uint256).max -> all PremiumManager token balances at risk]
[VARIATION: old RewardsManager upgradeable -> new implementation can drain; old RewardsManager immutable -> limited to existing functions]

#### Real Constants
| Constant | Value | Source Line |
|----------|-------|-------------|
| Approval amount | Set by admin (typically type(uint256).max) | PremiumManager.sol:112 |

#### Verdict
- [x] REFINED: The finding is valid but severity depends on the trust model. The `setRewardsManager` function does not revoke the old approval, creating a window where the old RewardsManager retains pull access. However: (a) both `setRewardsManager` and `approveSpender` are `DEFAULT_ADMIN_ROLE` gated, so the same entity controls both, (b) the admin CAN revoke manually, (c) the risk is highest if the old RewardsManager is upgradeable or has arbitrary transfer functions. This is a missing cleanup in an admin workflow -- severity is Medium if the old RewardsManager is independently upgradeable, Low if the same admin controls everything.

---

## Finding [DEPTH-TF-4]: setRewardsManager Does Not Revoke Prior ERC-20 Approval

**Verdict**: CONFIRMED
**Step Execution**: checkmark1,2,3,4,5
**Rules Applied**: [R4:checkmark, R5:x(single entity admin), R6:checkmark(admin role), R8:checkmark(stored external state: approval persists across setRewardsManager calls), R10:checkmark, R11:checkmark(external ERC-20 approval), R12:checkmark, R13:x(not design), R14:checkmark(rewardsManager pointer and approval are independently-settable)]
**Depth Evidence**: [TRACE:setRewardsManager->pointer updated, allowance unchanged->old can pull], [BOUNDARY:allowance=type(uint256).max->all balances at risk], [VARIATION:old RewardsManager upgradeable vs immutable->different exploitation paths]
**Severity**: Low
**Location**: PremiumManager.sol:L93-L97
**Description**: When `setRewardsManager` is called to rotate the RewardsManager address, the ERC-20 approval previously granted to the old RewardsManager via `approveSpender` is not revoked. The old address retains its pull access to PremiumManager's token balances. Both functions are `DEFAULT_ADMIN_ROLE` gated, meaning the same admin can (and must) manually clean up by calling `approveSpender(token, oldRewardsManager, 0)`. This is a missing convenience/safety measure rather than a privilege escalation.

**Impact**: If the admin forgets to revoke the old approval and the old RewardsManager is independently upgradeable or compromised, it can drain PremiumManager's token balances. In practice, the same admin team controls both the rotation and the cleanup, making this an operational risk rather than an access control vulnerability.

**Evidence**:
```solidity
// PremiumManager.sol:93-97 — no approval cleanup
function setRewardsManager(address rewardsManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
    require(rewardsManager_ != address(0), ZeroAddress());
    rewardsManager = rewardsManager_;
    emit RewardsManagerSet(rewardsManager_);
    // Missing: IERC20(token).forceApprove(oldRewardsManager, 0);
}
```

### Precondition Analysis
**Missing Precondition**: Admin must have previously granted approval to old RewardsManager AND forgotten to revoke it
**Precondition Type**: ACCESS + STATE
**Why This Blocks**: Admin who calls setRewardsManager can also call approveSpender to clean up -- same role controls both

### Postcondition Analysis
**Postconditions Created**: Old RewardsManager retains unlimited token pull access from PremiumManager
**Postcondition Types**: ACCESS, BALANCE
**Who Benefits**: Old RewardsManager controller (if compromised or upgraded maliciously)

---

### Target 5: Authorized Operators Can Waive Owner's Insurance

**Source Finding(s)**: RS1-2
**Breadth Claim**: ERC-20 operator can call emergencyRedeem/emergencyWithdraw, setting SKIP_INSURANCE_SLOT, causing owner to lose insurance payout.

#### Analysis

Traced the emergency exit paths:

1. `emergencyRedeem(shares, receiver, owner)` at L241: Sets `SKIP_INSURANCE_SLOT = 1`, then calls `super.redeem(shares, receiver, owner)`.

2. `super.redeem` is OZ's `ERC4626Upgradeable.redeem` (L255-265), which calls `_withdraw(_msgSender(), receiver, owner, assets, shares)`.

3. Since `_msgSender()` (the operator) != `owner`, CoveredVaultWrapper's `_withdraw` at L176-178 calls `_spendAllowance(owner, caller, shares)`. This requires the operator to have an ERC-20 allowance from the owner.

4. With `SKIP_INSURANCE_SLOT = 1`, `_computeInsurance` at L326 returns 0 immediately.

5. The owner's shares are burned, Morpho is redeemed, premium is deducted, but NO insurance claim is filed.

**Attack scenario**: Alice approves Bob for shares (standard ERC-20 allowance for DeFi integration). Bob calls `emergencyRedeem(alice_shares, bob_address, alice)`. Alice's position is liquidated without insurance. Bob receives the Morpho redemption proceeds (net of premium).

**Key nuance**: The receiver is set by the caller (Bob), not the owner (Alice). So Bob gets the proceeds AND Alice loses insurance.

**Is this exploitable for profit?** Bob receives exactly the net Morpho proceeds (assetsReceived - premium). Without the emergency path, Alice would have received the same net Morpho proceeds PLUS any insurance payout. Bob's profit is zero -- he gets the same amount either way (Morpho proceeds go to receiver regardless). But Alice loses her insurance payout.

Wait -- re-reading: if Bob has allowance on Alice's shares and calls normal `redeem(shares, bob, alice)`, Bob also receives the Morpho proceeds. The difference is: normal redeem ALSO files an insurance claim and adds the payout to `totalOut`. So the normal redeem sends MORE to Bob (net assets + insurance), while emergency redeem sends LESS (net assets only, no insurance).

So an attacker with share allowance would actually prefer the normal redeem path (more output for them). The emergency path gives them LESS. There is no profit motive for an operator to use emergencyRedeem over normal redeem -- they get less money.

**Refinement**: The scenario is: a malicious operator deliberately uses emergencyRedeem to deny the owner insurance coverage as griefing. This is economically irrational (they get less) but causes harm to the protocol (no insurance claim filed when one should have been). However, the prerequisite (ERC-20 share allowance from owner to attacker) is a strong trust assumption.

Additionally, shares are soulbound (L269-274). `_update` reverts for non-zero to non-zero transfers. So the only use of share allowance is the ERC-4626 `redeem/withdraw` pattern. Users would only approve operators they trust with their entire position.

[TRACE: emergencyRedeem -> super.redeem -> _withdraw(operator, receiver, owner) -> _spendAllowance -> _computeInsurance returns 0 -> no insurance claim]
[VARIATION: normal redeem vs emergencyRedeem -> normal gives operator MORE (includes insurance payout) -> no profit motive for emergency path]
[BOUNDARY: share allowance required -> soulbound shares mean approval is only for withdraw/redeem, strong trust requirement]

#### Verdict
- [x] REFINED: The finding is technically correct (operator CAN waive owner's insurance via emergencyRedeem), but the attack has no profit motive -- the operator receives LESS output than through normal redeem. This is a griefing-only vector requiring prior share allowance on soulbound shares (strong trust assumption). Severity should be Low.

---

## Finding [DEPTH-TF-5]: Operators Can Grief Owners by Waiving Insurance via Emergency Exit

**Verdict**: CONFIRMED
**Step Execution**: checkmark1,2,3,4,5,6
**Rules Applied**: [R4:checkmark(adversarial), R5:checkmark(operator+owner), R6:checkmark(operator role), R8:x(single-step), R10:checkmark, R11:x(no external tokens), R12:checkmark, R13:checkmark(by design for self-use, not for third-party)]
**Depth Evidence**: [TRACE:emergencyRedeem->super.redeem->_spendAllowance->SKIP_INSURANCE->no claim], [VARIATION:normal vs emergency redeem->normal gives MORE to operator->no profit motive], [BOUNDARY:soulbound shares->allowance only for withdraw/redeem->strong trust]
**Severity**: Low
**Location**: CoveredVaultWrapper.sol:L241-L248, L257-L262
**Description**: `emergencyRedeem` and `emergencyWithdraw` accept an `owner` parameter and use OZ's standard `_spendAllowance` check. Any address with ERC-20 share allowance from the owner can call these functions on the owner's behalf, setting `SKIP_INSURANCE_SLOT` to bypass insurance claims. However, there is no profit motive: normal redeem provides MORE output to the operator (includes insurance payout), making this a griefing-only vector. The prerequisite of share allowance on soulbound shares implies strong trust.

**Impact**: An approved operator can deny insurance coverage for the owner's withdrawal as a griefing attack. The operator receives less than they would through normal redeem. Limited practical impact due to strong prerequisite and lack of profit motive.

**Evidence**:
```solidity
// CoveredVaultWrapper.sol:241-248
function emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256) {
    _tstore(SKIP_INSURANCE_SLOT, 1);  // Bypasses insurance for ANY caller with allowance
    super.redeem(shares, receiver, owner);  // Uses _spendAllowance if caller != owner
    _tstore(SKIP_INSURANCE_SLOT, 0);
    ...
}
```

### Precondition Analysis
**Missing Precondition**: Operator needs ERC-20 share allowance from owner (strong trust requirement for soulbound tokens)
**Precondition Type**: ACCESS
**Why This Blocks**: Soulbound shares make allowance approval a deliberate trust action

---

### Target 6: Fee-on-Transfer Collateral Tokens Cause Over-Approval

**Source Finding(s)**: TF-5
**Breadth Claim**: approve(collateralAmount) then transferFrom; fee-on-transfer token arrives less; subsequent operations may fail.

#### Analysis

Traced the collateral flow in `_executeCollateralSwap` (L629-670):

1. L639: `_approveIfERC20(collateralToken, swapper, collateralAmount)` -- approves Swapper for full amount
2. The Swapper's `executeSwap` at L283 pulls tokens: `IERC20(actualTokenIn).safeTransferFrom(msg.sender, address(this), amountIn)` where amountIn = collateralAmount
3. If collateralToken is fee-on-transfer, the Swapper receives `collateralAmount - fee` but was told `amountIn = collateralAmount`
4. The Swapper then approves the swap target for `amountIn` (full amount) and the target tries to pull `amountIn` from Swapper -- this would fail because Swapper only has `collateralAmount - fee`

Wait, re-reading: ClaimManager approves Swapper for `collateralAmount`. Swapper calls `safeTransferFrom(ClaimManager, Swapper, amountIn=collateralAmount)`. For fee-on-transfer, the transfer sends `collateralAmount` from ClaimManager but Swapper receives `collateralAmount - fee`. The Swapper's `_performSwap` then approves the swap target for `amountIn=collateralAmount` and does `swapTarget.call(swapCalldata)`. The adapter reads `allowance(msg.sender, address(this))` = collateralAmount (the approval) and tries to `safeTransferFrom(Swapper, adapter, collateralAmount)`. But Swapper only has `collateralAmount - fee`, so this transfer reverts.

So the claim would revert entirely for fee-on-transfer tokens. This is a DoS, not a fund loss.

**Precondition**: The protocol must accept fee-on-transfer tokens as collateral in restaking vaults. This is a design/configuration choice. If only standard ERC-20 tokens (WETH, USDC, WBTC, etc.) are used as collateral, this is not reachable.

[TRACE: ClaimManager approves Swapper for collateralAmount -> Swapper pulls collateralAmount but receives less -> Swapper approves adapter for collateralAmount -> adapter.transferFrom(Swapper, collateralAmount) reverts -> claim DoS]
[BOUNDARY: fee-on-transfer tokens as collateral -> not typical for restaking/EigenLayer vaults]

#### Verdict
- [x] REFINED: The finding is technically correct but the precondition (fee-on-transfer token as restaking collateral) is very unlikely in practice. EigenLayer, Symbiotic, and SatLayer use standard tokens (ETH, WETH, WBTC, stETH). The DoS would affect claims only for vaults with fee-on-transfer collateral. Severity remains Low, matching the breadth assessment.

---

## Finding [DEPTH-TF-6]: Fee-on-Transfer Collateral Causes Claim Revert

**Verdict**: PARTIAL
**Step Execution**: checkmark1,2,3,4,5
**Rules Applied**: [R4:x(evidence clear), R5:x(single entity), R6:x(no role), R8:x(single-step), R10:checkmark, R11:checkmark(external fee-on-transfer), R12:x(no dangerous precondition), R13:x(not design)]
**Depth Evidence**: [TRACE:approve(full)->transferFrom(full)->receiver gets less->downstream transfer reverts], [BOUNDARY:fee-on-transfer tokens as restaking collateral->unlikely in practice]
**Severity**: Low
**Location**: ClaimManager.sol:L639, Swapper.sol:L283
**Description**: If a fee-on-transfer token is used as collateral in a restaking vault, the claim execution flow breaks: ClaimManager approves the full collateral amount but the Swapper receives less due to transfer fees, causing the downstream adapter transfer to revert.

**Impact**: DoS on insurance claims for policies backed by fee-on-transfer collateral. Does not affect standard ERC-20 collateral (WETH, USDC, WBTC, stETH).

### Precondition Analysis
**Missing Precondition**: Restaking vault must use fee-on-transfer token as collateral
**Precondition Type**: EXTERNAL
**Why This Blocks**: Standard restaking protocols (EigenLayer, Symbiotic) use only standard ERC-20 tokens

---

### Target 7: block.timestamp as Swap Deadline

**Source Finding(s)**: TF-1
**Breadth Claim**: `deadline: block.timestamp` at ClaimManager.sol:659 offers no forward deadline protection.

#### Analysis

At L659, `deadline: block.timestamp` means the swap is valid in whatever block it is included. The Swapper enforces `block.timestamp <= params.deadline` at L225, which is always true when deadline equals block.timestamp.

This means the transaction can be held by a mempool operator (or sequencer) for an arbitrary period. During that time:
- Token prices may move adversely
- The amountOutMin (computed from the quote at submission time) becomes stale
- A validator/sequencer can delay the transaction to maximize MEV extraction

However, the amountOutMin is computed on-chain at execution time (L643-649), NOT at submission time. The quote is fetched WITHIN the same transaction, so the deadline is irrelevant for price staleness -- the quote reflects the pool state at execution time.

The only remaining concern is: a validator could choose to include the transaction in a specific block to maximize sandwich profit. But the amountOutMin computed in the same block provides the protection (at 2% slippage tolerance). The deadline adds no additional protection when the quote is computed on-chain.

[TRACE: deadline=block.timestamp, but amountOutMin computed on-chain in same tx -> deadline provides no additional protection because quote is fresh]

#### Verdict
- [x] REFINED: The finding is technically correct (deadline=block.timestamp is a no-op) but the impact is minimal because the slippage protection comes from the on-chain quote (amountOutMin), not the deadline. The deadline would only matter if the amountOutMin were computed off-chain and passed as a parameter, which it is not. Severity is Informational.

---

## Finding [DEPTH-TF-7]: block.timestamp Deadline is a No-Op but Low Impact

**Verdict**: CONFIRMED
**Step Execution**: checkmark1,2,3,4,5,6
**Rules Applied**: [R4:x(evidence clear), R5:x(single entity), R6:x(no role), R8:x(single-step), R10:checkmark, R11:checkmark(external DEX), R12:x, R13:checkmark(known best practice)]
**Depth Evidence**: [TRACE:deadline=block.timestamp always passes, but amountOutMin from on-chain quote provides real protection]
**Severity**: Informational
**Location**: ClaimManager.sol:L659
**Description**: The swap deadline is set to `block.timestamp`, making the deadline check a no-op. However, since `amountOutMin` is computed on-chain from a fresh quote in the same transaction, the deadline provides no additional protection that isn't already covered by the slippage check. This is a minor code quality issue, not a meaningful vulnerability.

**Impact**: No practical impact. The slippage protection via on-chain quote is effective regardless of deadline.

---

### Target 8: Excess Collateral Stranded in ClaimManager (Same-Token Path)

**Source Finding(s)**: RS2-3
**Breadth Claim**: Same-token path caps transfer at remainingPayout but full collateralAmount was slashed; excess stays in ClaimManager.

#### Analysis

In `_processCollateral` at L599-613 (same-token branch):
```solidity
if (resolvedCollateral == resolvedPayout) {
    uint256 transferAmount = collateralAmount > remainingPayout ? remainingPayout : collateralAmount;
    ...
    _transferToken(payoutToken, beneficiary, transferAmount);
    amountOut = transferAmount;
}
```

The collateralAmount was already slashed from the restaking vault via `executeSlashing`. If `collateralAmount > remainingPayout`, only `remainingPayout` is sent to the beneficiary. The excess `collateralAmount - remainingPayout` stays in ClaimManager.

This is the same-token variant of DEPTH-TF-1 (swap path). The root cause is identical: the slashing mechanism may over-slash relative to the capped payout, and surplus stays in ClaimManager.

For the same-token case, the `_inflateForSlippage` is NOT applied (L538: `_resolveNative(token) == _resolveNative(payoutToken)` returns the base slash without inflation). However, the proportional slash calculation at L533 (`slashAmount = (tokenStake * requestedAmount) / totalPayoutEquivalent`) can still produce over-slashing when rounding or when multiple vaults contribute.

Actually, for same-token pairs, `payoutEquivalent = tokenStake` (L498), so `slashAmount = tokenStake * requestedAmount / totalPayoutEquivalent`. If there is only one vault, `totalPayoutEquivalent = tokenStake`, so `slashAmount = requestedAmount`. In multi-vault scenarios, proportional distribution could lead to slight over-slashing due to rounding.

But more importantly: `_slashAndDistribute` at L420 starts `remainingPayout = requestedAmount` and decrements it per iteration. In a multi-vault scenario where earlier vaults satisfy most of the payout, later vaults are over-slashed relative to the remaining need. This is because the slash amounts were pre-computed at L387-388 BEFORE the loop at L420-435.

[TRACE: _computeVaultSlashes pre-computes all slash amounts -> _slashAndDistribute processes in order -> later vaults may be slashed for more than remainingPayout -> excess capped and stranded]
[BOUNDARY: multi-vault scenario with first vault satisfying most payout -> second vault over-slashed]

#### Verdict
- [x] CONFIRMED: This is the same root cause as DEPTH-TF-1 (excess stranding). The same-token path has lower expected surplus (no slippage inflation), but can still strand excess in multi-vault scenarios. This finding should be consolidated with DEPTH-TF-1 since they share the same root cause and fix (return excess to restakers or reduce slash).

---

## Finding [DEPTH-TF-8]: Same-Token Excess Collateral Stranded in ClaimManager (Multi-Vault)

**Verdict**: CONFIRMED
**Step Execution**: checkmark1,2,3,4,5
**Rules Applied**: [R4:x(clear), R5:checkmark(multi-vault), R6:x(no role), R8:checkmark(pre-computed slash vs sequential payout), R10:checkmark, R11:x, R12:checkmark, R13:x]
**Depth Evidence**: [TRACE: _computeVaultSlashes pre-computes -> sequential processing -> cap -> surplus stranded], [BOUNDARY: multi-vault with first vault satisfying payout -> second vault over-slashed]
**Severity**: Low (same-token path, lower surplus than swap path)
**Location**: ClaimManager.sol:L599-L613, L420-L435
**Description**: Consolidation target with DEPTH-TF-1. In multi-vault same-token claim scenarios, vault slash amounts are pre-computed before sequential processing. If earlier vaults satisfy most of the remaining payout, later vaults are over-slashed relative to the remaining need. The excess stays in ClaimManager (recoverable via admin).

**Impact**: Minor excess collateral stranding in multi-vault same-token claims. Lower magnitude than swap-path stranding (no slippage inflation). Admin-recoverable via `recoverTokens`.

---

### Target 9: Morpho Share Donation Inflates _morphoValue()

**Source Finding(s)**: TF-3
**Breadth Claim**: Unsolicited Morpho share donation increases _morphoValue, benefits all depositors, attacker cannot extract.

#### Analysis

In `_morphoValue()` at CoveredVaultAccrual.sol:139-147:
```solidity
try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (uint256 val) {
    return val;
}
```

This reads the wrapper's Morpho share balance and converts to assets. If someone donates Morpho shares directly to the wrapper, `balanceOf(address(this))` increases, inflating `_morphoValue()`.

`totalAssets() = morphoValue - totalPremiumLiability - accruedPremium`

Higher morphoValue -> higher totalAssets -> higher share price -> benefits existing depositors (their shares are worth more in asset terms).

**Can an attacker extract profit?**
1. Attacker deposits into the wrapper, receiving shares
2. Attacker donates Morpho shares to wrapper, inflating morphoValue
3. Attacker withdraws -- gets proportionally more assets

But wait: the donated shares are NOT tracked in `userMorphoShares[attacker]`. The `_executeWithdrawal` at L537 computes `redeemShares = userMorphoShares[owner].mulDiv(shares, ownerBalance)`. Only the user's tracked Morpho shares are redeemed, not the donated ones.

So the attacker donates shares, inflating the price, but cannot extract them through withdrawal because their `userMorphoShares` doesn't include the donation. The donated shares are permanently stuck (no one's `userMorphoShares` includes them).

The inflation benefits ALL depositors proportionally. The attacker cannot selectively benefit. This is a donation attack that harms only the attacker.

[TRACE: donate Morpho shares -> balanceOf(wrapper) increases -> _morphoValue increases -> totalAssets increases -> all share prices increase -> BUT withdrawal only redeems tracked userMorphoShares -> donated shares stuck]
[BOUNDARY: donated shares are not in any userMorphoShares mapping -> unredeemable]

#### Vault Accounting Check (Injectable)
The `userMorphoShares` tracking prevents extraction of donated shares. `sum(userMorphoShares[user])` may be less than actual `morphoVault.balanceOf(wrapper)` after donation, but the excess is never redeemed.

#### Verdict
- [x] REFUTED: The donation attack is not exploitable. The attacker cannot extract donated Morpho shares because withdrawals only redeem tracked `userMorphoShares`. The donation benefits all depositors proportionally (positive externality) and harms the attacker. This is a known benign property, not a vulnerability. [CODE] evidence at CoveredVaultWrapper.sol:537 (userMorphoShares-based redemption) and CoveredVaultAccrual.sol:140 (balanceOf query).

---

## VAULT_ACCOUNTING Analysis

### Q1: Can totalPrincipal and totalPremiumLiability become permanently inconsistent?

Traced the relevant update paths:

**totalPrincipal**: Increased at deposit (L132: `totalPrincipal += assets`), decreased at withdraw (L189: `totalPrincipal -= userPrincipalForWithdrawal`).

**totalPremiumLiability**: Increased by `_accruePremium` (checkpointed premium), decreased at withdraw (L583: `totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal)`).

**Deep-loss scenario**: If Morpho value drops significantly, `premiumForWithdrawal` is capped at `assetsReceived` (L149: `premiumForWithdrawal_ = uncappedPremium_ < assetsReceived_ ? uncappedPremium_ : assetsReceived_`). The difference (uncapped - capped) is NOT subtracted from totalPremiumLiability. However, looking at L583: `totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal)` -- it subtracts only the actually-collected premium, not the uncapped amount.

This means in deep loss: uncappedPremium = 100, assetsReceived = 20, premiumForWithdrawal = 20. totalPremiumLiability decreases by 20. But the user's principal is fully removed (L189). The remaining 80 in totalPremiumLiability corresponds to premium that was never collected and never will be.

If ALL users withdraw in deep loss, totalPrincipal reaches 0, but totalPremiumLiability may still be > 0 (the uncollected/forgiven portions accumulate). However, with totalPrincipal = 0, no new premium accrues, and totalPremiumLiability is a phantom liability.

Does this cause harm? `totalAssets() = morphoValue - totalPremiumLiability - accruedPremium`. If totalPremiumLiability > morphoValue, totalAssets() returns 0 (floored). New depositors' share price would be based on morphoValue (from actual Morpho balance) minus the phantom liability. This could make shares cheaper than they should be, benefiting new depositors at the expense of... nobody (all old depositors already withdrew).

After all users exit and new deposits come in, totalPrincipal starts fresh, but totalPremiumLiability still has the phantom value. The `_accruePremium` function is capped by `_liabilityHeadroom(morphoVal)` which returns `morphoVal > totalPremiumLiability ? morphoVal - totalPremiumLiability : 0`. With phantom liability, new premium accrual is reduced/blocked until morphoValue grows enough.

This is the CS-2 "phantom liability after deep-loss" concern. It is a real accounting inconsistency but not a fund loss -- it makes the vault less attractive to new depositors (lower apparent totalAssets, premium accrual constrained).

[TRACE: deep loss -> premiumForWithdrawal capped at assetsReceived -> totalPremiumLiability decremented by capped amount only -> uncollected premium remains as phantom liability -> reduces totalAssets for future depositors]

This is an existing finding (CS-2) confirmed through depth analysis.

### Q2: Does balance-diff in _claimInsurance correctly measure payouts?

At L353-377 of CoveredVaultWrapper.sol:
```solidity
uint256 balanceBefore = IERC20(payoutToken).balanceOf(address(this));
_tstore(PENDING_CLAIM_AMOUNT_SLOT, cappedClaim);
...
try claimManager.fileClaim(policyId, cappedClaim, evidenceHash, additionalData) { }
catch { ... return 0; }
_tstore(PENDING_CLAIM_AMOUNT_SLOT, 0);
uint256 balanceAfter = IERC20(payoutToken).balanceOf(address(this));
payout = balanceAfter - balanceBefore;
```

The balance-diff correctly captures whatever ClaimManager sends to this contract. Edge case: ClaimManager sends 0 (no collateral slashed, or swap fails). Then `balanceAfter == balanceBefore`, payout = 0. The caller (`_settleWithdrawalTransfer`) adds 0 to totalOut. This is correct.

Edge case: ClaimManager sends less than cappedClaim (partial payout due to insufficient collateral). Balance-diff captures the actual amount. Correct.

Edge case: Someone else sends payoutToken to the wrapper during the fileClaim call (reentrancy or concurrent tx). However, `_withdraw` has `nonReentrant` at L172, and `fileClaim` is the only external call. Cross-transaction interference is not possible (balance-diff is within a single transaction). Correct.

The balance-diff pattern is sound for measuring actual payout.

### Q3: Can a user withdraw more than they deposited (ignoring yield)?

The user's withdrawal amount is: `totalOut = netAssetsReceived + insurancePayout` (L157).

`netAssetsReceived = assetsReceived - premiumForWithdrawal`. For the assets to exceed deposit, we need `netAssetsReceived + insurancePayout > userPrincipal`.

`assetsReceived` comes from Morpho redemption. If Morpho generated yield, `assetsReceived > userPrincipalForWithdrawal` is possible and expected (that's the yield). After premium deduction, the user receives net yield.

Insurance payout is only triggered when `insuredBasis > netAssetsReceived` (L328). The payout compensates for loss, capped at `maxCoverableLossBps` of basis minus deductible. It cannot exceed the shortfall.

So: `totalOut <= max(netAssetsReceived, insuredBasis)`. `insuredBasis = userPrincipalForWithdrawal - premiumForWithdrawal`. The user cannot withdraw more than their principal (excluding yield) through insurance -- insurance only makes them whole up to `insuredBasis`, never above.

With yield: `totalOut = (assetsReceived - premium) + insurance`. If assetsReceived includes yield, total can exceed original deposit. This is correct behavior.

No vulnerability found. The accounting is sound.

---

## Chain Summary

| Finding ID | Dangerous State | Postconditions | Precondition Type |
|------------|----------------|----------------|-------------------|
| DEPTH-TF-1 | Excess payout token stranded in ClaimManager after swap cap | Restaker over-slashed, surplus admin-recoverable only | BALANCE |
| DEPTH-TF-2 | Fee tier desync between quote and swap paths | Claims DoS or weakened slippage; two admin roles must coordinate | STATE, EXTERNAL |
| DEPTH-TF-3 | amountOutMin=1 when QuoterV2 reverts | Near-total MEV extraction from claim swap | EXTERNAL |
| DEPTH-TF-4 | Stale ERC-20 approval on old RewardsManager | Old address retains pull access to PremiumManager funds | ACCESS, BALANCE |
| DEPTH-TF-5 | Operator waives owner's insurance via emergency exit | Owner loses insurance payout; operator gets less (griefing only) | ACCESS |
| DEPTH-TF-6 | Fee-on-transfer collateral causes claim revert | DoS on claims for fee-on-transfer collateral vaults | EXTERNAL |
| DEPTH-TF-7 | block.timestamp deadline is no-op | No practical impact (on-chain quote provides protection) | - |
| DEPTH-TF-8 | Same-token excess collateral stranded (multi-vault) | Minor surplus in ClaimManager, admin-recoverable | BALANCE |
