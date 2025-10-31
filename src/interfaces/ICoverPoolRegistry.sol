// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title ICoverPoolRegistry
 * @notice Registry interface that exposes metadata for Cover Pool deployments.
 */
interface ICoverPoolRegistry is IAccessControl {
    /**
     * @notice Configuration snapshot for a registered CoverPool.
     * @dev Resolved by PolicyManager and PremiumManager to enforce fee and asset guards per pool.
     */
    struct PoolConfig {
        /// @notice Address of the deployed CoverPool contract.
        address pool;
        /// @notice Curator wallet responsible for pool management and quote signing.
        address curator;
        /// @notice ERC20 asset accepted for premium payments from buyers.
        address premiumToken;
        /// @notice ERC20 asset used to settle claims for policies under this pool.
        address payoutToken;
        /// @notice Identifier for the default Spec used if a quote omits an override.
        bytes32 defaultSpecId;
        /// @notice Basis points of premium routed to the curator upon binding.
        uint16 poolFeeBps;
        /// @notice Basis points of premium reserved for the Catalysis platform treasury.
        uint16 platformFeeBps;
        /// @notice Indicates if the pool is active and eligible for new policy bindings.
        bool active;
    }

    /**
     * @notice Emitted when configuration fields for a pool are updated.
     * @param pool Address of the pool being updated.
     * @param config Latest configuration snapshot persisted for the pool.
     */
    event PoolConfigUpdated(address indexed pool, PoolConfig config);

    /**
     * @notice Emitted when a pool's active status flips.
     * @param pool Address of the pool whose status changed.
     * @param active New activation flag.
     */
    event PoolStatusSet(address indexed pool, bool active);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when supplied fee values exceed the defined basis-point cap.
     */
    error InvalidFeeBps();

    /**
     * @notice Reverts when the requested pool does not exist in storage.
     * @param pool Address that failed the lookup.
     */
    error PoolNotFound(address pool);

    /**
     * @notice Reverts when resolving a pool address that has not been registered.
     * @param pool Address that failed the lookup.
     */
    error PoolNotRegistered(address pool);

    /**
     * @notice Reverts when attempting to set a pool status flag to its existing value.
     */
    error PoolStatusUnchanged();

    /**
     * @notice Reverts when config updates request an active flag change instead of using setPoolStatus.
     */
    error PoolActiveStatusMismatch();

    /**
     * @notice Reverts when a pagination request uses a zero limit.
     */
    error InvalidLimit();

    /**
     * @notice Pauses registry management.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes registry management.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Updates the configuration metadata for an existing pool.
     * @param newConfig Replacement configuration struct including the pool address.
     */
    function updatePoolConfig(PoolConfig calldata newConfig) external;

    /**
     * @notice Toggles whether a pool is eligible for new bindings.
     * @param pool Address of the pool to modify.
     * @param active Desired active flag.
     */
    function setPoolStatus(address pool, bool active) external;

    /**
     * @notice Enumerates registered pools using offset-based pagination.
     * @param offset Zero-based index to start the page from.
     * @param limit Maximum number of entries to return. Must be greater than zero.
     * @return pools Sequence of pool addresses contained in the page.
     * @return configs Matching pool configurations for the returned addresses.
     */
    function listPools(
        uint256 offset,
        uint256 limit
    )
        external
        view
        returns (address[] memory pools, PoolConfig[] memory configs);

    /**
     * @notice Returns the stored configuration for a given pool address.
     * @param pool Address to resolve.
     * @return PoolConfig struct describing the pool.
     */
    function getPoolConfig(address pool) external view returns (PoolConfig memory);

    /**
     * @notice Returns true when the pool has been registered.
     * @param pool Address of the CoverPool instance.
     */
    function isPoolRegistered(address pool) external view returns (bool);
}
