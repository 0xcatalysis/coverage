// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IQuotableAdapter
 * @notice Interface for DEX adapters that support quoting swap output without executing a trade.
 * @dev Implemented by adapters such as UniswapV3Adapter. Called by Swapper.quoteSwap to obtain
 *      a DEX quote for slippage-inflation calculations in ClaimManager._computeVaultSlashes.
 *      Not a view function because some DEX quoters (e.g. Uniswap V3 QuoterV2) use swap
 *      simulation internally, which modifies transient state before reverting.
 */
interface IQuotableAdapter {
    /**
     * @notice Returns an estimated output amount for a given input without executing a swap.
     * @param tokenIn Address of the input token.
     * @param tokenOut Address of the output token.
     * @param amountIn Amount of tokenIn to quote.
     * @return amountOut Estimated output amount of tokenOut.
     */
    function quote(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut);
}
