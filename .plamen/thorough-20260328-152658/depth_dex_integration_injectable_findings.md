# DEX Integration Security — Injectable Investigation Findings

**Agent**: DEX_INTEGRATION_SECURITY Injectable
**Date**: 2026-03-28
**Scope**: ClaimManager.sol (swap flow), Swapper.sol, UniswapV3Adapter.sol, DeployUniswapV3Adapter.s.sol
**Exclusions**: TF-1 (deadline=block.timestamp), TF-4 (quoteSwap returns 0), PC3-2 (fee tier desync)

---

## Finding [DEX-1]: Static amountOutMinimum=0 in Stored Route Calldata Eliminates Uniswap-Level Slippage Guard

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✓, R8:✓, R10:✓, R15:✗(no flash-loan state), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:DeployUniswapV3Adapter.s.sol:L59→routeCalldata encodes amountOutMinimum=0→UniswapV3Adapter.swap()→exactInputSingle(amountOutMinimum=0)], [VARIATION:amountOutMinimum=0 vs expected slippage-derived value], [BOUNDARY:amountOutMinimum=0 means Uniswap accepts any output including 1 wei]
**Severity**: Medium
**Location**: `script/DeployUniswapV3Adapter.s.sol:L59`, `src/adapters/UniswapV3Adapter.sol:L178`

**Description**:
The deployment script configures the swap route with `amountOutMinimum` hardcoded to `0` in the static route calldata:

```solidity
// script/DeployUniswapV3Adapter.s.sol:L59
bytes memory routeCalldata = abi.encodeCall(UniswapV3Adapter.swap, (tokenIn, tokenOut, poolFee, 0));
```

This calldata is stored verbatim in `Swapper._swapRoutes[routeKey].swapCalldata` and is used unchanged for every subsequent swap execution. When `Swapper._performSwap` calls the adapter via:

```solidity
(bool success, bytes memory returnData) = swapTarget.call(swapCalldata); // L311
```

the `UniswapV3Adapter.swap` function receives `amountOutMinimum=0` and passes it directly to Uniswap V3's `exactInputSingle`:

```solidity
IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
    ...
    amountOutMinimum: amountOutMinimum, // = 0 from stored calldata
    sqrtPriceLimitX96: 0
});
amountOut = SWAP_ROUTER.exactInputSingle(params); // L182
```

As a result, Uniswap's native slippage protection is completely disabled at the router level. Uniswap V3 will execute the full swap regardless of price impact.

The system relies entirely on the outer check in `Swapper.executeSwap`:
```solidity
require(amountOut >= params.amountOutMin, InsufficientOutputAmount(...)); // L243
```
where `params.amountOutMin` is computed by `ClaimManager._executeCollateralSwap` as `quoteSwap() * (10_000 - slippageBps) / 10_000`.

**Impact**:
The outer Swapper check provides protection only when `quoteSwap()` succeeds and returns a meaningful value. The slippage architecture has a **single point of failure**: if `quoteSwap()` returns 0 (documented as TF-4 — route failure, revert-prone QuoterV2, network congestion), `amountOutMin` falls back to `1`, and with `amountOutMinimum=0` at the Uniswap level, the swap executes at any price. A sandwicher can drain near-100% of slashed collateral value with no fallback protection.

Even in the normal path (quoteSwap succeeds), the absence of a Uniswap-level guard means that if the outer Swapper check were ever bypassed or misconfigured, there is zero backstop at the DEX layer — no defense-in-depth.

**Evidence**:
```solidity
// script/DeployUniswapV3Adapter.s.sol:L59
bytes memory routeCalldata = abi.encodeCall(UniswapV3Adapter.swap, (tokenIn, tokenOut, poolFee, 0));
//                                                                                            ^^^
//                                                                              amountOutMinimum = 0

// src/adapters/UniswapV3Adapter.sol:L166-L178
uint256 amountIn = IERC20(tokenIn).allowance(msg.sender, address(this));
IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
IERC20(tokenIn).forceApprove(address(SWAP_ROUTER), amountIn);

IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
    ...
    amountOutMinimum: amountOutMinimum,  // passes the static 0 through
    sqrtPriceLimitX96: 0
});
```

---

## Finding [DEX-2]: SWAP_EXECUTOR_ROLE Can Override Route Calldata to Bypass amountOutMin

**Verdict**: PARTIAL
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✗(single entity), R6:✓, R8:✓, R10:✓, R15:✗(no flash-loan)]
**Depth Evidence**: [TRACE:Swapper.executeSwap L240→effectiveCalldata=params.swapCalldata if non-empty→bypasses stored route calldata], [VARIATION:ClaimManager sends "" (safe) vs future SWAP_EXECUTOR sends custom calldata with amountOutMinimum=0]
**Severity**: Low
**Location**: `src/Swapper.sol:L240`

**Description**:
`Swapper.executeSwap` selects between stored route calldata and caller-supplied calldata:

```solidity
// Swapper.sol:L240
bytes memory effectiveCalldata = params.swapCalldata.length > 0 ? params.swapCalldata : routeCalldata;
amountOut = _performSwap(actualTokenIn, actualTokenOut, swapTarget, params.amountIn, effectiveCalldata);
```

Any account with `SWAP_EXECUTOR_ROLE` can supply non-empty `swapCalldata` that completely replaces the stored route calldata. The calldata is executed against the whitelisted `swapTarget` without any validation of its contents.

**Current state**: `ClaimManager._executeCollateralSwap` always passes `swapCalldata: ""` (L658), so the override path is not exercised in production. However, the `SWAP_EXECUTOR_ROLE` is a separate role from `DEFAULT_ADMIN_ROLE` — if this role is granted to any additional address (e.g., a future keeper, automated claims bot, or compromised key), that actor can craft calldata that:
1. Calls the UniswapV3Adapter's `swap()` function with `amountOutMinimum=0` explicitly
2. Targets any whitelisted swap target with arbitrary parameters

The outer `amountOut >= params.amountOutMin` check still applies, but since the caller controls both `swapCalldata` AND `amountOutMin` in `SwapParams`, they can set `amountOutMin=1` and `swapCalldata` encoding `amountOutMinimum=0` to execute zero-slippage-protection swaps.

**Precondition Analysis**:
**Missing Precondition**: SWAP_EXECUTOR_ROLE must be held by a malicious or compromised actor other than ClaimManager.
**Precondition Type**: ACCESS
**Why This Blocks**: ClaimManager (the canonical SWAP_EXECUTOR) always uses `swapCalldata: ""`. The attack requires misuse of the role.

**Evidence**:
```solidity
// ClaimManager.sol:L652-L660
ISwapper.SwapParams memory swapParams = ISwapper.SwapParams({
    tokenIn: collateralToken,
    tokenOut: payoutToken,
    amountIn: collateralAmount,
    amountOutMin: amountOutMin,
    recipient: address(this),
    swapCalldata: "",          // always empty — safe
    deadline: block.timestamp
});
```

---

## Finding [DEX-3]: UniswapV3Adapter amountIn Derived From Approval — Approval Race Window Between _performSwap and adapter.swap

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R15:✗(no flash-loan state)]
**Depth Evidence**: [TRACE:Swapper._performSwap:L308 forceApprove(swapTarget,amountIn)→L311 swapTarget.call(calldata)→UniswapV3Adapter:L166 allowance(msg.sender,this)=amountIn, same tx, no gap], [BOUNDARY:amountIn from approval == params.amountIn passed to _performSwap, no discrepancy]
**Severity**: N/A — REFUTED
**Location**: `src/Swapper.sol:L308-L311`, `src/adapters/UniswapV3Adapter.sol:L166`

**Description**:
The UniswapV3Adapter reads `amountIn` from `allowance(msg.sender, address(this))` rather than from calldata parameters. Investigated whether this creates a race condition or approval-amount mismatch.

**Analysis**: All operations occur within a single transaction with no external callbacks between approval and read. Swapper sets `forceApprove(swapTarget, amountIn)` at L308, then immediately calls `swapTarget.call(swapCalldata)` at L311 with no intervening external calls. Within the same call context, the adapter reads `allowance(msg.sender=Swapper, address(this)=adapter)` which returns the exact approval just set. The `forceApprove(0)` cleanup at L314 occurs after the swap completes. No race condition is possible.

**Precondition Analysis**:
**Missing Precondition**: There is no window between approval and consumption.
**Precondition Type**: TIMING
**Why This Blocks**: Single-transaction atomicity eliminates any race condition.

---

## Finding [DEX-4]: Large Claim Swaps Execute With No Price Impact Limit (sqrtPriceLimitX96=0)

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✓, R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R15:✗(no flash-loan), R16:✗(no oracle)]
**Depth Evidence**: [TRACE:UniswapV3Adapter.swap L179 sqrtPriceLimitX96=0→Uniswap router traverses ALL tick ranges until amountIn exhausted], [VARIATION:small claim (<0.1% pool depth) vs large claim (>10% pool depth)→price impact grows nonlinearly], [BOUNDARY:sqrtPriceLimitX96=0 is explicitly documented by Uniswap as "no price limit"]
**Severity**: Low
**Location**: `src/adapters/UniswapV3Adapter.sol:L179`

**Description**:
Both the swap execution and quoting paths use `sqrtPriceLimitX96=0`:

```solidity
// UniswapV3Adapter.sol:L172-L179 (swap)
IV3SwapRouter.ExactInputSingleParams memory params = IV3SwapRouter.ExactInputSingleParams({
    ...
    sqrtPriceLimitX96: 0   // no price limit — Uniswap will traverse all tick ranges
});

// UniswapV3Adapter.sol:L130-L134 (quote)
(amountOut,,,) = QUOTER.quoteExactInputSingle(
    IQuoterV2.QuoteExactInputSingleParams({
        ...
        sqrtPriceLimitX96: 0   // quote matches execution path: symmetric
    })
);
```

With `sqrtPriceLimitX96=0`, Uniswap V3 will consume all available liquidity in the pool across every tick range until `amountIn` is fully consumed. For small claims this is fine, but for large slashing events (e.g., a protocol-wide slash liquidating millions in collateral through a single pool), the price impact can be extreme.

Importantly, the quote uses the same `sqrtPriceLimitX96=0`, so the quote accurately reflects the execution price — the slippage tolerance (`maxSwapSlippageBps`) is correctly applied relative to the expected price-impacted output. This means the protection is not broken by this design choice, but it allows vault stakers to receive substantially less value than spot price on large claims.

**Impact**:
For large claims, vault stakers (who bear the slashing) receive significantly less than market value for slashed collateral due to price impact. A 10% pool depth swap on a thin pool could easily result in 5-15% additional value loss beyond the configured slippage tolerance. The `maxSwapSlippageBps` protects against MEV-induced slippage relative to the quote, but cannot protect against fundamental price impact for large swaps. No direct fund theft — this is an economic inefficiency that systematically disadvantages vault stakers during large loss events.

---

## Chain Summary

| Finding ID | Title | Severity | Verdict | Chains With |
|-----------|-------|----------|---------|-------------|
| DEX-1 | Static amountOutMinimum=0 Eliminates Uniswap-Level Slippage Guard | Medium | CONFIRMED | Compounds TF-4 (quoteSwap=0 path): DEX-1 + TF-4 together create complete slippage bypass with no fallback |
| DEX-2 | SWAP_EXECUTOR_ROLE Can Override Route Calldata to Bypass amountOutMin | Low | PARTIAL | Enabler for DEX-1 exploitation via any future SWAP_EXECUTOR |
| DEX-3 | UniswapV3Adapter amountIn Derived From Approval — Approval Race Window | N/A | REFUTED | — |
| DEX-4 | Large Claim Swaps Execute With No Price Impact Limit | Low | CONFIRMED | Compounds PC3-1 (excess swap output stranded): large price-impacted swap creates excess output that is stranded in ClaimManager per PC3-1 |
