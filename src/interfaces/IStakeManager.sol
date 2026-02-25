// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IStakeManager
 * @notice Minimal interface for Catalysis Core's StakeManager contract.
 * @dev Coverage contracts use only the committee lifecycle and stake query surfaces.
 *      Admin functions (setRouter, setCoverPoolFactory, etc.) are not called by coverage contracts.
 */
interface IStakeManager {
    /// @notice Thrown when committee ID 0 is used (reserved as sentinel value)
    error InvalidCommitteeId();

    /// @notice Thrown when attempting to create a committee that already exists
    error CommitteeAlreadyExists();

    /// @notice Thrown when an invalid amount is provided (zero)
    error InvalidAmount();

    /// @notice Thrown when an invalid duration is provided (zero)
    error InvalidDuration();

    /// @notice Thrown when attempting to add an operator that is already in a committee
    error OperatorAlreadyInCommittee();

    /// @notice Thrown when attempting to add an operator to a committee that already has an operator
    error CommitteeAlreadyHasOperator();

    /// @notice Creates a committee by setting up operator sets and network limits across protocols.
    /// @param committeeId The committee ID (1:1 with policyId).
    /// @param maxStakeForCommittee The maximum stake limit in USD (8 decimals).
    /// @param duration The duration in seconds for the vault lock period.
    function createCommittee(
        uint96 committeeId,
        uint256 maxStakeForCommittee,
        address coverPool,
        uint32 duration
    )
        external;

    /// @notice Adds an operator to a committee (one operator per committee).
    /// @param operator The address of the operator.
    /// @param committeeId The ID of the committee to add the operator to.
    function addOperatorToCommittee(address operator, uint96 committeeId) external;

    /// @notice Associates vaults with a committee and configures them in the appropriate adapters.
    /// @param committeeId The ID of the committee.
    /// @param vaults The array of vault addresses to associate.
    function addCommitteeVaults(uint96 committeeId, address[] calldata vaults) external;

    /// @notice Returns the total stake for a committee across all registered vaults (USD, 8 decimals).
    /// @dev Each committee has exactly one operator via the 1:1 policyId→committeeId mapping.
    /// @param committeeId The ID of the committee.
    /// @return The total stake for the committee in USD (8 decimals).
    function getOperatorCommitteeStake(uint96 committeeId) external view returns (uint256);

    /// @notice Returns all vault addresses associated with a committee.
    /// @param committeeId The ID of the committee to check.
    /// @return The array of vault addresses associated with the committee.
    function getCommitteeVaults(uint96 committeeId) external view returns (address[] memory);
}
