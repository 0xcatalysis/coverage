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
///      - _update() migrates userPrincipal proportionally on every ERC-20 transfer
///      - totalPrincipal is unchanged by transfers (only by deposits and withdrawals)
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
    /// @dev Monotonically increasing. On the write path (_withdraw), insuredBasis uses this value
    ///      directly because _accruePremium() has already settled all pending accrual into it.
    ///      On the view path, both this value and _accruedPremium() are deducted symmetrically.
    uint256 public totalPremiumRedeemed;

    /// @inheritdoc ICoveredVaultWrapper
    /// @dev Persisted from onPolicyBound so that setMaxCoverableLossBps can recompute depositCap
    ///      without a second call to the policy manager.
    uint256 public coverageLimit;

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidPolicyId();
    error NotAuthorized();
    error InvalidData();
    error PolicyBoundAlreadyExecuted();

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

    /// @notice Returns total assets managed by this wrapper, net of accrued-but-unprocessed premium
    /// @dev This keeps the share price honest: premium is a liability against the vault's assets
    function totalAssets() public view override (ERC4626Upgradeable, IERC4626) returns (uint256) {
        uint256 morphoValue = IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this)));
        uint256 accrued = _accruedPremium();
        return morphoValue > accrued ? morphoValue - accrued : 0;
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
        IVaultV2(morphoVault).deposit(assets, address(this));
        _mint(receiver, shares); // triggers _update(address(0), receiver, shares) — no principal migration for mints
        userPrincipal[receiver] += assets;
        totalPrincipal += assets;
        emit Deposit(caller, receiver, assets, shares);
    }

    /// @notice Withdraw assets from the wrapper
    /// @dev Full override — does NOT call super._withdraw. Redeems Morpho shares proportionally.
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

        // Calculate principal attributable to these shares BEFORE burn (balanceOf still includes them)
        uint256 ownerBalance = balanceOf(owner);
        uint256 userPrincipalForWithdrawal =
            ownerBalance > 0 ? userPrincipal[owner].mulDiv(shares, ownerBalance, Math.Rounding.Floor) : 0;

        _burn(owner, shares); // triggers _update(owner, address(0), shares) — no principal migration for burns

        // Redeem from Morpho: burn morpho shares proportional to wrapper shares redeemed
        // assets == 0 when totalAssets() == 0 (e.g. 100% loss) — skip morpho redeem in that case
        uint256 assetsReceived = 0;
        if (assets > 0) {
            uint256 morphoShares = IVaultV2(morphoVault).previewWithdraw(assets);
            // slither-disable-next-line reentrancy-state-change
            assetsReceived = IVaultV2(morphoVault).redeem(morphoShares, address(this), address(this));
        }

        // Per-user insurance: only if a loss-induced shortfall exists and policy is active.
        // insuredBasis = principal scaled down by the pro-rata premium already paid out of the vault.
        // This ensures that premium deductions — which reduce the Morpho position but NOT userPrincipal —
        // do not produce spurious insurance claims. Only losses BEYOND the premium-adjusted basis trigger a claim.
        uint256 insurancePayout = 0;
        uint256 insuredBasis = totalPrincipal > 0
            ? userPrincipalForWithdrawal.mulDiv(
                totalPrincipal > totalPremiumRedeemed ? totalPrincipal - totalPremiumRedeemed : 0,
                totalPrincipal,
                Math.Rounding.Floor
            )
            : 0;
        if (insuredBasis > assetsReceived && _isPolicyActive()) {
            uint256 shortfall = insuredBasis - assetsReceived;
            // Using the raw principal would allow claiming for premium-period losses beyond the insured position.
            uint256 maxInsurance = insuredBasis.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
            // Cap to maxInsurance first, then apply deductible to the capped loss.
            // This matches calculateShortfall() / userShortfall() which do the same two steps in order.
            // The old order (deductible on cap, then min with shortfall) skipped the deductible entirely
            // for any shortfall smaller than maxInsurance × (1 − deductible).
            uint256 capped = shortfall < maxInsurance ? shortfall : maxInsurance;
            uint256 claimAmount = capped.mulDiv(BPS_DENOMINATOR - deductibleBps, BPS_DENOMINATOR);
            if (claimAmount > 0) {
                insurancePayout = _claimInsurance(claimAmount, owner);
            }
        }

        uint256 totalOut = assetsReceived + insurancePayout;
        if (totalOut > 0) IERC20(asset()).safeTransfer(receiver, totalOut);

        // Pro-rata removal of totalPremiumRedeemed: without this, the full premium history
        // hangs against a shrinking totalPrincipal after each exit, making the ratio
        // (totalPrincipal − totalPremiumRedeemed) / totalPrincipal progressively worse and
        // undercharging insuredBasis for remaining users. Must use current totalPrincipal
        // as denominator before it is decremented below.
        if (totalPrincipal > 0) {
            totalPremiumRedeemed -= totalPremiumRedeemed.mulDiv(
                userPrincipalForWithdrawal, totalPrincipal, Math.Rounding.Floor
            );
        }
        userPrincipal[owner] -= userPrincipalForWithdrawal;
        totalPrincipal -= userPrincipalForWithdrawal;

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @notice Hook called on every ERC-20 share transfer
    /// @dev Migrates userPrincipal proportionally on transfers. Mint (from==0) and burn (to==0)
    ///      are intentionally excluded — those cases are handled explicitly in _deposit/_withdraw.
    ///      IMPORTANT: super._update() is called LAST so that balanceOf(from) is still pre-transfer.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fromBalance = balanceOf(from); // pre-transfer balance
            if (fromBalance > 0) {
                uint256 principalMoved = userPrincipal[from].mulDiv(value, fromBalance, Math.Rounding.Floor);
                userPrincipal[from] -= principalMoved;
                userPrincipal[to] += principalMoved;
                emit IE.PrincipalTransferred(from, to, principalMoved);
            }
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

    /// @notice Redeems accrued premium from Morpho into pendingPremium — never transfers to recipient.
    ///         Keeping the transfer out of this function ensures a blacklisted or reverting recipient
    ///         cannot freeze deposits, withdrawals, or admin configuration changes.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,incorrect-equality
    function _accruePremium() internal {
        uint256 accrued = _accruedPremium();
        if (accrued == 0) {
            lastPremiumAccrualTime = block.timestamp;
            return;
        }

        // Cap accrued premium at the wrapper's actual Morpho position value to prevent over-redemption
        // after a loss or prolonged accrual gap
        uint256 morphoValue = IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this)));
        if (accrued > morphoValue) accrued = morphoValue;

        uint256 morphoShares = IVaultV2(morphoVault).previewWithdraw(accrued);
        // Only advance timestamp when an actual redemption occurs; otherwise dust
        // carries forward into the next cycle rather than being silently dropped
        // slither-disable-next-line incorrect-equality
        if (morphoShares == 0) return;

        lastPremiumAccrualTime = block.timestamp;
        // slither-disable-next-line reentrancy-state-change
        uint256 assetsReceived = IVaultV2(morphoVault).redeem(morphoShares, address(this), address(this));
        if (assetsReceived > 0) {
            pendingPremium += assetsReceived;
            totalPremiumRedeemed += assetsReceived;
        }
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

        bool isValid = pendingClaimAmount == claimedAmount;
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
        uint256 netValue = morphoValue > accrued ? morphoValue - accrued : 0;
        // adjustedPrincipal must deduct BOTH already-redeemed premium AND the pending accrual,
        // mirroring netValue which subtracts the same total from the Morpho position.
        // Using only totalPremiumRedeemed here would cause a phantom shortfall equal to the
        // pending accrual even when no real loss has occurred.
        uint256 totalPremiumTotal = totalPremiumRedeemed + accrued;
        uint256 adjustedPrincipal = totalPrincipal > totalPremiumTotal ? totalPrincipal - totalPremiumTotal : 0;
        if (adjustedPrincipal > netValue) {
            uint256 rawShortfall = adjustedPrincipal - netValue;
            // EF-4: Cap on adjustedPrincipal so premium-period losses don't inflate the coverable amount
            uint256 maxCoverable = adjustedPrincipal.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
            uint256 capped = rawShortfall > maxCoverable ? maxCoverable : rawShortfall;
            return capped.mulDiv(BPS_DENOMINATOR - deductibleBps, BPS_DENOMINATOR);
        }
        return 0;
    }

    /// @inheritdoc ICoveredVaultWrapper
    // slither-disable-next-line incorrect-equality
    function userShortfall(address user) external view override returns (uint256) {
        uint256 userShares = balanceOf(user);
        if (userShares == 0) return 0;
        uint256 totalShares = totalSupply();
        uint256 morphoTotal = IVaultV2(morphoVault).convertToAssets(IVaultV2(morphoVault).balanceOf(address(this)));
        uint256 accrued = _accruedPremium();
        // Inline netMorphoTotal to free a stack slot for totalPremiumTotal below.
        uint256 userMorphoValue = totalShares > 0
            ? (morphoTotal > accrued ? morphoTotal - accrued : 0).mulDiv(userShares, totalShares, Math.Rounding.Floor)
            : 0;
        // Scale user's adjusted principal using total premium (redeemed + pending accrual).
        // Must match the net Morpho value which already subtracts the same accrued amount;
        // using only totalPremiumRedeemed would cause phantom shortfalls equal to the pending accrual.
        uint256 totalPremiumTotal = totalPremiumRedeemed + accrued;
        uint256 adjustedUserPrincipal = totalPrincipal > 0
            ? userPrincipal[user].mulDiv(
                totalPrincipal > totalPremiumTotal ? totalPrincipal - totalPremiumTotal : 0,
                totalPrincipal,
                Math.Rounding.Floor
            )
            : 0;
        if (adjustedUserPrincipal > userMorphoValue) {
            uint256 raw = adjustedUserPrincipal - userMorphoValue;
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
