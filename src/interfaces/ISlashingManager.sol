// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISlashingManager
 * @notice Interface for Catalysis Core's SlashingManager that executes stake slashing.
 */
interface ISlashingManager {
    /**
     * @notice Slashes stake backing a specific committee and returns seized collateral.
     * @dev Called by ClaimManager after claim approval to seize collateral from restakers.
     * @param committeeId The restaking committee identifier to slash against.
     * @param operator Operator address whose stake is being slashed.
     * @param slashAmount Slash amount in USD (with 8 decimals).
     * @param taskId Unique identifier for this slashing task, used to prevent replay attacks.
     * @return collateralTokens Array of seized collateral token addresses.
     * @return collateralAmounts Array of seized collateral amounts corresponding to tokens.
     */
    function executeSlashing(
        uint96 committeeId,
        address operator,
        uint256 slashAmount,
        bytes32 taskId
    )
        external
        returns (address[] memory collateralTokens, uint256[] memory collateralAmounts);
}
