// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChainlinkPriceFeed} from "./interfaces/IChainlinkPriceFeed.sol";
import {IClaimManager} from "./interfaces/IClaimManager.sol";
import {IPolicyManager} from "./interfaces/IPolicyManager.sol";
import {ISpec} from "./interfaces/ISpec.sol";
import {ISpecRegistry} from "./interfaces/ISpecRegistry.sol";
import {ISlashingManager} from "./interfaces/ISlashingManager.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/**
 * @title ClaimManager
 * @notice Orchestrates parametric claim processing by evaluating product specs, coordinating slashing,
 *         swapping collateral, and settling payouts to beneficiaries.
 * @dev Integrates with:
 *      - PolicyManager: Fetches policy metadata and coverage parameters
 *      - SpecRegistry: Resolves product-specific evaluation logic
 *      - SlashingManager (Core): Executes stake slashing for approved claims
 *      - Swapper: Converts slashed collateral to payout tokens
 *
 *      Claim Flow:
 *      fileClaim: Authorized claimer atomically files and resolves claim → evaluates Spec → if approved:
 *      slash stake → swap collateral → payout
 */
// slither-disable-next-line unimplemented-functions
contract ClaimManager is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuard,
    IClaimManager
{
    using SafeERC20 for IERC20;

    address public override specRegistry;
    address public override slashingManager;
    address public override swapper;
    address public override policyManager;
    address public override chainlinkPriceFeed;

    mapping(uint96 policyId => mapping(uint256 claimId => ClaimRecord)) private _claims;
    mapping(uint96 policyId => PolicyClaim) private _policyClaims;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the ClaimManager with role assignments and dependency wiring.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param specRegistry_ Address of the SpecRegistry contract.
     * @param slashingManager_ Address of the SlashingManager contract.
     * @param swapper_ Address of the Swapper contract.
     * @param policyManager_ Address of the PolicyManager contract.
     * @param chainlinkPriceFeed_ Address of the ChainlinkPriceFeed contract.
     */
    function initialize(
        address admin_,
        address specRegistry_,
        address slashingManager_,
        address swapper_,
        address policyManager_,
        address chainlinkPriceFeed_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && specRegistry_ != address(0) && slashingManager_ != address(0)
                && swapper_ != address(0) && policyManager_ != address(0) && chainlinkPriceFeed_ != address(0),
            ZeroAddress()
        );

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        specRegistry = specRegistry_;
        slashingManager = slashingManager_;
        swapper = swapper_;
        policyManager = policyManager_;
        chainlinkPriceFeed = chainlinkPriceFeed_;
    }

    /**
     * @inheritdoc IClaimManager
     */
    function pause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @inheritdoc IClaimManager
     */
    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setSpecRegistry(address specRegistry_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(specRegistry_ != address(0), ZeroAddress());
        specRegistry = specRegistry_;
        emit SpecRegistrySet(specRegistry_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setSlashingManager(address slashingManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(slashingManager_ != address(0), ZeroAddress());
        slashingManager = slashingManager_;
        emit SlashingManagerSet(slashingManager_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setSwapper(address swapper_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(swapper_ != address(0), ZeroAddress());
        swapper = swapper_;
        emit SwapperSet(swapper_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setPolicyManager(address policyManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(policyManager_ != address(0), ZeroAddress());
        policyManager = policyManager_;
        emit PolicyManagerSet(policyManager_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setChainlinkPriceFeed(address chainlinkPriceFeed_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(chainlinkPriceFeed_ != address(0), ZeroAddress());
        chainlinkPriceFeed = chainlinkPriceFeed_;
        emit ChainlinkPriceFeedSet(chainlinkPriceFeed_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function fileClaim(
        uint96 policyId,
        uint256 requestedAmount,
        bytes32 evidenceHash,
        bytes calldata additionalData
    )
        external
        override
        whenNotPaused
        nonReentrant
        returns (uint256 claimId)
    {
        IPolicyManager.PolicyMetadata memory metadata;

        (claimId, metadata) = _fileClaimWithMetadata(policyId, requestedAmount, evidenceHash);
        require(msg.sender == metadata.claimer, UnauthorizedClaimer(msg.sender, metadata.claimer));

        ClaimRecord storage claim = _claims[policyId][claimId];
        ISpec.EvaluationResult memory result = _evaluateSpec(policyId, metadata, evidenceHash, additionalData);

        claim.evaluationResult = result;
        claim.resolvedAt = block.timestamp;

        if (!result.isPayable) {
            claim.status = ClaimStatus.Rejected;
            emit ClaimRejected(policyId, claimId, "Spec evaluation failed", block.timestamp);
            return claimId;
        }

        claim.status = ClaimStatus.Approved;

        uint256 totalPayout = _capAndExecutePayout(policyId, claimId, metadata, requestedAmount);
        require(totalPayout > 0, ZeroPayoutAmount(policyId));
        // slither-disable-next-line reentrancy-no-eth
        claim.payoutAmount = totalPayout;

        emit ClaimApproved(policyId, claimId, metadata.payoutReceiver, totalPayout, block.timestamp);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function claimRecord(uint96 policyId, uint256 claimId) external view override returns (ClaimRecord memory) {
        return _claims[policyId][claimId];
    }

    /**
     * @inheritdoc IClaimManager
     */
    function policyClaim(uint96 policyId) external view override returns (PolicyClaim memory) {
        return _policyClaims[policyId];
    }

    /**
     * @inheritdoc IClaimManager
     */
    function remainingCoverage(uint96 policyId) external view override returns (uint256) {
        IPolicyManager.PolicyMetadata memory metadata = IPolicyManager(policyManager).policyMetadata(policyId);
        uint256 totalPaidOut = _policyClaims[policyId].totalPaidOut;
        return totalPaidOut >= metadata.coverageLimit ? 0 : metadata.coverageLimit - totalPaidOut;
    }

    /**
     * @inheritdoc IClaimManager
     */
    function paused() public view override (IClaimManager, PausableUpgradeable) returns (bool) {
        return super.paused();
    }

    /**
     * @notice Restricts UUPS upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal view override onlyRole(DEFAULT_ADMIN_ROLE) {}

    /**
     * @notice Internal helper for filing a claim and returning metadata to avoid double fetch.
     * @param policyId Identifier of the policy to claim against.
     * @param requestedAmount Requested payout amount in payout token terms.
     * @param evidenceHash Hash of evidence supporting the claim.
     * @return claimId Unique identifier for the filed claim.
     * @return metadata Policy metadata for subsequent resolution.
     */
    function _fileClaimWithMetadata(
        uint96 policyId,
        uint256 requestedAmount,
        bytes32 evidenceHash
    )
        private
        returns (uint256 claimId, IPolicyManager.PolicyMetadata memory metadata)
    {
        require(evidenceHash != bytes32(0), InvalidEvidenceHash());
        require(requestedAmount > 0, ZeroAmount());

        metadata = IPolicyManager(policyManager).policyMetadata(policyId);
        require(metadata.buyer != address(0), PolicyNotFound(policyId));

        uint256 totalPaidOut = _policyClaims[policyId].totalPaidOut;
        uint256 remaining = totalPaidOut >= metadata.coverageLimit ? 0 : metadata.coverageLimit - totalPaidOut;

        require(
            requestedAmount <= remaining, RequestedAmountExceedsRemainingCoverage(policyId, requestedAmount, remaining)
        );

        require(
            block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime,
            ClaimOutsideCoverageWindow(policyId, metadata.startTime, metadata.maturityTime, block.timestamp)
        );

        claimId = _policyClaims[policyId].claimCount;
        ClaimRecord storage claim = _claims[policyId][claimId];
        require(claim.status == ClaimStatus.None, ClaimAlreadyFiled(policyId, claimId));

        claim.status = ClaimStatus.Filed;
        claim.reporter = msg.sender;
        claim.filedAt = block.timestamp;
        claim.evidenceHash = evidenceHash;
        claim.requestedAmount = requestedAmount;

        _policyClaims[policyId].claimCount++;

        emit ClaimFiled(policyId, claimId, msg.sender, evidenceHash, requestedAmount, block.timestamp);
    }

    /**
     * @notice Caps payout to remaining coverage and executes payout, handling concurrent over-claiming.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @param metadata Policy metadata containing coverage limit and payout details.
     * @param requestedAmount Originally requested payout amount.
     * @return totalPayout Actual amount paid out (may be less if coverage exhausted).
     */
    function _capAndExecutePayout(
        uint96 policyId,
        uint256 claimId,
        IPolicyManager.PolicyMetadata memory metadata,
        uint256 requestedAmount
    )
        private
        returns (uint256 totalPayout)
    {
        uint256 totalPaidOut = _policyClaims[policyId].totalPaidOut;
        uint256 remaining = totalPaidOut >= metadata.coverageLimit ? 0 : metadata.coverageLimit - totalPaidOut;
        uint256 cappedAmount = requestedAmount > remaining ? remaining : requestedAmount;

        if (cappedAmount > 0) {
            _policyClaims[policyId].totalPaidOut += cappedAmount;
            totalPayout = _executeSlashingAndPayout(policyId, claimId, metadata, cappedAmount);

            if (totalPayout < cappedAmount) {
                // slither-disable-next-line reentrancy-no-eth
                _policyClaims[policyId].totalPaidOut -= (cappedAmount - totalPayout);
            }
        }
    }

    /**
     * @notice Executes slashing and collateral swapping for payout directly without.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @param metadata Policy metadata containing committeeId, operator, and payout details.
     * @param requestedAmount Maximum amount to disburse (in payout token terms).
     * @return totalPayout Total amount paid out from slashing.
     */
    function _executeSlashingAndPayout(
        uint96 policyId,
        uint256 claimId,
        IPolicyManager.PolicyMetadata memory metadata,
        uint256 requestedAmount
    )
        private
        returns (uint256 totalPayout)
    {
        // slither-disable-next-line calls-loop
        uint256 slashAmountUSD =
            IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(metadata.payoutToken, requestedAmount);

        // slither-disable-next-line calls-loop
        (address[] memory collateralTokens, uint256[] memory collateralAmounts) =
            ISlashingManager(slashingManager).executeSlashing(metadata.committeeId, metadata.operator, slashAmountUSD);

        uint256 tokensLength = collateralTokens.length;
        // slither-disable-next-line incorrect-equality
        require(tokensLength > 0 && tokensLength == collateralAmounts.length, NoCollateralSlashed(policyId));

        uint256 remainingPayout = requestedAmount;
        for (uint256 i = 0; i < tokensLength && remainingPayout > 0; ++i) {
            if (collateralAmounts[i] > 0) {
                uint256 amountOut = _processCollateral(
                    policyId,
                    claimId,
                    collateralTokens[i],
                    collateralAmounts[i],
                    metadata.payoutToken,
                    metadata.payoutReceiver,
                    remainingPayout
                );
                totalPayout += amountOut;
                remainingPayout = remainingPayout > amountOut ? remainingPayout - amountOut : 0;
            }
        }

        require(totalPayout > 0, ZeroPayoutAmount(policyId));
    }

    /**
     * @notice Processes collateral by swapping or transferring directly with cap.
     * @param policyId Identifier of the policy (for events).
     * @param claimId Identifier of the claim (for events).
     * @param collateralToken Address of the slashed collateral token.
     * @param collateralAmount Amount of collateral to process.
     * @param payoutToken Desired payout token address.
     * @param payoutReceiver Address to receive the payout.
     * @param remainingPayout Maximum payout amount still needed.
     * @return amountOut Amount of payout token delivered (capped at remainingPayout).
     */
    function _processCollateral(
        uint96 policyId,
        uint256 claimId,
        address collateralToken,
        uint256 collateralAmount,
        address payoutToken,
        address payoutReceiver,
        uint256 remainingPayout
    )
        private
        returns (uint256 amountOut)
    {
        if (collateralToken == payoutToken) {
            uint256 transferAmount = collateralAmount > remainingPayout ? remainingPayout : collateralAmount;
            IERC20(collateralToken).safeTransfer(payoutReceiver, transferAmount);
            amountOut = transferAmount;
        } else {
            IERC20(collateralToken).forceApprove(swapper, collateralAmount);

            ISwapper.SwapParams memory swapParams = ISwapper.SwapParams({
                tokenIn: collateralToken,
                tokenOut: payoutToken,
                amountIn: collateralAmount,
                amountOutMin: 1,
                recipient: address(this),
                swapCalldata: ""
            });

            // slither-disable-next-line calls-loop
            uint256 swapOutput = ISwapper(swapper).executeSwap(swapParams);

            amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput;
            IERC20(payoutToken).safeTransfer(payoutReceiver, amountOut);

            IERC20(collateralToken).forceApprove(swapper, 0);
        }

        emit CollateralSwapped(policyId, claimId, collateralToken, collateralAmount, payoutToken, amountOut);
    }

    /**
     * @notice Evaluates the Spec for a given policy.
     * @param policyId Identifier of the policy.
     * @param metadata Policy metadata from Policy contract.
     * @param evidenceHash Hash of evidence submitted with the claim.
     * @param additionalData Additional context data for Spec evaluation.
     * @return result Evaluation outcome from the Spec.
     */
    function _evaluateSpec(
        uint96 policyId,
        IPolicyManager.PolicyMetadata memory metadata,
        bytes32 evidenceHash,
        bytes calldata additionalData
    )
        private
        view
        returns (ISpec.EvaluationResult memory result)
    {
        ISpec spec = ISpecRegistry(specRegistry).resolveSpec(metadata.pool, metadata.specId);

        ISpec.EvaluationContext memory context = ISpec.EvaluationContext({
            policyId: policyId,
            pool: metadata.pool,
            coverageLimit: metadata.coverageLimit,
            startTime: metadata.startTime,
            maturityTime: metadata.maturityTime,
            evaluationTime: block.timestamp,
            evidenceHash: evidenceHash,
            additionalData: additionalData
        });

        result = spec.evaluate(context);
    }
}
