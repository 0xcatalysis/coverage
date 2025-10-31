// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICoverPoolRegistry} from "./ICoverPoolRegistry.sol";

/**
 * @title ICoverPoolFactory
 * @notice Interface describing deployment and registry management for CoverPool instances.
 */
interface ICoverPoolFactory is ICoverPoolRegistry {
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
     * @param coverPool Address of the deployed CoverPool clone.
     * @param curator Curator that owns the pool.
     * @param quoteSigner Initial quote signer configured on the pool.
     * @param policyManager PolicyManager address assigned on initialization.
     */
    event CoverPoolCreated(
        address indexed coverPool, address indexed curator, address quoteSigner, address policyManager
    );

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
     * @notice Reverts when a supplied implementation address lacks contract code.
     */
    error InvalidImplementation();

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
