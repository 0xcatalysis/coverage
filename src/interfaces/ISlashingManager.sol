// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISlashingManager
 * @notice Interface for Catalysis Core's SlashingManager that executes stake slashing.
 * @dev Part of Catalysis Core infrastructure; referenced by ClaimManager for claim settlements.
 */
interface ISlashingManager {
    /**
     * @notice Slashes stake backing a specific policy committee and returns seized collateral.
     * @dev Called by ClaimManager after claim approval to seize collateral from restakers.
     * @param taskIdentifier Task type identifier (e.g., "COVERAGE_POLICY").
     * @param operator Operator address whose stake is being slashed.
     * @param policyCommit Policy commitment hash identifying the coverage schedule.
     * @param slashAmount Amount to slash in USD terms (may be capped by available stake).
     * @return assets Array of seized collateral token addresses.
     * @return amounts Array of seized collateral amounts corresponding to assets.
     */
    function executeSlashing(
        bytes calldata taskIdentifier,
        address operator,
        bytes32 policyCommit,
        uint256 slashAmount
    )
        external
        returns (address[] memory assets, uint256[] memory amounts);
}

