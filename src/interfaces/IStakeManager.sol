// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IStakeManager
 * @notice Interface for Catalysis Core's StakeManager contract.
 * @dev Coverage contracts interact with StakeManager to register operators and query stake information.
 */
interface IStakeManager {
    /**
     * @notice Registers an operator to the Symbiotic network.
     * @dev This function is specifically for Symbiotic protocol operator registration.
     * @param operator The address of the operator to register.
     * @param deadline The deadline for the registration signature.
     * @param signature The operator's signature for registration.
     */
    function registerOperatorToNetwork(address operator, uint48 deadline, bytes calldata signature) external;

    /**
     * @notice Creates a committee by setting up operator sets and network limits across protocols.
     * @param committeeId The committee ID.
     * @param maxStakeForCommittee The maximum stake limit for Symbiotic vaults.
     */
    function createCommittee(uint96 committeeId, uint256 maxStakeForCommittee) external;

    /**
     * @notice Returns the total stake of an operator in a specific committee across all vaults (in USD with 8
     * decimals).
     * @param operator The address of the operator.
     * @param committeeId The ID of the committee.
     * @return The total stake of the operator in the committee in USD.
     */
    function getOperatorCommitteeStake(address operator, uint96 committeeId) external view returns (uint256);
}
