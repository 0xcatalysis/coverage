// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

/// @title ICoveredVaultWrapper
/// @notice Interface for the CoveredVaultWrapper — a user-facing ERC-4626 vault that sits on top of a Morpho V2 vault
///         and provides per-user insurance coverage.
interface ICoveredVaultWrapper is IERC4626 {
    /// @notice Returns the underlying Morpho V2 vault address
    function morphoVault() external view returns (address);

    /// @notice Returns the bound policy ID (0 if not yet bound)
    function policyId() external view returns (uint96);

    /// @notice Returns true if the onPolicyBound hook has been executed
    function policyBoundExecuted() external view returns (bool);

    /// @notice Maximum loss percentage that can be covered (in basis points)
    function maxCoverableLossBps() external view returns (uint16);

    /// @notice Deductible percentage applied to every insurance claim (in basis points)
    function deductibleBps() external view returns (uint16);

    /// @notice Returns the cost-basis principal tracked for a specific user
    function userPrincipal(address user) external view returns (uint256);

    /// @notice Returns total cost-basis principal across all users
    function totalPrincipal() external view returns (uint256);

    /// @notice Premium rate per second (WAD-scaled, e.g. 1e16 ≈ 1%/year on 1e18 principal)
    function premiumRatePerSecond() external view returns (uint256);

    /// @notice Timestamp of the last premium accrual
    function lastPremiumAccrualTime() external view returns (uint256);

    /// @notice Address that receives accrued premiums
    function premiumRecipient() external view returns (address);

    /// @notice Premium redeemed from Morpho and awaiting transfer to premiumRecipient via collectPremium()
    function pendingPremium() external view returns (uint256);

    /// @notice WAD-scaled cumulative premium per unit of principal (reward-per-token accumulator).
    ///         Increases by (accruedPremium × WAD / totalPrincipal) on every _accruePremium call.
    function cumulativePremiumPerUnit() external view returns (uint256);

    /// @notice Absolute premium debt — owed = principal × cumPerUnit / WAD − debt.
    function userPremiumDebt(address user) external view returns (uint256);

    /// @notice Total outstanding per-user premium debt not yet collected from withdrawal proceeds.
    function totalPremiumLiability() external view returns (uint256);

    /// @notice Number of underlying Vault shares minted for user's deposits.
    function userMorphoShares(address user) external view returns (uint256);

    /// @notice Coverage limit stored from the bound policy (0 before onPolicyBound is called).
    ///         Used to recalculate depositCap when maxCoverableLossBps changes post-binding.
    function coverageLimit() external view returns (uint256);

    /// @notice Timestamp at which the policy was bound (set to block.timestamp in onPolicyBound).
    ///         Used as the premium accrual start anchor. 0 before onPolicyBound is called.
    function policyStartTime() external view returns (uint256);

    /// @notice Maximum total assets (TVL) that can be deposited into this vault.
    ///         Set to 0 on deployment; updated by onPolicyBound to coverageLimit * BPS_DENOMINATOR /
    /// maxCoverableLossBps.
    function depositCap() external view returns (uint256);

    /// @notice Returns the global insurable shortfall (capped by maxCoverableLossBps and deductible)
    function calculateShortfall() external view returns (uint256);

    /// @notice Returns the per-user insurable shortfall (capped by maxCoverableLossBps and deductible)
    function userShortfall(address user) external view returns (uint256);

    /// @notice Accrues and transfers any pending premium to premiumRecipient
    function collectPremium() external;

    /// @notice Updates the premium rate per second. Accrues pending premium at the old rate first.
    ///         Only callable by the owner. Rate is WAD-scaled (e.g. 1e16 / 31536000 ≈ 0.1%/year).
    function setPremiumRate(uint256 newRate) external;

    /// @notice Updates the maximum coverable loss in basis points.
    ///         Only callable before the policy is bound. Reverts with InvalidMaxCoverableLoss if
    ///         newBps == 0, > 10_000, <= deductibleBps, or the policy is already bound.
    function setMaxCoverableLossBps(uint16 newBps) external;

    /// @notice Updates the deductible in basis points applied to every insurance claim.
    ///         Caller must be the owner. Reverts with InvalidParameters if newBps >= 10_000.
    function setDeductibleBps(uint16 newBps) external;

    /// @notice Applies a pending deductibleBps change after the standard timelock elapses.
    function executeDeductibleBps() external;

    /// @notice Proposes a new premium recipient (standard timelock). Call executePremiumRecipient() to apply.
    function setPremiumRecipient(address newRecipient) external;

    /// @notice Applies a pending premium recipient change after the standard timelock elapses.
    function executePremiumRecipient() external;

    /// @notice Called by PolicyManager when the policy is bound; sets policyId and depositCap
    function onPolicyBound(uint96 _policyId, uint256 _coverageLimit) external;

    /// @notice Cached Morpho vault value used as fallback when convertToAssets() reverts
    function lastKnownMorphoValue() external view returns (uint256);

    /// @notice Whether Morpho gate is active (premium accrual paused)
    function morphoGateActive() external view returns (bool);

    /// @notice Toggles Morpho gate status to pause/resume premium accrual
    function setMorphoGateActive(bool active) external;

    /// @notice Pending UUPS implementation address awaiting timelock
    function pendingImplementation() external view returns (address);

    /// @notice Timestamp after which pending upgrade may be executed
    function pendingUpgradeTimestamp() external view returns (uint64);

    /// @notice Proposes a UUPS upgrade with timelock
    function proposeUpgrade(address newImplementation) external;

    /// @notice Executes a pending UUPS upgrade after timelock
    function executeUpgrade() external;

    /// @notice Pending premium rate awaiting timelock
    function pendingPremiumRate() external view returns (uint256);

    /// @notice Timestamp after which pending premium rate may be executed
    function pendingPremiumRateTimestamp() external view returns (uint64);

    /// @notice Executes a pending premium rate change after timelock
    function executePremiumRate() external;

    /// @notice Proposes a new depositCap (standard timelock). Must not exceed the formula ceiling
    ///         (coverageLimit * BPS_DENOMINATOR / maxCoverableLossBps). Call executeDepositCap() to apply.
    function setDepositCap(uint256 newCap) external;

    /// @notice Applies a pending depositCap change after the standard timelock elapses.
    function executeDepositCap() external;

    /// @notice Rescues tokens accidentally sent to this contract
    function rescueTokens(address token, uint256 amount, address to) external;
}
