// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IChainlinkPriceFeed
 * @notice Interface for Catalysis Core's ChainlinkPriceFeed that converts token amounts to USD values.
 */
interface IChainlinkPriceFeed {
    /**
     * @notice Returns the USD value of a token amount.
     * @param token ERC20 token address.
     * @param amount Token amount in token's native decimals.
     * @return USD value with 8 decimals.
     */
    function getUSDValue(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Returns the token amount for a given USD value.
     * @param token ERC20 token address.
     * @param usdValue USD value with 8 decimals.
     * @return Token amount in token's native decimals.
     */
    function getTokenAmount(address token, uint256 usdValue) external view returns (uint256);
}
