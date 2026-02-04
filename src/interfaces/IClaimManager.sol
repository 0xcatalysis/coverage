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
     * @notice Emitted when the Policy address is updated.
     * @param policy New Policy address.
     */
    event PolicySet(address indexed policy);

    /**
     * @notice Emitted when the PremiumReserve address is updated.
     * @param premiumReserve New PremiumReserve address.
     */
    event PremiumReserveSet(address indexed premiumReserve);

    /**
     * @notice Emitted when the ChainlinkPriceFeed address is updated.
     * @param chainlinkPriceFeed New ChainlinkPriceFeed address.
     */
    event ChainlinkPriceFeedSet(address indexed chainlinkPriceFeed);

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
     * @notice Reverts when attempting to file a claim that has already been filed.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     */
    error ClaimAlreadyFiled(uint96 policyId, uint256 claimId);

    /**
     * @notice Reverts when attempting to resolve a claim that has already been resolved.
     * @param policyId Identifier of the policy.
     * @param claimId Identifier of the claim.
     */
    error ClaimAlreadyResolved(uint96 policyId, uint256 claimId);

    /**
     * @notice Reverts when attempting to file a claim outside the coverage window.
     * @param policyId Identifier of the policy.
     * @param startTime Coverage start timestamp.
     * @param maturityTime Coverage maturity timestamp.
     * @param currentTime Current block timestamp.
     */
    error ClaimOutsideCoverageWindow(uint96 policyId, uint64 startTime, uint64 maturityTime, uint256 currentTime);

    /**
     * @notice Reverts when the escrow is already released.
     * @param policyId Identifier of the policy.
     */
    error EscrowAlreadyReleased(uint96 policyId);

    /**
     * @notice Reverts when spec evaluation returns non-payable result.
     * @param policyId Identifier of the policy.
     * @param notesHash Hash of evaluation notes.
     */
    error ClaimNotPayable(uint96 policyId, bytes32 notesHash);

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
     * @notice Reverts when the requested amount exceeds the policy's remaining coverage.
     * @param policyId Identifier of the policy.
     * @param requestedAmount Amount requested by the claimant.
     * @param remainingCoverage Remaining coverage amount after previous claims.
     */
    error RequestedAmountExceedsRemainingCoverage(uint96 policyId, uint256 requestedAmount, uint256 remainingCoverage);

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
     * @notice Sets the Policy address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param policy_ Address of the Policy contract.
     */
    function setPolicy(address policy_) external;

    /**
     * @notice Sets the PremiumReserve address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param premiumReserve_ Address of the PremiumReserve contract.
     */
    function setPremiumReserve(address premiumReserve_) external;

    /**
     * @notice Sets the ChainlinkPriceFeed address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param chainlinkPriceFeed_ Address of the ChainlinkPriceFeed contract.
     */
    function setChainlinkPriceFeed(address chainlinkPriceFeed_) external;

    /**
     * @notice Files and resolves a claim atomically in a single transaction.
     * @dev Requires CLAIM_OPERATOR_ROLE. Combines filing and resolution into one atomic operation:
     *      1. Validates claim preconditions and locks escrow
     *      2. Evaluates the registered Spec for the policy's product
     *      3. If approved: executes premium waterfall → slashes shortfall → swaps → pays beneficiary
     *      4. Unlocks escrow regardless of outcome
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
     * @notice Returns the number of pending (filed but not resolved) claims for a policy.
     * @dev Escrow is locked when pendingClaimCount > 0 and unlocked when it reaches 0.
     * @param policyId Identifier of the policy.
     * @return count Number of pending claims.
     */
    function pendingClaimCount(uint96 policyId) external view returns (uint256 count);

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);

    /**
     * @notice AccessControl identifier for the claim operator role.
     */
    function CLAIM_OPERATOR_ROLE() external view returns (bytes32);

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
     * @notice Returns the Policy address.
     */
    function policy() external view returns (address);

    /**
     * @notice Returns the PremiumReserve address.
     */
    function premiumReserve() external view returns (address);

    /**
     * @notice Returns the ChainlinkPriceFeed address.
     */
    function chainlinkPriceFeed() external view returns (address);
}
