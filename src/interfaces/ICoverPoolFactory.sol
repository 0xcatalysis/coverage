// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title ICoverPoolFactory
 * @notice Interface describing deployment and registry management for CoverPool instances.
 */
interface ICoverPoolFactory is IAccessControl {
    /**
     * @notice Creation parameters required to deploy and register a CoverPool.
     */
    struct CreateCoverPoolParams {
        /// @notice Curator that will own and administer the pool.
        address curator;
        /// @notice Initial EIP-712 quote signer authorized on the pool.
        address quoteSigner;
        /// @notice ERC20 token selected for premium payments.
        address premiumToken;
        /// @notice ERC20 token used for claim payouts.
        address payoutToken;
        /// @notice Default spec identifier applied when quotes omit an override.
        bytes32 defaultSpecId;
        /// @notice Basis points routed to the curator on premium settlement.
        uint16 poolFeeBps;
        /// @notice Basis points routed to the platform treasury on settlement.
        uint16 platformFeeBps;
        /// @notice Activation flag recorded on the registry.
        bool active;
    }

    /**
     * @notice Configuration snapshot for a registered CoverPool.
     * @dev Resolved by downstream contracts to enforce fee and asset guards per pool.
     */
    struct PoolConfig {
        address pool;
        address curator;
        address premiumToken;
        address payoutToken;
        bytes32 defaultSpecId;
        uint16 poolFeeBps;
        uint16 platformFeeBps;
        bool active;
    }

    /**
     * @notice Emitted when a new CoverPool clone is deployed and registered.
     * @param coverPool Address of the deployed CoverPool clone.
     * @param curator Curator that owns the pool.
     * @param quoteSigner Initial quote signer configured on the pool.
     * @param policyManager PolicyManager address assigned on initialization.
     */
    event CoverPoolCreated(
        address indexed coverPool, address indexed curator, address quoteSigner, address policyManager
    );

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
     * @notice Emitted when the CoverPool implementation reference is updated.
     * @param previousImplementation Implementation used before the update.
     * @param newImplementation Implementation set after the update.
     */
    event CoverPoolImplementationSet(address indexed previousImplementation, address indexed newImplementation);

    /**
     * @notice Emitted when the PolicyManager reference is updated.
     * @param previousPolicyManager PolicyManager used before the update.
     * @param newPolicyManager PolicyManager set after the update.
     */
    event PolicyManagerSet(address indexed previousPolicyManager, address indexed newPolicyManager);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when a supplied implementation address lacks contract code.
     */
    error InvalidImplementation();

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
     * @notice Pauses cover pool creation.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes cover pool creation.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Deploys a CoverPool clone, registers it, and initializes configuration.
     * @param params Struct containing curator, token, and fee data.
     */
    function createCoverPool(CreateCoverPoolParams calldata params) external;

    /**
     * @notice Updates the CoverPool implementation used for future clones.
     * @param newImplementation Address of the implementation contract.
     */
    function setCoverPoolImplementation(address newImplementation) external;

    /**
     * @notice Updates the PolicyManager configured on new pools.
     * @param newPolicyManager Address of the PolicyManager contract.
     */
    function setPolicyManager(address newPolicyManager) external;

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

    /**
     * @notice Returns the CoverPool implementation address.
     */
    function coverPoolImplementation() external view returns (address);

    /**
     * @notice Returns the PolicyManager address.
     */
    function policyManager() external view returns (address);

    /**
     * @notice Role identifier allowed to create cover pools.
     */
    function CREATOR_ROLE() external view returns (bytes32);
}
