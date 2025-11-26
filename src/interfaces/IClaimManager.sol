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
        /// @notice Evaluation result from the Spec (if evaluated).
        ISpec.EvaluationResult evaluationResult;
        /// @notice Amount paid to the beneficiary (in payout token terms).
        uint256 payoutAmount;
    }

    /**
     * @notice Emitted when a claim is filed against a policy.
     * @param policyId Identifier of the policy.
     * @param reporter Address that filed the claim.
     * @param evidenceHash Hash of evidence supporting the claim.
     * @param timestamp Block timestamp when filed.
     */
    event ClaimFiled(uint256 indexed policyId, address indexed reporter, bytes32 evidenceHash, uint256 timestamp);

    /**
     * @notice Emitted when a claim is approved and payout is executed.
     * @param policyId Identifier of the policy.
     * @param beneficiary Address receiving the payout.
     * @param payoutAmount Amount paid in payout token terms.
     * @param timestamp Block timestamp when approved.
     */
    event ClaimApproved(uint256 indexed policyId, address indexed beneficiary, uint256 payoutAmount, uint256 timestamp);

    /**
     * @notice Emitted when a claim is rejected.
     * @param policyId Identifier of the policy.
     * @param reason Human-readable rejection reason.
     * @param timestamp Block timestamp when rejected.
     */
    event ClaimRejected(uint256 indexed policyId, string reason, uint256 timestamp);

    /**
     * @notice Emitted when slashed collateral is swapped to payout token.
     * @param policyId Identifier of the policy.
     * @param collateralToken Address of the slashed collateral token.
     * @param collateralAmount Amount of collateral swapped.
     * @param payoutToken Address of the payout token.
     * @param payoutAmount Amount received after swap.
     */
    event CollateralSwapped(
        uint256 indexed policyId,
        address indexed collateralToken,
        uint256 collateralAmount,
        address indexed payoutToken,
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
    error PolicyNotFound(uint256 policyId);

    /**
     * @notice Reverts when attempting to file a claim that has already been filed.
     * @param policyId Identifier of the policy.
     */
    error ClaimAlreadyFiled(uint256 policyId);

    /**
     * @notice Reverts when attempting to resolve a claim that hasn't been filed.
     * @param policyId Identifier of the policy.
     */
    error ClaimNotFiled(uint256 policyId);

    /**
     * @notice Reverts when attempting to resolve a claim that has already been resolved.
     * @param policyId Identifier of the policy.
     */
    error ClaimAlreadyResolved(uint256 policyId);

    /**
     * @notice Reverts when attempting to file a claim outside the coverage window.
     * @param policyId Identifier of the policy.
     * @param startTime Coverage start timestamp.
     * @param maturityTime Coverage maturity timestamp.
     * @param currentTime Current block timestamp.
     */
    error ClaimOutsideCoverageWindow(uint256 policyId, uint64 startTime, uint64 maturityTime, uint256 currentTime);

    /**
     * @notice Reverts when the escrow is already released.
     * @param policyId Identifier of the policy.
     */
    error EscrowAlreadyReleased(uint256 policyId);

    /**
     * @notice Reverts when spec evaluation returns non-payable result.
     * @param policyId Identifier of the policy.
     * @param notesHash Hash of evaluation notes.
     */
    error ClaimNotPayable(uint256 policyId, bytes32 notesHash);

    /**
     * @notice Reverts when slashing returns no collateral.
     * @param policyId Identifier of the policy.
     */
    error NoCollateralSlashed(uint256 policyId);

    /**
     * @notice Reverts when slashing or swaps result in zero payout amount.
     * @param policyId Identifier of the policy.
     */
    error ZeroPayoutAmount(uint256 policyId);

    /**
     * @notice Reverts when a required evidence hash is empty.
     */
    error InvalidEvidenceHash();

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
     * @notice Files a claim against a policy and locks the escrow.
     * @dev Anyone can file a claim (spam deterred by off-chain bond and rate limits).
     *      Locks the escrow to prevent premium release during evaluation.
     *      Does not automatically evaluate; requires separate resolveClaim call.
     * @param policyId Identifier of the policy to claim against.
     * @param evidenceHash Hash of evidence supporting the claim (e.g., IPFS CID).
     */
    function fileClaim(uint256 policyId, bytes32 evidenceHash) external;

    /**
     * @notice Resolves a filed claim by evaluating the Spec and executing payout if approved.
     * @dev Requires CLAIM_OPERATOR_ROLE.
     *      Evaluates the registered Spec for the policy's product.
     *      If approved: slashes stake, swaps collateral via pre-configured routes, pays beneficiary, unlocks escrow.
     *      If rejected: unlocks escrow without payout.
     * @param policyId Identifier of the policy to resolve.
     * @param additionalData Optional ABI-encoded data for Spec evaluation.
     */
    function resolveClaim(uint256 policyId, bytes calldata additionalData) external;

    /**
     * @notice Manually rejects a claim without Spec evaluation.
     * @dev Requires CLAIM_OPERATOR_ROLE.
     *      Used for administrative rejections (e.g., fraud, invalid evidence).
     *      Unlocks escrow without payout.
     * @param policyId Identifier of the policy.
     * @param reason Human-readable rejection reason.
     */
    function rejectClaim(uint256 policyId, string calldata reason) external;

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
     * @notice Returns the claim record for a policy.
     * @param policyId Identifier to query.
     * @return ClaimRecord snapshot describing the claim state.
     */
    function claimRecord(uint256 policyId) external view returns (ClaimRecord memory);

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);
}

