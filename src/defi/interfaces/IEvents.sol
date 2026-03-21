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
    /// @param claimAmount The post-cap, post-deductible amount submitted to the claim manager
    /// @param payout The actual payout received (may be less than claimAmount if coverage is exhausted)
    event InsuranceClaimed(address indexed user, uint96 indexed policyId, uint256 claimAmount, uint256 payout);

    /// @notice Emitted when a policy is bound to a user position
    /// @param user The user address
    /// @param policyId The policy ID bound
    event PolicyBound(address indexed user, uint96 indexed policyId);

    /// @notice Emitted when premium is collected from the vault
    event PremiumCollected(address indexed recipient, uint256 amount);

    /// @notice Emitted when the premium rate is updated by the owner
    event PremiumRateUpdated(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when the premium recipient is updated
    event PremiumRecipientUpdated(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when maxCoverableLossBps is updated by the owner
    event MaxCoverableLossUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when deductibleBps is updated by the owner
    event DeductibleUpdated(uint16 oldBps, uint16 newBps);

    /// @notice Emitted when underlyingExpectedLossBps is updated by the owner
    event UnderlyingExpectedLossUpdated(uint256 oldBps, uint256 newBps);

    // --- Timelock parameter-change events (H-01 remediation) ---

    /// @notice Emitted when a deductibleBps change is proposed (2-day delay starts)
    event DeductibleBpsProposed(uint16 indexed newBps, uint64 executeAfter);

    /// @notice Emitted when a pending deductibleBps change is executed
    event DeductibleBpsExecuted(uint16 indexed newBps);

    /// @notice Emitted when a maxCoverableLossBps change is proposed (2-day delay starts)
    event MaxCoverableLossBpsProposed(uint16 indexed newBps, uint64 executeAfter);

    /// @notice Emitted when a pending maxCoverableLossBps change is executed
    event MaxCoverableLossBpsExecuted(uint16 indexed newBps);

    /// @notice Emitted when an underlyingExpectedLossBps change is proposed (2-day delay starts)
    event UnderlyingExpectedLossBpsProposed(uint256 indexed newBps, uint64 executeAfter);

    /// @notice Emitted when a pending underlyingExpectedLossBps change is executed
    event UnderlyingExpectedLossBpsExecuted(uint256 indexed newBps);

    // --- Liveness and safety events ---

    /// @notice Emitted when claimManager.fileClaim() is unavailable and the claim is skipped
    event ClaimManagerUnavailable(uint96 indexed policyId);

    /// @notice Emitted when the Morpho V2 redeem call fails (gate active or other revert)
    event MorphoRedeemFailed(uint256 redeemShares);

    /// @notice Emitted when policyBoundExecuted is reset to allow a new policy binding
    event PolicyBoundReset(uint96 indexed oldPolicyId);

    /// @notice Emitted when stranded underlying tokens are rescued by the owner
    event UnderlyingRescued(address indexed to, uint256 amount);

    /// @notice Emitted when onPolicyBound() validation fails (diagnostic, precedes revert)
    event PolicyBindingFailed(bytes32 indexed reason);

    /// @notice Emitted when a user exits via emergencyRedeem/emergencyWithdraw (no insurance claim filed)
    event EmergencyExit(address indexed owner, address indexed receiver, uint256 shares, uint256 assetsOut);
}
