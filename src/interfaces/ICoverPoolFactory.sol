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
        /// @notice Basis points routed to the curator on premium settlement.
        uint16 poolFeeBps;
        /// @notice Deadline for the operator registration signature.
        uint48 deadline;
        /// @notice Operator's signature for network registration.
        bytes signature;
    }

    /**
     * @notice Emitted when a new CoverPool clone is deployed.
     * @param coverPool Address of the deployed CoverPool clone.
     * @param curator Curator that owns the pool.
     * @param quoteSigner Initial quote signer configured on the pool.
     * @param policyManager PolicyManager address assigned on initialization.
     * @param poolFeeBps Default pool fee configured for the pool.
     */
    event CoverPoolCreated(
        address indexed coverPool,
        address indexed curator,
        address quoteSigner,
        address policyManager,
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
     * @notice Emitted when the StakeManager reference is updated.
     */
    event StakeManagerSet(address indexed previousStakeManager, address indexed newStakeManager);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when a supplied implementation address lacks contract code.
     */
    error InvalidImplementation();

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
     * @dev Requires CREATOR_ROLE. Emits CoverPoolCreated event.
     * @param params Struct containing cover pool parameters.
     */
    function createCoverPool(CreateCoverPoolParams calldata params) external;

    /**
     * @notice Updates the CoverPool implementation used for future clones.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param implementation_ Address of the new CoverPool implementation contract.
     */
    function setCoverPoolImplementation(address implementation_) external;

    /**
     * @notice Updates the PolicyManager configured on new pools.
     * @dev Requires CREATOR_ROLE.
     * @param policyManager_ Address of the new PolicyManager contract.
     */
    function setPolicyManager(address policyManager_) external;

    /**
     * @notice Updates the StakeManager configured for operator registration.
     * @dev Requires CREATOR_ROLE.
     * @param stakeManager_ Address of the new StakeManager contract.
     */
    function setStakeManager(address stakeManager_) external;

    /**
     * @notice Returns the CoverPool implementation address.
     * @return The address of the CoverPool implementation contract.
     */
    function coverPoolImplementation() external view returns (address);

    /**
     * @notice Returns the PolicyManager address.
     * @return The address of the PolicyManager contract.
     */
    function policyManager() external view returns (address);

    /**
     * @notice Role identifier allowed to create cover pools.
     * @return The role identifier hash.
     */
    function CREATOR_ROLE() external view returns (bytes32);

    /**
     * @notice Address of the StakeManager contract from Catalysis Core.
     * @dev Used to register operators to restaking networks.
     * @return The address of the StakeManager contract.
     */
    function stakeManager() external view returns (address);

    /**
     * @notice Returns the deterministic address that would be used for a cover pool deployment.
     * @param params Struct containing cover pool parameters.
     * @return The deterministic address for the cover pool.
     */
    function computeCoverPoolAddress(CreateCoverPoolParams calldata params) external view returns (address);

    /**
     * @notice Returns true when the pool has been registered.
     * @param pool Address of the CoverPool to check.
     * @return True if the pool exists, false otherwise.
     */
    function coverPoolExists(address pool) external view returns (bool);

    /**
     * @notice Returns the pool address stored at the given index.
     * @param index Position in the pool array.
     * @return The address of the CoverPool at the specified index.
     */
    function coverPoolAt(uint256 index) external view returns (address);

    /**
     * @notice Returns the number of pools deployed by the factory.
     * @return The total number of CoverPools created by this factory.
     */
    function coverTotalPools() external view returns (uint256);

    /**
     * @notice Returns a slice of pool addresses.
     * @param offset Zero-based index to start the page from.
     * @param limit Maximum number of entries to return. Must be greater than zero.
     * @return pools Array of CoverPool addresses.
     */
    function getCoverPools(uint256 offset, uint256 limit) external view returns (address[] memory pools);
}
