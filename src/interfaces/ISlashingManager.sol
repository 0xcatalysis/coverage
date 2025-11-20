// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISlashingManager
 * @notice Interface for Catalysis Core's SlashingManager that executes stake slashing.
 */
interface ISlashingManager {
    /**
     * @notice Slashes stake backing a specific policy committee and returns seized collateral.
     * @dev Called by ClaimManager after claim approval to seize collateral from restakers.
     *      Slash amount is pre-configured in Core via setSlashConfig().
     * @param taskType Task type identifier (e.g., bytes("COVERAGE_POLICY")).
     * @param taskPerformer Operator address whose stake is being slashed.
     * @param taskDefinitionId Policy commitment hash identifying the coverage schedule.
     * @return assets Array of seized collateral token addresses.
     * @return amounts Array of seized collateral amounts corresponding to assets.
     */
    function executeSlashing(
        bytes calldata taskType,
        address taskPerformer,
        bytes32 taskDefinitionId
    )
        external
        returns (address[] memory assets, uint256[] memory amounts);
}
