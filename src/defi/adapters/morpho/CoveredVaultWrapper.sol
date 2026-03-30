// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoveredVaultAdmin} from "./CoveredVaultAdmin.sol";
import {ICoveredVaultWrapper} from "../../interfaces/ICoveredVaultWrapper.sol";
import {IVaultV2} from "../../interfaces/Morpho/IVaultV2.sol";
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
///
///      Inheritance chain (for storage layout and separation of concerns):
///      CoveredVaultStorage → CoveredVaultAccrual → CoveredVaultAdmin → CoveredVaultWrapper
contract CoveredVaultWrapper is CoveredVaultAdmin, IBindPolicyHook {
    using SafeERC20 for IERC20;
    using Math for uint256;

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
        require(_deductibleBps < _maxCoverableLossBps, IA.InvalidParameters());

        __ERC4626_init(IERC20(IVaultV2(_morphoVault).asset()));
        __ERC20_init(_name, _symbol);
        __Ownable_init(_owner);
        __BasePolicyInteractions_init(IClaimManager(_claimManager).policyManager(), _claimManager, _coverPool);

        morphoVault = _morphoVault;
        maxCoverableLossBps = _maxCoverableLossBps;
        deductibleBps = _deductibleBps;
        premiumRecipient = _premiumRecipient;
        // lastPremiumAccrualTime is intentionally NOT set here. It is set in onPolicyBound when the
        // policy is bound and deposits open, so the accrual clock starts exactly at coverage start.
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns total assets managed by this wrapper, net of premium liabilities.
    function totalAssets() public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 mv = _morphoValue();
        uint256 totalLiability = totalPremiumLiability + _accruedPremiumFor(mv);
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
        // Increase absolute debt so new assets don't inherit past premium.
        // Must use Ceil to match _calcOwedDebt, otherwise ceil(p*c/WAD) - floor(p*c/WAD) = 1 wei phantom debt.
        userPremiumDebt[receiver] += assets.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Ceil);
        userPrincipal[receiver] += assets;
        totalPrincipal += assets;
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @dev Computes insurance payout, transfers net assets + payout to receiver, and returns the amounts
    ///      needed for accounting. Extracted from _withdraw to avoid stack-too-deep.
    function _settleWithdrawalTransfer(
        address receiver_,
        uint256 userPrincipalForWithdrawal_,
        uint256 uncappedPremium_,
        uint256 assetsReceived_,
        address owner_
    )
        private
        returns (uint256 premiumForWithdrawal_, uint256 totalOut_)
    {
        // Cap: can't deduct more premium than what Morpho returned (deep-loss guard)
        premiumForWithdrawal_ = uncappedPremium_ < assetsReceived_ ? uncappedPremium_ : assetsReceived_;

        // insuredBasis = principal reduced by the actually-collected premium.
        // We use premiumForWithdrawal_ (not uncappedPremium_) because in a deep-loss scenario the uncollected
        // portion of the premium is effectively forgiven — it never reaches pendingPremium — so it should not
        // further reduce the user's insured basis (that would penalise the user twice for the same loss event).
        uint256 insuredBasis = _safeSub(userPrincipalForWithdrawal_, premiumForWithdrawal_);
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
                    POLICY BINDING
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

        // Policy start and accrual clock both begin at the binding timestamp.
        // Deposits are gated by policyBoundExecuted, so no deposit can arrive before this point
        // and lastPremiumAccrualTime is guaranteed to start at or before the first deposit.
        policyStartTime = block.timestamp;
        lastPremiumAccrualTime = block.timestamp;

        // depositCap = total TVL cap implied by the coverage limit
        // If maxCoverableLossBps=10% (1000) and coverageLimit=100, cap = 100 * 10000/1000 = 1000
        depositCap = (_coverageLimit * BPS_DENOMINATOR) / uint256(maxCoverableLossBps);

        emit IE.PolicyBound(address(this), _policyId);
    }

    /*//////////////////////////////////////////////////////////////
                    INSURANCE INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Computes insurance payout given insuredBasis and net assets, then claims if eligible.
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
        // Mirror the deep-loss guard in _settleWithdrawalTransfer: cap premium deduction at
        // available Morpho assets so the view matches the actual withdrawal path in all scenarios.
        uint256 cappedPremium = totalPremiumTotal < mv ? totalPremiumTotal : mv;
        uint256 netValue = mv - cappedPremium;
        uint256 adjustedPrincipal = _safeSub(totalPrincipal, cappedPremium);
        if (adjustedPrincipal > netValue) {
            return _capAndApplyDeductible(adjustedPrincipal - netValue, adjustedPrincipal);
        }
        return 0;
    }

    /// @inheritdoc ICoveredVaultWrapper
    // slither-disable-next-line incorrect-equality
    function userShortfall(address user) external view override returns (uint256) {
        if (balanceOf(user) == 0) return 0;
        uint256 accrued = _accruedPremium();

        uint256 principal = userPrincipal[user];
        uint256 totalUserPremium = _calcOwedDebt(principal, cumulativePremiumPerUnit, userPremiumDebt[user])
            + (totalPrincipal > 0 ? principal.mulDiv(accrued, totalPrincipal, Math.Rounding.Floor) : 0);
        // Mirror the deep-loss guard in _settleWithdrawalTransfer: cap the premium deduction at
        // the user's available Morpho assets so the view matches the actual withdrawal path.
        uint256 userMorphoVal = _userMorphoValue(user);
        uint256 cappedUserPremium = totalUserPremium < userMorphoVal ? totalUserPremium : userMorphoVal;
        uint256 userMorphoNet = userMorphoVal - cappedUserPremium;
        uint256 adjustedUserPrincipal = _safeSub(principal, cappedUserPremium);
        if (adjustedUserPrincipal > userMorphoNet) {
            return _capAndApplyDeductible(adjustedUserPrincipal - userMorphoNet, adjustedUserPrincipal);
        }
        return 0;
    }

    /// @notice Returns maximum withdrawable assets accounting for premium deductions
    function maxWithdraw(address owner) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 shares = balanceOf(owner);
        if (shares == 0) return 0;
        // totalAssets() already deducts totalPremiumLiability + _accruedPremiumFor(mv),
        // so _convertToAssets produces a share price net of all premium obligations.
        // Subtracting owedPremium again would double-count the liability.
        return _convertToAssets(shares, Math.Rounding.Floor);
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
    function maxMint(address receiver) public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        return previewDeposit(maxDeposit(receiver));
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                    PRIVATE HELPERS
    //////////////////////////////////////////////////////////////*/

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

    /// @dev Computes owed premium from the absolute-debt formula.
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
            ? amounts.totalOwedPremium.mulDiv(shares_, ownerBalance_, Math.Rounding.Ceil)
            : amounts.totalOwedPremium;
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
            owner_, userPrincipal[owner_], userPrincipalForWithdrawal_, a.totalOwedPremium, a.uncappedPremium
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
            receiver_, userPrincipalForWithdrawal_, a.uncappedPremium, assetsReceived, owner_
        );

        pendingPremium += premiumForWithdrawal;
        // Decrement totalPremiumLiability by premiumForWithdrawal (actually collected) rather than
        // a.uncappedPremium (intended amount). In deep-loss scenarios where assetsReceived < uncappedPremium,
        // the forgiven delta was never collected into pendingPremium and should not reduce the liability tracker,
        // otherwise totalAssets() is inflated for remaining holders by the forgiven amount.
        totalPremiumLiability = _safeSub(totalPremiumLiability, premiumForWithdrawal);
    }

    /// @notice Updates absolute debts and principal after a withdrawal.
    function _updateDebtsAfterWithdrawal(
        address owner_,
        uint256 principal_,
        uint256 principalForWithdrawal_,
        uint256 totalOwedPremium_,
        uint256 uncappedPremium_
    )
        private
    {
        uint256 newPrincipal = principal_ - principalForWithdrawal_;
        // Must use Ceil to match _calcOwedDebt and avoid 1 wei phantom debt after each withdrawal.
        uint256 newRawDebt = newPrincipal.mulDiv(cumulativePremiumPerUnit, WAD, Math.Rounding.Ceil);
        userPremiumDebt[owner_] = _safeSub(newRawDebt, totalOwedPremium_ - uncappedPremium_);

        userPrincipal[owner_] = newPrincipal;
    }

    function _validatePolicyBinding(IPolicyManager.PolicyMetadata memory pol) private view {
        if (pol.buyer != owner()) revert PolicyBindingFailed(bytes32(uint256(1)));
        if (pol.pool != address(coverPool)) revert PolicyBindingFailed(bytes32(uint256(2)));
        if (pol.claimer != address(this)) revert PolicyBindingFailed(bytes32(uint256(3)));
        if (pol.beneficiary != address(this)) revert PolicyBindingFailed(bytes32(uint256(4)));
        if (pol.payoutToken != asset()) revert PolicyBindingFailed(bytes32(uint256(5)));
    }

    /// @dev Safe subtraction returning 0 on underflow. Reduces repeated ternary bytecode.
    function _safeSub(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    /// @dev Computes owed debt from the reward-per-token formula: principal × cumPerUnit / WAD − userDebt.
    function _calcOwedDebt(uint256 principal, uint256 cumulative, uint256 userDebt) private pure returns (uint256) {
        uint256 raw = principal.mulDiv(cumulative, WAD, Math.Rounding.Ceil);
        return raw > userDebt ? raw - userDebt : 0;
    }

    /// @dev Caps shortfall at maxCoverableLossBps of basis, then subtracts a traditional deductible.
    ///      The deductible is a fixed threshold (deductibleBps % of basis) that the policyholder absorbs
    ///      before insurance pays anything. Losses at or below the threshold yield a $0 payout.
    function _capAndApplyDeductible(uint256 shortfall, uint256 basis) private view returns (uint256) {
        uint256 maxInsurance = basis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR, Math.Rounding.Floor);
        uint256 capped = shortfall > maxInsurance ? maxInsurance : shortfall;
        uint256 deductibleAmt = basis.mulDiv(deductibleBps, BPS_DENOMINATOR, Math.Rounding.Ceil);
        return capped > deductibleAmt ? capped - deductibleAmt : 0;
    }

    function _tstore(uint256 slot, uint256 value) private {
        assembly { tstore(slot, value) }
    }

    function _tload(uint256 slot) private view returns (uint256 value) {
        assembly { value := tload(slot) }
    }
}
