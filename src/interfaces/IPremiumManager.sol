// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IPremiumManager
 * @notice Interface for distributing premiums from vault collectors (e.g. CoveredVaultWrapper),
 * routing fees, and distributing restaker shares to RewardsManager.
 */
interface IPremiumManager is IAccessControl {
    /**
     * @notice Emitted when premiums are successfully distributed.
     * @param pool CoverPool associated with the distribution.
     * @param policyId Policy identifier receiving restaker premiums.
     * @param amount Total premium amount distributed.
     */
    event PremiumDistributed(address indexed pool, uint96 indexed policyId, uint256 amount);

    /**
     * @notice Emitted when the RewardsManager dependency is set or updated.
     * @param rewardsManager_ Address of the rewards manager contract.
     */
    event RewardsManagerSet(address indexed rewardsManager_);

    /**
     * @notice Emitted when an ERC20 spender approval is set by the admin.
     * @param token ERC20 token address.
     * @param spender Address approved to spend the token.
     * @param amount Approved amount.
     */
    event SpenderApproved(address indexed token, address indexed spender, uint256 amount);

    /**
     * @notice Emitted when the platform treasury is set or updated.
     * @param platformTreasury_ Address of the platform treasury.
     */
    event PlatformTreasurySet(address indexed platformTreasury_);

    /**
     * @notice Emitted when the platform fee is updated.
     * @param platformFeeBps_ New platform fee in basis points.
     */
    event PlatformFeeBpsSet(uint16 indexed platformFeeBps_);

    /**
     * @notice Reverts when a zero address is provided where not allowed.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when a zero amount is provided where not allowed.
     */
    error ZeroAmount();

    /**
     * @notice Reverts when provided policy identifier is invalid.
     */
    error InvalidPolicyId();

    /**
     * @notice Reverts when combined platform and pool fees exceed 100%.
     * @param platformFeeBps Platform fee in basis points.
     * @param poolFeeBps Pool fee in basis points.
     * @param totalFeeBps Sum of both fees.
     */
    error ExcessiveCombinedFees(uint16 platformFeeBps, uint16 poolFeeBps, uint16 totalFeeBps);

    /**
     * @notice Reverts when platform fee exceeds maximum allowed.
     * @param feeBps The invalid fee value.
     */
    error InvalidPlatformFeeBps(uint16 feeBps);

    /**
     * @notice Reverts when policyId is not bound to the supplied pool.
     * @param policyId Policy identifier that was not found in the pool.
     * @param pool CoverPool address that was queried.
     */
    error PolicyNotBound(uint96 policyId, address pool);

    /**
     * @notice Pauses premium processing operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes premium processing operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Sets the RewardsManager contract used for immediate reward distribution.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param rewardsManager_ Address of the RewardsManager implementation.
     */
    function setRewardsManager(address rewardsManager_) external;

    /**
     * @notice Approves a spender to transfer an ERC20 token held by this contract.
     * @dev Requires DEFAULT_ADMIN_ROLE. Uses forceApprove to safely reset allowances.
     * @param token ERC20 token to approve.
     * @param spender Address to grant approval to.
     * @param amount Allowance amount (use type(uint256).max for unlimited).
     */
    function approveSpender(address token, address spender, uint256 amount) external;

    /**
     * @notice Sets the platform treasury address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param treasury Address of the platform treasury.
     */
    function setPlatformTreasury(address treasury) external;

    /**
     * @notice Sets the platform fee in basis points.
     * @dev Requires DEFAULT_ADMIN_ROLE. Must not exceed 25% (2500 bps).
     * @param platformFeeBps_ Platform fee in basis points (1 bps = 0.01%).
     */
    function setPlatformFeeBps(uint16 platformFeeBps_) external;

    /**
     * @notice Distributes premiums, routing fees and restaker shares.
     * @dev Permissionless — any caller may invoke this, but PremiumManager only distributes tokens
     *      it already holds. Callers (e.g. CoveredVaultWrapper) must transfer tokens to
     *      PremiumManager before calling this function.
     * @param pool CoverPool address for fee routing.
     * @param policyId Policy identifier for rewards routing.
     * @param premiumToken ERC20 token to distribute.
     * @param amount Total premium amount to distribute.
     */
    function distributePremium(address pool, uint96 policyId, address premiumToken, uint256 amount) external;

    /**
     * @notice Returns the configured RewardsManager address.
     */
    function rewardsManager() external view returns (address);

    /**
     * @notice Returns the configured platform treasury address.
     */
    function platformTreasury() external view returns (address);

    /**
     * @notice Returns the platform fee in basis points.
     */
    function platformFeeBps() external view returns (uint16);

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);

    /**
     **
     * @notice Calculates the platform, pool, and restaker premium splits for a given gross premium.
     * @param grossPremium Premium value to evaluate.
     * @param platformFeeBps_ Platform fee rate in basis points.
     * @param poolFeeBps Pool fee rate in basis points.
     * @return platformSplit Amount allocated to the platform.
     * @return poolSplit Amount allocated to the pool curator.
     * @return restakerSplit Amount remaining for restaker escrow after fees.
     */
    function getFeeSplits(
        uint256 grossPremium,
        uint16 platformFeeBps_,
        uint16 poolFeeBps
    )
        external
        pure
        returns (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit);
}
