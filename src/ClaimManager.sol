// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
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
    using Address for address payable;
    using SafeERC20 for IERC20;

    uint16 private constant _MAX_SLIPPAGE_BPS = 10_000;
    address private constant _NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 private constant MAX_COLLATERAL_ENTRIES = 20;

    address public override specRegistry;
    address public override slashingManager;
    address public override swapper;
    address public override policyManager;
    address public override chainlinkPriceFeed;
    address public override excessCollateralRecipient;
    uint16 public override maxSwapSlippageBps;

    mapping(uint96 policyId => mapping(uint256 claimId => ClaimRecord)) private _claims;
    mapping(uint96 policyId => PolicyClaim) private _policyClaims;
    mapping(uint96 policyId => bool) private _claimApprovalRequired;
    mapping(uint96 policyId => mapping(bytes32 evidenceHash => bool used)) private _usedEvidenceHashes;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Allows the ClaimManager to receive native ETH.
     */
    receive() external payable {}

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
        maxSwapSlippageBps = 200; // 2%
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
    function setMaxSwapSlippageBps(uint16 maxSwapSlippageBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxSwapSlippageBps_ < _MAX_SLIPPAGE_BPS, InvalidSlippageBps(maxSwapSlippageBps_));
        maxSwapSlippageBps = maxSwapSlippageBps_;
        emit MaxSwapSlippageBpsSet(maxSwapSlippageBps_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setExcessCollateralRecipient(address recipient_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(recipient_ != address(0), ZeroAddress());
        excessCollateralRecipient = recipient_;
        emit ExcessCollateralRecipientSet(recipient_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function recoverTokens(address token, address to, uint256 amount) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0) && to != address(0), ZeroAddress());
        require(amount != 0, ZeroAmount());
        _transferToken(token, to, amount);
        emit TokensRecovered(token, to, amount);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function approveNextClaim(uint96 policyId) external override {
        IPolicyManager.PolicyMetadata memory metadata = IPolicyManager(policyManager).policyMetadata(policyId);
        require(metadata.buyer != address(0), PolicyNotFound(policyId));
        require(msg.sender == ICoverPool(metadata.pool).owner(), UnauthorizedApprover());
        _claimApprovalRequired[policyId] = false;
        emit NextClaimApproved(policyId, msg.sender);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function claimApprovalRequired(uint96 policyId) external view override returns (bool) {
        return _claimApprovalRequired[policyId];
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
        require(!_claimApprovalRequired[policyId], ClaimApprovalRequired(policyId));

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
        // slither-disable-next-line reentrancy-eth,reentrancy-no-eth
        claim.payoutAmount = totalPayout;
        // slither-disable-next-line reentrancy-eth,reentrancy-no-eth
        _claimApprovalRequired[policyId] = true;

        emit ClaimApproved(policyId, claimId, metadata.beneficiary, totalPayout, block.timestamp);
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
        require(requestedAmount > 0, ZeroAmount());
        require(evidenceHash != bytes32(0), InvalidEvidenceHash());
        require(!_usedEvidenceHashes[policyId][evidenceHash], DuplicateEvidenceHash(policyId, evidenceHash));

        metadata = IPolicyManager(policyManager).policyMetadata(policyId);
        require(metadata.buyer != address(0), PolicyNotFound(policyId));
        require(!metadata.premiumDefaulted, PremiumDefaulted(policyId));

        uint256 totalPaidOut = _policyClaims[policyId].totalPaidOut;
        uint256 remaining = totalPaidOut >= metadata.coverageLimit ? 0 : metadata.coverageLimit - totalPaidOut;

        require(
            requestedAmount <= remaining, RequestedAmountExceedsRemainingCoverage(policyId, requestedAmount, remaining)
        );

        require(
            block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime,
            ClaimOutsideCoverageWindow(policyId, metadata.startTime, metadata.maturityTime, uint32(block.timestamp))
        );

        _usedEvidenceHashes[policyId][evidenceHash] = true;

        claimId = _policyClaims[policyId].claimCount;
        ClaimRecord storage claim = _claims[policyId][claimId];

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
                // slither-disable-next-line reentrancy-eth,reentrancy-no-eth
                _policyClaims[policyId].totalPaidOut -= (cappedAmount - totalPayout);
            }
        }
    }

    /**
     * @notice Executes slashing and collateral swapping for payout directly.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @param metadata Policy metadata containing policyId and payout details.
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

        // taskId is deterministic per (policyId, claimId) pair to prevent replay attacks.
        // slither-disable-next-line calls-loop
        (address[] memory collateralTokens, uint256[] memory collateralAmounts) = ISlashingManager(slashingManager)
            .executeSlashing(
                metadata.policyId,
                metadata.curator,
                slashAmountUSD,
                keccak256(abi.encodePacked(metadata.policyId, claimId))
            );

        uint256 tokensLength = collateralTokens.length;
        // slither-disable-next-line incorrect-equality
        require(tokensLength > 0 && tokensLength == collateralAmounts.length, NoCollateralSlashed(policyId));
        require(tokensLength <= MAX_COLLATERAL_ENTRIES, TooManyCollateralEntries(tokensLength));

        uint256 remainingPayout = requestedAmount;
        for (uint256 i = 0; i < tokensLength && remainingPayout > 0; ++i) {
            if (collateralAmounts[i] > 0) {
                uint256 amountOut = _processCollateral(
                    policyId,
                    claimId,
                    collateralTokens[i],
                    collateralAmounts[i],
                    metadata.payoutToken,
                    metadata.beneficiary,
                    remainingPayout
                );
                totalPayout += amountOut;
                remainingPayout = remainingPayout > amountOut ? remainingPayout - amountOut : 0;
            }
        }

        _sweepExcessTokens(collateralTokens, tokensLength, metadata.payoutToken);

        require(totalPayout > 0, ZeroPayoutAmount(policyId));
    }

    /**
     * @notice Sweeps any leftover collateral and payout token balances to the configured
     *         excess recipient. No-op when no recipient is set.
     * @param collateralTokens Collateral token addresses returned from slashing.
     * @param tokensLength Length of the collateral token array.
     * @param payoutToken Payout token address for the policy.
     */
    function _sweepExcessTokens(
        address[] memory collateralTokens,
        uint256 tokensLength,
        address payoutToken
    )
        private
    {
        address excessRecipient = excessCollateralRecipient;
        if (excessRecipient == address(0)) return;

        for (uint256 i = 0; i < tokensLength; ++i) {
            uint256 strandedBalance = IERC20(collateralTokens[i]).balanceOf(address(this));
            if (strandedBalance > 0) {
                IERC20(collateralTokens[i]).safeTransfer(excessRecipient, strandedBalance);
            }
        }
        uint256 excessPayout = IERC20(payoutToken).balanceOf(address(this));
        if (excessPayout > 0) {
            IERC20(payoutToken).safeTransfer(excessRecipient, excessPayout);
        }
    }

    /**
     * @notice Processes collateral by swapping or transferring directly with cap.
     * @param policyId Identifier of the policy (for events).
     * @param claimId Identifier of the claim (for events).
     * @param collateralToken Address of the slashed collateral token.
     * @param collateralAmount Amount of collateral to process.
     * @param payoutToken Desired payout token address.
     * @param beneficiary Address to receive the payout.
     * @param remainingPayout Maximum payout amount still needed.
     * @return amountOut Amount of payout token delivered (capped at remainingPayout).
     */
    // slither-disable-start calls-loop
    function _processCollateral(
        uint96 policyId,
        uint256 claimId,
        address collateralToken,
        uint256 collateralAmount,
        address payoutToken,
        address beneficiary,
        uint256 remainingPayout
    )
        private
        returns (uint256 amountOut)
    {
        if (collateralToken == payoutToken) {
            uint256 transferAmount = collateralAmount > remainingPayout ? remainingPayout : collateralAmount;
            _transferToken(collateralToken, beneficiary, transferAmount);
            amountOut = transferAmount;
        } else {
            _approveIfERC20(collateralToken, swapper, collateralAmount);

            uint256 collateralUSD =
                IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(collateralToken, collateralAmount);
            uint256 expectedOut = IChainlinkPriceFeed(chainlinkPriceFeed).getTokenAmount(payoutToken, collateralUSD);
            uint256 slippageBps = maxSwapSlippageBps;
            uint256 amountOutMin = expectedOut * (10_000 - slippageBps) / 10_000;
            if (amountOutMin == 0) {
                amountOutMin = 1;
            }

            ISwapper.SwapParams memory swapParams = ISwapper.SwapParams({
                tokenIn: collateralToken,
                tokenOut: payoutToken,
                amountIn: collateralAmount,
                amountOutMin: amountOutMin,
                recipient: address(this),
                swapCalldata: "",
                deadline: block.timestamp
            });

            // slither-disable-next-line arbitrary-send-eth
            uint256 swapOutput =
                ISwapper(swapper).executeSwap{value: collateralToken == _NATIVE_ETH ? collateralAmount : 0}(swapParams);

            amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput;
            _transferToken(payoutToken, beneficiary, amountOut);

            _approveIfERC20(collateralToken, swapper, 0);
        }

        emit CollateralSwapped(policyId, claimId, collateralToken, collateralAmount, payoutToken, amountOut);
    }

    // slither-disable-end calls-loop

    /**
     * @notice Transfers `amount` of `token` to `to`, handling native ETH and ERC-20 uniformly.
     */
    function _transferToken(address token, address to, uint256 amount) private {
        if (token == _NATIVE_ETH) {
            payable(to).sendValue(amount);
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Approves `spender` to spend `amount` of `token` only when `token` is an ERC-20.
     *         Pass `amount = 0` to revoke an existing approval.
     */
    function _approveIfERC20(address token, address spender, uint256 amount) private {
        if (token != _NATIVE_ETH) {
            IERC20(token).forceApprove(spender, amount);
        }
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
            evaluationTime: uint32(block.timestamp),
            evidenceHash: evidenceHash,
            additionalData: additionalData
        });

        result = spec.evaluate(context);
    }
}
