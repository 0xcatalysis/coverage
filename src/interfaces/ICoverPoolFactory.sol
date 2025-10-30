// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICoverPoolRegistry} from "./ICoverPoolRegistry.sol";

/**
 * @title ICoverPoolFactory
 * @notice Interface describing minimal clone deployments for CoverPool instances.
 */
interface ICoverPoolFactory {
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
     * @notice Emitted when a new CoverPool clone is deployed and registered.
     * @param poolId Identifier assigned by the registry.
     * @param coverPool Address of the deployed CoverPool clone.
     * @param curator Curator that owns the pool.
     * @param quoteSigner Initial quote signer configured on the pool.
     * @param policyManager PolicyManager address assigned on initialization.
     */
    event CoverPoolCreated(
        uint256 indexed poolId,
        address indexed coverPool,
        address indexed curator,
        address quoteSigner,
        address policyManager
    );

    /**
     * @notice Emitted when the CoverPool implementation reference is updated.
     * @param previousImplementation Implementation used before the update.
     * @param newImplementation Implementation set after the update.
     */
    event CoverPoolImplementationSet(address indexed previousImplementation, address indexed newImplementation);

    /**
     * @notice Emitted when the CoverPoolRegistry reference is updated.
     * @param previousRegistry Registry used before the update.
     * @param newRegistry Registry set after the update.
     */
    event CoverPoolRegistrySet(address indexed previousRegistry, address indexed newRegistry);

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
     * @notice Reverts when trying to deploy without a configured CoverPool implementation.
     */
    error ImplementationNotSet();

    /**
     * @notice Reverts when trying to deploy without a configured CoverPoolRegistry.
     */
    error RegistryNotSet();

    /**
     * @notice Reverts when trying to deploy without a configured PolicyManager.
     */
    error PolicyManagerNotSet();

    /**
     * @notice Deploys a CoverPool clone, registers it, and initializes configuration.
     * @param params Struct containing curator, token, and fee data.
     * @return coverPool Address of the deployed CoverPool clone.
     * @return poolId Identifier assigned by the CoverPoolRegistry.
     */
    function createCoverPool(CreateCoverPoolParams calldata params) external returns (address coverPool, uint256 poolId);

    /**
     * @notice Updates the CoverPool implementation used for future clones.
     * @param newImplementation Address of the implementation contract.
     */
    function setCoverPoolImplementation(address newImplementation) external;

    /**
     * @notice Updates the registry used when registering pool metadata.
     * @param newRegistry Address of the CoverPoolRegistry contract.
     */
    function setCoverPoolRegistry(address newRegistry) external;

    /**
     * @notice Updates the PolicyManager configured on new pools.
     * @param newPolicyManager Address of the PolicyManager contract.
     */
    function setPolicyManager(address newPolicyManager) external;

    /**
     * @notice Returns the CoverPool implementation address.
     */
    function coverPoolImplementation() external view returns (address);

    /**
     * @notice Returns the CoverPoolRegistry address.
     */
    function coverPoolRegistry() external view returns (address);

    /**
     * @notice Returns the PolicyManager address.
     */
    function policyManager() external view returns (address);

    /**
     * @notice Role identifier allowed to create cover pools.
     */
    function CREATOR_ROLE() external view returns (bytes32);
}
