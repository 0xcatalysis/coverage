// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IStakeManager
 * @notice Interface for Catalysis Core StakeManager contract.
 * @dev Coverage contracts interact with StakeManager to register policy committees
 *      and query stake information for claim processing.
 */
interface IStakeManager {
    /**
     * @notice Adds a vault to a committee.
     * @dev Requires STAKE_MANAGER_CONFIG_ROLE on the Core StakeManager.
     * @param committeeId The ID of the committee.
     * @param vault The address of the vault to add.
     */
    function addCommitteeVault(uint96 committeeId, address vault) external;

    /**
     * @notice Removes a vault from a committee.
     * @dev Requires STAKE_MANAGER_CONFIG_ROLE on the Core StakeManager.
     * @param committeeId The ID of the committee.
     * @param vault The address of the vault to remove.
     */
    function removeCommitteeVault(uint96 committeeId, address vault) external;

    /**
     * @notice Adds an operator to a committee.
     * @dev Requires STAKE_MANAGER_CONFIG_ROLE on the Core StakeManager.
     *      Registers the operator if not already registered.
     * @param operator The address of the operator.
     * @param committeeId The ID of the committee.
     */
    function addOperatorToCommittee(address operator, uint96 committeeId) external;

    /**
     * @notice Removes an operator from a committee.
     * @dev Requires STAKE_MANAGER_CONFIG_ROLE on the Core StakeManager.
     *      Also removes the operator from all vaults in the committee.
     * @param operator The address of the operator.
     * @param committeeId The ID of the committee.
     */
    function removeOperatorFromCommittee(address operator, uint96 committeeId) external;

    /**
     * @notice Returns all vault addresses associated with a committee.
     * @param committeeId The ID of the committee.
     * @return Array of vault addresses in the committee.
     */
    function getCommitteeVaults(uint96 committeeId) external view returns (address[] memory);

    /**
     * @notice Returns all operators in a committee.
     * @param committeeId The ID of the committee.
     * @return Array of operator addresses in the committee.
     */
    function getCommitteeOperators(uint96 committeeId) external view returns (address[] memory);

    /**
     * @notice Returns the total stake of an operator in a specific committee.
     * @param operator The address of the operator.
     * @param committeeId The ID of the committee.
     * @return The total stake in USD (8 decimals).
     */
    function getOperatorCommitteeStake(address operator, uint96 committeeId) external view returns (uint256);
}
