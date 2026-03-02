// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IEvents
/// @notice Event definitions for CatalysisBundleAdapter
interface IEvents {
    /// @notice Emitted when NAV is recorded on deposit
    /// @param user The user address
    /// @param assets Amount of assets deposited
    /// @param shares Amount of shares received
    /// @param totalNav User's total NAV after deposit
    event NavRecorded(address indexed user, uint256 assets, uint256 shares, uint256 totalNav);

    /// @notice Emitted when NAV is reduced on withdrawal
    /// @param user The user address
    /// @param assets Amount of assets withdrawn
    /// @param sharesBurned Amount of shares burned
    /// @param insurancePayout Actual insurance paid to user (if any)
    /// @param remainingNav User's remaining NAV after withdrawal
    event NavWithdrawn(
        address indexed user, uint256 assets, uint256 sharesBurned, uint256 insurancePayout, uint256 remainingNav
    );

    /// @notice Emitted when insurance is claimed for a shortfall
    /// @param user The user address
    /// @param policyId The policy ID used
    /// @param shortfall The shortfall amount requested
    /// @param payout The actual payout received
    event InsuranceClaimed(address indexed user, uint96 indexed policyId, uint256 shortfall, uint256 payout);

    /// @notice Emitted when a policy is bound to a user position
    /// @param user The user address
    /// @param policyId The policy ID bound
    event PolicyBound(address indexed user, uint96 indexed policyId);

    /// @notice Emitted when a claim is filed
    /// @param policyId The policy for which claim is filed
    /// @param evidenceHash Hash of the evidence supporting the claim
    event ClaimFiled(uint96 indexed policyId, bytes32 indexed evidenceHash);

    /// @notice Emitted when configuration is updated
    event ConfigUpdated();
}
