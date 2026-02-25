// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { IAdapter } from "./Morpho/IAdapter.sol";

/// @title ICatalysisCoverAdapter
/// @notice Interface for CatalysisCoverAdapter - Vault V2 adapter with NAV-based insurance coverage
/// @dev This adapter:
///      1. Connects Covered Vault (parent) to Underlying Vault (child)
///      2. Tracks per-user principal alongside global aggregate
///      3. Detects per-user NAV loss on deallocate and pays insurance directly to the user
///      4. Premium is collected via management fee on Covered Vault
///      5. realAssets() returns pure currentValue() — insurance is NOT baked into share price
///
///      Architecture:
///      User -> Covered Vault (V2) -> CatalysisCoverAdapter -> Underlying Vault (V2)
///                                           |
///                                           v
///                                    Catalysis CoverPool
interface ICatalysisCoverAdapter is IAdapter {
    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the parent vault (Covered Vault)
    function parentVault() external view returns (address);

    /// @notice Returns the underlying vault where funds are deployed
    function underlyingVault() external view returns (address);

    /// @notice Returns the underlying asset
    function asset() external view returns (address);

    /// @notice Returns the adapter's unique ID for tracking
    function adapterId() external view returns (bytes32);

    /// @notice Returns the deployment timestamp used in adapterId generation
    function deployTimestamp() external view returns (uint256);

    /// @notice Returns the raw idData preimage whose keccak256 equals adapterId
    /// @dev Used by onPolicyBound and external consumers (deploy scripts) to construct
    ///      the preimage needed by the V2 vault's increaseAbsoluteCap/increaseRelativeCap
    function idData() external view returns (bytes memory);

    /// @notice Returns the adapter's IDs array
    function ids() external view returns (bytes32[] memory);

    /// @notice Returns current allocation value
    function allocation() external view returns (uint256);

    /// @notice Returns the total principal tracked (global aggregate)
    function totalPrincipal() external view returns (uint256);

    /// @notice Returns the current value of shares in underlying vault
    function currentValue() external view returns (uint256);

    /// @notice Calculates the global shortfall (if any), capped by maxCoverableLossBps
    /// @return shortfall Amount of NAV loss (0 if no loss)
    function calculateShortfall() external view returns (uint256 shortfall);

    /// @notice Returns the policy ID covering this adapter
    function policyId() external view returns (uint96);

    /// @notice Returns the maximum coverable loss in basis points (e.g., 1000 = 10%)
    function maxCoverableLossBps() external view returns (uint16);

    /// @notice Returns the PolicyManager contract address
    function policyManager() external view returns (address);

    /// @notice Returns whether the onPolicyBound hook has been executed
    function policyBoundExecuted() external view returns (bool);

    /// @notice Returns the principal tracked for a specific user
    /// @param user The user address
    function userPrincipal(
        address user
    ) external view returns (uint256);

    /// @notice Returns the underlying vault shares tracked for a specific user
    /// @param user The user address
    function userUnderlyingShares(
        address user
    ) external view returns (uint256);

    /// @notice Returns the insurance-eligible shortfall for a specific user
    /// @dev Returns the raw shortfall capped by maxCoverableLossBps
    /// @param user The user address
    function userShortfall(
        address user
    ) external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Hook called by PolicyManager when a policy is bound to this adapter.
    /// @dev Only callable by PolicyManager, and only once.
    ///      Validates policy parameters (buyer, times, pool, beneficiary) and stores policyId.
    ///      Calculates and sets the absolute cap on the parent vault based on coverage limit.
    ///      Formula: absoluteCap = (BPS_DENOMINATOR / maxCoverableLossBps) * coverageLimit
    /// @param _policyId The policy ID being bound
    /// @param coverageLimit The coverage limit of the bound policy
    function onPolicyBound(
        uint96 _policyId,
        uint256 coverageLimit
    ) external;
}
