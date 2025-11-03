// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title ICoverPoolFactory
 * @notice Interface describing deployment and lightweight registry tracking for CoverPool instances.
 */
interface ICoverPoolFactory is IAccessControl {
    /**
     * @notice Creation parameters required to deploy a CoverPool clone.
     */
    struct CreateCoverPoolParams {
        /// @notice Curator that will own and administer the pool.
        address curator;
        /// @notice Initial EIP-712 quote signer authorized on the pool.
        address quoteSigner;
        /// @notice Default spec identifier applied when quotes omit an override.
        bytes32 defaultSpecId;
        /// @notice Basis points routed to the curator on premium settlement.
        uint16 poolFeeBps;
    }

    /**
     * @notice Emitted when a new CoverPool clone is deployed.
     * @param coverPool Address of the deployed CoverPool clone.
     * @param curator Curator that owns the pool.
     * @param quoteSigner Initial quote signer configured on the pool.
     * @param policyManager PolicyManager address assigned on initialization.
     * @param defaultSpecId Default spec configured for the pool.
     * @param poolFeeBps Default pool fee configured for the pool.
     */
    event CoverPoolCreated(
        address indexed coverPool,
        address indexed curator,
        address quoteSigner,
        address policyManager,
        bytes32 defaultSpecId,
        uint16 poolFeeBps
    );

    /**
     * @notice Emitted when the CoverPool implementation reference is updated.
     */
    event CoverPoolImplementationSet(address indexed previousImplementation, address indexed newImplementation);

    /**
     * @notice Emitted when the PolicyManager reference is updated.
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
     * @notice Reverts when a pagination request uses a zero limit.
     */
    error InvalidLimit();

    /**
     * @notice Pauses cover pool creation.
     */
    function pause() external;

    /**
     * @notice Resumes cover pool creation.
     */
    function unpause() external;

    /**
     * @notice Deploys a CoverPool clone and configures initial settings.
     * @param params Struct containing curator, signer, and default settings.
     */
    function createCoverPool(CreateCoverPoolParams calldata params) external;

    /**
     * @notice Updates the CoverPool implementation used for future clones.
     */
    function setCoverPoolImplementation(address newImplementation) external;

    /**
     * @notice Updates the PolicyManager configured on new pools.
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

    /**
     * @notice Returns true when the pool has been registered.
     */
    function isPoolRegistered(address pool) external view returns (bool);

    /**
     * @notice Returns the number of pools deployed by the factory.
     */
    function totalPools() external view returns (uint256);

    /**
     * @notice Returns the pool address stored at the given index.
     * @param index Position in the pool array.
     */
    function poolAt(uint256 index) external view returns (address);

    /**
     * @notice Returns a slice of pool addresses.
     * @param offset Zero-based index to start the page from.
     * @param limit Maximum number of entries to return. Must be greater than zero.
     */
    function getPools(uint256 offset, uint256 limit) external view returns (address[] memory pools);
}
