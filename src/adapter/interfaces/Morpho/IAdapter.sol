// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IAdapter
/// @notice Interface for Morpho Vault V2 adapters
/// @dev Adapters connect a parent Vault V2 to external protocols for yield generation.
///      The adapter must:
///      - Enforce that only the parent vault can call allocate/deallocate
///      - Enter/exit markets only in allocate/deallocate
///      - Return the correct ids on allocate/deallocate (no duplicates)
///      - After deallocate, vault must have approval to transfer at least `assets` from adapter
interface IAdapter {
    /// @notice Allocates assets to external protocol
    /// @dev Called by parent vault to deploy assets
    /// @param data Protocol-specific allocation data
    /// @param assets Amount of assets to allocate
    /// @param selector The function selector that triggered this call (msg.sig from vault)
    /// @param sender The original caller (msg.sender from vault)
    /// @return ids Array of market/allocation identifiers affected
    /// @return change The net change in allocation value (can be positive due to accrued interest)
    function allocate(
        bytes memory data,
        uint256 assets,
        bytes4 selector,
        address sender
    )
        external
        returns (bytes32[] memory ids, int256 change);

    /// @notice Deallocates assets from external protocol
    /// @dev Called by parent vault to withdraw assets
    /// @param data Protocol-specific deallocation data
    /// @param assets Amount of assets to deallocate
    /// @param selector The function selector that triggered this call (msg.sig from vault)
    /// @param sender The original caller (msg.sender from vault)
    /// @return ids Array of market/allocation identifiers affected
    /// @return change The net change in allocation value (negative on withdrawal, can include losses)
    function deallocate(
        bytes memory data,
        uint256 assets,
        bytes4 selector,
        address sender
    )
        external
        returns (bytes32[] memory ids, int256 change);

    /// @notice Returns current value of adapter's investments
    /// @dev Used by vault to calculate total assets
    /// @return assets Current value in underlying asset terms
    function realAssets() external view returns (uint256 assets);
}
