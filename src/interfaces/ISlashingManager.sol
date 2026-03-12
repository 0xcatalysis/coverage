// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISlashingManager
 * @notice Interface for Catalysis Core's SlashingManager that executes stake slashing.
 */
interface ISlashingManager {
    /**
     * @notice Per-vault slash specification with token-native amounts.
     * @dev Computed by ClaimManager._computeVaultSlashes using DEX quotes and passed verbatim
     *      to executeSlashing. Core executes slashing at these exact token amounts — no USD
     *      conversion is performed internally.
     */
    struct VaultSlash {
        /// @notice Address of the vault to slash.
        address vault;
        /// @notice Address of the collateral token held by the vault.
        address token;
        /// @notice Amount to slash in token-native units.
        uint256 amount;
    }

    /**
     * @notice Returns a preview of slashable stake for a committee without executing any slashing.
     * @dev Called by ClaimManager before executing slashing to compute proportional slash amounts.
     * @param committeeId The restaking committee identifier.
     * @param operator Operator address whose stake is being queried.
     * @return vaults Array of vault addresses in the committee.
     * @return collateralTokens Array of collateral token addresses per vault.
     * @return tokenStakes Array of slashable amounts per vault in token-native units.
     */
    function previewSlashing(
        uint96 committeeId,
        address operator
    )
        external
        view
        returns (address[] memory vaults, address[] memory collateralTokens, uint256[] memory tokenStakes);

    /**
     * @notice Slashes stake backing a specific committee using token-native amounts and returns
     *         the seized collateral.
     * @dev Called by ClaimManager after claim approval with pre-computed per-vault slash amounts.
     *      Core executes slashing at the exact provided amounts without USD conversion.
     * @param committeeId The restaking committee identifier to slash against.
     * @param operator Operator address whose stake is being slashed.
     * @param vaultSlashes Per-vault slash specifications with token-native amounts.
     * @param taskId Unique identifier for this slashing task, used to prevent replay attacks.
     * @return collateralTokens Array of seized collateral token addresses.
     * @return collateralAmounts Array of seized collateral amounts in token-native units.
     */
    function executeSlashing(
        uint96 committeeId,
        address operator,
        VaultSlash[] calldata vaultSlashes,
        bytes32 taskId
    )
        external
        returns (address[] memory collateralTokens, uint256[] memory collateralAmounts);
}
