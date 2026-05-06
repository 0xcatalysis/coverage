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
import {IPremiumManager} from "./interfaces/IPremiumManager.sol";
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

    /// @dev BPS denominator used in slippage inflation formulas. Must not change.
    uint16 private constant _MAX_SLIPPAGE_BPS = 10_000;
    /// @dev Upper bound for the admin-settable slippage parameter.
    uint16 private constant _MAX_SETTABLE_SLIPPAGE_BPS = 3000;
    /// @dev Upper bound for the admin-settable price deviation tolerance.
    uint16 private constant _MAX_SETTABLE_DEVIATION_BPS = 1000;
    address private constant _NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint32 private constant _SWAP_DEADLINE_BUFFER = 15 minutes;

    address public override specRegistry;
    address public override slashingManager;
    address public override swapper;
    address public override policyManager;
    address public override premiumManager;
    uint16 public override maxSwapSlippageBps;

    mapping(uint96 policyId => mapping(uint256 claimId => ClaimRecord)) private _claims;
    mapping(uint96 policyId => PolicyClaim) private _policyClaims;
    mapping(uint96 policyId => bool) private _claimApprovalRequired;
    mapping(uint96 policyId => mapping(bytes32 evidenceHash => bool used)) private _usedEvidenceHashes;

    // --- Storage layout V2 (appended; do not insert variables above this line) ---
    address public override chainlinkPriceFeed;
    uint16 public override priceDeviationToleranceBps;
    // slither-disable-next-line unused-state
    uint256[48] private __gap;

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
    function initializeV2(address chainlinkPriceFeed_, uint16 priceDeviationToleranceBps_) external reinitializer(2) {
        require(chainlinkPriceFeed_ != address(0), ZeroAddress());
        require(
            priceDeviationToleranceBps_ <= _MAX_SETTABLE_DEVIATION_BPS, InvalidDeviationBps(priceDeviationToleranceBps_)
        );
        chainlinkPriceFeed = chainlinkPriceFeed_;
        priceDeviationToleranceBps = priceDeviationToleranceBps_;
        emit ChainlinkPriceFeedSet(chainlinkPriceFeed_);
        emit PriceDeviationToleranceBpsSet(priceDeviationToleranceBps_);
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
        require(maxSwapSlippageBps_ <= _MAX_SETTABLE_SLIPPAGE_BPS, InvalidSlippageBps(maxSwapSlippageBps_));
        maxSwapSlippageBps = maxSwapSlippageBps_;
        emit MaxSwapSlippageBpsSet(maxSwapSlippageBps_);
    }

    /**
     * @inheritdoc IClaimManager
     */
    function setPremiumManager(address premiumManager_) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(premiumManager_ != address(0), ZeroAddress());
        premiumManager = premiumManager_;
        emit PremiumManagerSet(premiumManager_);
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
    function setPriceDeviationToleranceBps(uint16 priceDeviationToleranceBps_)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        require(
            priceDeviationToleranceBps_ <= _MAX_SETTABLE_DEVIATION_BPS, InvalidDeviationBps(priceDeviationToleranceBps_)
        );
        priceDeviationToleranceBps = priceDeviationToleranceBps_;
        emit PriceDeviationToleranceBpsSet(priceDeviationToleranceBps_);
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
        require(msg.sender == metadata.curator, UnauthorizedApprover());
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
     * @notice Computes the Chainlink fair value of `amountIn` units of `tokenIn` denominated in `tokenOut`.
     * @dev Normalizes the NATIVE_ETH sentinel to the Swapper's nativeWrapper before feed lookups, mirroring
     *      Swapper.quoteSwap so a slashed-native-ETH leg priced against a WETH feed works correctly.
     *      Both external Chainlink calls are wrapped in try/catch so staleness reverts surface as
     *      OracleUnavailable rather than propagating raw Chainlink errors.
     * @param tokenIn Collateral token (may be the NATIVE_ETH sentinel).
     * @param tokenOut Payout token (may be the NATIVE_ETH sentinel).
     * @param amountIn Amount of tokenIn to value.
     * @return fair Token-native amount of tokenOut equivalent to amountIn of tokenIn at Chainlink prices.
     */
    function _chainlinkFairValue(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    )
        private
        view
        returns (uint256 fair)
    {
        address feed = chainlinkPriceFeed;
        if (feed == address(0)) revert OracleUnavailable(tokenIn, tokenOut);

        address actualIn = tokenIn == _NATIVE_ETH ? ISwapper(swapper).nativeWrapper() : tokenIn;
        address actualOut = tokenOut == _NATIVE_ETH ? ISwapper(swapper).nativeWrapper() : tokenOut;

        if (actualIn == actualOut) return amountIn;

        IChainlinkPriceFeed oracle = IChainlinkPriceFeed(feed);

        if (!oracle.hasPriceFeed(actualIn) || !oracle.hasPriceFeed(actualOut)) {
            revert OracleUnavailable(tokenIn, tokenOut);
        }

        uint256 usd;
        try oracle.getUSDValue(actualIn, amountIn) returns (uint256 v) {
            usd = v;
        } catch {
            revert OracleUnavailable(tokenIn, tokenOut);
        }
        if (usd == 0) revert OracleUnavailable(tokenIn, tokenOut);

        try oracle.getTokenAmount(actualOut, usd) returns (uint256 v) {
            fair = v;
        } catch {
            revert OracleUnavailable(tokenIn, tokenOut);
        }
        if (fair == 0) revert OracleUnavailable(tokenIn, tokenOut);
    }

    /**
     * @notice Validates that a DEX spot quote is within the configured tolerance of the Chainlink fair value.
     * @dev Reverts with QuoteDeviatesFromOracle when the absolute deviation exceeds priceDeviationToleranceBps.
     *      Callers must guarantee chainlinkFair > 0 (enforced by _chainlinkFairValue).
     * @param tokenIn Collateral token (used only in the revert payload).
     * @param tokenOut Payout token (used only in the revert payload).
     * @param dexQuote Spot quote returned by the DEX route.
     * @param chainlinkFair Chainlink-derived fair value for the same amount.
     */
    function _validateDexAgainstOracle(
        address tokenIn,
        address tokenOut,
        uint256 dexQuote,
        uint256 chainlinkFair
    )
        private
        view
    {
        uint256 diff = dexQuote > chainlinkFair ? dexQuote - chainlinkFair : chainlinkFair - dexQuote;
        uint256 deviationBps = (diff * uint256(_MAX_SLIPPAGE_BPS)) / chainlinkFair;
        if (deviationBps > priceDeviationToleranceBps) {
            revert QuoteDeviatesFromOracle(tokenIn, tokenOut, dexQuote, chainlinkFair, deviationBps);
        }
    }

    /**
     * @notice Files a claim record and returns policy metadata.
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
            block.timestamp >= metadata.startTime && block.timestamp < metadata.maturityTime,
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
     * @return totalPayout Actual amount paid out (may be less if coverage is exhausted).
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
     * @dev Flow: previewSlashing → _computeVaultSlashes → executeSlashing → loop swap/transfer.
     *      The loop exits as soon as remainingPayout reaches zero; entries beyond that point
     *      are skipped entirely.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @param metadata Policy metadata containing payout token and beneficiary details.
     * @param requestedAmount Maximum amount to disburse in payout token terms.
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
                    remainingPayout,
                    i
                );
                totalPayout += amountOut;
                remainingPayout -= amountOut;
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
     * @dev Two-pass: values each stake via Chainlink fair value (oracle-anchored), then computes proportional
     *      slash amounts. The DEX quote is used as a bounded sanity check — if it deviates from the Chainlink
     *      fair value by more than `priceDeviationToleranceBps`, the whole claim reverts.
     *      Cross-token slashes are inflated by MAX / (MAX - maxSwapSlippageBps) so the beneficiary receives
     *      the full requestedAmount even at worst-case swap slippage; same-token vaults need no inflation.
     * @param vaults Vault addresses from previewSlashing.
     * @param tokens Collateral token address per vault.
     * @param tokenStakes Token-native stake amount per vault.
     * @param payoutToken Desired payout token.
     * @param requestedAmount Payout amount in payout token terms.
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
                // Chainlink fair value is authoritative for slash distribution sizing.
                // The DEX quote is a bounded sanity check: revert if it deviates too far from fair value,
                // indicating a manipulated or illiquid pool.
                // slither-disable-next-line calls-loop
                uint256 fair = _chainlinkFairValue(tokens[i], payoutToken, tokenStakes[i]);

                uint256 dex;
                // slither-disable-next-line calls-loop
                try ISwapper(swapper).quoteSwap(tokens[i], payoutToken, tokenStakes[i]) returns (uint256 quoted) {
                    dex = quoted;
                } catch {
                    revert QuoteUnavailable(tokens[i], payoutToken);
                }
                if (dex == 0) revert QuoteUnavailable(tokens[i], payoutToken);

                _validateDexAgainstOracle(tokens[i], payoutToken, dex, fair);

                payoutEquivalents[i] = fair;
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
                if (tokens[i] != payoutToken) {
                    emit VaultExcludedFromSlashing(vaults[i], tokens[i]);
                    continue;
                }
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
     * @notice Processes collateral by swapping or transferring directly, capped at remainingPayout.
     * @dev amountOutMin is derived from Chainlink fair value with the DEX quote as a bounded sanity check
     *      (see `_computeAmountOutMin`). Surplus beyond remainingPayout is forwarded via
     *      PremiumManager.distributeSurplusAsRewards() if configured.
     *      vaultIndex is included in the taskId to prevent replay collisions when two vault legs
     *      share the same collateral token.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @param collateralToken Address of the slashed collateral token.
     * @param collateralAmount Amount of collateral to process.
     * @param payoutToken Desired payout token address.
     * @param beneficiary Address to receive the payout.
     * @param curator Operator address used as reward recipient context in PremiumManager.distributeSurplusAsRewards().
     * @param remainingPayout Maximum payout amount still needed.
     * @param vaultIndex Position of this vault leg in the collateralTokens array (used in taskId).
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
        uint256 remainingPayout,
        uint256 vaultIndex
    )
        private
        returns (uint256 amountOut)
    {
        bytes32 surplusTaskId = keccak256(abi.encodePacked(policyId, claimId, collateralToken, vaultIndex));

        if (collateralToken == payoutToken) {
            uint256 transferAmount = collateralAmount > remainingPayout ? remainingPayout : collateralAmount;
            if (transferAmount > 0) {
                _transferToken(collateralToken, beneficiary, transferAmount);
            }
            amountOut = transferAmount;

            if (collateralAmount > transferAmount && premiumManager != address(0) && collateralToken != _NATIVE_ETH) {
                _distributeSurplus(
                    policyId, claimId, collateralToken, curator, collateralAmount - transferAmount, surplusTaskId
                );
            }
        } else {
            _approveIfERC20(collateralToken, swapper, collateralAmount);

            uint256 amountOutMin = _computeAmountOutMin(collateralToken, payoutToken, collateralAmount);

            ISwapper.SwapParams memory swapParams = ISwapper.SwapParams({
                tokenIn: collateralToken,
                tokenOut: payoutToken,
                amountIn: collateralAmount,
                amountOutMin: amountOutMin,
                recipient: address(this),
                deadline: block.timestamp + _SWAP_DEADLINE_BUFFER
            });

            // slither-disable-next-line arbitrary-send-eth
            uint256 swapOutput =
                ISwapper(swapper).executeSwap{value: collateralToken == _NATIVE_ETH ? collateralAmount : 0}(swapParams);

            amountOut = swapOutput > remainingPayout ? remainingPayout : swapOutput;
            if (amountOut > 0) {
                _transferToken(payoutToken, beneficiary, amountOut);
            }

            if (swapOutput > amountOut && premiumManager != address(0) && payoutToken != _NATIVE_ETH) {
                _distributeSurplus(policyId, claimId, payoutToken, curator, swapOutput - amountOut, surplusTaskId);
            }

            _approveIfERC20(collateralToken, swapper, 0);
        }

        emit CollateralSwapped(policyId, claimId, collateralToken, collateralAmount, payoutToken, amountOut);
    }

    /**
     * @notice Derives the minimum acceptable swap output, anchored to Chainlink fair value with a bounded
     *         DEX sanity check.
     * @dev The Chainlink fair value is the primary anchor; the DEX quote is validated against it via
     *      `_validateDexAgainstOracle` and then used to determine the tighter of the two bounds:
     *        anchor = min(fair, dex)
     *        amountOutMin = anchor × (MAX − maxSwapSlippageBps) / MAX
     *      Using min(fair, dex) ensures the bound is achievable on-chain when the DEX quote is within
     *      tolerance below the Chainlink fair value, while a manipulated DEX quote above fair is capped
     *      to fair (preventing an inflated bound that cannot be met).
     *      Reverts with OracleUnavailable if the Chainlink feed is unset, missing, stale, or returns zero.
     *      Reverts with QuoteUnavailable if the DEX quote is unavailable or zero.
     *      Reverts with QuoteDeviatesFromOracle if the DEX quote deviates beyond priceDeviationToleranceBps.
     *      Returns at least 1 to prevent a zero-minimum swap that would accept any output.
     * @param tokenIn Collateral token to sell.
     * @param tokenOut Payout token to receive.
     * @param amountIn Amount of collateral being swapped.
     * @return Slippage-adjusted minimum output amount (≥ 1).
     */
    function _computeAmountOutMin(address tokenIn, address tokenOut, uint256 amountIn) private returns (uint256) {
        uint256 fair = _chainlinkFairValue(tokenIn, tokenOut, amountIn);

        uint256 dex;
        try ISwapper(swapper).quoteSwap(tokenIn, tokenOut, amountIn) returns (uint256 quoted) {
            dex = quoted;
        } catch {
            revert QuoteUnavailable(tokenIn, tokenOut);
        }
        if (dex == 0) revert QuoteUnavailable(tokenIn, tokenOut);

        _validateDexAgainstOracle(tokenIn, tokenOut, dex, fair);

        uint256 anchor = fair < dex ? fair : dex;
        uint256 amountOutMin = (anchor * (uint256(_MAX_SLIPPAGE_BPS) - maxSwapSlippageBps)) / _MAX_SLIPPAGE_BPS;
        return amountOutMin == 0 ? 1 : amountOutMin;
    }

    // slither-disable-end calls-loop

    /**
     * @notice Distributes surplus tokens to restakers via PremiumManager.distributeSurplusAsRewards().
     * @dev Guards (premiumManager set, not native ETH) are checked by the caller.
     *      Wrapped in try/catch so a Core revert cannot block beneficiary payout; on failure
     *      the surplus remains in this contract and is recoverable via `recoverTokens`.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @param token ERC-20 token to distribute.
     * @param curator Operator address passed to PremiumManager.distributeSurplusAsRewards() as the reward recipient
     * context.
     * @param surplus Amount to distribute.
     * @param taskId Unique task identifier for Core replay protection.
     */
    function _distributeSurplus(
        uint96 policyId,
        uint256 claimId,
        address token,
        address curator,
        uint256 surplus,
        bytes32 taskId
    )
        private
    {
        IERC20(token).forceApprove(premiumManager, surplus);
        // slither-disable-next-line calls-loop
        try IPremiumManager(premiumManager)
            .distributeSurplusAsRewards(policyId, curator, surplus, IERC20(token), taskId) {
            IERC20(token).forceApprove(premiumManager, 0);
            emit SwapSurplusDistributed(policyId, claimId, token, surplus);
        } catch {
            IERC20(token).forceApprove(premiumManager, 0);
            emit SwapSurplusDistributionFailed(policyId, claimId, token, surplus);
        }
    }

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
     * @param metadata Policy metadata containing pool and spec details.
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
