// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IQuotableAdapter
 * @notice Optional interface that swap adapters may implement to provide pre-swap quotes.
 * @dev Implemented by UniswapV3Adapter. Swapper.quoteSwap calls this when a route's swapTarget
 *      supports it. Not a view function — QuoterV2 uses swap simulation with revert internally.
 */
interface IQuotableAdapter {
    /**
     * @notice Quotes the expected output for a swap without executing it.
     * @param amountIn Amount of tokenIn to swap.
     * @param swapCalldata Stored route calldata from Swapper (same bytes the Swapper passes to swap).
     * @return amountOut Expected amount of tokenOut.
     */
    function quote(uint256 amountIn, bytes calldata swapCalldata) external returns (uint256 amountOut);
}
