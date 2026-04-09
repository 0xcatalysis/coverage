// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title IEvents
/// @notice Event definitions for CoveredVaultWrapper
interface IEvents {
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

    // --- Timelock parameter-change events ---

    /// @notice Emitted when a deductibleBps change is proposed (standard delay starts)
    event DeductibleBpsProposed(uint16 indexed newBps, uint64 executeAfter);

    /// @notice Emitted when a pending deductibleBps change is executed
    event DeductibleBpsExecuted(uint16 oldBps, uint16 indexed newBps);

    /// @notice Emitted when maxCoverableLossBps is updated (only allowed before policy binding)
    event MaxCoverableLossBpsUpdated(uint16 oldBps, uint16 indexed newBps);

    // --- Liveness and safety events ---

    /// @notice Emitted when claimManager.fileClaim() is unavailable and the claim is skipped
    event ClaimManagerUnavailable(uint96 indexed policyId);

    /// @notice Emitted when the Morpho V2 redeem call fails (gate active or other revert)
    event MorphoRedeemFailed(uint256 redeemShares);

    /// @notice Emitted when a user exits via emergencyRedeem/emergencyWithdraw (no insurance claim filed)
    event EmergencyExit(address indexed owner, address indexed receiver, uint256 shares, uint256 assetsOut);

    /// @notice Emitted when the Morpho gate status is toggled
    event MorphoGateStatusUpdated(bool active);

    /// @notice Emitted when a UUPS upgrade is proposed with a 7-day timelock
    event UpgradeProposed(address indexed implementation, uint64 executeAfter);

    /// @notice Emitted when a pending UUPS upgrade is executed
    event UpgradeExecuted(address indexed implementation);

    /// @notice Emitted when a premium rate change is proposed
    event PremiumRateProposed(uint256 newRate, uint64 executeAfter);

    /// @notice Emitted when a pending premium rate change is executed
    event PremiumRateExecuted(uint256 oldRate, uint256 newRate);

    /// @notice Emitted when tokens are rescued by the owner
    event TokensRescued(address indexed token, address indexed to, uint256 amount);

    /// @notice Emitted when a pending timelocked proposal is superseded by a new proposal
    event ProposalSuperseded(bytes32 indexed paramKey);

    /// @notice Emitted when a pending premium recipient change is proposed (standard delay starts)
    event PremiumRecipientProposed(address indexed newRecipient, uint64 executeAfter);

    /// @notice Emitted when a pending premium recipient change is executed
    event PremiumRecipientExecuted(address indexed oldRecipient, address indexed newRecipient);

    /// @notice Emitted when a depositCap change is proposed (standard delay starts)
    event DepositCapProposed(uint256 newCap, uint64 executeAfter);

    /// @notice Emitted when a pending depositCap change is executed
    event DepositCapExecuted(uint256 oldCap, uint256 newCap);

    /// @notice Emitted when the policy binding is reset to allow a new policy to be bound
    event PolicyBindingReset(uint96 indexed previousPolicyId);
}
