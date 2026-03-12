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

    /// @notice Updates the premium recipient. Accrues pending premium at the old address first.
    function setPremiumRecipient(address newRecipient) external;

    /// @notice Returns maximum shares mintable — mirrors maxDeposit() to enforce the deposit cap via mint()
    function maxMint(address receiver) external view returns (uint256);

    /// @notice Called by PolicyManager when the policy is bound; sets policyId and depositCap
    function onPolicyBound(uint96 _policyId, uint256 coverageLimit) external;
}
