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
        uint256 mv = _morphoValue();
        uint256 totalLiability =
            totalPremiumLiability + _accruedPremiumFor(mv) + totalExpectedLossLiability + _accruedExpectedLossFor(mv);
        return mv > totalLiability ? mv - totalLiability : 0;
    }

    /// @notice Deposit assets into the wrapper
    /// @dev Full override — does NOT call super._deposit. Deposits into Morpho as address(this).
    ///      Principal is tracked for the receiver (not the caller).
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        // Reject dust deposits that round to zero wrapper shares — prevents principal/shares desync.
        // slither-disable-next-line incorrect-equality
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
        uint256 insuredBasis = _safeSub(userPrincipalForWithdrawal_, premiumForWithdrawal_ + uncappedExpectedLoss_);
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
        uint256 actualOut = _executeWithdrawal(owner, receiver, shares, userPrincipalForWithdrawal, ownerBalance);

        totalPrincipal -= userPrincipalForWithdrawal;

        // Store actual transferred amount so overriding redeem()/withdraw() can return it.
        _tstore(ACTUAL_OUT_SLOT, actualOut);

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
        return _tload(ACTUAL_OUT_SLOT);
    }

    /// @notice ERC-4626-compliant withdraw override. Returns shares burned.
    /// @dev The base OZ implementation is already correct (returns shares), but this explicit override documents
    ///      the important caveat: the actual assets received by the caller may differ from the `assets` parameter
    ///      because premium deductions reduce proceeds and insurance payouts may increase them.
    ///      Integrators needing exact asset-flow tracking should use redeem() and read _tload(ACTUAL_OUT_SLOT) via the
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
        _tstore(SKIP_INSURANCE_SLOT, 1);
        super.redeem(shares, receiver, owner);
        _tstore(SKIP_INSURANCE_SLOT, 0);
        uint256 totalOut = _tload(ACTUAL_OUT_SLOT);
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
        _tstore(SKIP_INSURANCE_SLOT, 1);
        shares = super.withdraw(assets, receiver, owner);
        _tstore(SKIP_INSURANCE_SLOT, 0);
        emit IE.EmergencyExit(owner, receiver, shares, _tload(ACTUAL_OUT_SLOT));
    }

    /// @dev Computes owed premium and expected loss from the absolute-debt formula.
    function _computeOwedAmounts(
        address owner_,
        uint256 shares_,
        uint256 ownerBalance_
    )
        private
        view
        returns (WithdrawalAmounts memory amounts)
    {
        uint256 principal = userPrincipal[owner_];

        amounts.totalOwedPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[owner_]);
        amounts.uncappedPremium = ownerBalance_ > 0
            ? amounts.totalOwedPremium.mulDiv(shares_, ownerBalance_, Math.Rounding.Floor)
            : amounts.totalOwedPremium;

        amounts.totalOwedExpectedLoss =
            _calcOwedDebt(principal, cumulativeExpectedLossPerUnit, userExpectedLossDebt[owner_]);
        amounts.uncappedExpectedLoss = ownerBalance_ > 0
            ? amounts.totalOwedExpectedLoss.mulDiv(shares_, ownerBalance_, Math.Rounding.Floor)
            : amounts.totalOwedExpectedLoss;
    }

    /// @dev Morpho redeem, insurance settlement, premium accounting, and debt updates.
    ///      Extracted from _withdraw to avoid stack-too-deep.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,reentrancy-events
    function _executeWithdrawal(
        address owner_,
        address receiver_,
        uint256 shares_,
        uint256 userPrincipalForWithdrawal_,
        uint256 ownerBalance_
    )
        private
        returns (uint256 totalOut_)
    {
        WithdrawalAmounts memory a = _computeOwedAmounts(owner_, shares_, ownerBalance_);

        // Gross Morpho entitlement (MUST be computed before burn)
        uint256 redeemShares = userMorphoShares[owner_].mulDiv(shares_, ownerBalance_, Math.Rounding.Floor);

        // At final withdrawal cap redeemShares to actual wrapper balance to handle rounding dust
        // accumulated over many partial withdrawals (sum(userMorphoShares) may exceed actual balance by N dust).
        // slither-disable-next-line incorrect-equality
        if (shares_ == ownerBalance_) {
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
        totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal);
        uint256 remainingAfterPremium = _safeSub(assetsReceived, premiumForWithdrawal);
        uint256 expectedLossForWithdrawal =
            a.uncappedExpectedLoss < remainingAfterPremium ? a.uncappedExpectedLoss : remainingAfterPremium;
        totalExpectedLossLiability = _safeSub(totalExpectedLossLiability, expectedLossForWithdrawal);
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
            // Guard: only fire the catch-up branch after the policy has started.
            if (
                meta.buyer != address(0) && uint256(meta.maturityTime) > checkpoint
                    && block.timestamp >= uint256(meta.startTime)
            ) {
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
    // slither-disable-next-line incorrect-equality,dead-code
    function _accruedExpectedLossFor(uint256 morphoVal) internal view returns (uint256) {
        if (morphoGateActive) return 0;
        if (underlyingExpectedLossBps == 0 || totalPrincipal == 0) return 0;
        uint256 elapsed = _activeElapsedFrom(lastPremiumAccrualTime);
        if (elapsed == 0) return 0;
        uint256 accrued = totalPrincipal.mulDiv(
            underlyingExpectedLossBps * elapsed, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
        );
        uint256 elHeadroom = _liabilityHeadroom(morphoVal);
        return accrued < elHeadroom ? accrued : elHeadroom;
    }

    /// @notice Returns accrued-but-unprocessed premium owed to premiumRecipient
    /// @dev Computes the active elapsed window:
    ///      - If policy is currently active: full [lastCheckpoint, now] window.
    ///      - If policy just expired and lastCheckpoint < maturityTime: only [lastCheckpoint, maturityTime].
    ///      - Otherwise: 0 (no phantom premium after expiry is fully settled).
    // slither-disable-next-line incorrect-equality
    function _accruedPremium() internal view returns (uint256) {
        return _accruedPremiumFor(_morphoValue());
    }

    // slither-disable-next-line incorrect-equality
    function _accruedPremiumFor(uint256 morphoVal) internal view returns (uint256) {
        if (morphoGateActive) return 0;
        if (totalPrincipal == 0 || premiumRatePerSecond == 0) return 0;
        uint256 elapsed = _activeElapsedFrom(lastPremiumAccrualTime);
        if (elapsed == 0) return 0;
        uint256 accrued = totalPrincipal.mulDiv(premiumRatePerSecond * elapsed, WAD, Math.Rounding.Floor);
        if (accrued == 0) return 0;
        uint256 maxNewLiability = _liabilityHeadroom(morphoVal);
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
        uint256 morphoValue = _morphoValue();
        lastKnownMorphoValue = morphoValue;

        // Cache hot storage reads
        uint256 _totalPrincipal = totalPrincipal;
        uint256 _elBps = underlyingExpectedLossBps;

        // Advance expected loss accumulator for the active elapsed period.
        if (_elBps > 0 && _totalPrincipal > 0) {
            uint256 elIncrement = _totalPrincipal.mulDiv(
                _elBps * activeElapsed, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
            );
            // Cap totalExpectedLossLiability against morphoValue headroom
            uint256 elHeadroom = _liabilityHeadroom(morphoValue);
            if (elIncrement > elHeadroom) {
                // Cap per-unit accumulator proportionally when headroom is exhausted.
                uint256 cappingFactor = elHeadroom.mulDiv(WAD, elIncrement);
                cumulativeExpectedLossPerUnit += _elBps.mulDiv(
                    activeElapsed * cappingFactor, BPS_DENOMINATOR * 365 days
                );
                elIncrement = elHeadroom;
            } else {
                cumulativeExpectedLossPerUnit += _elBps.mulDiv(activeElapsed * WAD, BPS_DENOMINATOR * 365 days);
            }
            totalExpectedLossLiability += elIncrement;
        }

        // Compute accrued premium using the active elapsed window.
        uint256 accrued = _totalPrincipal > 0
            ? _totalPrincipal.mulDiv(premiumRatePerSecond * activeElapsed, WAD, Math.Rounding.Floor)
            : 0;

        if (accrued == 0) return;

        // Cap: combined liabilities must not exceed current Morpho value
        uint256 maxNewLiability = _liabilityHeadroom(morphoValue);
        if (accrued > maxNewLiability) accrued = maxNewLiability;
        if (accrued == 0) return;
        if (_totalPrincipal > 0) {
            cumulativePremiumPerUnit += accrued.mulDiv(WAD, _totalPrincipal);
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
        pendingPremiumRateTimestamp = _propose(pendingPremiumRateTimestamp, "premiumRate");
        pendingPremiumRate = newRate;
        emit IE.PremiumRateProposed(newRate, pendingPremiumRateTimestamp);
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
        pendingMaxCoverableLossTimestamp = _propose(pendingMaxCoverableLossTimestamp, "maxCoverableLossBps");
        pendingMaxCoverableLossBps = newBps;
        emit IE.MaxCoverableLossBpsProposed(newBps, pendingMaxCoverableLossTimestamp);
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
        pendingExpectedLossTimestamp = _propose(pendingExpectedLossTimestamp, "underlyingExpectedLossBps");
        pendingExpectedLossBps = newBps;
        emit IE.UnderlyingExpectedLossBpsProposed(newBps, pendingExpectedLossTimestamp);
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
        pendingDeductibleTimestamp = _propose(pendingDeductibleTimestamp, "deductibleBps");
        pendingDeductibleBps = newBps;
        emit IE.DeductibleBpsProposed(newBps, pendingDeductibleTimestamp);
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
    /// @dev Now uses propose/execute pattern consistent with all other parameter changes.
    function setPremiumRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0), IA.ZeroAddress());
        pendingPremiumRecipientTimestamp = _propose(pendingPremiumRecipientTimestamp, "premiumRecipient");
        pendingPremiumRecipient = newRecipient;
        emit IE.PremiumRecipientProposed(newRecipient, pendingPremiumRecipientTimestamp);
    }

    /// @notice Applies a pending premium recipient change after the 2-day timelock elapses.
    function executePremiumRecipient() external onlyOwner {
        _requireTimelockReady(pendingPremiumRecipientTimestamp);
        address oldRecipient = premiumRecipient;
        premiumRecipient = pendingPremiumRecipient;
        pendingPremiumRecipientTimestamp = 0;
        emit IE.PremiumRecipientExecuted(pendingPremiumRecipient);
        emit IE.PremiumRecipientUpdated(oldRecipient, pendingPremiumRecipient);
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
        if (_tload(SKIP_INSURANCE_SLOT) != 0) return 0;

        if (insuredBasis > netAssetsReceived && _isPolicyActive()) {
            uint256 claimAmount = _capAndApplyDeductible(insuredBasis - netAssetsReceived, insuredBasis);
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

        _tstore(PENDING_CLAIM_AMOUNT_SLOT, cappedClaim);

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
            _tstore(PENDING_CLAIM_AMOUNT_SLOT, 0);
            emit IE.ClaimManagerUnavailable(policyId);
            return 0;
        }

        _tstore(PENDING_CLAIM_AMOUNT_SLOT, 0);

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
        uint256 pendingClaimAmount = _tload(PENDING_CLAIM_AMOUNT_SLOT);
        bool hasPendingClaim = pendingClaimAmount > 0;
        (address claimant, uint256 claimedAmount) = abi.decode(context.additionalData, (address, uint256));

        if (!hasPendingClaim || policyId != context.policyId) {
            return ISpec.EvaluationResult({isPayable: false, notesHash: bytes32(uint256(0))});
        }

        bool isValid = pendingClaimAmount == claimedAmount && claimant == address(this);
        result = ISpec.EvaluationResult({
            isPayable: isValid, notesHash: keccak256(abi.encodePacked(claimant, claimedAmount, isValid))
        });
    }

    /*//////////////////////////////////////////////////////////////
                    VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICoveredVaultWrapper
    // slither-disable-next-line incorrect-equality
    function calculateShortfall() external view override returns (uint256) {
        if (totalPrincipal == 0) return 0;
        uint256 mv = _morphoValue();
        uint256 accrued = _accruedPremiumFor(mv);
        uint256 totalPremiumTotal = totalPremiumLiability + accrued;
        uint256 netValue = _safeSub(mv, totalPremiumTotal);
        uint256 totalExpectedLoss = totalExpectedLossLiability + _accruedExpectedLossFor(mv);
        uint256 adjustedPrincipal = _safeSub(totalPrincipal, totalPremiumTotal + totalExpectedLoss);
        if (adjustedPrincipal > netValue) {
            return _capAndApplyDeductible(adjustedPrincipal - netValue, adjustedPrincipal);
        }
        return 0;
    }

    /// @dev Returns the total pending expected loss (accrued + uncheckpointed period) for a user.
    ///      Extracted to reduce stack depth in userShortfall.
    ///      Uses the same active-window logic as _accruedExpectedLoss() so that expected loss does
    ///      not accumulate beyond policy maturity, keeping userShortfall() consistent with totalAssets().
    function _userTotalExpectedLoss(address user) private view returns (uint256) {
        uint256 total = _calcOwedDebt(userPrincipal[user], cumulativeExpectedLossPerUnit, userExpectedLossDebt[user]);
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

        uint256 principal = userPrincipal[user];
        uint256 totalUserPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[user])
            + (totalPrincipal > 0 ? principal.mulDiv(accrued, totalPrincipal, Math.Rounding.Floor) : 0);
        uint256 totalUserDeductions = totalUserPremium + _userTotalExpectedLoss(user);
        uint256 userMorphoNet = _safeSub(_userMorphoValue(user), totalUserPremium);
        uint256 adjustedUserPrincipal = _safeSub(principal, totalUserDeductions);
        if (adjustedUserPrincipal > userMorphoNet) {
            return _capAndApplyDeductible(adjustedUserPrincipal - userMorphoNet, adjustedUserPrincipal);
        }
        return 0;
    }

    /// @notice Returns maximum withdrawable assets accounting for premium deductions
    function maxWithdraw(address owner) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 shares = balanceOf(owner);
        if (shares == 0) return 0;
        uint256 grossAssets = _convertToAssets(shares, Math.Rounding.Floor);
        // Include pending (uncheckpointed) premium delta and expected loss
        uint256 principal = userPrincipal[owner];
        uint256 fraction = totalPrincipal > 0 ? principal.mulDiv(WAD, totalPrincipal) : 0;
        uint256 owedPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[owner]);
        uint256 owedEL = _calcOwedDebt(principal, cumulativeExpectedLossPerUnit, userExpectedLossDebt[owner]);
        uint256 mv = _morphoValue();
        uint256 totalDeductions = owedPremium + _accruedPremiumFor(mv).mulDiv(fraction, WAD) + owedEL
            + _accruedExpectedLossFor(mv).mulDiv(fraction, WAD);
        return _safeSub(grossAssets, totalDeductions);
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
    /// @dev Extends maturityTime by gateGracePeriod so users trapped behind a
    ///      Morpho gate retain insurance eligibility for the duration of the gate overlap.
    // slither-disable-next-line incorrect-equality
    function _isPolicyActive() internal view returns (bool) {
        if (policyId == 0) return false;
        IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
        uint256 effectiveMaturity = uint256(metadata.maturityTime) + gateGracePeriod;
        return
            metadata.buyer != address(0) && block.timestamp >= metadata.startTime && block.timestamp < effectiveMaturity;
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
        uint256 newRawDebt = newPrincipal.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Floor);
        userPremiumDebt[owner_] = _safeSub(newRawDebt, totalOwedPremium_ - uncappedPremium_);

        uint256 newRawELDebt = newPrincipal.mulDiv(cumulativeExpectedLossPerUnit, WAD, Math.Rounding.Floor);
        userExpectedLossDebt[owner_] = _safeSub(newRawELDebt, totalOwedExpectedLoss_ - uncappedExpectedLoss_);

        userPrincipal[owner_] = newPrincipal;
    }

    /// @dev Validates that a timelocked proposal is ready to execute.
    function _requireTimelockReady(uint64 timestamp) private view {
        if (timestamp == 0) revert NoPendingChange();
        if (block.timestamp < timestamp) revert DelayNotElapsed();
    }

    /// @dev Shared propose logic: emits supersede event if overwriting, returns new execute-after timestamp.
    function _propose(uint64 currentTimestamp, bytes32 paramKey) private returns (uint64 executeAfter) {
        if (currentTimestamp != 0) emit IE.ProposalSuperseded(paramKey);
        executeAfter = uint64(block.timestamp + PARAM_CHANGE_DELAY);
    }

    /// @dev Safe subtraction returning 0 on underflow. Reduces repeated ternary bytecode.
    function _safeSub(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @dev Computes owed debt from the absolute-debt formula: principal × accumulator / WAD - debt.
    function _calcOwedDebt(uint256 principal, uint256 cumulative, uint256 userDebt) private pure returns (uint256) {
        uint256 raw = principal.mulDiv(cumulative, WAD, Math.Rounding.Floor);
        return _safeSub(raw, userDebt);
    }

    /// @dev Caps a shortfall at maxCoverableLossBps of basis and applies the deductible.
    function _capAndApplyDeductible(uint256 shortfall, uint256 basis) private view returns (uint256) {
        uint256 maxCoverable = basis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
        uint256 capped = shortfall > maxCoverable ? maxCoverable : shortfall;
        return capped.mulDiv(BPS_DENOMINATOR - deductibleBps, BPS_DENOMINATOR);
    }

    /// @dev Returns combined-liability headroom against Morpho value.
    function _liabilityHeadroom(uint256 morphoVal) private view returns (uint256) {
        uint256 total = totalPremiumLiability + totalExpectedLossLiability;
        return morphoVal > total ? morphoVal - total : 0;
    }

    /// @dev Validates policy metadata matches this wrapper's configuration. Emits diagnostic event on failure.
    function _validatePolicyBinding(IPolicyManager.PolicyMetadata memory pol) private {
        if (pol.buyer != owner()) _revertBinding(bytes32(uint256(1)));
        if (pol.pool != address(coverPool)) _revertBinding(bytes32(uint256(2)));
        if (pol.claimer != address(this)) _revertBinding(bytes32(uint256(3)));
        if (pol.beneficiary != address(this)) _revertBinding(bytes32(uint256(4)));
        if (pol.payoutToken != asset()) _revertBinding(bytes32(uint256(5)));
    }

    function _revertBinding(bytes32 code) private {
        emit IE.PolicyBindingFailed(code);
        revert InvalidData();
    }

    function _tstore(uint256 slot, uint256 value) private {
        assembly { tstore(slot, value) }
    }

    function _tload(uint256 slot) private view returns (uint256 value) {
        assembly { value := tload(slot) }
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Clear all pending timelocked proposals on ownership transfer.
    function acceptOwnership() public override {
        super.acceptOwnership();
        pendingPremiumRateTimestamp = 0;
        pendingDeductibleTimestamp = 0;
        pendingMaxCoverableLossTimestamp = 0;
        pendingExpectedLossTimestamp = 0;
        pendingUpgradeTimestamp = 0;
        pendingImplementation = address(0);
        pendingPremiumRecipientTimestamp = 0;
    }

    /// @notice Prevents ownership renunciation which would permanently brick all onlyOwner functions
    ///         and the UUPS upgrade path.
    function renounceOwnership() public override onlyOwner {
        revert RenounceDisabled();
    }

    /// @notice Proposes a UUPS upgrade with a 2-day timelock
    function proposeUpgrade(address newImplementation) external onlyOwner {
        require(newImplementation != address(0), IA.ZeroAddress());
        pendingUpgradeTimestamp = _propose(pendingUpgradeTimestamp, "upgrade");
        pendingImplementation = newImplementation;
        emit IE.UpgradeProposed(newImplementation, pendingUpgradeTimestamp);
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
    /// @dev Tracks gate duration and extends policy grace period by the overlap
    ///      with the policy window, so users trapped behind a gate retain insurance eligibility.
    function setMorphoGateActive(bool active) external onlyOwner {
        if (active && !morphoGateActive) {
            // Gate activated — record timestamp and try to cache current Morpho value
            gateActivatedAt = block.timestamp;
            try IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this))) returns (
                uint256 val
            ) {
                lastKnownMorphoValue = val;
            } catch {}
        } else if (!active && morphoGateActive && gateActivatedAt > 0) {
            // Gate lifted — extend grace period by the gate duration
            uint256 gateDuration = block.timestamp - gateActivatedAt;
            gateGracePeriod += gateDuration;
            gateActivatedAt = 0;
        }
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
            // Guard against underflow when pendingPremium > balance
            uint256 balance = IERC20(token).balanceOf(address(this));
            uint256 reserved = pendingPremium;
            uint256 sweepable = balance >= reserved ? balance - reserved : 0;
            require(amount <= sweepable, IA.InvalidParameters());
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
