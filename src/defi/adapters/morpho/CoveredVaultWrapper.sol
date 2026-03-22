// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoveredVaultWrapper} from "../../interfaces/ICoveredVaultWrapper.sol";
import {IVaultV2} from "../../interfaces/Morpho/IVaultV2.sol";
import {BasePolicyInteractions} from "../../base/BasePolicyInteractions.sol";
import {IAlerts as IA} from "../../interfaces/IAlerts.sol";
import {IEvents as IE} from "../../interfaces/IEvents.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";
import {IPolicyManager} from "coverage/interfaces/IPolicyManager.sol";
import {IClaimManager} from "coverage/interfaces/IClaimManager.sol";
import {IBindPolicyHook} from "coverage/interfaces/IBindPolicyHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title CoveredVaultWrapper
/// @notice User-facing ERC-4626 vault (UUPS proxy) that wraps a Morpho V2 vault and provides per-user insurance.
///
/// @dev Architecture:
///      User → CoveredVaultWrapper (ERC-4626, UUPS)
///               → Morpho V2 vault (fees=0, sole depositor=wrapper)
///                   → MorphoVaultV1Adapter (off-the-shelf)
///                       → Underlying ERC-4626 yield source
///
///      Coverage model:
///      - Tracks per-user principal (cost basis) in userPrincipal[user]
///      - Premium accrues on totalPrincipal (not totalAssets), preventing premium on yield
///      - Insurance is paid directly to the receiver on withdrawal, not via share price
///      - Maximum per-user coverage is capped at maxCoverableLossBps of the user's principal
///      - A configurable deductible (deductibleBps) is applied to every insurance claim
///
///      Share transfer invariant:
///      - Shares are non-transferable (soulbound): only mints and burns are permitted
///      - Any ERC-20 transfer between two non-zero addresses reverts with TransfersDisabled()
contract CoveredVaultWrapper is
    ICoveredVaultWrapper,
    ERC4626Upgradeable,
    Ownable2StepUpgradeable,
    BasePolicyInteractions,
    UUPSUpgradeable,
    ReentrancyGuardTransient,
    IBindPolicyHook
{
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator (100% = 10_000)
    // aderyn-fp-next-line(large-numeric-literal) 10_000 is clearer than 1e4 for basis points
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Transient storage slot for pending claim amount.
    ///         Uses ERC-7201-style namespace to prevent collision in future upgrades.
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 private constant PENDING_CLAIM_AMOUNT_SLOT =
        uint256(keccak256("catalyst.coveredvault.pendingClaimAmount")) - 1;

    /// @notice Transient storage slot for the actual assets transferred in the current withdrawal.
    ///         Written by _withdraw so that overriding redeem()/withdraw() can return the real amount.
    ///         Uses ERC-7201-style namespace to prevent collision in future upgrades.
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 private constant ACTUAL_OUT_SLOT = uint256(keccak256("catalyst.coveredvault.actualOut")) - 1;

    /// @notice Transient storage slot for the emergency-exit flag.
    ///         Set to 1 by emergencyRedeem/emergencyWithdraw so _computeInsurance returns 0.
    ///         Uses ERC-7201-style namespace to prevent collision in future upgrades.
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 private constant SKIP_INSURANCE_SLOT = uint256(keccak256("catalyst.coveredvault.skipInsurance")) - 1;

    /// @notice WAD scaling factor for premium rate
    uint256 private constant WAD = 1e18;

    /// @notice Maximum allowed premium rate: ~50% per year (WAD-scaled per second)
    /// @dev 50e16 / 365 days = 15_854_895_991 wei/second
    uint256 private constant MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991;

    /// @notice Minimum delay between proposing and executing an insurance parameter change.
    uint256 private constant PARAM_CHANGE_DELAY = 2 days;

    /// @notice Maximum allowed underlyingExpectedLossBps cap (20% per year) to prevent retroactive loss inflation.
    uint256 private constant MAX_EXPECTED_LOSS_BPS = 2000;

    /*//////////////////////////////////////////////////////////////
                         STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoveredVaultWrapper
    address public morphoVault;

    /// @inheritdoc ICoveredVaultWrapper
    uint16 public maxCoverableLossBps;

    /// @notice Deductible percentage applied to every insurance claim (in basis points)
    uint16 public deductibleBps;

    /// @inheritdoc ICoveredVaultWrapper
    uint96 public policyId;

    /// @inheritdoc ICoveredVaultWrapper
    bool public policyBoundExecuted;

    /// @inheritdoc ICoveredVaultWrapper
    mapping(address => uint256) public userPrincipal;

    /// @inheritdoc ICoveredVaultWrapper
    uint256 public totalPrincipal;

    /// @inheritdoc ICoveredVaultWrapper
    uint256 public premiumRatePerSecond;

    /// @inheritdoc ICoveredVaultWrapper
    uint256 public lastPremiumAccrualTime;

    /// @inheritdoc ICoveredVaultWrapper
    address public premiumRecipient;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Set to 0 on deployment; updated by onPolicyBound. maxDeposit() returns 0 until set.
    uint256 public depositCap;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Accumulates assets redeemed from Morpho for the premium recipient.
    ///      Kept separate from depositor assets so that a blocked transfer cannot freeze the vault.
    uint256 public pendingPremium;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Persisted from onPolicyBound so that setMaxCoverableLossBps can recompute depositCap
    ///      without a second call to the policy manager.
    uint256 public coverageLimit;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev WAD-scaled cumulative premium per unit of principal (reward-per-token accumulator).
    ///      Increases by (accruedPremium × WAD / totalPrincipal) on every _accruePremium call.
    uint256 public cumulativePremiumPerUnit;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Absolute premium debt — owed = principal × cumPerUnit / WAD − debt.
    ///      Increased on deposit so new assets don't inherit past premium; updated on withdrawal.
    mapping(address => uint256) public userPremiumDebt;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Total outstanding per-user premium liability not yet deducted from withdrawal proceeds.
    ///      Increases on every _accruePremium call; decreases when a user's debt is collected at withdrawal.
    uint256 public totalPremiumLiability;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Annual expected loss rate of the underlying Morpho vault in basis points (e.g. 200 = 2%/year).
    ///      Losses within this rate are considered expected (e.g. management fees) and NOT covered by insurance.
    ///      Set by the owner to match the underlying vault's management fee. Default 0 = fully insured.
    uint256 public underlyingExpectedLossBps;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev WAD-scaled cumulative expected loss per unit of principal. Same reward-per-token pattern as
    ///      cumulativePremiumPerUnit. Increases on every _accruePremium call when underlyingExpectedLossBps > 0.
    uint256 public cumulativeExpectedLossPerUnit;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Absolute expected-loss debt — owed = principal × cumELPerUnit / WAD − debt.
    mapping(address => uint256) public userExpectedLossDebt;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Total outstanding per-user expected-loss liability not yet deducted from withdrawal proceeds.
    ///      Mirrors totalPremiumLiability: increases on every _accruePremium call when underlyingExpectedLossBps > 0;
    ///      decreases when a user's expected-loss debt is settled at withdrawal.
    uint256 public totalExpectedLossLiability;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Total number of underlying vault shares minted for user.
    ///      Per-user Morpho share tracking for preserving each user's exact Morpho
    ///      position while still allowing principal-based premium distribution.
    mapping(address => uint256) public userMorphoShares;

    // --- Timelock pending state for insurance parameter changes ---

    /// @notice Pending deductibleBps value awaiting timelock execution
    uint16 public pendingDeductibleBps;
    /// @notice Timestamp after which pendingDeductibleBps may be executed (0 = no pending change)
    uint64 public pendingDeductibleTimestamp;

    /// @notice Pending maxCoverableLossBps value awaiting timelock execution
    uint16 public pendingMaxCoverableLossBps;
    /// @notice Timestamp after which pendingMaxCoverableLossBps may be executed (0 = no pending change)
    uint64 public pendingMaxCoverableLossTimestamp;

    /// @notice Pending underlyingExpectedLossBps value awaiting timelock execution
    uint256 public pendingExpectedLossBps;
    /// @notice Timestamp after which pendingExpectedLossBps may be executed (0 = no pending change)
    uint64 public pendingExpectedLossTimestamp;

    /// @notice Cached Morpho vault value used as fallback when convertToAssets() reverts
    uint256 public lastKnownMorphoValue;

    /// @notice When true, premium accrual is paused (owner sets during Morpho gate lock)
    bool public morphoGateActive;

    /// @notice Pending UUPS implementation address awaiting timelock execution
    address public pendingImplementation;
    /// @notice Timestamp after which pendingImplementation may be executed (0 = no pending upgrade)
    uint64 public pendingUpgradeTimestamp;

    /// @notice Pending premium rate awaiting timelock execution
    uint256 public pendingPremiumRate;
    /// @notice Timestamp after which pendingPremiumRate may be executed (0 = no pending change)
    uint64 public pendingPremiumRateTimestamp;

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
    /// @notice Thrown when executing a parameter change before the 2-day delay has elapsed.
    error DelayNotElapsed();
    /// @notice Thrown when executing a parameter change with no pending proposal.
    error NoPendingChange();
    /// @notice Thrown when the Morpho V2 redeem call reverts (e.g. gate active).
    error MorphoRedeemReverted();

    /// @dev Packed withdrawal amounts to avoid stack-too-deep
    struct WithdrawalAmounts {
        uint256 uncappedPremium;
        uint256 uncappedExpectedLoss;
        uint256 totalOwedPremium;
        uint256 totalOwedExpectedLoss;
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the CoveredVaultWrapper
    /// @param _morphoVault Address of the underlying Morpho V2 vault
    /// @param _claimManager Address of the ClaimManager contract
    /// @param _coverPool Address of the CoverPool contract
    /// @param _maxCoverableLossBps Maximum loss percentage coverable in basis points (e.g. 1000 = 10%)
    /// @param _deductibleBps Deductible percentage in basis points applied to every claim (e.g. 100 = 1%)
    /// @param _premiumRecipient Address that receives accrued premiums
    /// @param _owner Owner of the wrapper (also the required policy buyer)
    /// @param _name ERC-20 name for the wrapper shares
    /// @param _symbol ERC-20 symbol for the wrapper shares
    function initialize(
        address _morphoVault,
        address _claimManager,
        address _coverPool,
        uint16 _maxCoverableLossBps,
        uint16 _deductibleBps,
        address _premiumRecipient,
        address _owner,
        string memory _name,
        string memory _symbol
    )
        external
        initializer
    {
        require(_morphoVault != address(0), IA.ZeroAddress());
        require(_claimManager != address(0), IA.ZeroAddress());
        require(_premiumRecipient != address(0), IA.ZeroAddress());
        require(_maxCoverableLossBps > 0 && _maxCoverableLossBps <= BPS_DENOMINATOR, IA.InvalidMaxCoverableLoss());
        require(_deductibleBps < BPS_DENOMINATOR, IA.InvalidParameters());

        __ERC4626_init(IERC20(IVaultV2(_morphoVault).asset()));
        __ERC20_init(_name, _symbol);
        __Ownable_init(_owner);
        __BasePolicyInteractions_init(IClaimManager(_claimManager).policyManager(), _claimManager, _coverPool);

        morphoVault = _morphoVault;
        maxCoverableLossBps = _maxCoverableLossBps;
        deductibleBps = _deductibleBps;
        premiumRecipient = _premiumRecipient;
        lastPremiumAccrualTime = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns total assets managed by this wrapper, net of all liabilities.
    /// @dev Deducts totalExpectedLossLiability so new depositors are not disadvantaged.
    function totalAssets() public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 morphoValue = _morphoValue();
        uint256 totalLiability =
            totalPremiumLiability + _accruedPremium() + totalExpectedLossLiability + _accruedExpectedLoss();
        return morphoValue > totalLiability ? morphoValue - totalLiability : 0;
    }

    /// @notice Deposit assets into the wrapper
    /// @dev Full override — does NOT call super._deposit. Deposits into Morpho as address(this).
    ///      Principal is tracked for the receiver (not the caller).
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        // Reject dust deposits that round to zero wrapper shares — prevents principal/shares desync.
        if (shares == 0) revert InvalidData();
        _accruePremium();
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        IERC20(asset()).forceApprove(address(morphoVault), assets);
        // slither-disable-next-line reentrancy-state-change,unused-return
        uint256 morphoSharesReceived = IVaultV2(morphoVault).deposit(assets, address(this));
        require(morphoSharesReceived > 0, IA.ZeroSharesReceived());
        lastKnownMorphoValue = _morphoValue();
        userMorphoShares[receiver] += morphoSharesReceived;
        _mint(receiver, shares); // triggers _update(address(0), receiver, shares) — no principal migration for mints
        // Increase absolute debts so new assets don't inherit past premium/expected-loss
        userPremiumDebt[receiver] += assets.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
        userExpectedLossDebt[receiver] += assets.mulDiv(cumulativeExpectedLossPerUnit, WAD, Math.Rounding.Floor);
        userPrincipal[receiver] += assets;
        totalPrincipal += assets;
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @notice Withdraw assets from the wrapper
    /// @dev Full override — does NOT call super._withdraw. Redeems Morpho shares proportionally.
    /// @dev Computes insurance payout, transfers net assets + payout to receiver, and returns the amounts
    ///      needed for accounting. Extracted from _withdraw to avoid stack-too-deep.
    function _settleWithdrawalTransfer(
        address receiver_,
        uint256 userPrincipalForWithdrawal_,
        uint256 uncappedPremium_,
        uint256 uncappedExpectedLoss_,
        uint256 assetsReceived_,
        address owner_
    )
        private
        returns (uint256 premiumForWithdrawal_, uint256 totalOut_)
    {
        // Cap: can't deduct more premium than what Morpho returned (deep-loss guard)
        premiumForWithdrawal_ = uncappedPremium_ < assetsReceived_ ? uncappedPremium_ : assetsReceived_;

        // insuredBasis = principal reduced by the actually-collected premium AND the expected underlying loss.
        // We use premiumForWithdrawal_ (not uncappedPremium_) because in a deep-loss scenario the uncollected
        // portion of the premium is effectively forgiven — it never reaches pendingPremium — so it should not
        // further reduce the user's insured basis (that would penalise the user twice for the same loss event).
        uint256 totalDeductions = premiumForWithdrawal_ + uncappedExpectedLoss_;
        uint256 insuredBasis =
            userPrincipalForWithdrawal_ > totalDeductions ? userPrincipalForWithdrawal_ - totalDeductions : 0;
        uint256 netAssetsReceived = assetsReceived_ - premiumForWithdrawal_;
        totalOut_ = netAssetsReceived + _computeInsurance(insuredBasis, netAssetsReceived, owner_);
        if (totalOut_ > 0) IERC20(asset()).safeTransfer(receiver_, totalOut_);
    }

    /// @notice Insurance is paid directly to receiver if a loss is detected and policy is active.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,events-maths
    function _withdraw(
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    )
        internal
        override
        nonReentrant
    {
        _accruePremium();

        if (caller != owner) {
            _spendAllowance(owner, caller, shares);
        }

        // Principal attributable to these shares (fraction of owner's position, computed BEFORE burn)
        uint256 ownerBalance = balanceOf(owner);
        uint256 userPrincipalForWithdrawal =
            ownerBalance > 0 ? userPrincipal[owner].mulDiv(shares, ownerBalance, Math.Rounding.Floor) : 0;

        // Redeem Morpho, settle insurance, update debts — extracted to avoid stack-too-deep
        // Returns the actual amount transferred to receiver (net Morpho proceeds + insurance).
        uint256 actualOut = _executeWithdrawal(owner, receiver, shares, userPrincipalForWithdrawal);

        totalPrincipal -= userPrincipalForWithdrawal;

        // Store actual transferred amount so overriding redeem()/withdraw() can return it.
        _setActualOut(actualOut);

        // ERC-4626 spec: assets in Withdraw must equal the amount actually transferred to receiver.
        emit Withdraw(caller, receiver, owner, actualOut, shares);
    }

    /// @notice Redeem shares for the actual assets transferred (net Morpho proceeds + any insurance payout).
    /// @dev Overrides OZ's redeem() whose return value is previewRedeem(shares), which does not account for
    ///      premium deductions or insurance payouts. The correct return value is the amount actually received.
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    )
        public
        override (ERC4626Upgradeable, IERC4626)
        returns (uint256)
    {
        super.redeem(shares, receiver, owner);
        return _getActualOut();
    }

    /// @notice ERC-4626-compliant withdraw override. Returns shares burned.
    /// @dev The base OZ implementation is already correct (returns shares), but this explicit override documents
    ///      the important caveat: the actual assets received by the caller may differ from the `assets` parameter
    ///      because premium deductions reduce proceeds and insurance payouts may increase them.
    ///      Integrators needing exact asset-flow tracking should use redeem() and read _getActualOut() via the
    ///      Withdraw event, or call userShortfall() off-chain before withdrawing.
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    )
        public
        override (ERC4626Upgradeable, IERC4626)
        returns (uint256 shares)
    {
        shares = super.withdraw(assets, receiver, owner);
    }

    /// @notice Emergency exit: redeem shares without filing an insurance claim.
    /// @dev Use when ClaimManager is unavailable or the user chooses to waive coverage for an immediate exit.
    ///      All other accounting (premium deduction, Morpho redemption) proceeds normally.
    ///      The user explicitly acknowledges they will NOT receive any insurance payout.
    ///      NOTE: This function does NOT bypass the Morpho gate — if Morpho blocks redemptions,
    ///      emergencyRedeem will also revert. Only ClaimManager dependency is bypassed.
    ///      nonReentrant is NOT added here because super.redeem() → _withdraw() already has it;
    ///      adding it would cause a double-lock revert (ReentrancyGuardTransient).
    // slither-disable-next-line reentrancy-events
    function emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256) {
        _setSkipInsurance(true);
        super.redeem(shares, receiver, owner);
        _setSkipInsurance(false);
        uint256 totalOut = _getActualOut();
        emit IE.EmergencyExit(owner, receiver, shares, totalOut);
        return totalOut;
    }

    /// @notice Emergency exit: withdraw assets without filing an insurance claim.
    /// @dev Use when ClaimManager is unavailable or the user chooses to waive coverage for an immediate exit.
    ///      All other accounting (premium deduction, Morpho redemption) proceeds normally.
    ///      The user explicitly acknowledges they will NOT receive any insurance payout.
    ///      NOTE: Does NOT bypass Morpho gate — see emergencyRedeem NatSpec.
    ///      nonReentrant transitively applied via inner _withdraw().
    // slither-disable-next-line reentrancy-events
    function emergencyWithdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        _setSkipInsurance(true);
        shares = super.withdraw(assets, receiver, owner);
        _setSkipInsurance(false);
        emit IE.EmergencyExit(owner, receiver, shares, _getActualOut());
    }

    /// @dev Computes owed premium and expected loss from the absolute-debt formula.
    function _computeOwedAmounts(
        address owner_,
        uint256 shares_
    )
        private
        view
        returns (WithdrawalAmounts memory amounts)
    {
        uint256 ownerBalance = balanceOf(owner_);
        uint256 principal = userPrincipal[owner_];

        amounts.totalOwedPremium = principal.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
        amounts.totalOwedPremium =
            amounts.totalOwedPremium > userPremiumDebt[owner_] ? amounts.totalOwedPremium - userPremiumDebt[owner_] : 0;
        // The else branch (ownerBalance == 0) is unreachable: _executeWithdrawal's
        // mulDiv(shares_, balanceOf(owner_)) would revert with a division-by-zero panic before this path
        // produces a usable result for a non-zero withdrawal.
        amounts.uncappedPremium = ownerBalance > 0
            ? amounts.totalOwedPremium.mulDiv(shares_, ownerBalance, Math.Rounding.Floor)
            : amounts.totalOwedPremium;

        amounts.totalOwedExpectedLoss = principal.mulDiv(cumulativeExpectedLossPerUnit, WAD, Math.Rounding.Floor);
        amounts.totalOwedExpectedLoss = amounts.totalOwedExpectedLoss > userExpectedLossDebt[owner_]
            ? amounts.totalOwedExpectedLoss - userExpectedLossDebt[owner_]
            : 0;
        amounts.uncappedExpectedLoss = ownerBalance > 0
            ? amounts.totalOwedExpectedLoss.mulDiv(shares_, ownerBalance, Math.Rounding.Floor)
            : amounts.totalOwedExpectedLoss;
    }

    /// @dev Morpho redeem, insurance settlement, premium accounting, and debt updates.
    ///      Extracted from _withdraw to avoid stack-too-deep.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function _executeWithdrawal(
        address owner_,
        address receiver_,
        uint256 shares_,
        uint256 userPrincipalForWithdrawal_
    )
        private
        returns (uint256 totalOut_)
    {
        WithdrawalAmounts memory a = _computeOwedAmounts(owner_, shares_);

        // Gross Morpho entitlement (MUST be computed before burn)
        uint256 ownerBalance = balanceOf(owner_);
        uint256 redeemShares = userMorphoShares[owner_].mulDiv(shares_, ownerBalance, Math.Rounding.Floor);

        // At final withdrawal cap redeemShares to actual wrapper balance to handle rounding dust
        // accumulated over many partial withdrawals (sum(userMorphoShares) may exceed actual balance by N dust).
        // slither-disable-next-line incorrect-equality
        if (shares_ == ownerBalance) {
            uint256 actualMorphoBalance = IVaultV2(morphoVault).balanceOf(address(this));
            if (redeemShares > actualMorphoBalance) redeemShares = actualMorphoBalance;
        }

        userMorphoShares[owner_] -= redeemShares;
        _burn(owner_, shares_);

        // Update debts BEFORE filing claim so that userPrincipal is consistent with balanceOf(owner_) == 0
        // during the evaluate() callback triggered inside _settleWithdrawalTransfer → _claimInsurance.
        _updateDebtsAfterWithdrawal(
            owner_,
            userPrincipal[owner_],
            userPrincipalForWithdrawal_,
            a.totalOwedPremium,
            a.uncappedPremium,
            a.totalOwedExpectedLoss,
            a.uncappedExpectedLoss
        );

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        uint256 assetsReceived = 0;
        if (redeemShares > 0) {
            // Wrap Morpho redeem in try/catch; emit diagnostic event then re-revert.
            // There is no alternative asset path (wrapper holds only Morpho shares), so withdrawal
            // cannot succeed if Morpho is gated. A clear revert is preferable to a silent 0.
            // slither-disable-next-line reentrancy-state-change
            try IVaultV2(morphoVault).redeem(redeemShares, address(this), address(this)) returns (uint256 received) {
                assetsReceived = received;
                // Update cached Morpho value after successful redeem
                lastKnownMorphoValue = _morphoValue();
            } catch {
                emit IE.MorphoRedeemFailed(redeemShares);
                revert MorphoRedeemReverted();
            }
        }

        uint256 premiumForWithdrawal;
        (premiumForWithdrawal, totalOut_) = _settleWithdrawalTransfer(
            receiver_, userPrincipalForWithdrawal_, a.uncappedPremium, a.uncappedExpectedLoss, assetsReceived, owner_
        );

        pendingPremium += premiumForWithdrawal;
        // Decrement totalPremiumLiability by premiumForWithdrawal (actually collected) rather than
        // a.uncappedPremium (intended amount). In deep-loss scenarios where assetsReceived < uncappedPremium,
        // the forgiven delta was never collected into pendingPremium and should not reduce the liability tracker,
        // otherwise totalAssets() is inflated for remaining holders by the forgiven amount.
        totalPremiumLiability =
            totalPremiumLiability > premiumForWithdrawal ? totalPremiumLiability - premiumForWithdrawal : 0;
        // Cap EL decrement at actually-realized amount (same logic as premium path above).
        // In deep-loss scenarios, decrementing by the full uncappedExpectedLoss when Morpho returned less
        // would overstate totalAssets() for remaining holders.
        uint256 remainingAfterPremium =
            assetsReceived > premiumForWithdrawal ? assetsReceived - premiumForWithdrawal : 0;
        uint256 expectedLossForWithdrawal =
            a.uncappedExpectedLoss < remainingAfterPremium ? a.uncappedExpectedLoss : remainingAfterPremium;
        totalExpectedLossLiability = totalExpectedLossLiability > expectedLossForWithdrawal
            ? totalExpectedLossLiability - expectedLossForWithdrawal
            : 0;
    }

    /// @notice Blocks ERC-20 share transfers between accounts.
    /// @dev Shares represent an insured position. Allowing transfers would let a user
    ///      move an underwater cost basis to another account, inflating their insurance cap.
    ///      Only mints (from == address(0)) and burns (to == address(0)) are permitted;
    ///      those paths are handled explicitly in _deposit and _withdraw.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            revert TransfersDisabled();
        }
        super._update(from, to, value);
    }

    /*//////////////////////////////////////////////////////////////
                    PREMIUM FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the number of seconds that should count toward accrual starting from `checkpoint`.
    ///      - Policy active: full [checkpoint, now] window.
    ///      - Policy expired, checkpoint < maturityTime: only [max(checkpoint, startTime), maturityTime].
    ///      - No policy or window already settled: 0.
    ///      Single source of truth for the active-window calculation used by _accruedExpectedLoss,
    ///      _accruedPremium, _accruePremium, and _userTotalExpectedLoss.
    function _activeElapsedFrom(uint256 checkpoint) private view returns (uint256) {
        if (_isPolicyActive()) {
            return block.timestamp - checkpoint;
        }
        if (policyId != 0) {
            IPolicyManager.PolicyMetadata memory meta = _policyManager.policyMetadata(policyId);
            if (meta.buyer != address(0) && uint256(meta.maturityTime) > checkpoint) {
                uint256 activeStart = checkpoint > uint256(meta.startTime) ? checkpoint : uint256(meta.startTime);
                if (uint256(meta.maturityTime) > activeStart) {
                    return uint256(meta.maturityTime) - activeStart;
                }
            }
        }
        return 0;
    }

    /// @notice Returns pending (uncheckpointed) expected-loss accrual for the current elapsed window.
    /// @dev Uses the same active-window logic as _accruedPremium() so totalAssets() remains consistent
    ///      with calculateShortfall() and does not overstate NAV between accrual checkpoints.
    // slither-disable-next-line incorrect-equality
    function _accruedExpectedLoss() internal view returns (uint256) {
        if (underlyingExpectedLossBps == 0 || totalPrincipal == 0) return 0;
        uint256 elapsed = _activeElapsedFrom(lastPremiumAccrualTime);
        if (elapsed == 0) return 0;
        return totalPrincipal.mulDiv(
            underlyingExpectedLossBps * elapsed, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
        );
    }

    /// @notice Returns accrued-but-unprocessed premium owed to premiumRecipient
    /// @dev Computes the active elapsed window:
    ///      - If policy is currently active: full [lastCheckpoint, now] window.
    ///      - If policy just expired and lastCheckpoint < maturityTime: only [lastCheckpoint, maturityTime].
    ///      - Otherwise: 0 (no phantom premium after expiry is fully settled).
    // slither-disable-next-line incorrect-equality
    function _accruedPremium() internal view returns (uint256) {
        if (totalPrincipal == 0 || premiumRatePerSecond == 0) return 0;
        uint256 elapsed = _activeElapsedFrom(lastPremiumAccrualTime);
        if (elapsed == 0) return 0;
        uint256 accrued = totalPrincipal.mulDiv(premiumRatePerSecond * elapsed, WAD, Math.Rounding.Floor);
        if (accrued == 0) return 0;
        // Apply the same Morpho-value cap as _accruePremium() so that callers (totalAssets, calculateShortfall,
        // userShortfall) never see a larger pending premium than what would actually be settled.
        uint256 morphoValue = _morphoValue();
        uint256 maxNewLiability = morphoValue > totalPremiumLiability ? morphoValue - totalPremiumLiability : 0;
        return accrued < maxNewLiability ? accrued : maxNewLiability;
    }

    /// @notice Records accrued premium as a liability in the per-user debt accumulator, and advances the
    ///         expected loss accumulator for the elapsed period.
    ///         No Morpho shares are redeemed here — premium is deducted from user proceeds at withdrawal.
    ///         Keeping transfers out of this function ensures a blacklisted recipient cannot freeze the vault.
    // slither-disable-next-line incorrect-equality
    function _accruePremium() internal {
        uint256 checkpointTime = lastPremiumAccrualTime;

        // Always advance the timestamp unconditionally so that when a new policy is later bound,
        // there is no catch-up accrual for the inactive gap period.
        lastPremiumAccrualTime = block.timestamp;

        if (block.timestamp == checkpointTime) return;

        // Skip all accrual when Morpho gate is active (owner-toggled).
        // Timestamp is still advanced above to prevent catch-up accrual when gate is lifted.
        if (morphoGateActive) return;

        // Compute the active portion of the elapsed window via the shared helper.
        uint256 activeElapsed = _activeElapsedFrom(checkpointTime);

        if (activeElapsed == 0) return;

        // Fetch Morpho value once for both premium and EL caps.
        uint256 morphoValue = _morphoValueAndCache();

        // Advance expected loss accumulator for the active elapsed period.
        if (underlyingExpectedLossBps > 0 && totalPrincipal > 0) {
            cumulativeExpectedLossPerUnit += underlyingExpectedLossBps.mulDiv(
                activeElapsed * WAD, BPS_DENOMINATOR * 365 days
            );
            uint256 elIncrement = totalPrincipal.mulDiv(
                underlyingExpectedLossBps * activeElapsed, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
            );
            // Cap totalExpectedLossLiability against morphoValue headroom
            uint256 currentLiabilities = totalPremiumLiability + totalExpectedLossLiability;
            uint256 elHeadroom = morphoValue > currentLiabilities ? morphoValue - currentLiabilities : 0;
            if (elIncrement > elHeadroom) elIncrement = elHeadroom;
            totalExpectedLossLiability += elIncrement;
        }

        // Compute accrued premium using the active elapsed window.
        uint256 accrued = totalPrincipal > 0
            ? totalPrincipal.mulDiv(premiumRatePerSecond * activeElapsed, WAD, Math.Rounding.Floor)
            : 0;

        if (accrued == 0) {
            return;
        }

        // Cap: totalPremiumLiability + accrued must not exceed current Morpho value
        uint256 maxNewLiability = morphoValue > totalPremiumLiability ? morphoValue - totalPremiumLiability : 0;
        if (accrued > maxNewLiability) accrued = maxNewLiability;
        if (accrued == 0) return;
        if (totalPrincipal > 0) {
            cumulativePremiumPerUnit += accrued.mulDiv(WAD, totalPrincipal);
        }
        totalPremiumLiability += accrued;
    }

    /// @inheritdoc ICoveredVaultWrapper
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    function collectPremium() external nonReentrant {
        _accruePremium();
        uint256 pending = pendingPremium;
        if (pending > 0) {
            pendingPremium = 0;
            IERC20(asset()).safeTransfer(premiumRecipient, pending);
            emit IE.PremiumCollected(premiumRecipient, pending);
        }
    }

    /// @inheritdoc ICoveredVaultWrapper
    // slither-disable-next-line reentrancy-no-eth,reentrancy-events
    /// @notice Proposes a new premium rate. Call executePremiumRate() after the delay to apply.
    function setPremiumRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_PREMIUM_RATE_PER_SECOND, IA.InvalidParameters());
        uint64 executeAfter = uint64(block.timestamp + PARAM_CHANGE_DELAY);
        pendingPremiumRate = newRate;
        pendingPremiumRateTimestamp = executeAfter;
        emit IE.PremiumRateProposed(newRate, executeAfter);
    }

    /// @notice Applies a pending premium rate change after the 2-day timelock elapses.
    function executePremiumRate() external onlyOwner {
        _requireTimelockReady(pendingPremiumRateTimestamp);
        // Settle any premium accrued at the old rate before switching.
        _accruePremium();
        lastPremiumAccrualTime = block.timestamp;
        uint256 oldRate = premiumRatePerSecond;
        premiumRatePerSecond = pendingPremiumRate;
        pendingPremiumRateTimestamp = 0;
        emit IE.PremiumRateExecuted(pendingPremiumRate);
        emit IE.PremiumRateUpdated(oldRate, pendingPremiumRate);
    }

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Call executeMaxCoverableLossBps() after the delay to apply the pending value.
    function setMaxCoverableLossBps(uint16 newBps) external onlyOwner {
        require(newBps > 0 && newBps <= BPS_DENOMINATOR, IA.InvalidMaxCoverableLoss());
        uint64 executeAfter = uint64(block.timestamp + PARAM_CHANGE_DELAY);
        pendingMaxCoverableLossBps = newBps;
        pendingMaxCoverableLossTimestamp = executeAfter;
        emit IE.MaxCoverableLossBpsProposed(newBps, executeAfter);
    }

    /// @notice Applies a pending maxCoverableLossBps change after the 2-day timelock elapses.
    function executeMaxCoverableLossBps() external onlyOwner {
        _requireTimelockReady(pendingMaxCoverableLossTimestamp);
        uint16 newBps = pendingMaxCoverableLossBps;
        uint16 oldBps = maxCoverableLossBps;
        if (policyBoundExecuted) {
            depositCap = (coverageLimit * BPS_DENOMINATOR) / uint256(newBps);
        }
        maxCoverableLossBps = newBps;
        pendingMaxCoverableLossTimestamp = 0;
        emit IE.MaxCoverableLossBpsExecuted(newBps);
        emit IE.MaxCoverableLossUpdated(oldBps, newBps);
    }

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Call executeUnderlyingExpectedLossBps() after the delay to apply the pending value.
    function setUnderlyingExpectedLossBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_EXPECTED_LOSS_BPS, IA.InvalidParameters());
        uint64 executeAfter = uint64(block.timestamp + PARAM_CHANGE_DELAY);
        pendingExpectedLossBps = newBps;
        pendingExpectedLossTimestamp = executeAfter;
        emit IE.UnderlyingExpectedLossBpsProposed(newBps, executeAfter);
    }

    /// @notice Applies a pending underlyingExpectedLossBps change after the 2-day timelock elapses.
    function executeUnderlyingExpectedLossBps() external onlyOwner {
        _requireTimelockReady(pendingExpectedLossTimestamp);
        // Settle accrual at the old rate before switching, same as setPremiumRate.
        _accruePremium();
        lastPremiumAccrualTime = block.timestamp;
        uint256 oldBps = underlyingExpectedLossBps;
        underlyingExpectedLossBps = pendingExpectedLossBps;
        pendingExpectedLossTimestamp = 0;
        emit IE.UnderlyingExpectedLossBpsExecuted(underlyingExpectedLossBps);
        emit IE.UnderlyingExpectedLossUpdated(oldBps, underlyingExpectedLossBps);
    }

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Call executeDeductibleBps() after the delay to apply the pending value.
    function setDeductibleBps(uint16 newBps) external onlyOwner {
        require(newBps < BPS_DENOMINATOR, IA.InvalidParameters());
        uint64 executeAfter = uint64(block.timestamp + PARAM_CHANGE_DELAY);
        pendingDeductibleBps = newBps;
        pendingDeductibleTimestamp = executeAfter;
        emit IE.DeductibleBpsProposed(newBps, executeAfter);
    }

    /// @notice Applies a pending deductibleBps change after the 2-day timelock elapses.
    function executeDeductibleBps() external onlyOwner {
        _requireTimelockReady(pendingDeductibleTimestamp);
        uint16 oldBps = deductibleBps;
        deductibleBps = pendingDeductibleBps;
        pendingDeductibleTimestamp = 0;
        emit IE.DeductibleBpsExecuted(deductibleBps);
        emit IE.DeductibleUpdated(oldBps, deductibleBps);
    }

    /// @inheritdoc ICoveredVaultWrapper
    function setPremiumRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), IA.ZeroAddress());
        address oldRecipient = premiumRecipient;
        premiumRecipient = newRecipient;
        emit IE.PremiumRecipientUpdated(oldRecipient, newRecipient);
    }

    /*//////////////////////////////////////////////////////////////
                    POLICY HOOK
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IBindPolicyHook
    // slither-disable-next-line reentrancy-events
    function onPolicyBound(
        uint96 _policyId,
        uint256 _coverageLimit
    )
        external
        override (IBindPolicyHook, ICoveredVaultWrapper)
    {
        if (_policyId == 0) revert InvalidPolicyId();
        if (msg.sender != address(_policyManager)) revert NotAuthorized();
        if (policyBoundExecuted) revert PolicyBoundAlreadyExecuted();

        // Validate that the policy parameters are consistent with this wrapper.
        // Emit a diagnostic event before each revert to enable on-chain debugging.
        // aderyn-fp-next-line(reentrancy-state-change) Only callable by trusted PolicyManager, executed once
        IPolicyManager.PolicyMetadata memory pol = _policyManager.policyMetadata(_policyId);
        // aderyn-fp-next-line(reentrancy-state-change) Only callable by trusted PolicyManager, executed once
        _validatePolicyBinding(pol);

        policyId = _policyId;
        policyBoundExecuted = true;
        coverageLimit = _coverageLimit;

        // depositCap = total TVL cap implied by the coverage limit
        // If maxCoverableLossBps=10% (1000) and coverageLimit=100, cap = 100 * 10000/1000 = 1000
        depositCap = (_coverageLimit * BPS_DENOMINATOR) / uint256(maxCoverableLossBps);

        emit IE.PolicyBound(address(this), _policyId);
    }

    /*//////////////////////////////////////////////////////////////
                    INSURANCE INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes insurance payout given insuredBasis and net assets, then claims if eligible.
    ///         Extracted to avoid stack-too-deep in _withdraw.
    ///         Returns 0 when the SKIP_INSURANCE_SLOT transient flag is set (emergency exit path).
    function _computeInsurance(
        uint256 insuredBasis,
        uint256 netAssetsReceived,
        address owner
    )
        internal
        returns (uint256 insurancePayout)
    {
        // Emergency exit: user explicitly waives insurance coverage.
        uint256 skipSlot = SKIP_INSURANCE_SLOT;
        uint256 skipFlag;
        assembly {
            skipFlag := tload(skipSlot)
        }
        if (skipFlag != 0) return 0;

        if (insuredBasis > netAssetsReceived && _isPolicyActive()) {
            uint256 shortfall = insuredBasis - netAssetsReceived;
            uint256 maxInsurance = insuredBasis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
            uint256 capped = shortfall < maxInsurance ? shortfall : maxInsurance;
            uint256 claimAmount = capped.mulDiv(BPS_DENOMINATOR - deductibleBps, BPS_DENOMINATOR);
            if (claimAmount > 0) {
                insurancePayout = _claimInsurance(claimAmount, owner);
            }
        }
    }

    /// @notice Claims insurance for a capped, post-deductible amount
    /// @param claimAmount The amount to claim (post-cap and post-deductible, further capped by remaining coverage)
    /// @param user Address of the user who suffered the loss (used for event emission)
    /// @return payout The actual insurance payout received
    // slither-disable-next-line reentrancy-events,incorrect-equality
    function _claimInsurance(uint256 claimAmount, address user) internal returns (uint256 payout) {
        // Use local state instead of _getCoverageParams() external call.
        // coverageLimit is stored in state (set by onPolicyBound), payoutToken is the vault asset.
        uint256 policyCoverageLimit = coverageLimit;
        address payoutToken = asset();

        uint256 paidOut = _getPaidCover(policyId);
        uint256 remainingCoverage = policyCoverageLimit > paidOut ? policyCoverageLimit - paidOut : 0;

        uint256 cappedClaim = claimAmount > remainingCoverage ? remainingCoverage : claimAmount;
        if (cappedClaim == 0) return 0;

        uint256 balanceBefore = IERC20(payoutToken).balanceOf(address(this));

        _setPendingClaim(cappedClaim);

        // aderyn-fp-next-line(weak-randomness) evidenceHash is for claim identification, not security-critical
        bytes32 evidenceHash = keccak256(abi.encodePacked(user, policyId, cappedClaim, block.timestamp));
        bytes memory additionalData = abi.encode(address(this), cappedClaim);

        // Wrap fileClaim in try/catch so ClaimManager pause doesn't block withdrawals.
        // On failure, emit ClaimManagerUnavailable event and return 0 payout.
        // aderyn-fp-next-line(unchecked-return) ClaimId not needed — success determined via balance change
        // slither-disable-next-line unused-return
        try claimManager.fileClaim(policyId, cappedClaim, evidenceHash, additionalData) {
        // success — fall through to balance check below
        }
        catch {
            _clearPendingClaim();
            emit IE.ClaimManagerUnavailable(policyId);
            return 0;
        }

        _clearPendingClaim();

        uint256 balanceAfter = IERC20(payoutToken).balanceOf(address(this));
        payout = balanceAfter - balanceBefore;

        emit IE.InsuranceClaimed(user, policyId, claimAmount, payout);
    }

    /// @inheritdoc ISpec
    /// @dev Restricted to claimManager to prevent information leakage via staticcall.
    function evaluate(ISpec.EvaluationContext calldata context)
        external
        view
        override
        returns (ISpec.EvaluationResult memory result)
    {
        require(msg.sender == address(claimManager), NotAuthorized());
        (uint256 pendingClaimAmount, bool hasPendingClaim) = _getPendingClaim();
        (address claimant, uint256 claimedAmount) = abi.decode(context.additionalData, (address, uint256));

        if (!hasPendingClaim || policyId != context.policyId) {
            return ISpec.EvaluationResult({
                isPayable: false, notesHash: keccak256(abi.encodePacked("No pending claim from wrapper"))
            });
        }

        bool isValid = pendingClaimAmount == claimedAmount && claimant == address(this);
        result = ISpec.EvaluationResult({
            isPayable: isValid,
            notesHash: keccak256(
                abi.encodePacked(claimant, claimedAmount, isValid ? "Shortfall validated" : "Invalid claim")
            )
        });
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoveredVaultWrapper
    // slither-disable-next-line incorrect-equality
    function calculateShortfall() external view override returns (uint256) {
        if (totalPrincipal == 0) return 0;
        uint256 morphoValue = _morphoValue();
        uint256 accrued = _accruedPremium();
        // netValue = totalAssets(): morphoValue minus all premium liability (settled + pending).
        // Since no Morpho shares are redeemed during accrual, morphoValue includes settled premium;
        // subtracting only accrued would leave totalPremiumLiability in netValue and underreport shortfall.
        uint256 totalPremiumTotal = totalPremiumLiability + accrued;
        uint256 netValue = morphoValue > totalPremiumTotal ? morphoValue - totalPremiumTotal : 0;
        // Also deduct global expected loss (management fee drag) so it is not counted as insurable shortfall.
        // Use the global tracker (mirrors totalPremiumLiability) to correctly account for per-user debts —
        // totalPrincipal * cumulativeExpectedLossPerUnit / WAD would overcount by ignoring userExpectedLossDebt
        // for users who deposited after the accumulator had already increased.
        uint256 totalExpectedLoss = totalExpectedLossLiability + _accruedExpectedLoss();
        uint256 totalDeductions = totalPremiumTotal + totalExpectedLoss;
        uint256 adjustedPrincipal = totalPrincipal > totalDeductions ? totalPrincipal - totalDeductions : 0;
        if (adjustedPrincipal > netValue) {
            uint256 rawShortfall = adjustedPrincipal - netValue;
            // Cap on adjustedPrincipal so premium-period losses don't inflate the coverable amount
            uint256 maxCoverable = adjustedPrincipal.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
            uint256 capped = rawShortfall > maxCoverable ? maxCoverable : rawShortfall;
            return capped.mulDiv(BPS_DENOMINATOR - deductibleBps, BPS_DENOMINATOR);
        }
        return 0;
    }

    /// @dev Returns the total pending expected loss (accrued + uncheckpointed period) for a user.
    ///      Extracted to reduce stack depth in userShortfall.
    ///      Uses the same active-window logic as _accruedExpectedLoss() so that expected loss does
    ///      not accumulate beyond policy maturity, keeping userShortfall() consistent with totalAssets().
    function _userTotalExpectedLoss(address user) private view returns (uint256) {
        uint256 rawOwed = userPrincipal[user].mulDiv(cumulativeExpectedLossPerUnit, WAD, Math.Rounding.Floor);
        uint256 total = rawOwed > userExpectedLossDebt[user] ? rawOwed - userExpectedLossDebt[user] : 0;
        // Cap elapsed to the policy active window via the shared helper so that expected loss
        // stops accruing at maturity, consistent with _accruedExpectedLoss() and totalAssets().
        uint256 pendingElapsedSecs = _activeElapsedFrom(lastPremiumAccrualTime);
        if (underlyingExpectedLossBps > 0 && pendingElapsedSecs > 0) {
            total += userPrincipal[user].mulDiv(
                underlyingExpectedLossBps * pendingElapsedSecs, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
            );
        }
        return total;
    }

    /// @inheritdoc ICoveredVaultWrapper
    // slither-disable-next-line incorrect-equality
    function userShortfall(address user) external view override returns (uint256) {
        if (balanceOf(user) == 0) return 0;
        uint256 accrued = _accruedPremium();

        // Per-user premium: absolute-debt formula + pending global accrual share
        uint256 rawPremium = userPrincipal[user].mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
        uint256 totalUserPremium = (rawPremium > userPremiumDebt[user] ? rawPremium - userPremiumDebt[user] : 0)
            + (totalPrincipal > 0 ? userPrincipal[user].mulDiv(accrued, totalPrincipal, Math.Rounding.Floor) : 0);

        // Total deductions = premium + expected underlying loss (management fee drag)
        uint256 totalUserDeductions = totalUserPremium + _userTotalExpectedLoss(user);

        // User's gross Morpho value from their tracked Morpho shares — mirrors _executeWithdrawal exactly.
        // Using wrapper-share ratio (morphoTotal * userShares / totalShares) diverges when users entered at
        // different Morpho share prices, so we use the per-user Morpho share record instead.
        uint256 userMorphoGross = _userMorphoValue(user);
        // Net Morpho value subtracts only premium (premium is owed to recipient, not insurable)
        uint256 userMorphoNet = userMorphoGross > totalUserPremium ? userMorphoGross - totalUserPremium : 0;

        uint256 adjustedUserPrincipal =
            userPrincipal[user] > totalUserDeductions ? userPrincipal[user] - totalUserDeductions : 0;

        if (adjustedUserPrincipal > userMorphoNet) {
            uint256 raw = adjustedUserPrincipal - userMorphoNet;
            // EF-4: Cap on adjustedUserPrincipal so premium-period losses don't inflate the coverable amount
            uint256 maxCoverable = adjustedUserPrincipal.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
            uint256 capped = raw > maxCoverable ? maxCoverable : raw;
            return capped.mulDiv(BPS_DENOMINATOR - deductibleBps, BPS_DENOMINATOR);
        }
        return 0;
    }

    /// @notice Returns maximum withdrawable assets accounting for premium deductions
    function maxWithdraw(address owner) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 shares = balanceOf(owner);
        if (shares == 0) return 0;
        uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
        // Estimate user's owed premium
        uint256 rawPremium = userPrincipal[owner].mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
        uint256 owedPremium = rawPremium > userPremiumDebt[owner] ? rawPremium - userPremiumDebt[owner] : 0;
        return grossAssets > owedPremium ? grossAssets - owedPremium : 0;
    }

    /// @notice Returns maximum redeemable shares (all shares are redeemable)
    function maxRedeem(address owner) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        return balanceOf(owner);
    }

    /// @notice Decimal offset for inflation attack protection
    /// @dev Inserts 10^6 virtual shares; an attacker must donate >10^6× the victim's deposit to profit from rounding
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Deposits are blocked until the policy is bound (depositCap is set by onPolicyBound)
    function maxDeposit(address) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (!policyBoundExecuted) return 0;
        return depositCap > totalPrincipal ? depositCap - totalPrincipal : 0;
    }

    /// @notice Returns maximum shares mintable — mirrors maxDeposit() to enforce the deposit cap via mint()
    function maxMint(address receiver)
        public
        view
        override (ERC4626Upgradeable, ICoveredVaultWrapper)
        returns (uint256)
    {
        return previewDeposit(maxDeposit(receiver));
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the total Morpho vault value, falling back to cached value on revert
    function _morphoValue() private view returns (uint256) {
        try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (
            uint256 val
        ) {
            return val;
        } catch {
            return lastKnownMorphoValue;
        }
    }

    /// @notice Returns Morpho value and caches it for future fallback (non-view)
    function _morphoValueAndCache() private returns (uint256 val) {
        val = _morphoValue();
        lastKnownMorphoValue = val;
    }

    /// @notice Returns a user's Morpho value, falling back to proportional cached value on revert
    // slither-disable-next-line incorrect-equality
    function _userMorphoValue(address user) private view returns (uint256) {
        uint256 shares = userMorphoShares[user];
        if (shares == 0) return 0;
        try IVaultV2(morphoVault).convertToAssets(shares) returns (uint256 val) {
            return val;
        } catch {
            // Pro-rata fallback from cached global value
            try IVaultV2(morphoVault).balanceOf(address(this)) returns (uint256 totalShares) {
                return totalShares > 0 ? lastKnownMorphoValue * shares / totalShares : 0;
            } catch {
                return 0;
            }
        }
    }

    /// @notice Checks if the policy is currently active (bound and within coverage window)
    /// @dev Uses strict `<` for maturityTime (exclusive end boundary). If PolicyManager treats
    ///      maturityTime as inclusive, change `<` back to `<=` to match the intended semantics.
    // slither-disable-next-line incorrect-equality
    function _isPolicyActive() internal view returns (bool) {
        if (policyId == 0) return false;
        IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
        return metadata.buyer != address(0) && block.timestamp >= metadata.startTime
            && block.timestamp < metadata.maturityTime;
    }

    /*//////////////////////////////////////////////////////////////
                    PRIVATE HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Updates absolute debts and principal after a withdrawal.
    ///         Extracted from _withdraw to avoid stack-too-deep.
    function _updateDebtsAfterWithdrawal(
        address owner_,
        uint256 principal_,
        uint256 principalForWithdrawal_,
        uint256 totalOwedPremium_,
        uint256 uncappedPremium_,
        uint256 totalOwedExpectedLoss_,
        uint256 uncappedExpectedLoss_
    )
        private
    {
        uint256 newPrincipal = principal_ - principalForWithdrawal_;
        uint256 remainingPremium = totalOwedPremium_ - uncappedPremium_;
        uint256 newRawDebt = newPrincipal.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
        userPremiumDebt[owner_] = newRawDebt > remainingPremium ? newRawDebt - remainingPremium : 0;

        uint256 remainingExpectedLoss = totalOwedExpectedLoss_ - uncappedExpectedLoss_;
        uint256 newRawELDebt = newPrincipal.mulDiv(cumulativeExpectedLossPerUnit, WAD, Math.Rounding.Floor);
        userExpectedLossDebt[owner_] = newRawELDebt > remainingExpectedLoss ? newRawELDebt - remainingExpectedLoss : 0;

        userPrincipal[owner_] = newPrincipal;
    }

    /// @dev Validates that a timelocked proposal is ready to execute.
    function _requireTimelockReady(uint64 timestamp) private view {
        if (timestamp == 0) revert NoPendingChange();
        if (block.timestamp < timestamp) revert DelayNotElapsed();
    }

    /// @dev Validates policy metadata matches this wrapper's configuration. Emits diagnostic event on failure.
    function _validatePolicyBinding(IPolicyManager.PolicyMetadata memory pol) private {
        if (pol.buyer != owner()) {
            emit IE.PolicyBindingFailed(keccak256("buyer != owner"));
            revert InvalidData();
        }
        if (pol.pool != address(coverPool)) {
            emit IE.PolicyBindingFailed(keccak256("pool mismatch"));
            revert InvalidData();
        }
        if (pol.claimer != address(this)) {
            emit IE.PolicyBindingFailed(keccak256("claimer != this"));
            revert InvalidData();
        }
        if (pol.beneficiary != address(this)) {
            emit IE.PolicyBindingFailed(keccak256("beneficiary != this"));
            revert InvalidData();
        }
        if (pol.payoutToken != asset()) {
            emit IE.PolicyBindingFailed(keccak256("payoutToken != asset"));
            revert InvalidData();
        }
    }

    function _setSkipInsurance(bool skip) private {
        uint256 slot = SKIP_INSURANCE_SLOT;
        uint256 val = skip ? 1 : 0;
        assembly {
            tstore(slot, val)
        }
    }

    function _setActualOut(uint256 amount) private {
        // Load constant into local var — inline assembly requires direct integer references, not computed constants.
        uint256 slot = ACTUAL_OUT_SLOT;
        assembly {
            tstore(slot, amount)
        }
    }

    function _getActualOut() private view returns (uint256 amount) {
        uint256 slot = ACTUAL_OUT_SLOT;
        assembly {
            amount := tload(slot)
        }
    }

    function _setPendingClaim(uint256 amount) private {
        uint256 slot = PENDING_CLAIM_AMOUNT_SLOT;
        assembly {
            tstore(slot, amount)
        }
    }

    function _getPendingClaim() private view returns (uint256 amount, bool hasPendingClaim) {
        uint256 slot = PENDING_CLAIM_AMOUNT_SLOT;
        assembly {
            amount := tload(slot)
            hasPendingClaim := gt(amount, 0)
        }
    }

    function _clearPendingClaim() private {
        uint256 slot = PENDING_CLAIM_AMOUNT_SLOT;
        assembly {
            tstore(slot, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Prevents ownership renunciation which would permanently brick all onlyOwner functions
    ///         and the UUPS upgrade path.
    function renounceOwnership() public override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Proposes a UUPS upgrade with a 2-day timelock
    function proposeUpgrade(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), IA.ZeroAddress());
        uint64 executeAfter = uint64(block.timestamp + PARAM_CHANGE_DELAY);
        pendingImplementation = newImplementation;
        pendingUpgradeTimestamp = executeAfter;
        emit IE.UpgradeProposed(newImplementation, executeAfter);
    }

    /// @notice Executes a pending UUPS upgrade after the 2-day timelock elapses
    function executeUpgrade() external onlyOwner {
        _requireTimelockReady(pendingUpgradeTimestamp);
        address impl = pendingImplementation;
        emit IE.UpgradeExecuted(impl);
        // NOTE: pendingImplementation and pendingUpgradeTimestamp are cleared AFTER upgradeToAndCall
        // because _authorizeUpgrade() validates them during the upgrade call.
        upgradeToAndCall(impl, "");
        pendingUpgradeTimestamp = 0;
        pendingImplementation = address(0);
    }

    /// @notice Restricts UUPS upgrade authorization to the wrapper owner.
    ///         Verifies implementation matches pending upgrade and timelock has elapsed.
    function _authorizeUpgrade(address newImplementation) internal override {
        require(msg.sender == owner(), IA.NotAuthorizedUpgrader(msg.sender));
        require(
            newImplementation == pendingImplementation && pendingUpgradeTimestamp != 0
                && block.timestamp >= pendingUpgradeTimestamp,
            IA.NotAuthorizedUpgrader(msg.sender)
        );
    }

    /// @notice Toggles the Morpho gate status to pause/resume premium accrual
    /// @param active True when Morpho gate is active (pauses premium), false to resume
    function setMorphoGateActive(bool active) external onlyOwner {
        morphoGateActive = active;
        emit IE.MorphoGateStatusUpdated(active);
    }

    /// @notice Rescues tokens accidentally sent to this contract
    /// @param token The ERC-20 token to rescue
    /// @param amount The amount to rescue
    /// @param to The address to send rescued tokens to
    function rescueTokens(address token, uint256 amount, address to) external onlyOwner {
        require(to != address(0), IA.ZeroAddress());
        if (token == asset()) {
            // For the underlying asset: only allow sweeping balance above pendingPremium
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 reserved = pendingPremium;
            require(amount <= balance - reserved, IA.InvalidParameters());
        } else if (token == morphoVault) {
            // For Morpho shares: only allow sweeping surplus above tracked user shares
            uint256 balance = IVaultV2(morphoVault).balanceOf(address(this));
            uint256 trackedShares = totalPrincipal > 0 ? balance : 0; // conservative: if users exist, don't sweep
            require(amount <= balance - trackedShares, IA.InvalidParameters());
        }
        IERC20(token).safeTransfer(to, amount);
        emit IE.TokensRescued(token, to, amount);
    }
}
