// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title ISpec
 * @notice Interface for parametric claim evaluation logic.
 * @dev Third-party implementations define protocol-specific rules that map on-chain/off-chain data
 *      to deterministic claim outcomes. Each vertical (Morpho, Maple, Ethena, etc.) provides
 *      versioned Spec contracts that ClaimManager invokes during claim resolution.
 */
interface ISpec {
    /**
     * @notice Evaluation result containing claim decision and payout details.
     */
    struct EvaluationResult {
        /// @notice True if the claim should be paid, false if rejected.
        bool isPayable;
        /// @notice Amount to pay in USD terms (18 decimals).
        uint256 amountUsd;
        /// @notice Hash of evaluation notes/evidence for auditability.
        bytes32 notesHash;
    }

    /**
     * @notice Evaluation context passed by ClaimManager to the Spec.
     */
    struct EvaluationContext {
        /// @notice Policy identifier being evaluated.
        uint256 policyId;
        /// @notice Address of the pool providing coverage.
        address pool;
        /// @notice Maximum coverage limit from the policy.
        uint256 coverageLimit;
        /// @notice Policy start timestamp.
        uint64 startTime;
        /// @notice Policy maturity timestamp.
        uint64 maturityTime;
        /// @notice Block timestamp when evaluation is performed.
        uint256 evaluationTime;
        /// @notice Hash of evidence submitted with the claim.
        bytes32 evidenceHash;
        /// @notice Additional context data (ABI-encoded product-specific parameters).
        bytes additionalData;
    }

    /**
     * @notice Evaluates a claim using deterministic on-chain/off-chain data.
     * @dev Called by ClaimManager during claim resolution.
     * @param context Evaluation parameters including policy details and evidence.
     * @return result Evaluation outcome with payout decision and amount.
     */
    function evaluate(EvaluationContext calldata context) external view returns (EvaluationResult memory result);
}
