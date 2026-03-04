// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISwapAdapter
 * @notice Standard interface for DEX adapter contracts that support both execution and quoting.
 * @dev Implemented by adapters (e.g., UniswapV3Adapter) registered as swapTargets in the Swapper.
 *      The `quote` function mirrors the routing logic of `swap` but delegates to the DEX quoter
 *      rather than executing the trade, allowing ClaimManager to preview expected output before slashing.
 */
interface ISwapAdapter {
    /**
     * @notice Returns the expected output amount for a swap without executing it.
     * @dev Decodes the same routeCalldata format used by the adapter's swap function.
     *      For UniswapV3Adapter, routeCalldata encodes `swap(tokenIn, tokenOut, fee)`.
     *      Reverts if the route is not supported or the quoter fails.
     * @param routeCalldata The pre-stored calldata for the swap route (same format as swap execution).
     * @param amountIn The amount of input token to quote for.
     * @return amountOut The expected amount of output token.
     */
    function quote(bytes calldata routeCalldata, uint256 amountIn) external returns (uint256 amountOut);
}
