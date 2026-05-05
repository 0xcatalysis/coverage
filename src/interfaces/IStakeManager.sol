// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IStakeManager
 * @notice Minimal interface for Catalysis Core's StakeManager contract.
 * @dev Coverage contracts use only the committee lifecycle and stake query surfaces.
 *      Admin functions (setRouter, setCoverPoolFactory, etc.) are not called by coverage contracts.
 */
interface IStakeManager {
    /// @notice Creates a committee by setting up operator sets and network limits across protocols.
    /// @param committeeId The committee ID (1:1 with policyId).
    /// @param coverPool The address of the cover pool authorized for this committee.
    /// @param duration The duration in seconds for the vault lock period.
    function createCommittee(uint96 committeeId, address coverPool, uint32 duration) external;

    /// @notice Adds an operator to a committee (one operator per committee).
    /// @dev Requires POLICY_MANAGER_ROLE. The curator (CoverPool owner) is used as the committee operator.
    /// @param operator The address of the operator (curator).
    /// @param committeeId The ID of the committee to add the operator to.
    function addOperatorToCommittee(address operator, uint96 committeeId) external;

    /// @notice Removes an operator from a committee.
    /// @dev Called by the operator themselves or by POLICY_MANAGER_ROLE to free the slot.
    /// @param operator The address of the operator to remove.
    /// @param committeeId The ID of the committee to remove the operator from.
    function removeOperatorFromCommittee(address operator, uint96 committeeId) external;

    /// @notice Associates vaults with a committee and configures them in the appropriate adapters.
    /// @param committeeId The ID of the committee.
    /// @param vaults The array of vault addresses to associate.
    /// @param coverageLimitUSD The coverage limit for the committee expressed in 8-decimal USD (Chainlink standard).
    function setCommitteeVaults(uint96 committeeId, address[] calldata vaults, uint256 coverageLimitUSD) external;

    /// @notice Returns per-vault stake breakdown for a committee in token-native units.
    /// @dev Called by PolicyManager.bindPolicy for the bind-time sufficiency check (oracle-converted to USD).
    /// @param committeeId The ID of the committee.
    /// @return vaults Array of vault addresses in the committee.
    /// @return tokens Array of underlying collateral token addresses per vault.
    /// @return tokenStakes Array of token-native stake amounts per vault.
    function getCommitteeTokenStakes(uint96 committeeId)
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes);

    /// @notice Returns all vault addresses associated with a committee.
    /// @param committeeId The ID of the committee to check.
    /// @return The array of vault addresses associated with the committee.
    function getCommitteeVaults(uint96 committeeId) external view returns (address[] memory);
}
