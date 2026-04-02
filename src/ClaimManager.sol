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
import {IClaimManager} from "./interfaces/IClaimManager.sol";
import {ICoverPool} from "./interfaces/ICoverPool.sol";
import {IPolicyManager} from "./interfaces/IPolicyManager.sol";
import {IRewardsManager} from "./interfaces/IRewardsManager.sol";
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
 *      previewSlashing → _computeVaultSlashes → executeSlashing → swap collateral → payout
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
    uint32 private constant _SWAP_DEADLINE_BUFFER = 15 minutes;

    address public override specRegistry;
    address public override slashingManager;
    address public override swapper;
    address public override policyManager;
    address public override rewardsManager;
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
     */
    function initialize(
        address admin_,
        address specRegistry_,
        address slashingManager_,
        address swapper_,
        address policyManager_
    )
        external
        initializer
    {
        require(
            admin_ != address(0) && specRegistry_ != address(0) && slashingManager_ != address(0)
                && swapper_ != address(0) && policyManager_ != address(0),
            ZeroAddress()
        );

        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        specRegistry = specRegistry_;
        slashingManager = slashingManager_;
        swapper = swapper_;
        policyManager = policyManager_;
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
    function setMaxSwapSlippageBps(uint16 maxSwapSlippageBps_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(maxSwapSlippageBps_ < _MAX_SLIPPAGE_BPS, InvalidSlippageBps(maxSwapSlippageBps_));
        maxSwapSlippageBps = maxSwapSlippageBps_;
        emit MaxSwapSlippageBpsSet(maxSwapSlippageBps_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setRewardsManager(address rewardsManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        rewardsManager = rewardsManager_;
        emit RewardsManagerSet(rewardsManager_);
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
        require(_claimApprovalRequired[policyId], NoApprovalPending(policyId));
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
        _usedEvidenceHashes[policyId][evidenceHash] = true;

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
     * @notice Executes slashing and collateral swapping for payout using token-native amounts.
     * @dev Flow: previewSlashing → _computeVaultSlashes → executeSlashing → loop swap/transfer
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
        (address[] memory collateralTokens, uint256[] memory collateralAmounts) =
            _slash(metadata, claimId, requestedAmount);

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
                    metadata.beneficiary,
                    metadata.curator,
                    remainingPayout
                );
                totalPayout += amountOut;
                remainingPayout = remainingPayout > amountOut ? remainingPayout - amountOut : 0;
            }
        }

        require(totalPayout > 0, ZeroPayoutAmount(policyId));
    }

    /**
     * @notice Previews slashing, computes vault slash amounts, and executes slashing in core.
     * @dev Extracted to avoid stack-too-deep in _executeSlashingAndPayout.
     */
    function _slash(
        IPolicyManager.PolicyMetadata memory metadata,
        uint256 claimId,
        uint256 requestedAmount
    )
        private
        returns (address[] memory collateralTokens, uint256[] memory collateralAmounts)
    {
        address operator = metadata.curator;

        (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes) =
            ISlashingManager(slashingManager).previewSlashing(metadata.policyId, operator);

        uint256 vaultsLength = vaults.length;
        if (vaultsLength != tokens.length || vaultsLength != tokenStakes.length) {
            revert SlashingArrayLengthMismatch(vaultsLength, tokens.length, tokenStakes.length);
        }

        ISlashingManager.VaultSlash[] memory vaultSlashes =
            _computeVaultSlashes(vaults, tokens, tokenStakes, metadata.payoutToken, requestedAmount);

        require(vaultSlashes.length > 0, NoCollateralSlashed(metadata.policyId));

        // slither-disable-next-line calls-loop
        (collateralTokens, collateralAmounts) = ISlashingManager(slashingManager)
            .executeSlashing(
                metadata.policyId, operator, vaultSlashes, keccak256(abi.encodePacked(metadata.policyId, claimId))
            );
    }

    /**
     * @notice Computes per-vault token-native slash amounts proportional to each vault's payout-equivalent value.
     * @dev Two-pass: quotes each stake to payout-token equivalent, then computes proportional slash amounts.
     *      Cross-token slashes are inflated by MAX / (MAX - maxSwapSlippageBps) so the beneficiary receives the
     *      full requestedAmount even at worst-case swap slippage; same-token vaults are direct transfers and need
     *      no inflation. Any surplus from a better-than-worst-case swap is distributed to restakers via
     *      RewardsManager in _processCollateral; payout accounting (amountOut) is capped at remainingPayout.
     *      The amountOutMin set there is complementary sandwich protection, not double-counting.
     * @param vaults Array of vault addresses from previewSlashing.
     * @param tokens Array of collateral token addresses per vault.
     * @param tokenStakes Array of token-native stake amounts per vault.
     * @param payoutToken The desired payout token.
     * @param requestedAmount The payout amount requested in payout token terms.
     * @return vaultSlashes Per-vault slash instructions ready for executeSlashing.
     */
    // slither-disable-next-line cyclomatic-complexity
    function _computeVaultSlashes(
        address[] memory vaults,
        address[] memory tokens,
        uint256[] memory tokenStakes,
        address payoutToken,
        uint256 requestedAmount
    )
        private
        returns (ISlashingManager.VaultSlash[] memory vaultSlashes)
    {
        uint256 vaultsLength = vaults.length;
        uint256 totalPayoutEquivalent = 0;
        uint256[] memory payoutEquivalents = new uint256[](vaultsLength);

        for (uint256 i = 0; i < vaultsLength; ++i) {
            if (tokenStakes[i] == 0) {
                continue;
            }

            if (tokens[i] == payoutToken) {
                payoutEquivalents[i] = tokenStakes[i];
            } else {
                // slither-disable-next-line calls-loop
                try ISwapper(swapper).quoteSwap(tokens[i], payoutToken, tokenStakes[i]) returns (uint256 quoted) {
                    payoutEquivalents[i] = quoted;
                } catch {
                    payoutEquivalents[i] = 0;
                }
            }
            totalPayoutEquivalent += payoutEquivalents[i];
        }

        if (vaultsLength == 0 || totalPayoutEquivalent == 0) {
            return new ISlashingManager.VaultSlash[](0);
        }

        ISlashingManager.VaultSlash[] memory scratch = new ISlashingManager.VaultSlash[](vaultsLength);
        uint256 nonZeroCount = 0;
        uint256 cachedMaxSwapSlippageBps = maxSwapSlippageBps;
        for (uint256 i = 0; i < vaultsLength; ++i) {
            if (payoutEquivalents[i] == 0) {
                continue;
            }

            // slither-disable-next-line divide-before-multiply
            uint256 baseSlash = (tokenStakes[i] * requestedAmount) / totalPayoutEquivalent;
            if (tokens[i] != payoutToken && cachedMaxSwapSlippageBps > 0) {
                uint256 maxSlippage = uint256(_MAX_SLIPPAGE_BPS);
                baseSlash = (baseSlash * maxSlippage) / (maxSlippage - cachedMaxSwapSlippageBps);
            }

            if (baseSlash == 0) {
                baseSlash = 1;
            } else if (baseSlash > tokenStakes[i]) {
                baseSlash = tokenStakes[i];
            }

            scratch[nonZeroCount] = ISlashingManager.VaultSlash({vault: vaults[i], token: tokens[i], amount: baseSlash});
            ++nonZeroCount;
        }

        vaultSlashes = new ISlashingManager.VaultSlash[](nonZeroCount);
        for (uint256 i = 0; i < nonZeroCount; ++i) {
            vaultSlashes[i] = scratch[i];
        }
    }

    /**
     * @notice Processes collateral by swapping or transferring directly with cap.
     * @dev Uses quoteSwap for amountOutMin instead of oracle-based pricing.
     *      Any swap surplus (swapOutput > remainingPayout) is distributed to restakers via RewardsManager
     *      if configured, mirroring the PremiumManager reward distribution pattern.
     * @param policyId Identifier of the policy (for events).
     * @param claimId Identifier of the claim (for events).
     * @param collateralToken Address of the slashed collateral token.
     * @param collateralAmount Amount of collateral to process.
     * @param payoutToken Desired payout token address.
     * @param beneficiary Address to receive the payout.
     * @param curator Operator address (used as reward recipient in RewardsManager).
     * @param remainingPayout Maximum payout amount still needed.
     * @return amountOut Amount of payout token delivered to beneficiary (capped at remainingPayout).
     */
    // slither-disable-start calls-loop
    function _processCollateral(
        uint96 policyId,
        uint256 claimId,
        address collateralToken,
        uint256 collateralAmount,
        address payoutToken,
        address beneficiary,
        address curator,
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

            uint256 amountOutMin = 0;
            try ISwapper(swapper).quoteSwap(collateralToken, payoutToken, collateralAmount) returns (uint256 quoted) {
                if (quoted == 0) {
                    revert QuoteUnavailable(collateralToken, payoutToken);
                }
                amountOutMin = (quoted * (uint256(_MAX_SLIPPAGE_BPS) - maxSwapSlippageBps)) / _MAX_SLIPPAGE_BPS;
                if (amountOutMin == 0) {
                    amountOutMin = 1;
                }
            } catch {
                revert QuoteUnavailable(collateralToken, payoutToken);
            }

            ISwapper.SwapParams memory swapParams = ISwapper.SwapParams({
                tokenIn: collateralToken,
                tokenOut: payoutToken,
                amountIn: collateralAmount,
                amountOutMin: amountOutMin,
                recipient: address(this),
                swapCalldata: "",
                deadline: block.timestamp + _SWAP_DEADLINE_BUFFER
            });

            // slither-disable-next-line arbitrary-send-eth
            uint256 swapOutput =
                ISwapper(swapper).executeSwap{value: collateralToken == _NATIVE_ETH ? collateralAmount : 0}(swapParams);

            amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput;
            _transferToken(payoutToken, beneficiary, amountOut);

            if (swapOutput > amountOut && rewardsManager != address(0) && payoutToken != _NATIVE_ETH) {
                uint256 surplus = swapOutput - amountOut;
                bytes32 taskId = keccak256(abi.encodePacked(policyId, claimId, collateralToken));
                IERC20(payoutToken).forceApprove(rewardsManager, surplus);
                // slither-disable-next-line calls-loop
                IRewardsManager(rewardsManager)
                    .distributeRewards(policyId, curator, surplus, IERC20(payoutToken), taskId);
                IERC20(payoutToken).forceApprove(rewardsManager, 0);
                emit SwapSurplusDistributed(policyId, claimId, payoutToken, surplus);
            }

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
