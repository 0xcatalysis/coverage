// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISlashingManager
 * @notice Interface for Catalysis Core's SlashingManager that executes stake slashing.
 */
interface ISlashingManager {
    /**
     * @notice Per-vault slash instruction: how much to slash in which token from which vault.
     */
    struct VaultSlash {
        address vault;
        address token;
        uint256 amount; // token-native units
    }

    /**
     * @notice Slashes stake backing a specific committee using token-native amounts and returns seized collateral.
     * @dev Called by ClaimManager after claim approval. Coverage computes per-vault amounts; core forwards exact
     *      amounts to adapters without internal USD conversion.
     * @param committeeId The restaking committee identifier to slash against.
     * @param operator Operator address whose stake is being slashed.
     * @param vaultSlashes Per-vault slash instructions (vault, token, token-native amount).
     * @param taskId Unique identifier for this slashing task, used to prevent replay attacks.
     * @return collateralTokens Array of seized collateral token addresses.
     * @return collateralAmounts Array of seized collateral amounts in token-native units.
     */
    function executeSlashing(
        uint96 committeeId,
        address operator,
        VaultSlash[] memory vaultSlashes,
        bytes32 taskId
    )
        external
        returns (address[] memory collateralTokens, uint256[] memory collateralAmounts);

    /**
     * @notice Previews per-vault token stakes without executing slashing.
     * @param committeeId The restaking committee identifier.
     * @param operator Operator address whose stake backs the committee.
     * @return vaults Array of vault addresses in the committee.
     * @return tokens Array of underlying collateral token addresses per vault.
     * @return tokenStakes Array of token-native stake amounts per vault.
     */
    function previewSlashing(
        uint96 committeeId,
        address operator
    )
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes);
}
