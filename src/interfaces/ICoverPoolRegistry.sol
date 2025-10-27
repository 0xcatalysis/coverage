// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ICoverPoolRegistry
 * @notice Registry interface that exposes metadata for Cover Pool deployments.
 */
interface ICoverPoolRegistry {
    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when supplied fee values exceed the basis point limit.
     */
    error InvalidFeeBps();

    /**
     * @notice Reverts when the combined platform and pool fee basis points exceed 10_000.
     */
    error InvalidFeeSum();

    /**
     * @notice Reverts when attempting to register a pool whose address is already tracked.
     * @param pool Address of the CoverPool contract that was previously registered.
     */
    error PoolAlreadyRegistered(address pool);

    /**
     * @notice Reverts when updating a pool to an address that is already assigned to a different pool id.
     * @param pool Address of the CoverPool contract that conflicts with an existing registration.
     */
    error PoolAddressInUse(address pool);

    /**
     * @notice Reverts when the requested pool identifier does not exist in storage.
     * @param poolId Identifier that failed the lookup.
     */
    error PoolNotFound(uint256 poolId);

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
    error ActiveStatusMismatch();

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
     * @notice Emitted when a new CoverPool is registered in the registry.
     * @param poolId Deterministic identifier assigned to the pool.
     * @param pool Address of the CoverPool contract.
     * @param curator Address of the curator that controls the pool.
     */
    event PoolRegistered(uint256 indexed poolId, address indexed pool, address indexed curator, PoolConfig config);

    /**
     * @notice Emitted when configuration fields for a pool are updated.
     * @param poolId Identifier of the pool being updated.
     * @param config Latest configuration snapshot persisted for the pool.
     */
    event PoolConfigUpdated(uint256 indexed poolId, PoolConfig config);

    /**
     * @notice Emitted when a pool's active status flips.
     * @param poolId Identifier of the pool whose status changed.
     * @param active New activation flag.
     */
    event PoolStatusSet(uint256 indexed poolId, bool active);

    /**
     * @notice Registers a new CoverPool and assigns it a deterministic identifier.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param config Initial configuration parameters describing the pool.
     * @return poolId Newly assigned pool identifier.
     */
    function registerPool(PoolConfig calldata config) external returns (uint256 poolId);

    /**
     * @notice Updates the configuration metadata for an existing pool.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param poolId Identifier of the pool to update.
     * @param newConfig Replacement configuration struct.
     */
    function updatePoolConfig(uint256 poolId, PoolConfig calldata newConfig) external;

    /**
     * @notice Toggles whether a pool is eligible for new bindings.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param poolId Identifier of the pool to modify.
     * @param active Desired active flag.
     */
    function setPoolStatus(uint256 poolId, bool active) external;

    /**
     * @notice Pauses registry mutations.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes registry mutations.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Resolves a pool identifier by CoverPool contract address.
     * @param pool Address of the CoverPool instance.
     * @return poolId Registry identifier associated with the address.
     */
    function resolvePool(address pool) external view returns (uint256 poolId);

    /**
     * @notice Returns the stored configuration for a given pool identifier.
     * @param poolId Identifier to resolve.
     * @return PoolConfig struct describing the pool.
     */
    function getPoolConfig(uint256 poolId) external view returns (PoolConfig memory);
}
