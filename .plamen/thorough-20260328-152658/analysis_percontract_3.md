# Per-Contract Analysis #3: ClaimManager + BasePolicyInteractions + Swapper + UniswapV3Adapter

**Cluster**: Claims + DEX cluster
**Agent**: PC3
**Files analyzed**:
- `/Users/dhruv/catalystlabs/coverage/src/ClaimManager.sol`
- `/Users/dhruv/catalystlabs/coverage/src/defi/base/BasePolicyInteractions.sol`
- `/Users/dhruv/catalystlabs/coverage/src/Swapper.sol`
- `/Users/dhruv/catalystlabs/coverage/src/adapters/UniswapV3Adapter.sol`

---

## Finding [PC3-1]: Excess Swap Output Permanently Stranded in ClaimManager

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5 | ✗6(N/A—no external oracle) | ✗7(N/A)
**Rules Applied**: [R4:✗(evidence clear), R5:✓, R6:✗(no role), R8:✓, R10:✓, R11:✓, R12:✓, R13:✗(not design-related), R14:✗(no aggregate constraints), R15:✗(no flash loan path), R16:✗(no oracle dependency)]
**Depth Evidence**: [TRACE:swapOutput=120, remainingPayout=100 → amountOut=100, 20 tokens stranded in ClaimManager with no reclaim path], [BOUNDARY:swapOutput > remainingPayout → surplus never returned to vaults or accounting]
**Severity**: High
**Location**: `ClaimManager.sol:L663-L669`
**Description**:
In `_executeCollateralSwap`, after the Swapper executes a swap and returns `swapOutput` tokens to ClaimManager (recipient is `address(this)` at L657), the function caps the delivered amount at `remainingPayout`:

```solidity
// L663-L669
uint256 swapOutput =
    ISwapper(swapper).executeSwap{value: collateralToken == _NATIVE_ETH ? collateralAmount : 0}(swapParams);

amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput;
_transferToken(payoutToken, beneficiary, amountOut);

_approveIfERC20(collateralToken, swapper, 0);
```

When `swapOutput > remainingPayout` (which is expected in the multi-collateral case where slippage inflation caused more collateral to be slashed than strictly necessary), the surplus `swapOutput - remainingPayout` payout tokens remain in ClaimManager. There is no automated mechanism to route this surplus back to vault stakers or credit the next claim. The `totalPaidOut` accounting was already corrected via the `cappedAmount - totalPayout` subtraction at L354, but it uses `amountOut` (the capped value), not `swapOutput` — so the surplus tokens are simply orphaned in the contract.

The accounting consequence: `_policyClaims[policyId].totalPaidOut` is decremented by `cappedAmount - totalPayout` where `totalPayout == amountOut == remainingPayout`. This is correct for the accounting ledger but does nothing to return the physical surplus tokens.

**Impact**:
- Vault stakers are slashed for more collateral than the beneficiary ultimately receives. The delta (`swapOutput - remainingPayout` per affected swap) is permanently locked in ClaimManager.
- Over time, with many multi-collateral claims, the surplus accumulates. Only `DEFAULT_ADMIN_ROLE` can recover it via `recoverTokens`, meaning vault stakers permanently lose value that silently subsidises the admin-recoverable ClaimManager balance.
- In the worst case (high-volatility markets with frequent slippage inflation), every claim silently over-extracts from vaults.

**Evidence**:
```solidity
// ClaimManager.sol:L639-L669
function _executeCollateralSwap(...) private returns (uint256 amountOut) {
    _approveIfERC20(collateralToken, swapper, collateralAmount);

    uint256 amountOutMin = 1;
    try ISwapper(swapper).quoteSwap(collateralToken, payoutToken, collateralAmount) returns (uint256 quoted) {
        if (quoted > 0) {
            amountOutMin = quoted * (10_000 - maxSwapSlippageBps) / 10_000;
            if (amountOutMin == 0) { amountOutMin = 1; }
        }
    } catch {}

    ISwapper.SwapParams memory swapParams = ISwapper.SwapParams({
        ...
        recipient: address(this),   // <--- swap output lands in ClaimManager
        ...
    });

    uint256 swapOutput = ISwapper(swapper).executeSwap{...}(swapParams);

    amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput; // capped
    _transferToken(payoutToken, beneficiary, amountOut);                     // only capped amount sent

    // surplus (swapOutput - remainingPayout) stays in ClaimManager forever
    _approveIfERC20(collateralToken, swapper, 0);
}
```

### Postcondition Analysis
**Postconditions Created**: Stranded payout tokens in ClaimManager contract balance
**Postcondition Types**: [BALANCE, STATE]
**Who Benefits**: Only DEFAULT_ADMIN_ROLE (via `recoverTokens`); vault stakers who were over-slashed receive no compensation

---

## Finding [PC3-2]: UniswapV3Adapter Fee-Tier Mismatch Between `quote` and `swap` Breaks Slippage Calculation

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✓, R6:✗(no role), R8:✓, R10:✓, R11:✓, R12:✓, R13:✗(not design-related), R14:✗(no settable constraints here), R15:✗(no flash loan path), R16:✗(no oracle dependency)]
**Depth Evidence**: [VARIATION:pairFees[key]=500 for quote, stored calldata encodes fee=3000 for swap → quote uses 0.05% USDC/WETH pool (deep), actual swap uses 0.3% pool (shallower) → quote overestimates output → amountOutMin set too high → swap reverts OR quote underestimates output → slippage protection weaker than expected], [TRACE:setPairFee(WETH,USDC,500) → quote reads pairFees=500 → setSwapRoute(WETH,USDC,...,swap(WETH,USDC,3000,...)) → swap executes with fee=3000 → pools diverge]
**Severity**: High
**Location**: `UniswapV3Adapter.sol:L127-L135` (quote), `UniswapV3Adapter.sol:L155-L188` (swap)
**Description**:
`UniswapV3Adapter` has two separate sources of truth for the fee tier used on a token pair:

1. **`quote()`** reads fee from `_getFee(tokenIn, tokenOut)` which consults `pairFees` (set via `setPairFee`):
```solidity
// UniswapV3Adapter.sol:L127-L135
function quote(address tokenIn, address tokenOut, uint256 amountIn) external override returns (uint256 amountOut) {
    uint24 fee = _getFee(tokenIn, tokenOut); // reads pairFees mapping
    (amountOut,,,) = QUOTER.quoteExactInputSingle(
        IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
        })
    );
}
```

2. **`swap()`** receives fee as a parameter encoded in the calldata stored in `Swapper.setSwapRoute()`:
```solidity
// UniswapV3Adapter.sol:L155-L182
function swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountOutMinimum) external returns (uint256 amountOut) {
    require(msg.sender == SWAPPER, UnauthorizedCaller());
    uint256 amountIn = IERC20(tokenIn).allowance(msg.sender, address(this));
    ...
    IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
        ...
        fee: fee,   // fee from calldata, NOT from pairFees
        ...
    });
    amountOut = SWAP_ROUTER.exactInputSingle(params);
}
```

The calldata is static — encoded once when `setSwapRoute` is called. If an admin later calls `setPairFee` to update the fee tier (for example, migrating routing from the 0.3% pool to the newly-deployed 0.05% pool for better execution), the `quote` function immediately uses the new tier while `swap` still uses the old tier baked into the stored calldata. The two paths now operate on different Uniswap V3 pools with different liquidity depths.

**Consequences in ClaimManager**:
- `_computeVaultSlashes` calls `quoteSwap` (→ `quote`) to compute `payoutEquivalents` and `inflateForSlippage`
- `_executeCollateralSwap` calls `quoteSwap` again for `amountOutMin`, then executes the swap (→ `swap`) via stored calldata
- If `pairFees` fee is lower than stored calldata fee (deeper pool quoted, shallower pool executed):
  - Quote overestimates actual output → `amountOutMin` set too high → swap reverts every time → claim fails
- If `pairFees` fee is higher than stored calldata fee (shallower pool quoted, deeper pool executed):
  - Quote underestimates actual output → `amountOutMin` set lower than real execution → slippage protection is weaker than intended → beneficiary under-protected against sandwich attacks

Both consequences are active whenever `pairFees` and stored calldata fall out of sync, which is the normal outcome of any fee tier migration.

**Impact**:
- Scenario A: All claim payouts via this route revert permanently until admin re-configures the stored calldata, causing claim DoS.
- Scenario B: Slippage protection is understated, exposing beneficiary and vault stakers to MEV extraction beyond `maxSwapSlippageBps`.

### Postcondition Analysis
**Postconditions Created**: Fee-tier desync state between quote and swap subsystems
**Postcondition Types**: [STATE, EXTERNAL]
**Who Benefits**: MEV bots (scenario B); effective DoS of claims (scenario A)

---

## Finding [PC3-3]: Excess Collateral Stranded in ClaimManager on Same-Token Path

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✓, R6:✗(no role), R8:✓, R10:✓, R11:✓, R12:✓, R13:✗(not design-related), R14:✗(no aggregate constraints), R15:✗(no flash loan path), R16:✗(no oracle dependency)]
**Depth Evidence**: [BOUNDARY:collateralAmount=150, remainingPayout=100 → transferAmount=100, 50 units stranded; collateralAmount=0 → no issue], [TRACE:_processCollateral(same-token path) → transferAmount=min(collateralAmount,remainingPayout) → only transferAmount sent, surplus in ClaimManager]
**Severity**: Medium
**Location**: `ClaimManager.sol:L598-L620`
**Description**:
In `_processCollateral`, when `resolvedCollateral == resolvedPayout` (same-token path: e.g., payout token is USDC and collateral is also USDC), the transfer amount is capped at `remainingPayout`:

```solidity
// ClaimManager.sol:L602-L613
if (resolvedCollateral == resolvedPayout) {
    uint256 transferAmount = collateralAmount > remainingPayout ? remainingPayout : collateralAmount;
    if (collateralToken != payoutToken) {
        if (collateralToken == _NATIVE_ETH) {
            IWETH(resolvedPayout).deposit{value: transferAmount}();
        } else {
            IWETH(resolvedCollateral).withdraw(transferAmount);
        }
    }
    _transferToken(payoutToken, beneficiary, transferAmount);
    amountOut = transferAmount;
}
```

When `collateralAmount > remainingPayout`, the surplus `collateralAmount - remainingPayout` stays in ClaimManager. Unlike the swap path (PC3-1) where slippage inflation explains why surplus arises, on the same-token path this surplus is purely a consequence of the proportional slashing logic in `_computeVaultSlashes` allocating more collateral than strictly needed once `remainingPayout` has been partially satisfied by earlier loop iterations (`_slashAndDistribute:L420-L435`).

The `totalPaidOut` accounting is correctly adjusted (via `cappedAmount - totalPayout` subtraction), but the physical tokens remain stranded.

**Impact**:
- Vault stakers are slashed for collateral that neither reaches the beneficiary nor is returned to them.
- The magnitude is smaller than PC3-1 (only arises in multi-token claims where the final collateral token overshoots the remaining payout), but the mechanism is identical and cumulative.
- Admin can recover via `recoverTokens` but this is manual and unsystematic.

### Postcondition Analysis
**Postconditions Created**: Stranded collateral tokens in ClaimManager
**Postcondition Types**: [BALANCE, STATE]
**Who Benefits**: Only DEFAULT_ADMIN_ROLE via manual recovery

---

## Finding [PC3-4]: `approveNextClaim` Emits Misleading Event When Called on Non-Gated Policy

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4 | ✗5(N/A—no multi-entity interaction)
**Rules Applied**: [R4:✗(evidence clear), R5:✗(single entity), R6:✗(no semi-trusted role), R8:✗(single-step), R10:✓, R11:✗(no external tokens), R12:✗(no dangerous precondition), R13:✓, R14:✗(no aggregate variables), R15:✗(no flash loan path), R16:✗(no oracle dependency)]
**Depth Evidence**: [BOUNDARY:_claimApprovalRequired[policyId]=false when approveNextClaim called → no-op write, misleading event; _claimApprovalRequired[policyId]=true → correct behavior]
**Severity**: Low
**Location**: `ClaimManager.sol:L179-L185`
**Description**:
`approveNextClaim` unconditionally writes `_claimApprovalRequired[policyId] = false` and emits `NextClaimApproved` regardless of whether approval was actually required:

```solidity
// ClaimManager.sol:L179-L185
function approveNextClaim(uint96 policyId) external override {
    IPolicyManager.PolicyMetadata memory metadata = IPolicyManager(policyManager).policyMetadata(policyId);
    require(metadata.buyer != address(0), PolicyNotFound(policyId));
    require(msg.sender == ICoverPool(metadata.pool).owner(), UnauthorizedApprover());
    _claimApprovalRequired[policyId] = false;  // no check that it was true
    emit NextClaimApproved(policyId, msg.sender);
}
```

There is no `require(_claimApprovalRequired[policyId], ...)` guard. A pool owner can call this:
1. On a policy that has never had a successful claim (initial state is `false`)
2. Immediately after a previous `approveNextClaim` call (if a claim was filed between the two calls but they land in the same block, or if the second call is accidental)

In case 1, the event emission implies an approval action occurred when the state was already open. Off-chain monitoring systems relying on `NextClaimApproved` events to track claim gate state will see spurious approvals.

More critically, the pool owner cannot query "did I already approve the next claim?" from the event log alone without cross-referencing `claimApprovalRequired()` view. The event log becomes unreliable for audit/monitoring purposes.

**Impact**:
- Off-chain systems relying on `NextClaimApproved` events to track approval state receive incorrect signals, potentially double-counting approvals or failing to detect that a gate-required situation was not actually gated.
- Low severity because there is no fund loss and the `claimApprovalRequired()` view returns the correct on-chain state.

---

## Finding [PC3-5]: `_fileClaimWithMetadata` Permanently Consumes `evidenceHash` Even on Subsequently Rejected Claims

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(evidence clear), R5:✓, R6:✗(no role), R8:✓, R10:✓, R11:✗(no external tokens), R12:✗(no dangerous precondition), R13:✓, R14:✗(no aggregate variables), R15:✗(no flash loan path), R16:✗(no oracle dependency)]
**Depth Evidence**: [TRACE:fileClaim → _fileClaimWithMetadata marks evidenceHash used at L311 → spec evaluation fails → claim.status=Rejected at L223 → evidenceHash still marked used, cannot re-file same evidence], [BOUNDARY:evidenceHash for legitimate coverage event → rejected by spec (e.g. transient data) → claimer cannot refile with same evidence even if underlying event was valid]
**Severity**: Low
**Location**: `ClaimManager.sol:L311`, `ClaimManager.sol:L222-L225`
**Description**:
In `_fileClaimWithMetadata`, the `_usedEvidenceHashes` mapping is set to `true` at line 311 — before `_evaluateSpec` is called and before the claim is approved or rejected:

```solidity
// ClaimManager.sol:L310-L322
_usedEvidenceHashes[policyId][evidenceHash] = true;  // permanently consumed

claimId = _policyClaims[policyId].claimCount;
ClaimRecord storage claim = _claims[policyId][claimId];
claim.status = ClaimStatus.Filed;
...
_policyClaims[policyId].claimCount++;
```

Back in `fileClaim`, if spec evaluation fails:
```solidity
// ClaimManager.sol:L222-L225
if (!result.isPayable) {
    claim.status = ClaimStatus.Rejected;
    emit ClaimRejected(policyId, claimId, "Spec evaluation failed", block.timestamp);
    return claimId;
}
```

The claim is rejected but `_usedEvidenceHashes[policyId][evidenceHash]` remains `true`. If the spec rejection was due to transient data (e.g., a price feed not updated in time, a block reorg causing slightly different `additionalData` to be valid on re-submission), the claimer cannot re-file using the same `evidenceHash` even if the underlying covered event genuinely occurred.

In a parametric insurance context where evidence may be deterministically derived from on-chain data at a specific timestamp, this is particularly relevant: a claimer who submits at a temporarily bad moment permanently loses the right to use that specific evidence hash.

**Impact**:
- A legitimate claim backed by valid evidence may be permanently barred from re-submission if the first submission fails due to timing or transient conditions — without any fault of the claimer.
- The claimer must construct a different `evidenceHash` for the same event, which may not always be possible if the hash is a deterministic commitment to on-chain state at a specific timestamp.
- `claimCount` also increments on rejection, so the claim counter diverges from "number of paid claims" which may confuse off-chain systems.

---

## Chain Summary

| Finding ID | Type | Root Cause | Severity | Location |
|-----------|------|-----------|----------|----------|
| PC3-1 | Value leak | Surplus swap output not returned | High | ClaimManager:L663-L669 |
| PC3-2 | Fee mismatch | pairFees vs stored calldata desync | High | UniswapV3Adapter:L127-L188 |
| PC3-3 | Value leak | Same-token surplus not returned | Medium | ClaimManager:L602-L613 |
| PC3-4 | State logic | approveNextClaim no-op when already false | Low | ClaimManager:L179-L185 |
| PC3-5 | State logic | evidenceHash consumed before outcome known | Low | ClaimManager:L311 |

**Chain opportunities identified**:
- PC3-1 + PC3-2 chain: If fee mismatch causes quote to underestimate actual swap output (scenario B), the over-output then gets stranded in ClaimManager (PC3-1 mechanism). This creates a compound vault over-slashing path where both the inflation AND the swap surplus accumulate silently.
- PC3-2 (scenario A: quote overestimates) → claim DoS → combined with RS1-1 (grace window) → policies cannot collect insurance within the coverage window at all.
