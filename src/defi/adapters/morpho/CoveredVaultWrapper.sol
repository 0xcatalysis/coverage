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
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
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
    OwnableUpgradeable,
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

    /// @notice Transient storage slot for pending claim amount
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 private constant PENDING_CLAIM_AMOUNT_SLOT = 0x1;

    /// @notice Transient storage slot for the actual assets transferred in the current withdrawal.
    ///         Written by _withdraw so that overriding redeem()/withdraw() can return the real amount.
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 private constant ACTUAL_OUT_SLOT = 0x2;

    /// @notice WAD scaling factor for premium rate
    uint256 private constant WAD = 1e18;

    /// @notice Maximum allowed premium rate: ~50% per year (WAD-scaled per second)
    /// @dev 50e16 / 365 days = 15_854_895_991 wei/second
    uint256 private constant MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991;

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

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidPolicyId();
    error NotAuthorized();
    error InvalidData();
    error PolicyBoundAlreadyExecuted();
    /// @notice Thrown when a share transfer between accounts is attempted.
    error TransfersDisabled();

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

    /// @notice Returns total assets managed by this wrapper, net of total premium liability
    /// @dev Share price is identical to the old formula: morphoValue is higher by totalPremiumLiability
    ///      (no longer redeemed), which is then subtracted back here. Net effect is the same NAV.
    function totalAssets() public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 morphoValue = IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this)));
        uint256 totalLiability = totalPremiumLiability + _accruedPremium();
        return morphoValue > totalLiability ? morphoValue - totalLiability : 0;
    }

    /// @notice Deposit assets into the wrapper
    /// @dev Full override — does NOT call super._deposit. Deposits into Morpho as address(this).
    ///      Principal is tracked for the receiver (not the caller).
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        _accruePremium();
        IERC20(asset()).safeTransferFrom(caller, address(this), assets);
        IERC20(asset()).forceApprove(address(morphoVault), assets);
        // slither-disable-next-line reentrancy-state-change,unused-return
        uint256 morphoSharesReceived = IVaultV2(morphoVault).deposit(assets, address(this));
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

    ///      Insurance is paid directly to receiver if a loss is detected and policy is active.
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
        uint256 redeemShares = userMorphoShares[owner_].mulDiv(shares_, balanceOf(owner_), Math.Rounding.Floor);
        userMorphoShares[owner_] -= redeemShares;

        _burn(owner_, shares_);

        // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
        uint256 assetsReceived = 0;
        if (redeemShares > 0) {
            // slither-disable-next-line reentrancy-state-change
            assetsReceived = IVaultV2(morphoVault).redeem(redeemShares, address(this), address(this));
        }

        uint256 premiumForWithdrawal;
        (premiumForWithdrawal, totalOut_) = _settleWithdrawalTransfer(
            receiver_, userPrincipalForWithdrawal_, a.uncappedPremium, a.uncappedExpectedLoss, assetsReceived, owner_
        );

        pendingPremium += premiumForWithdrawal;
        // Saturating subtractions guard against any rounding-induced edge case where per-user
        // owed values could marginally exceed their respective global liability trackers.
        totalPremiumLiability =
            totalPremiumLiability > a.uncappedPremium ? totalPremiumLiability - a.uncappedPremium : 0;
        totalExpectedLossLiability = totalExpectedLossLiability > a.uncappedExpectedLoss
            ? totalExpectedLossLiability - a.uncappedExpectedLoss
            : 0;

        // Update absolute debts and principal
        _updateDebtsAfterWithdrawal(
            owner_,
            userPrincipal[owner_],
            userPrincipalForWithdrawal_,
            a.totalOwedPremium,
            a.uncappedPremium,
            a.totalOwedExpectedLoss,
            a.uncappedExpectedLoss
        );
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

    /// @notice Returns accrued-but-unprocessed premium owed to premiumRecipient
    // slither-disable-next-line incorrect-equality
    function _accruedPremium() internal view returns (uint256) {
        if (totalPrincipal == 0) return 0;
        uint256 elapsed = block.timestamp - lastPremiumAccrualTime;
        return totalPrincipal.mulDiv(premiumRatePerSecond * elapsed, WAD, Math.Rounding.Floor);
    }

    /// @notice Records accrued premium as a liability in the per-user debt accumulator, and advances the
    ///         expected loss accumulator for the elapsed period.
    ///         No Morpho shares are redeemed here — premium is deducted from user proceeds at withdrawal.
    ///         Keeping transfers out of this function ensures a blacklisted recipient cannot freeze the vault.
    // slither-disable-next-line incorrect-equality
    function _accruePremium() internal {
        // Advance expected loss accumulator for the elapsed period, regardless of whether wrapper premium accrued.
        uint256 elapsed = block.timestamp - lastPremiumAccrualTime;
        if (underlyingExpectedLossBps > 0 && totalPrincipal > 0 && elapsed > 0) {
            cumulativeExpectedLossPerUnit += underlyingExpectedLossBps.mulDiv(elapsed * WAD, BPS_DENOMINATOR * 365 days);
            totalExpectedLossLiability += totalPrincipal.mulDiv(
                underlyingExpectedLossBps * elapsed, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
            );
        }

        // Compute accrued premium using the same elapsed window captured above, before advancing the timestamp.
        uint256 accrued =
            totalPrincipal > 0 ? totalPrincipal.mulDiv(premiumRatePerSecond * elapsed, WAD, Math.Rounding.Floor) : 0;

        // Always advance the timestamp once both accumulators have been updated for this period,
        // so subsequent calls never double-count the same elapsed time (even if premium caps to zero).
        lastPremiumAccrualTime = block.timestamp;

        if (accrued == 0) {
            return;
        }

        // Cap: totalPremiumLiability + accrued must not exceed current Morpho value
        uint256 morphoValue = IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this)));
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
    function collectPremium() external {
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
    function setPremiumRate(uint256 newRate) external onlyOwner {
        require(newRate <= MAX_PREMIUM_RATE_PER_SECOND, IA.InvalidParameters());
        // Settle any premium accrued at the old rate before switching.
        _accruePremium();
        // Force-advance the timestamp even if _accruePremium() hit the dust path (accrued > 0
        // but rounds to 0 Morpho shares). Without this, lastPremiumAccrualTime stays stale and
        // newRate would be charged retroactively over the period when oldRate was still active.
        // We accept losing at most 1 Morpho share of carry-forward premium (<< $1 in practice).
        lastPremiumAccrualTime = block.timestamp;
        uint256 oldRate = premiumRatePerSecond;
        premiumRatePerSecond = newRate;
        emit IE.PremiumRateUpdated(oldRate, newRate);
    }

    /// @inheritdoc ICoveredVaultWrapper
    function setMaxCoverableLossBps(uint16 newBps) external onlyOwner {
        require(newBps > 0 && newBps <= BPS_DENOMINATOR, IA.InvalidMaxCoverableLoss());
        uint16 oldBps = maxCoverableLossBps;
        maxCoverableLossBps = newBps;
        // Recalculate depositCap against the stored coverage limit so the two values stay consistent.
        // If the policy is not yet bound, coverageLimit == 0 and depositCap stays 0 — onPolicyBound
        // will set the correct cap using the new maxCoverableLossBps when it is eventually called.
        if (policyBoundExecuted) {
            depositCap = (coverageLimit * BPS_DENOMINATOR) / uint256(newBps);
        }
        emit IE.MaxCoverableLossUpdated(oldBps, newBps);
    }

    /// @inheritdoc ICoveredVaultWrapper
    function setUnderlyingExpectedLossBps(uint256 newBps) external onlyOwner {
        require(newBps <= BPS_DENOMINATOR, IA.InvalidParameters());
        // Settle accrual at the old rate before switching, same as setPremiumRate.
        _accruePremium();
        lastPremiumAccrualTime = block.timestamp;
        uint256 oldBps = underlyingExpectedLossBps;
        underlyingExpectedLossBps = newBps;
        emit IE.UnderlyingExpectedLossUpdated(oldBps, newBps);
    }

    /// @inheritdoc ICoveredVaultWrapper
    function setDeductibleBps(uint16 newBps) external onlyOwner {
        require(newBps < BPS_DENOMINATOR, IA.InvalidParameters());
        uint16 oldBps = deductibleBps;
        deductibleBps = newBps;
        emit IE.DeductibleUpdated(oldBps, newBps);
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

        // Validate that the policy parameters are consistent with this wrapper
        // aderyn-fp-next-line(reentrancy-state-change) Only callable by trusted PolicyManager, executed once
        IPolicyManager.PolicyMetadata memory pol = _policyManager.policyMetadata(_policyId);
        // aderyn-fp-next-line(reentrancy-state-change) Only callable by trusted PolicyManager, executed once
        if (pol.buyer != owner()) revert InvalidData();
        if (pol.pool != address(coverPool)) revert InvalidData();
        if (pol.claimer != address(this)) revert InvalidData();
        if (pol.beneficiary != address(this)) revert InvalidData();
        if (pol.payoutToken != asset()) revert InvalidData();

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
    function _computeInsurance(
        uint256 insuredBasis,
        uint256 netAssetsReceived,
        address owner
    )
        internal
        returns (uint256 insurancePayout)
    {
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
        (uint256 policyCoverageLimit, address payoutToken) = _getCoverageParams(policyId);

        uint256 paidOut = _getPaidCover(policyId);
        uint256 remainingCoverage = policyCoverageLimit > paidOut ? policyCoverageLimit - paidOut : 0;

        uint256 cappedClaim = claimAmount > remainingCoverage ? remainingCoverage : claimAmount;
        if (cappedClaim == 0) return 0;

        uint256 balanceBefore = IERC20(payoutToken).balanceOf(address(this));

        _setPendingClaim(cappedClaim);

        // aderyn-fp-next-line(weak-randomness) evidenceHash is for claim identification, not security-critical
        bytes32 evidenceHash = keccak256(abi.encodePacked(user, policyId, cappedClaim, block.timestamp));
        // aderyn-fp-next-line(unchecked-return) ClaimId not needed — success determined via balance change
        _fileAndResolveClaim(policyId, cappedClaim, evidenceHash, abi.encode(address(this), cappedClaim));

        _clearPendingClaim();

        uint256 balanceAfter = IERC20(payoutToken).balanceOf(address(this));
        payout = balanceAfter - balanceBefore;

        emit IE.InsuranceClaimed(user, policyId, claimAmount, payout);
    }

    /// @inheritdoc ISpec
    function evaluate(ISpec.EvaluationContext calldata context)
        external
        view
        override
        returns (ISpec.EvaluationResult memory result)
    {
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
        uint256 morphoValue = IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this)));
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
        uint256 pendingElapsedSecs = block.timestamp - lastPremiumAccrualTime;
        uint256 totalExpectedLoss = totalExpectedLossLiability;
        if (underlyingExpectedLossBps > 0 && pendingElapsedSecs > 0) {
            totalExpectedLoss += totalPrincipal.mulDiv(
                underlyingExpectedLossBps * pendingElapsedSecs, BPS_DENOMINATOR * uint256(365 days), Math.Rounding.Floor
            );
        }
        uint256 totalDeductions = totalPremiumTotal + totalExpectedLoss;
        uint256 adjustedPrincipal = totalPrincipal > totalDeductions ? totalPrincipal - totalDeductions : 0;
        if (adjustedPrincipal > netValue) {
            uint256 rawShortfall = adjustedPrincipal - netValue;
            // EF-4: Cap on adjustedPrincipal so premium-period losses don't inflate the coverable amount
            uint256 maxCoverable = adjustedPrincipal.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
            uint256 capped = rawShortfall > maxCoverable ? maxCoverable : rawShortfall;
            return capped.mulDiv(BPS_DENOMINATOR - deductibleBps, BPS_DENOMINATOR);
        }
        return 0;
    }

    /// @dev Returns the total pending expected loss (accrued + uncheckpointed period) for a user.
    ///      Extracted to reduce stack depth in userShortfall.
    function _userTotalExpectedLoss(address user) private view returns (uint256) {
        uint256 rawOwed = userPrincipal[user].mulDiv(cumulativeExpectedLossPerUnit, WAD, Math.Rounding.Floor);
        uint256 total = rawOwed > userExpectedLossDebt[user] ? rawOwed - userExpectedLossDebt[user] : 0;
        uint256 pendingElapsedSecs = block.timestamp - lastPremiumAccrualTime;
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
        uint256 userMorphoGross = IVaultV2(morphoVault).convertToAssets(userMorphoShares[user]);
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

    /// @notice Checks if the policy is currently active (bound and within coverage window)
    // slither-disable-next-line incorrect-equality
    function _isPolicyActive() internal view returns (bool) {
        if (policyId == 0) return false;
        IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
        return metadata.buyer != address(0) && block.timestamp >= metadata.startTime
            && block.timestamp <= metadata.maturityTime;
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

    function _setActualOut(uint256 amount) private {
        assembly {
            tstore(ACTUAL_OUT_SLOT, amount)
        }
    }

    function _getActualOut() private view returns (uint256 amount) {
        assembly {
            amount := tload(ACTUAL_OUT_SLOT)
        }
    }

    function _setPendingClaim(uint256 amount) private {
        assembly {
            tstore(PENDING_CLAIM_AMOUNT_SLOT, amount)
        }
    }

    function _getPendingClaim() private view returns (uint256 amount, bool hasPendingClaim) {
        assembly {
            amount := tload(PENDING_CLAIM_AMOUNT_SLOT)
            hasPendingClaim := gt(amount, 0)
        }
    }

    function _clearPendingClaim() private {
        assembly {
            tstore(PENDING_CLAIM_AMOUNT_SLOT, 0)
        }
    }

    /// @notice Restricts UUPS upgrade authorization to the wrapper owner
    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == owner(), IA.NotAuthorizedUpgrader(msg.sender));
    }
}
