// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IChainlinkPriceFeed} from "./interfaces/IChainlinkPriceFeed.sol";
import {IClaimManager} from "./interfaces/IClaimManager.sol";
import {IPremiumReserve} from "./interfaces/IPremiumReserve.sol";
import {IPolicy} from "./interfaces/IPolicy.sol";
import {ISpec} from "./interfaces/ISpec.sol";
import {ISpecRegistry} from "./interfaces/ISpecRegistry.sol";
import {ISlashingManager} from "./interfaces/ISlashingManager.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/**
 * @title ClaimManager
 * @notice Orchestrates parametric claim processing by evaluating product specs, coordinating slashing,
 *         swapping collateral, and settling payouts to beneficiaries.
 * @dev Integrates with:
 *      - Policy: Fetches policy metadata and coverage parameters
 *      - PremiumReserve: Locks escrow during evaluation, pays claims from reserve
 *      - SpecRegistry: Resolves product-specific evaluation logic
 *      - SlashingManager (Core): Executes stake slashing for approved claims
 *      - Swapper: Converts slashed collateral to payout tokens
 *
 *      Claim Flow:
 *      1. fileClaim: Any reporter files claim, escrow locked
 *      2. resolveClaim: Operator evaluates Spec, if approved → premium reserve waterfall → slash shortfall → swap
 * → payout
 *      3. rejectClaim: Operator manually rejects, escrow unlocked
 *
 *      Premium Reserve Waterfall:
 *      - First attempts to pay claim from premium reserve collected for the policy
 *      - If premium reserve sufficient, no slashing occurs
 *      - If premium reserve insufficient, only slashes the shortfall amount
 *      Example: 100k in reserve, 2M policy, 70k claim → pay from reserve only
 *      Example: 100k in reserve, 2M policy, 250k claim → 100k from reserve + 150k from slashing
 */
// slither-disable-next-line unimplemented-functions
contract ClaimManager is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    IClaimManager
{
    using SafeERC20 for IERC20;

    bytes32 public constant override CLAIM_OPERATOR_ROLE = keccak256("CLAIM_OPERATOR_ROLE");

    address public override specRegistry;
    address public override slashingManager;
    address public override swapper;
    address public override policy;
    address public override premiumReserve;
    address public override priceFeed;

    mapping(uint256 policyId => ClaimRecord) private _claims;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the ClaimManager with role assignments and dependency wiring.
     * @param admin_ Address receiving DEFAULT_ADMIN_ROLE.
     * @param claimOperator_ Address granted CLAIM_OPERATOR_ROLE for resolving claims.
     * @param specRegistry_ Address of the SpecRegistry contract.
     * @param slashingManager_ Address of the SlashingManager contract (Catalysis Core).
     * @param swapper_ Address of the Swapper contract.
     * @param policy_ Address of the Policy contract.
     * @param premiumReserve_ Address of the PremiumReserve contract.
     * @param priceFeed_ Address of the PriceFeed contract (Catalysis Core).
     */
    function initialize(
        address admin_,
        address claimOperator_,
        address specRegistry_,
        address slashingManager_,
        address swapper_,
        address policy_,
        address premiumReserve_,
        address priceFeed_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && claimOperator_ != address(0) && specRegistry_ != address(0)
                && slashingManager_ != address(0) && swapper_ != address(0) && policy_ != address(0)
                && premiumReserve_ != address(0) && priceFeed_ != address(0),
            ZeroAddress()
        );

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CLAIM_OPERATOR_ROLE, claimOperator_);

        specRegistry = specRegistry_;
        slashingManager = slashingManager_;
        swapper = swapper_;
        policy = policy_;
        premiumReserve = premiumReserve_;
        priceFeed = priceFeed_;
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
    function setPolicy(address policy_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(policy_ != address(0), ZeroAddress());
        policy = policy_;
        emit PolicySet(policy_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setPremiumReserve(address premiumReserve_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(premiumReserve_ != address(0), ZeroAddress());
        premiumReserve = premiumReserve_;
        emit PremiumReserveSet(premiumReserve_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setPriceFeed(address priceFeed_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(priceFeed_ != address(0), ZeroAddress());
        priceFeed = priceFeed_;
        emit PriceFeedSet(priceFeed_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function fileClaim(
        uint256 policyId,
        uint256 requestedAmount,
        bytes32 evidenceHash
    )
        external
        override
        whenNotPaused
        nonReentrant
    {
        require(evidenceHash != bytes32(0), InvalidEvidenceHash());
        require(requestedAmount > 0, ZeroAmount());

        IPolicy.PolicyMetadata memory metadata = IPolicy(policy).policyMetadata(policyId);
        require(metadata.buyer != address(0), PolicyNotFound(policyId));

        require(
            requestedAmount <= metadata.coverageLimit,
            RequestedAmountExceedsCoverage(policyId, requestedAmount, metadata.coverageLimit)
        );

        require(
            block.timestamp >= metadata.startTime && block.timestamp <= metadata.maturityTime,
            ClaimOutsideCoverageWindow(policyId, metadata.startTime, metadata.maturityTime, block.timestamp)
        );

        require(!IPremiumReserve(premiumReserve).isEscrowReleased(policyId), EscrowAlreadyReleased(policyId));

        ClaimRecord storage claim = _claims[policyId];
        require(claim.status == ClaimStatus.None, ClaimAlreadyFiled(policyId));

        claim.status = ClaimStatus.Filed;
        claim.reporter = msg.sender;
        claim.filedAt = block.timestamp;
        claim.evidenceHash = evidenceHash;
        claim.requestedAmount = requestedAmount;

        emit ClaimFiled(policyId, msg.sender, evidenceHash, requestedAmount, block.timestamp);

        // slither-disable-next-line calls-loop
        IPremiumReserve(premiumReserve).setClaimLockStatus(policyId, true);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function resolveClaim(
        uint256 policyId,
        bytes calldata additionalData
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRole(CLAIM_OPERATOR_ROLE)
    {
        ClaimRecord storage claim = _claims[policyId];
        require(claim.status == ClaimStatus.Filed, ClaimNotFiled(policyId));

        IPolicy.PolicyMetadata memory metadata = IPolicy(policy).policyMetadata(policyId);

        ISpec.EvaluationResult memory result = _evaluateSpec(policyId, metadata, claim.evidenceHash, additionalData);
        claim.evaluationResult = result;
        claim.resolvedAt = block.timestamp;

        if (!result.isPayable) {
            claim.status = ClaimStatus.Rejected;
            emit ClaimRejected(policyId, "Spec evaluation failed", block.timestamp);
            // slither-disable-next-line calls-loop
            IPremiumReserve(premiumReserve).setClaimLockStatus(policyId, false);
            return;
        }

        claim.status = ClaimStatus.Approved;

        // slither-disable-next-line reentrancy-no-eth
        uint256 totalPayout = _executeSlashingAndPayout(policyId, metadata, claim.requestedAmount);
        claim.payoutAmount = totalPayout;

        emit ClaimApproved(policyId, metadata.payoutReceiver, totalPayout, block.timestamp);

        // slither-disable-next-line calls-loop
        IPremiumReserve(premiumReserve).setClaimLockStatus(policyId, false);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function rejectClaim(
        uint256 policyId,
        string calldata reason
    )
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(CLAIM_OPERATOR_ROLE)
    {
        ClaimRecord storage claim = _claims[policyId];
        require(claim.status == ClaimStatus.Filed, ClaimNotFiled(policyId));

        claim.status = ClaimStatus.Rejected;
        claim.resolvedAt = block.timestamp;

        emit ClaimRejected(policyId, reason, block.timestamp);

        // slither-disable-next-line calls-loop
        IPremiumReserve(premiumReserve).setClaimLockStatus(policyId, false);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function claimRecord(uint256 policyId) external view override returns (ClaimRecord memory) {
        return _claims[policyId];
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
     * @notice Executes premium reserve waterfall followed by slashing and converts collateral to payout tokens.
     * @dev Implements waterfall logic:
     *      1. First attempts to pay from premium reserve
     *      2. If premium reserve insufficient, slashes only the shortfall
     *      3. Converts slashed collateral to payout token via Swapper
     * @param policyId Identifier of the policy.
     * @param metadata Policy metadata containing committeeId, operator, and payout details.
     * @param requestedAmount Maximum amount to disburse (in payout token terms).
     * @return totalPayout Total amount paid out in payout token terms (capped at requestedAmount).
     */
    function _executeSlashingAndPayout(
        uint256 policyId,
        IPolicy.PolicyMetadata memory metadata,
        uint256 requestedAmount
    )
        private
        returns (uint256 totalPayout)
    {
        // slither-disable-next-line calls-loop,unused-return
        (totalPayout,) = IPremiumReserve(premiumReserve).payClaim(policyId, metadata.payoutReceiver, requestedAmount);

        uint256 remainingPayout = requestedAmount - totalPayout;
        // slither-disable-next-line incorrect-equality
        if (remainingPayout == 0) {
            return totalPayout;
        }

        totalPayout += _slashAndSwap(policyId, metadata, remainingPayout);
        require(totalPayout > 0, ZeroPayoutAmount(policyId));
    }

    /**
     * @notice Slashes collateral and swaps to payout token.
     * @param policyId Identifier of the policy.
     * @param metadata Policy metadata containing committeeId, operator, and payout details.
     * @param shortfallAmount Amount needed after premium reserve depletion.
     * @return payoutFromSlashing Total payout obtained from slashing and swapping.
     */
    function _slashAndSwap(
        uint256 policyId,
        IPolicy.PolicyMetadata memory metadata,
        uint256 shortfallAmount
    )
        private
        returns (uint256 payoutFromSlashing)
    {
        // slither-disable-next-line calls-loop
        uint256 slashAmountUSD = IChainlinkPriceFeed(priceFeed).getUSDValue(metadata.payoutToken, shortfallAmount);

        // slither-disable-next-line calls-loop
        (address[] memory collateralTokens, uint256[] memory collateralAmounts) =
            ISlashingManager(slashingManager).executeSlashing(metadata.committeeId, metadata.operator, slashAmountUSD);

        uint256 assetsLength = collateralTokens.length;
        // slither-disable-next-line incorrect-equality
        require(assetsLength > 0 && assetsLength == collateralAmounts.length, NoCollateralSlashed(policyId));

        uint256 remainingPayout = shortfallAmount;
        for (uint256 i = 0; i < assetsLength && remainingPayout > 0; ++i) {
            if (collateralAmounts[i] > 0) {
                uint256 amountOut = _processCollateral(
                    policyId,
                    collateralTokens[i],
                    collateralAmounts[i],
                    metadata.payoutToken,
                    metadata.payoutReceiver,
                    remainingPayout
                );
                payoutFromSlashing += amountOut;
                remainingPayout = remainingPayout > amountOut ? remainingPayout - amountOut : 0;
            }
        }
    }

    /**
     * @notice Processes a single collateral asset by swapping or transferring directly.
     * @dev Uses Swapper's pre-configured routes and calldata for swaps.
     *      Receives swap output to this contract first, then transfers only up to remainingPayout
     *      to avoid over-disbursement. Any excess from swaps remains in the contract.
     * @param policyId Identifier of the policy (for events).
     * @param collateralToken Address of the slashed collateral token.
     * @param collateralAmount Amount of collateral to process.
     * @param payoutToken Desired payout token address.
     * @param payoutReceiver Address to receive the payout.
     * @param remainingPayout Maximum payout amount still needed.
     * @return amountOut Amount of payout token delivered (capped at remainingPayout).
     */
    function _processCollateral(
        uint256 policyId,
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

            // Empty swapCalldata triggers use of pre-configured route calldata
            // amountOutMin of 1 ensures swap produces non-zero output; slippage is controlled by route config
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

        emit CollateralSwapped(policyId, collateralToken, collateralAmount, payoutToken, amountOut);
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
        uint256 policyId,
        IPolicy.PolicyMetadata memory metadata,
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
