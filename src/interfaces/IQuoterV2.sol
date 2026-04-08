// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IQuoterV2
 * @notice Minimal interface for Uniswap V3 QuoterV2.
 * @dev Based on https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/IQuoterV2.sol
 *      Not a view function — QuoterV2 uses swap simulation with revert internally, which is not
 *      staticcall-safe.
 */
interface IQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    /**
     * @notice Returns the amount out received for a given exact input swap without executing the swap.
     * @param params The params for the quote, encoded as QuoteExactInputSingleParams.
     * @return amountOut The amount of tokenOut that would be received.
     * @return sqrtPriceX96After The sqrt price of the pool after the swap.
     * @return initializedTicksCrossed The number of initialized ticks that the swap crossed.
     * @return gasEstimate The estimate of the gas that the swap consumes.
     */
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
