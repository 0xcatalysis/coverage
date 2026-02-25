// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ICatalysisCoverAdapter } from "../../interfaces/ICatalysisCoverAdapter.sol";
// aderyn-fp-next-line(unused-import) IAdapter is inherited via ICatalysisCoverAdapter
import { IAdapter } from "../../interfaces/Morpho/IAdapter.sol";
import { IVaultV2 } from "../../interfaces/Morpho/IVaultV2.sol";
import { BasePolicyInteractions } from "../../base/BasePolicyInteractions.sol";
import { ISpec } from "coverage/interfaces/ISpec.sol";
import { IPolicyManager } from "coverage/interfaces/IPolicyManager.sol";
import { IClaimManager } from "coverage/interfaces/IClaimManager.sol";
import { IBindPolicyHook } from "coverage/interfaces/IBindPolicyHook.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IAlerts as IA } from "../../interfaces/IAlerts.sol";
import { IEvents as IE } from "../../interfaces/IEvents.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CatalysisCoverAdapter
/// @notice Morpho Vault V2 adapter that provides NAV-based insurance coverage
/// @dev Architecture:
///      User -> Covered Vault (V2) -> CatalysisCoverAdapter -> Underlying Vault (V1 or V2)
///
///      Flow:
///      1. Curator deploys Covered Vault + this adapter via deployment script
///      2. Policy is created and bound after deployment; onPolicyBound stores the policyId
///      3. Users deposit into Covered Vault (premium via management fee)
///      4. Funds are deployed to Underlying Vault on each user deposit (adapter set as liquidityAdapter)
///      5. On deallocate(), adapter detects per-user NAV loss
///      6. If user's principal exceeds their share of the underlying value and coverage is active:
///         - Burns pro-rata shares from underlying vault
///         - Files insurance claim for user's personal shortfall (capped by maxCoverableLossBps)
///         - Transfers insurance payout directly to the user (bypassing the vault)
///
///      Coverage model:
///      - Tracks per-user principal (userPrincipal[sender]) alongside global aggregate
///      - realAssets() returns pure currentValue() — no insurance baked into share price
///      - Insurance is paid directly to the user on withdrawal, not via vault share price
///      - Maximum coverage is capped at maxCoverableLossBps percent of user's principal
contract CatalysisCoverAdapter is ICatalysisCoverAdapter, BasePolicyInteractions, ReentrancyGuard, IBindPolicyHook {
    using SafeERC20 for IERC20;
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                            CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis points denominator (100% = 10_000)
    // aderyn-fp-next-line(large-numeric-literal) 10_000 is clearer than 1e4 for basis points (100% = 10000 bps)
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Deductible percentage in basis points (1% = 100 bps)
    /// @dev This is deducted from insurance claims - users pay this portion of the loss
    uint256 private constant DEDUCTIBLE_BPS = 100;

    /// @notice Transient storage slot for pending claim amount
    // aderyn-fp-next-line(unused-state-variable) Used in inline assembly with tstore/tload
    uint256 private constant PENDING_CLAIM_AMOUNT_SLOT = 0x1;

    bytes4 private constant DEALLOCATE_SELECTOR = 0x4b219d16;
    bytes4 private constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8;
    bytes4 private constant ALLOCATE_SELECTOR = 0x5c9ce04d;

    /*//////////////////////////////////////////////////////////////
                           IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICatalysisCoverAdapter
    address public immutable override parentVault;

    /// @inheritdoc ICatalysisCoverAdapter
    address public immutable override underlyingVault;

    /// @inheritdoc ICatalysisCoverAdapter
    address public immutable override asset;

    /// @inheritdoc ICatalysisCoverAdapter
    bytes32 public immutable override adapterId;

    /// @notice Deployment timestamp, included in adapterId for uniqueness
    uint256 public immutable override deployTimestamp;

    /// @notice Maximum loss percentage that can be covered (in basis points, e.g., 1000 = 10%)
    uint16 public immutable maxCoverableLossBps;

    /*//////////////////////////////////////////////////////////////
                             STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICatalysisCoverAdapter
    uint256 public override totalPrincipal;

    /// @notice Shares held in the underlying vault
    uint256 public underlyingShares;

    /// @inheritdoc ICatalysisCoverAdapter
    /// @dev Packed with policyBoundExecuted in the same storage slot (12 + 1 = 13 bytes)
    uint96 public override policyId;

    /// @inheritdoc ICatalysisCoverAdapter
    /// @dev Packed with policyId in the same storage slot
    bool public policyBoundExecuted;

    /// @inheritdoc ICatalysisCoverAdapter
    mapping(address => uint256) public override userPrincipal;

    /// @inheritdoc ICatalysisCoverAdapter
    mapping(address => uint256) public override userUnderlyingShares;

    /*//////////////////////////////////////////////////////////////
                             ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAuthorized();
    error InvalidData();
    error AssetMismatch();
    error SameVault();
    error PolicyBoundAlreadyExecuted();

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Validates that caller is parent vault and data is empty
    modifier onlyParentVaultWithEmptyData(
        bytes memory data
    ) {
        if (msg.sender != parentVault) revert NotAuthorized();
        if (data.length != 0) revert InvalidData();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _parentVault The Covered Vault (Morpho V2)
    /// @param _underlyingVault The Underlying Vault (Morpho V1 or V2)
    /// @param _claimManager The ClaimManager contract (policyManager is derived from it)
    /// @param _coverPool The CoverPool contract
    /// @param _maxCoverableLossBps Maximum loss percentage coverable (in basis points, e.g., 1000 = 10%)
    constructor(
        address _parentVault,
        address _underlyingVault,
        address _claimManager,
        address _coverPool,
        uint16 _maxCoverableLossBps
    ) BasePolicyInteractions(IClaimManager(_claimManager).policyManager(), _claimManager, _coverPool) {
        require(_parentVault != address(0), IA.ZeroAddress());
        require(_underlyingVault != address(0), IA.ZeroAddress());
        if (_parentVault == _underlyingVault) revert SameVault();
        require(_maxCoverableLossBps > 0 && _maxCoverableLossBps <= BPS_DENOMINATOR, IA.InvalidMaxCoverableLoss());

        parentVault = _parentVault;
        underlyingVault = _underlyingVault;
        // aderyn-fp-next-line(reentrancy-state-change) Constructor cannot be reentered
        asset = IVaultV2(_parentVault).asset();
        maxCoverableLossBps = _maxCoverableLossBps;
        deployTimestamp = block.timestamp;

        // Verify both vaults use the same underlying asset
        // aderyn-fp-next-line(reentrancy-state-change) Constructor cannot be reentered
        require(asset == IVaultV2(_underlyingVault).asset(), AssetMismatch());

        // Generate unique adapter ID (includes deploy timestamp for cross-deployment uniqueness)
        adapterId =
        // aderyn-fp-next-line(weak-randomness) Deterministic adapter ID, not used for randomness
        keccak256(abi.encodePacked("CatalysisCoverAdapter", _parentVault, _underlyingVault, block.timestamp));
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdapter
    /// @dev Called by parent vault to deploy assets to underlying vault
    /// @dev Tracks per-user principal alongside global aggregate
    /// @dev Returns (ids, delta) where delta = newAllocation - oldAllocation (yield accrued only)
    // slither-disable-next-line reentrancy-benign
    function allocate(
        bytes memory data,
        uint256 assets,
        bytes4 selector,
        address sender
    ) external override nonReentrant onlyParentVaultWithEmptyData(data) returns (bytes32[] memory, int256) {
        if (assets > 0) {
            // Approve exact amount before depositing into underlying vault
            IERC20(asset).forceApprove(underlyingVault, assets);
            // Use shares output instead of checking share balance delta, since ERC4626 guarantees
            // to return the exact amount of minted shares.
            // aderyn-fp-next-line(reentrancy-state-change) Protected by nonReentrant modifier
            uint256 shares = IERC4626(underlyingVault).deposit(assets, address(this));
            underlyingShares += shares;
            totalPrincipal += assets;

            if (selector != ALLOCATE_SELECTOR) {
                // Tracking per-user principal and shares only during user operations such as deposit / mint
                userPrincipal[sender] += assets;
                userUnderlyingShares[sender] += shares;
            }
        }

        // Read allocation AFTER deposit - matches Morpho's approach
        // This returns delta between previous and current allocation
        // to the Underlying Vault
        uint256 oldAllocation = allocation();
        uint256 newAllocation =
            IERC4626(underlyingVault).previewRedeem(IERC4626(underlyingVault).balanceOf(address(this)));

        emit IE.NavRecorded(sender, assets, underlyingShares, totalPrincipal);

        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @inheritdoc IAdapter
    /// @dev Called by parent vault to withdraw assets from underlying vault
    /// @dev If sender has tracked principal and a shortfall exists, insurance is paid directly to sender
    /// @dev Returns (ids, delta) where delta = newAllocation - oldAllocation (yield accrued only)
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,events-maths
    function deallocate(
        bytes memory data,
        uint256 assets,
        bytes4 selector,
        address sender
    ) external override nonReentrant onlyParentVaultWithEmptyData(data) returns (bytes32[] memory, int256) {
        if (assets > 0) {
            // aderyn-fp-next-line(reentrancy-state-change) Only called by trusted parentVault via nonReentrant +
            // onlyParentVaultWithEmptyData
            if (
                (selector == DEALLOCATE_SELECTOR || selector == FORCE_DEALLOCATE_SELECTOR)
                    || sender == IVaultV2(parentVault).managementFeeRecipient()
            ) {
                // case 1. Operation is deallocate / force deallocate or sender is management fee recipient.
                // Withdraw assets and proportionally decrease total principal.
                // In this case, do not modify per-user principal.
                // Coverage is not requested in this case as deallocate or force deallocate should be used only in case
                // of emergency.
                // Note! We treat management fee recipient specially because he doesn't have per-user principal stored
                // and shouldn't receive coverage.
                uint256 currentVal = currentValue();
                // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
                // aderyn-fp-next-line(reentrancy-state-change) Trusted underlyingVault set in constructor
                uint256 sharesToBurn = IERC4626(underlyingVault).withdraw(assets, address(this), address(this));
                // slither-disable-next-line events-maths
                underlyingShares -= sharesToBurn;
                uint256 principalDecrease = totalPrincipal.mulDiv(assets, currentVal);
                if (principalDecrease > totalPrincipal) principalDecrease = totalPrincipal;
                // slither-disable-next-line events-maths
                totalPrincipal -= principalDecrease;

                // Force full withdrawal on deallocations
                if (selector == DEALLOCATE_SELECTOR || selector == FORCE_DEALLOCATE_SELECTOR) {
                    require(totalPrincipal == 0, IA.WithdrawAllOnlyDuringDealoc());
                }
            } else if (
                // Validate that user doesn't withdraw more than his principal by comparing
                // his underlying shares balance with share value of `assets`.
                userPrincipal[sender] > 0
                    && IERC4626(underlyingVault).previewWithdraw(assets) <= userUnderlyingShares[sender]
            ) {
                // case 2. User withdraws and receives insurance payout in case of shortfall.
                _withdraw(assets, sender);
            } else {
                revert IA.UnsupportedDeallocation(assets, selector, sender);
            }

            // Approve exact amount for parent vault to pull back
            IERC20(asset).forceApprove(parentVault, assets);
        }

        // Read allocation AFTER withdraw - matches Morpho's approach
        // This returns delta from yield only, not from the withdrawal itself
        uint256 oldAllocation = allocation();
        uint256 newAllocation =
            IERC4626(underlyingVault).previewRedeem(IERC4626(underlyingVault).balanceOf(address(this)));

        return (ids(), int256(newAllocation) - int256(oldAllocation));
    }

    /// @inheritdoc ICatalysisCoverAdapter
    /// @dev Only callable by PolicyManager, and only once.
    ///      Calculates the absolute cap for the adapter based on coverage limit:
    ///        absoluteCap = (BPS_DENOMINATOR / maxCoverableLossBps) * coverageLimit
    ///      Then calls submit + increaseAbsoluteCap on the parent vault.
    ///      Requires the adapter to have the Curator role on the parent vault.
    /// @dev Deposits to the Parent Vault should not be possible until the hook is executed.
    ///      Absolute cap should be 0 until the hook is executed.
    // slither-disable-next-line reentrancy-events
    function onPolicyBound(
        uint96 _policyId,
        uint256 coverageLimit
    ) external override(IBindPolicyHook, ICatalysisCoverAdapter) {
        if (msg.sender != address(_policyManager)) revert NotAuthorized();
        if (policyBoundExecuted) revert PolicyBoundAlreadyExecuted();

        // Validate bound policy parameters (deferred from constructor to resolve chicken-and-egg)
        // aderyn-fp-next-line(reentrancy-state-change) Only callable by trusted PolicyManager, executed once
        IPolicyManager.PolicyMetadata memory pol = _policyManager.policyMetadata(_policyId);
        // aderyn-fp-next-line(reentrancy-state-change) Only callable by trusted PolicyManager, executed once
        if (pol.buyer != IVaultV2(parentVault).owner()) revert InvalidData();
        if (pol.pool != address(coverPool)) revert InvalidData();
        if (pol.claimer != address(this)) revert InvalidData();
        if (pol.payoutToken != asset) revert InvalidData();

        policyId = _policyId;
        policyBoundExecuted = true;

        // Calculate absolute cap: total assets the vault can hold for this adapter
        // If maxCoverableLossBps is 10% (1000) and coverageLimit is 100, cap = 10 * 100 = 1000
        // slither-disable-next-line divide-before-multiply
        uint256 absoluteCap = (BPS_DENOMINATOR / uint256(maxCoverableLossBps)) * coverageLimit;

        // Construct idData matching the adapterId encoding
        bytes memory _idData = abi.encodePacked("CatalysisCoverAdapter", parentVault, underlyingVault, deployTimestamp);

        // Submit and execute increaseAbsoluteCap on parent vault (requires Curator role)
        bytes memory data = abi.encodeWithSignature("increaseAbsoluteCap(bytes,uint256)", _idData, absoluteCap);
        // slither-disable-next-line reentrancy-events
        IVaultV2(parentVault).submit(data);
        IVaultV2(parentVault).increaseAbsoluteCap(_idData, absoluteCap);

        emit IE.PolicyBound(address(this), _policyId);
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) external pure returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /*//////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICatalysisCoverAdapter
    function policyManager() external view override returns (address) {
        return address(_policyManager);
    }

    /// @inheritdoc ICatalysisCoverAdapter
    function idData() external view override returns (bytes memory) {
        return abi.encodePacked("CatalysisCoverAdapter", parentVault, underlyingVault, deployTimestamp);
    }

    /// @inheritdoc IAdapter
    /// @notice Returns the current value of all underlying shares
    /// @dev Insurance is NOT baked into the share price. Users receive insurance directly
    ///      on withdrawal via _withdraw() rather than through vault share price appreciation.
    function realAssets() external view override returns (uint256) {
        return currentValue();
    }

    /// @inheritdoc ICatalysisCoverAdapter
    /// @dev Returns the global shortfall capped by maxCoverableLossBps
    // slither-disable-next-line incorrect-equality
    function calculateShortfall() external view override returns (uint256) {
        if (totalPrincipal == 0) return 0;

        uint256 value = currentValue();
        if (totalPrincipal > value) {
            uint256 rawShortfall = totalPrincipal - value;
            uint256 maxCoverableLoss = (totalPrincipal * maxCoverableLossBps) / BPS_DENOMINATOR;
            return rawShortfall > maxCoverableLoss ? maxCoverableLoss : rawShortfall;
        }
        return 0;
    }

    /// @inheritdoc ICatalysisCoverAdapter
    // slither-disable-next-line incorrect-equality
    function userShortfall(
        address user
    ) external view override returns (uint256) {
        if (userUnderlyingShares[user] == 0) return 0;
        uint256 userCurrentValue = IERC4626(underlyingVault).convertToAssets(userUnderlyingShares[user]);
        if (userPrincipal[user] > userCurrentValue) {
            uint256 rawShortfall = userPrincipal[user] - userCurrentValue;
            uint256 maxCoverableLoss = userPrincipal[user].mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
            return rawShortfall > maxCoverableLoss ? maxCoverableLoss : rawShortfall;
        }
        return 0;
    }

    /// @notice Called by ClaimManager to evaluate a claim
    /// @dev Part of ISpec implementation
    function evaluate(
        ISpec.EvaluationContext calldata context
    ) external view override returns (ISpec.EvaluationResult memory result) {
        (, uint256 pendingClaimAmount, bool hasPendingClaim) = _getPendingClaim();
        (address claimant, uint256 claimedAmount) = abi.decode(context.additionalData, (address, uint256));

        if (!hasPendingClaim || policyId != context.policyId) {
            return ISpec.EvaluationResult({
                isPayable: false, notesHash: keccak256(abi.encodePacked("No pending claim from adapter"))
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
                     PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICatalysisCoverAdapter
    function ids() public view override returns (bytes32[] memory) {
        bytes32[] memory _ids = new bytes32[](1);
        _ids[0] = adapterId;
        return _ids;
    }

    /// @inheritdoc ICatalysisCoverAdapter
    function allocation() public view override returns (uint256) {
        return IVaultV2(parentVault).allocation(adapterId);
    }

    /// @inheritdoc ICatalysisCoverAdapter
    // slither-disable-next-line incorrect-equality
    function currentValue() public view override returns (uint256) {
        if (underlyingShares == 0) return 0;
        return IERC4626(underlyingVault).previewRedeem(underlyingShares);
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Execute withdrawal with per-user insurance paid directly to sender
    /// @dev Burns pro-rata shares from underlying vault (proportional to assets/currentValue).
    ///      If sender has tracked principal and a shortfall exists, claims insurance and
    ///      transfers payout directly to sender (not through the vault).
    ///      Returns assetsFromUnderlying — the vault pulls this amount via pre-approval.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign,incorrect-equality
    function _withdraw(
        uint256 assets,
        address sender
    ) internal {
        uint256 currentVal = currentValue();
        if (currentVal == 0) return;

        // Burn pro-rata shares from underlying vault based on currentValue (not protected value)
        // Use withdraw(assets) rather than redeem(sharesToBurn) to guarantee the adapter
        // receives exactly `assets` tokens.  redeem(sharesToBurn) applies two consecutive
        // floors — once when computing sharesToBurn and again inside redeem — which can
        // leave the adapter 1 wei short of what the parent vault tries to pull back via
        // transferFrom, causing an ERC20 balance revert.
        uint256 sharesToBurn = IERC4626(underlyingVault).withdraw(assets, address(this), address(this));
        underlyingShares -= sharesToBurn;

        // Sender has tracked shares — use per-user path
        uint256 userPrincipalForWithdrawal = userPrincipal[sender].mulDiv(sharesToBurn, userUnderlyingShares[sender]);
        require(
            userPrincipalForWithdrawal <= totalPrincipal,
            IA.ExceedsTotalPrincipal(userPrincipalForWithdrawal, totalPrincipal)
        );
        userPrincipal[sender] -= userPrincipalForWithdrawal;
        userUnderlyingShares[sender] -= sharesToBurn;
        totalPrincipal -= userPrincipalForWithdrawal;

        // Per-user insurance: only if sender has tracked principal and policy is active
        uint256 insurancePayout;
        if (userPrincipalForWithdrawal > 0 && _isPolicyActive()) {
            uint256 shortfall = userPrincipalForWithdrawal > assets ? userPrincipalForWithdrawal - assets : 0;
            if (shortfall > 0) {
                uint256 maxInsurance = userPrincipalForWithdrawal.mulDiv(maxCoverableLossBps, BPS_DENOMINATOR);
                uint256 effectiveInsurance = maxInsurance.mulDiv(BPS_DENOMINATOR - DEDUCTIBLE_BPS, BPS_DENOMINATOR);
                uint256 claimAmount = shortfall < effectiveInsurance ? shortfall : effectiveInsurance;
                if (claimAmount > 0) {
                    insurancePayout = _claimInsurance(claimAmount, sender);
                    if (insurancePayout > 0) {
                        IERC20(asset).safeTransfer(sender, insurancePayout);
                    }
                }
            }
        }

        emit IE.NavWithdrawn(sender, assets, sharesToBurn, insurancePayout, totalPrincipal);
    }

    /// @notice Claims insurance for a shortfall
    /// @param shortfall The shortfall amount
    /// @param sender Address for coverage payment
    /// @return payout The insurance payout amount
    function _claimInsurance(
        uint256 shortfall,
        address sender
    ) internal returns (uint256 payout) {
        (uint256 coverageLimit, address payoutToken) = _getCoverageParams(policyId);

        // Calculate remaining coverage (coverageLimit - already paid out)
        uint256 paidOut = _getPaidCover(policyId);
        uint256 remainingCoverage = coverageLimit > paidOut ? coverageLimit - paidOut : 0;

        // Cap claim at remaining coverage
        uint256 cappedShortfall = shortfall > remainingCoverage ? remainingCoverage : shortfall;

        if (cappedShortfall == 0) {
            return 0;
        }

        uint256 balanceBefore = IERC20(payoutToken).balanceOf(address(this));

        _setPendingClaim(policyId, cappedShortfall);

        // aderyn-fp-next-line(weak-randomness) evidenceHash is for claim identification, not security-critical
        bytes32 evidenceHash = keccak256(abi.encodePacked(sender, policyId, cappedShortfall, block.timestamp));
        // aderyn-fp-next-line(unchecked-return) ClaimId not needed - success determined via balance change
        _fileAndResolveClaim(policyId, cappedShortfall, evidenceHash, abi.encode(address(this), cappedShortfall));

        _clearPendingClaim();

        uint256 balanceAfter = IERC20(payoutToken).balanceOf(address(this));
        payout = balanceAfter - balanceBefore;

        emit IE.InsuranceClaimed(sender, policyId, shortfall, payout);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks if policy is bound and not expired
    /// @return True if policy is active and coverage applies
    function _isPolicyActive() internal view returns (bool) {
        if (policyId == 0) return false;
        IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
        return metadata.buyer != address(0) && block.timestamp >= metadata.startTime
            && block.timestamp <= metadata.maturityTime;
    }

    /*//////////////////////////////////////////////////////////////
                    PRIVATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setPendingClaim(
        uint256,
        uint256 amount
    ) private {
        assembly {
            tstore(PENDING_CLAIM_AMOUNT_SLOT, amount)
        }
    }

    function _getPendingClaim() private view returns (uint256 _policyId, uint256 amount, bool hasPendingClaim) {
        assembly {
            amount := tload(PENDING_CLAIM_AMOUNT_SLOT)
            hasPendingClaim := gt(amount, 0)
        }
        _policyId = policyId;
    }

    function _clearPendingClaim() private {
        assembly {
            tstore(PENDING_CLAIM_AMOUNT_SLOT, 0)
        }
    }
}
