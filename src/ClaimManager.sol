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
import {ICoverPool} from "./interfaces/ICoverPool.sol";
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

    uint16 private constant _MAX_SLIPPAGE_BPS = 10_000;

    address public override specRegistry;
    address public override slashingManager;
    address public override swapper;
    address public override policyManager;
    address public override chainlinkPriceFeed;
    uint16 public override maxSwapSlippageBps;

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
            ClaimOutsideCoverageWindow(policyId, metadata.startTime, metadata.maturityTime, uint32(block.timestamp))
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
     * @notice Inflates the slash amount by real-time Uniswap slippage, executes slashing, then
     *         distributes collateral proceeds to the beneficiary.
     * @param policyId Policy / committee identifier.
     * @param claimId Claim identifier used to build the unique taskId.
     * @param metadata Policy metadata for payout token, beneficiary, and committee info.
     * @param requestedAmount Maximum payout amount in payout token terms.
     * @return Total amount delivered to the beneficiary.
     */
    function _executeSlashingAndPayout(
        uint96 policyId,
        uint256 claimId,
        IPolicyManager.PolicyMetadata memory metadata,
        uint256 requestedAmount
    )
        private
        returns (uint256)
    {
        address payoutToken_ = metadata.payoutToken;
        address beneficiary_ = metadata.beneficiary;
        address operator = ICoverPool(metadata.pool).owner();

        // slither-disable-next-line calls-loop
        uint256 slashAmountUSD = IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(payoutToken_, requestedAmount);

        {
            uint16 slippageBps = _previewSlippageBps(policyId, operator, payoutToken_, slashAmountUSD);
            if (slippageBps > 0) {
                slashAmountUSD = slashAmountUSD * 10_000 / (10_000 - slippageBps);
            }
        }

        (address[] memory collateralTokens, uint256[] memory collateralAmounts) =
            _executeSlash(metadata.policyId, operator, claimId, slashAmountUSD, policyId);

        uint256 totalPayout = _distributeCollateralPayout(
            policyId, claimId, collateralTokens, collateralAmounts, payoutToken_, beneficiary_, requestedAmount
        );

        require(totalPayout > 0, ZeroPayoutAmount(policyId));
        return totalPayout;
    }

    /**
     * @notice Iterates over slashed collateral tokens and routes each to _processCollateral.
     * @param policyId Policy identifier (for events and errors).
     * @param claimId Claim identifier (for events).
     * @param collateralTokens Collateral token addresses returned by executeSlashing.
     * @param collateralAmounts Collateral amounts returned by executeSlashing.
     * @param payoutToken Payout token the beneficiary receives.
     * @param beneficiary Address that receives the payout.
     * @param requestedAmount Maximum total payout requested.
     * @return totalPayout Total payout delivered across all collateral tokens.
     */
    function _distributeCollateralPayout(
        uint96 policyId,
        uint256 claimId,
        address[] memory collateralTokens,
        uint256[] memory collateralAmounts,
        address payoutToken,
        address beneficiary,
        uint256 requestedAmount
    )
        private
        returns (uint256 totalPayout)
    {
        uint256 remainingPayout = requestedAmount;
        uint256 tokensLength = collateralTokens.length;

        for (uint256 i = 0; i < tokensLength && remainingPayout > 0; ++i) {
            if (collateralAmounts[i] > 0) {
                uint256 amountOut = _processCollateral(
                    policyId,
                    claimId,
                    collateralTokens[i],
                    collateralAmounts[i],
                    payoutToken,
                    beneficiary,
                    remainingPayout
                );
                totalPayout += amountOut;
                remainingPayout = remainingPayout > amountOut ? remainingPayout - amountOut : 0;
            }
        }
    }

    /**
     * @notice Calls SlashingManager.executeSlashing, validating the returned arrays.
     */
    function _executeSlash(
        uint96 metadataPolicyId,
        address operator,
        uint256 claimId,
        uint256 slashAmountUSD,
        uint96 policyId
    )
        private
        returns (address[] memory collateralTokens, uint256[] memory collateralAmounts)
    {
        // slither-disable-next-line calls-loop
        (collateralTokens, collateralAmounts) = ISlashingManager(slashingManager)
            .executeSlashing(
                metadataPolicyId, operator, slashAmountUSD, keccak256(abi.encodePacked(metadataPolicyId, claimId))
            );
        // slither-disable-next-line incorrect-equality
        require(
            collateralTokens.length > 0 && collateralTokens.length == collateralAmounts.length,
            NoCollateralSlashed(policyId)
        );
    }

    /**
     * @notice Previews real-time swap slippage for collateral by querying Uniswap QuoterV2.
     * @dev Calls SlashingManager.previewSlashing (which resolves collateral tokens via SSPRouter)
     *      to get the pro-rata distribution, then quotes each swap via Swapper.quoteSwap.
     * @param policyId Committee ID (1:1 with policyId) used to query vault distribution.
     * @param operator Operator address whose stake backs the committee.
     * @param payoutToken The token the beneficiary receives; used to skip same-token vaults.
     * @param baseSlashAmountUSD Base USD slash amount before inflation (8 decimals).
     * @return slippageBps Real-time slippage in basis points.
     */
    function _previewSlippageBps(
        uint96 policyId,
        address operator,
        address payoutToken,
        uint256 baseSlashAmountUSD
    )
        private
        returns (uint16)
    {
        address[] memory collateralTokens = new address[](0);
        uint256[] memory slashAmountsUSD = new uint256[](0);
        try ISlashingManager(slashingManager).previewSlashing(policyId, operator, baseSlashAmountUSD) returns (
            address[] memory t, uint256[] memory a
        ) {
            collateralTokens = t;
            slashAmountsUSD = a;
        } catch {
            return 0;
        }

        uint256 tokensLength = collateralTokens.length;
        if (tokensLength == 0) {
            return 0;
        }

        uint256 totalOracleExpected = 0;
        uint256 totalQuoted = 0;

        for (uint256 i = 0; i < tokensLength; ++i) {
            if (slashAmountsUSD[i] == 0 || collateralTokens[i] == address(0)) continue;

            (uint256 oracle, uint256 quoted) = _quoteVaultSlippage(collateralTokens[i], payoutToken, slashAmountsUSD[i]);
            totalOracleExpected += oracle;
            totalQuoted += quoted;
        }

        if (totalOracleExpected == 0 || totalQuoted >= totalOracleExpected) {
            return 0;
        }

        uint256 computedBps = (totalOracleExpected - totalQuoted) * 10_000 / totalOracleExpected;
        if (computedBps >= 10_000) {
            return 0;
        }

        uint16 cap = maxSwapSlippageBps;
        if (computedBps >= cap) {
            return cap;
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(computedBps);
    }

    /**
     * @notice Quotes the expected swap output for a single vault's slash allocation.
     * @dev collateralToken is resolved by the core (SlashingManager.previewSlashing via
     *      SSPRouter.getVaultToken) before this function is called, so no protocol-specific
     *      vault introspection is required here.
     * @param collateralToken Underlying collateral token for this vault (resolved by core).
     * @param payoutToken Payout token address.
     * @param slashUSD USD slash amount for this vault (8 decimals).
     * @return Oracle-priced expected payout token amount.
     * @return Uniswap-quoted expected payout token amount.
     */
    // slither-disable-start calls-loop
    function _quoteVaultSlippage(
        address collateralToken,
        address payoutToken,
        uint256 slashUSD
    )
        private
        returns (uint256, uint256)
    {
        if (collateralToken == payoutToken) {
            uint256 amount = _getTokenAmount(payoutToken, slashUSD);
            return (amount, amount);
        }

        uint256 collateralAmount = _getTokenAmount(collateralToken, slashUSD);
        if (collateralAmount == 0) {
            return (0, 0);
        }

        uint256 usdValue = _getUSDValue(collateralToken, collateralAmount);
        if (usdValue == 0) {
            return (0, 0);
        }

        uint256 oracleExpected = _getTokenAmount(payoutToken, usdValue);
        if (oracleExpected == 0) {
            return (0, 0);
        }

        uint256 quoted = oracleExpected;
        try ISwapper(swapper).quoteSwap(collateralToken, payoutToken, collateralAmount) returns (uint256 q) {
            quoted = q;
        } catch {}

        return (oracleExpected, quoted);
    }

    /// @dev Delegates to ChainlinkPriceFeed.getTokenAmount; returns 0 on revert.
    function _getTokenAmount(address token, uint256 usdValue) private returns (uint256) {
        try IChainlinkPriceFeed(chainlinkPriceFeed).getTokenAmount(token, usdValue) returns (uint256 amount) {
            return amount;
        } catch {
            return 0;
        }
    }

    /// @dev Delegates to ChainlinkPriceFeed.getUSDValue; returns 0 on revert.
    function _getUSDValue(address token, uint256 amount) private returns (uint256) {
        try IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(token, amount) returns (uint256 usdValue) {
            return usdValue;
        } catch {
            return 0;
        }
    }

    // slither-disable-end calls-loop

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
            IERC20(collateralToken).safeTransfer(beneficiary, transferAmount);
            amountOut = transferAmount;
        } else {
            IERC20(collateralToken).forceApprove(swapper, collateralAmount);

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

            uint256 swapOutput = ISwapper(swapper).executeSwap(swapParams);

            amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput;
            IERC20(payoutToken).safeTransfer(beneficiary, amountOut);

            IERC20(collateralToken).forceApprove(swapper, 0);
        }

        emit CollateralSwapped(policyId, claimId, collateralToken, collateralAmount, payoutToken, amountOut);
    }

    // slither-disable-end calls-loop

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
