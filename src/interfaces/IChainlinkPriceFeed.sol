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
     * @notice Returns the token amount corresponding to a USD value.
     * @param token ERC20 token address.
     * @param amountUSD USD value with 8 decimals (Chainlink standard).
     * @return Token amount in the token's native decimals.
     */
    function getTokenAmount(address token, uint256 amountUSD) external view returns (uint256);

    /**
     * @notice Returns whether a Chainlink price feed is registered for the given token.
     * @param token ERC20 token address.
     * @return True if a price feed exists for the token.
     */
    function hasPriceFeed(address token) external view returns (bool);
}
