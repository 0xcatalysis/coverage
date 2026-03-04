// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IQuotableAdapter
 * @notice Interface for DEX adapter contracts that support off-chain quote simulation.
 * @dev Implemented by adapters (e.g., UniswapV3Adapter) registered as swapTargets in the Swapper.
 *      Execution is handled via stored calldata replayed with a low-level call; this interface
 *      standardises only the quote path, allowing ClaimManager to preview expected output before
 *      slashing without executing the trade.
 */
interface IQuotableAdapter {
    /**
     * @notice Returns the expected output amount for a swap without executing it.
     * @dev Decodes the same routeCalldata format used by the adapter's swap function.
     * @param routeCalldata The pre-stored calldata for the swap route (same format as swap execution).
     * @param amountIn The amount of input token to quote for.
     * @return amountOut The expected amount of output token.
     */
    function quote(bytes calldata routeCalldata, uint256 amountIn) external returns (uint256 amountOut);
}
