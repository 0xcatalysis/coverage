// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @notice Minimal Uniswap V3 QuoterV2 interface.
 * @dev Avoids importing the full Uniswap dependency tree.
 *      Based on https://github.com/Uniswap/v3-periphery/blob/main/contracts/interfaces/IQuoterV2.sol
 *
 *      Sepolia QuoterV2: 0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3
 *      Mainnet QuoterV2: 0x61fFE014bA17989E743c5F6cB21bF9697530B21e
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
     * @notice Returns the amount out received for a given exact input but for a swap of a single pool.
     * @param params The params for the quote, encoded as `QuoteExactInputSingleParams`
     * @return amountOut The amount of `tokenOut` that would be received
     * @return sqrtPriceX96After The sqrt price of the pool after the swap
     * @return initializedTicksCrossed The number of initialized ticks that the swap crossed
     * @return gasEstimate The estimate of the gas that the swap consumes
     */
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}
