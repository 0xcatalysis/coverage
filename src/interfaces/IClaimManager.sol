// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ISpec} from "./ISpec.sol";

/**
 * @title IClaimManager
 * @notice Interface describing the claim orchestration contract that evaluates specs, slashes stake,
 *         swaps collateral, and settles payouts.
 */
interface IClaimManager is IAccessControl {
    /**
     * @notice Status enumeration for claim lifecycle tracking.
     */
    enum ClaimStatus {
        None, // Claim not yet filed
        Filed, // Claim filed, evaluation pending
        Approved, // Claim approved, payout executed
        Rejected // Claim rejected, no payout
    }

    /**
     * @notice Claim record tracking evaluation progress and outcomes.
     */
    struct ClaimRecord {
        /// @notice Current status of the claim.
        ClaimStatus status;
        /// @notice Address that filed the claim.
        address reporter;
        /// @notice Timestamp when the claim was filed.
        uint256 filedAt;
        /// @notice Timestamp when the claim was resolved (approved or rejected).
        uint256 resolvedAt;
        /// @notice Hash of evidence submitted with the claim.
        bytes32 evidenceHash;
        /// @notice Requested payout amount in payout token terms (must be <= remaining coverage).
        uint256 requestedAmount;
        /// @notice Evaluation result from the Spec (if evaluated).
        ISpec.EvaluationResult evaluationResult;
        /// @notice Amount paid to the beneficiary (in payout token terms).
        uint256 payoutAmount;
    }

    /**
     * @notice Policy claim state tracking total payouts and claim count.
     */
    struct PolicyClaim {
        /// @notice Total amount paid out across all claims for this policy.
        uint256 totalPaidOut;
        /// @notice Number of claims filed for this policy.
        uint256 claimCount;
    }

    /**
     * @notice Emitted when a claim is filed against a policy.
     * @param policyId Identifier of the policy.
     * @param claimId Unique identifier for this claim.
     * @param reporter Address that filed the claim.
     * @param evidenceHash Hash of evidence supporting the claim.
     * @param requestedAmount Requested payout amount in payout token terms.
     * @param timestamp Block timestamp when filed.
     */
    event ClaimFiled(
        uint96 indexed policyId,
        uint256 indexed claimId,
        address indexed reporter,
        bytes32 evidenceHash,
        uint256 requestedAmount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a claim is approved and payout is executed.
     * @param policyId Identifier of the policy.
     * @param claimId Unique identifier for this claim.
     * @param beneficiary Address receiving the payout.
     * @param payoutAmount Amount paid in payout token terms.
     * @param timestamp Block timestamp when approved.
     */
    event ClaimApproved(
        uint96 indexed policyId,
        uint256 indexed claimId,
        address indexed beneficiary,
        uint256 payoutAmount,
        uint256 timestamp
    );

    /**
     * @notice Emitted when a claim is rejected.
     * @param policyId Identifier of the policy.
     * @param claimId Unique identifier for this claim.
     * @param reason Human-readable rejection reason.
     * @param timestamp Block timestamp when rejected.
     */
    event ClaimRejected(uint96 indexed policyId, uint256 indexed claimId, string reason, uint256 timestamp);

    /**
     * @notice Emitted when slashed collateral is swapped to payout token.
     * @param policyId Identifier of the policy.
     * @param claimId Unique identifier for this claim.
     * @param collateralToken Address of the slashed collateral token.
     * @param collateralAmount Amount of collateral swapped.
     * @param payoutToken Address of the payout token.
     * @param payoutAmount Amount received after swap.
     */
    event CollateralSwapped(
        uint96 indexed policyId,
        uint256 indexed claimId,
        address indexed collateralToken,
        uint256 collateralAmount,
        address payoutToken,
        uint256 payoutAmount
    );

    /**
     * @notice Emitted when the SpecRegistry address is updated.
     * @param specRegistry New SpecRegistry address.
     */
    event SpecRegistrySet(address indexed specRegistry);

    /**
     * @notice Emitted when the SlashingManager address is updated.
     * @param slashingManager New SlashingManager address.
     */
    event SlashingManagerSet(address indexed slashingManager);

    /**
     * @notice Emitted when the Swapper address is updated.
     * @param swapper New Swapper address.
     */
    event SwapperSet(address indexed swapper);

    /**
     * @notice Emitted when the PolicyManager address is updated.
     * @param policyManager New PolicyManager address.
     */
    event PolicyManagerSet(address indexed policyManager);

    /**
     * @notice Emitted when the maximum swap slippage tolerance is updated.
     * @param maxSwapSlippageBps New slippage tolerance in basis points.
     */
    event MaxSwapSlippageBpsSet(uint16 maxSwapSlippageBps);

    /**
     * @notice Emitted when the RewardsManager address is updated.
     * @param rewardsManager New RewardsManager address.
     */
    event RewardsManagerSet(address indexed rewardsManager);

    /**
     * @notice Emitted when surplus collateral or payout tokens are distributed as restaker rewards.
     * @dev Surplus arises in two cases: (1) cross-token path — swap output exceeds remainingPayout;
     *      (2) same-token path — slashed collateral exceeds remainingPayout (no swap involved).
     *      In both cases the surplus ERC-20 is forwarded to RewardsManager for restaker distribution.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @param token Address of the ERC-20 token distributed as reward.
     * @param surplusAmount Amount distributed beyond the beneficiary payout.
     */
    event SwapSurplusDistributed(
        uint96 indexed policyId, uint256 indexed claimId, address indexed token, uint256 surplusAmount
    );

    /**
     * @notice Emitted when surplus distribution to RewardsManager fails so the claim is not blocked.
     * @dev The surplus amount remains in this contract and can be recovered via `recoverTokens`.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @param token Address of the ERC-20 token that could not be distributed.
     * @param surplusAmount Amount that failed to distribute.
     */
    event SwapSurplusDistributionFailed(
        uint96 indexed policyId, uint256 indexed claimId, address indexed token, uint256 surplusAmount
    );

    /**
     * @notice Emitted when the pool curator approves the next claim for a policy.
     * @param policyId Identifier of the policy.
     * @param approver Address that granted the approval.
     */
    event NextClaimApproved(uint96 indexed policyId, address indexed approver);

    /**
     * @notice Emitted when stranded tokens or native ETH are recovered by an admin.
     * @param token Token address recovered, or the native ETH sentinel (0xEeee...eeEE).
     * @param to Recipient of the recovered funds.
     * @param amount Amount recovered.
     */
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

    /**
     * @notice Emitted when a vault is excluded from slashing because its collateral token
     *         has no configured or functioning swap route (quoteSwap reverted).
     * @dev Partial exclusion is not reverted; remaining vaults absorb the full claim pro-rata.
     *      Monitor this event to detect misconfigured swap routes before a loss event.
     * @param vault Address of the excluded vault.
     * @param token Collateral token for which the quote failed.
     */
    event VaultExcludedFromSlashing(address indexed vault, address indexed token);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when a required amount is zero.
     */
    error ZeroAmount();

    /**
     * @notice Reverts when attempting to file a claim for a policy that doesn't exist.
     * @param policyId Identifier that failed the lookup.
     */
    error PolicyNotFound(uint96 policyId);

    /**
     * @notice Reverts when attempting to file a claim outside the coverage window.
     * @param policyId Identifier of the policy.
     * @param startTime Coverage start timestamp.
     * @param maturityTime Coverage maturity timestamp.
     * @param currentTime Current block timestamp.
     */
    error ClaimOutsideCoverageWindow(uint96 policyId, uint32 startTime, uint32 maturityTime, uint32 currentTime);

    /**
     * @notice Reverts when the caller is not authorized to file a claim for this policy.
     * @param caller Address that attempted to file the claim.
     * @param expectedClaimer Address authorized to file claims for this policy.
     */
    error UnauthorizedClaimer(address caller, address expectedClaimer);

    /**
     * @notice Reverts when slashing returns no collateral.
     * @param policyId Identifier of the policy.
     */
    error NoCollateralSlashed(uint96 policyId);

    /**
     * @notice Reverts when slashing or swaps result in zero payout amount.
     * @param policyId Identifier of the policy.
     */
    error ZeroPayoutAmount(uint96 policyId);

    /**
     * @notice Reverts when a required evidence hash is empty.
     */
    error InvalidEvidenceHash();

    /**
     * @notice Reverts when an evidence hash has already been used for a previous claim on the same policy.
     * @param policyId Identifier of the policy.
     * @param evidenceHash The evidence hash that was already used.
     */
    error DuplicateEvidenceHash(uint96 policyId, bytes32 evidenceHash);

    /**
     * @notice Reverts when the requested amount exceeds the policy's remaining coverage.
     * @param policyId Identifier of the policy.
     * @param requestedAmount Amount requested by the claimant.
     * @param remainingCoverage Remaining coverage amount after previous claims.
     */
    error RequestedAmountExceedsRemainingCoverage(uint96 policyId, uint256 requestedAmount, uint256 remainingCoverage);

    /**
     * @notice Reverts when the slippage tolerance exceeds the maximum settable bound (3000 bps).
     * @param slippageBps The invalid slippage value provided.
     */
    error InvalidSlippageBps(uint16 slippageBps);

    /**
     * @notice Reverts when a second or subsequent claim is filed before curator approval.
     * @param policyId Identifier of the policy requiring approval.
     */
    error ClaimApprovalRequired(uint96 policyId);

    /**
     * @notice Reverts when the caller is not the pool curator.
     */
    error UnauthorizedApprover();

    /**
     * @notice Reverts when attempting to file a claim for a policy whose holder is in premium default.
     * @param policyId Identifier of the policy in premium default.
     */
    error PremiumDefaulted(uint96 policyId);

    /**
     * @notice Reverts when no valid swap quote is available for the collateral-to-payout route.
     * @param collateralToken Address of the collateral token.
     * @param payoutToken Address of the payout token.
     */
    error QuoteUnavailable(address collateralToken, address payoutToken);

    /**
     * @notice Reverts when previewSlashing returns arrays of different lengths.
     * @param vaultsLength Length of the vaults array.
     * @param tokensLength Length of the tokens array.
     * @param tokenStakesLength Length of the tokenStakes array.
     */
    error SlashingArrayLengthMismatch(uint256 vaultsLength, uint256 tokensLength, uint256 tokenStakesLength);

    /**
     * @notice Reverts when approveNextClaim is called but no approval gate is active.
     * @param policyId Identifier of the policy.
     */
    error NoApprovalPending(uint96 policyId);

    /**
     * @notice Pauses claim operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes claim operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Sets the SpecRegistry address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param specRegistry_ Address of the SpecRegistry contract.
     */
    function setSpecRegistry(address specRegistry_) external;

    /**
     * @notice Sets the SlashingManager address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param slashingManager_ Address of the SlashingManager contract.
     */
    function setSlashingManager(address slashingManager_) external;

    /**
     * @notice Sets the Swapper address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param swapper_ Address of the Swapper contract.
     */
    function setSwapper(address swapper_) external;

    /**
     * @notice Sets the PolicyManager address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param policyManager_ Address of the PolicyManager contract.
     */
    function setPolicyManager(address policyManager_) external;

    /**
     * @notice Sets the maximum allowed slippage for collateral-to-payout swaps.
     * @dev Requires DEFAULT_ADMIN_ROLE. Must be less than 10000 bps (100%).
     * @param maxSwapSlippageBps_ Slippage tolerance in basis points (e.g., 200 = 2%).
     */
    function setMaxSwapSlippageBps(uint16 maxSwapSlippageBps_) external;

    /**
     * @notice Sets the RewardsManager address used to distribute swap surplus as restaker rewards.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param rewardsManager_ Address of the RewardsManager contract. Must be non-zero.
     */
    function setRewardsManager(address rewardsManager_) external;

    /**
     * @notice Files and resolves a claim atomically in a single transaction.
     * @dev Caller must be the policy's designated claimer address. Combines filing and resolution into one atomic
     * operation:
     *      1. Validates claim preconditions and verifies claimer authorization
     *      2. Evaluates the registered Spec for the policy's product
     *      3. If approved: slashes stake → swaps collateral → pays beneficiary
     *      Multiple partial claims can be filed against the same policy up to the coverage limit.
     *
     * @param policyId Identifier of the policy to claim against.
     * @param requestedAmount Requested payout amount in payout token terms (must be <= remaining coverage).
     * @param evidenceHash Hash of evidence supporting the claim (e.g., IPFS CID).
     * @param additionalData Optional ABI-encoded data for Spec evaluation.
     * @return claimId Unique identifier for the filed claim.
     */
    function fileClaim(
        uint96 policyId,
        uint256 requestedAmount,
        bytes32 evidenceHash,
        bytes calldata additionalData
    )
        external
        returns (uint256 claimId);

    /**
     * @notice Returns the claim record for a specific claim.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     * @return ClaimRecord snapshot describing the claim state.
     */
    function claimRecord(uint96 policyId, uint256 claimId) external view returns (ClaimRecord memory);

    /**
     * @notice Returns the policy claim state tracking total payouts.
     * @param policyId Identifier of the policy.
     * @return PolicyClaim snapshot with total paid out and claim count.
     */
    function policyClaim(uint96 policyId) external view returns (PolicyClaim memory);

    /**
     * @notice Returns the remaining coverage available for a policy.
     * @param policyId Identifier of the policy.
     * @return remaining Amount of coverage remaining after all approved claims.
     */
    function remainingCoverage(uint96 policyId) external view returns (uint256 remaining);

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);

    /**
     * @notice Returns the SpecRegistry address.
     */
    function specRegistry() external view returns (address);

    /**
     * @notice Returns the SlashingManager address.
     */
    function slashingManager() external view returns (address);

    /**
     * @notice Returns the Swapper address.
     */
    function swapper() external view returns (address);

    /**
     * @notice Returns the PolicyManager address.
     */
    function policyManager() external view returns (address);

    /**
     * @notice Returns the maximum swap slippage tolerance in basis points.
     */
    function maxSwapSlippageBps() external view returns (uint16);

    /**
     * @notice Returns the RewardsManager address.
     */
    function rewardsManager() external view returns (address);

    /**
     * @notice Clears the claim approval gate for a policy, allowing the next claim to be filed freely.
     * @dev Callable only by the pool curator.
     * @param policyId Identifier of the policy to clear the approval gate for.
     */
    function approveNextClaim(uint96 policyId) external;

    /**
     * @notice Returns whether curator approval is required before the next claim can be filed.
     * @param policyId Identifier of the policy.
     * @return True if approval is required; false if the next claim may be filed freely.
     */
    function claimApprovalRequired(uint96 policyId) external view returns (bool);

    /**
     * @notice Recovers stranded ERC-20 tokens or native ETH from this contract.
     * @dev Requires DEFAULT_ADMIN_ROLE. Use the native ETH sentinel address
     *      (0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) for `token` to recover ETH.
     * @param token Token address to recover, or the native ETH sentinel.
     * @param to Recipient address.
     * @param amount Amount to transfer.
     */
    function recoverTokens(address token, address to, uint256 amount) external;
}
