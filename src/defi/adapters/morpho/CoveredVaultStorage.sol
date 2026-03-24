// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoveredVaultWrapper} from "../../interfaces/ICoveredVaultWrapper.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {BasePolicyInteractions} from "../../base/BasePolicyInteractions.sol";

/// @title CoveredVaultStorage
/// @notice Constants, storage layout, errors, and struct definitions for CoveredVaultWrapper.
/// @dev All storage variables are declared here in a single file to make the UUPS storage layout
///      trivially auditable. No logic — just state. Inherits from OZ bases in the same order as
///      the original monolithic contract to preserve C3 linearization and slot assignments.
abstract contract CoveredVaultStorage is
    ICoveredVaultWrapper,
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    BasePolicyInteractions,
    UUPSUpgradeable,
    ReentrancyGuardTransient
{
    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator (100% = 10_000)
    // aderyn-fp-next-line(large-numeric-literal) 10_000 is clearer than 1e4 for basis points
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    /// @notice Transient storage slot for pending claim amount.
    ///         Uses ERC-7201-style namespace to prevent collision in future upgrades.
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 internal constant PENDING_CLAIM_AMOUNT_SLOT =
        uint256(keccak256("catalyst.coveredvault.pendingClaimAmount")) - 1;

    /// @notice Transient storage slot for the actual assets transferred in the current withdrawal.
    ///         Written by _withdraw so that overriding redeem()/withdraw() can return the real amount.
    ///         Uses ERC-7201-style namespace to prevent collision in future upgrades.
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 internal constant ACTUAL_OUT_SLOT = uint256(keccak256("catalyst.coveredvault.actualOut")) - 1;

    /// @notice Transient storage slot for the emergency-exit flag.
    ///         Set to 1 by emergencyRedeem/emergencyWithdraw so _computeInsurance returns 0.
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 internal constant SKIP_INSURANCE_SLOT = uint256(keccak256("catalyst.coveredvault.skipInsurance")) - 1;

    /// @notice WAD scaling factor for premium rate
    uint256 internal constant WAD = 1e18;

    /// @notice Maximum allowed premium rate: ~50% per year (WAD-scaled per second)
    /// @dev 50e16 / 365 days = 15_854_895_991 wei/second
    uint256 internal constant MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991;

    /// @notice Delay for UUPS upgrades (full logic replacement — maximum user notice).
    uint256 internal constant UPGRADE_DELAY = 7 days;

    /// @notice Delay for coverage-term changes (maxCoverableLoss, deductible, premiumRecipient).
    uint256 internal constant STANDARD_DELAY = 2 days;

    /// @notice Delay for rate parameters (premiumRate) — short because rate cap
    ///         limits per-hour damage and operational response to Morpho stress needs speed.
    uint256 internal constant OPERATIONAL_DELAY = 2 hours;

    /*//////////////////////////////////////////////////////////////
                         STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Address of the underlying Morpho V2 vault
    address public override morphoVault;

    /// @notice Maximum loss percentage that can be covered (in basis points)
    uint16 public override maxCoverableLossBps;

    /// @notice Deductible percentage applied to every insurance claim (in basis points)
    uint16 public override deductibleBps;

    /// @notice Bound policy ID (0 if not yet bound)
    uint96 public override policyId;

    /// @notice True if the onPolicyBound hook has been executed
    bool public override policyBoundExecuted;

    /// @notice Per-user cost-basis principal
    mapping(address => uint256) public override userPrincipal;

    /// @notice Total cost-basis principal across all users
    uint256 public override totalPrincipal;

    /// @notice Premium rate per second (WAD-scaled)
    uint256 public override premiumRatePerSecond;

    /// @notice Timestamp of the last premium accrual
    uint256 public override lastPremiumAccrualTime;

    /// @notice Address that receives accrued premiums
    address public override premiumRecipient;

    /// @notice Maximum total assets (TVL) that can be deposited
    /// @dev Set to 0 on deployment; updated by onPolicyBound. maxDeposit() returns 0 until set.
    uint256 public override depositCap;

    /// @notice Premium redeemed from Morpho and awaiting transfer to premiumRecipient
    /// @dev Kept separate from depositor assets so that a blocked transfer cannot freeze the vault.
    uint256 public override pendingPremium;

    /// @notice Coverage limit stored from the bound policy
    /// @dev Persisted from onPolicyBound so that setMaxCoverableLossBps can recompute depositCap.
    uint256 public override coverageLimit;

    /// @notice WAD-scaled cumulative premium per unit of principal (reward-per-token accumulator)
    uint256 public override cumulativePremiumPerUnit;

    /// @notice Absolute premium debt per user
    mapping(address => uint256) public override userPremiumDebt;

    /// @notice Total outstanding per-user premium debt
    uint256 public override totalPremiumLiability;

    /// @notice Number of underlying vault shares minted for each user
    mapping(address => uint256) public override userMorphoShares;

    // --- Timelock pending state for insurance parameter changes ---

    /// @notice Pending deductibleBps value awaiting timelock execution
    uint16 public pendingDeductibleBps;
    /// @notice Timestamp after which pendingDeductibleBps may be executed (0 = no pending change)
    uint64 public pendingDeductibleTimestamp;

    /// @notice Pending maxCoverableLossBps value awaiting timelock execution
    uint16 public pendingMaxCoverableLossBps;
    /// @notice Timestamp after which pendingMaxCoverableLossBps may be executed (0 = no pending change)
    uint64 public pendingMaxCoverableLossTimestamp;

    /// @notice Cached Morpho vault value used as fallback when convertToAssets() reverts
    uint256 public override lastKnownMorphoValue;

    /// @notice When true, premium accrual is paused (owner sets during Morpho gate lock)
    bool public override morphoGateActive;

    /// @notice Pending UUPS implementation address awaiting timelock execution
    address public override pendingImplementation;
    /// @notice Timestamp after which pendingImplementation may be executed (0 = no pending upgrade)
    uint64 public override pendingUpgradeTimestamp;

    /// @notice Pending premium rate awaiting timelock execution
    uint256 public override pendingPremiumRate;
    /// @notice Timestamp after which pendingPremiumRate may be executed (0 = no pending change)
    uint64 public override pendingPremiumRateTimestamp;

    /// @notice Pending premium recipient awaiting timelock execution
    address public pendingPremiumRecipient;
    /// @notice Timestamp after which pendingPremiumRecipient may be executed (0 = no pending change)
    uint64 public pendingPremiumRecipientTimestamp;

    /// @notice Timestamp when the Morpho gate was activated (0 = not gated)
    uint256 public gateActivatedAt;
    /// @notice Grace period extension on policy maturity to compensate for gate overlap
    uint256 public gateGracePeriod;

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidPolicyId();
    error NotAuthorized();
    error InvalidData();
    error PolicyBoundAlreadyExecuted();
    /// @notice Thrown when a share transfer between accounts is attempted.
    error TransfersDisabled();
    /// @notice Thrown when renounceOwnership() is called (disabled for safety).
    error RenounceDisabled();
    /// @notice Thrown when executing a parameter change before the timelock delay has elapsed.
    error DelayNotElapsed();
    /// @notice Thrown when executing a parameter change with no pending proposal.
    error NoPendingChange();
    /// @notice Thrown when the Morpho V2 redeem call reverts (e.g. gate active).
    error MorphoRedeemReverted();

    /*//////////////////////////////////////////////////////////////
                            STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Packed withdrawal amounts to avoid stack-too-deep
    struct WithdrawalAmounts {
        uint256 uncappedPremium;
        uint256 totalOwedPremium;
    }
}
