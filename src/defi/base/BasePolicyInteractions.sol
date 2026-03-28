// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IPolicyManager} from "coverage/interfaces/IPolicyManager.sol";
import {IClaimManager} from "coverage/interfaces/IClaimManager.sol";
import {ICoverPool} from "coverage/interfaces/ICoverPool.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";

/**
 * @title BasePolicyInteractions
 * @notice Upgradeable base contract for interacting with Catalysis policy and claim management.
 * @dev This is a simpler version of PolicyInteractions without the upgradeable pattern.
 *      Designed for use in non-proxy contracts like Bundler3 adapters.
 */
abstract contract BasePolicyInteractions is Initializable, ISpec {
    // ========================================
    // Storage
    // ========================================

    /// @notice ClaimManager contract for filing and resolving claims.
    IClaimManager internal claimManager;

    /// @notice PolicyManager contract for querying policy metadata.
    IPolicyManager internal _policyManager;

    /// @notice The address of cover pool corresponding to the Adapter.
    address internal coverPool;

    // ========================================
    // Errors
    // ========================================

    /// @notice Reverts when querying a policy that doesn't exist.
    error PolicyNotFound();

    /// @notice Reverts when a required address argument is zero.
    error ZeroAddress();

    /// @notice Reverts when ClaimManager's policyManager doesn't match the provided PolicyManager.
    error PolicyManagerMismatch();

    /// @notice Reverts when the coverPool address is invalid (not a properly initialized CoverPool).
    error InvalidCoverPoolAddress();

    /// @notice Reverts when a required evidence hash is empty.
    error InvalidEvidenceHash();

    // ========================================
    // Initializer
    // ========================================

    /**
     * @notice Initializes the PolicyInteractions contract with required Catalysis protocol contracts.
     * @param policyManager_ Address of the PolicyManager contract.
     * @param claimManager_ Address of the ClaimManager contract.
     * @param pool_ Address of the CoverPool contract.
     */
    function __BasePolicyInteractions_init(
        address policyManager_,
        address claimManager_,
        address pool_
    )
        internal
        onlyInitializing
    {
        if (policyManager_ == address(0) || claimManager_ == address(0) || pool_ == address(0)) {
            revert ZeroAddress();
        }

        // Sanity check: verify ClaimManager references the same PolicyManager
        if (IClaimManager(claimManager_).policyManager() != policyManager_) {
            revert PolicyManagerMismatch();
        }

        // Validate coverPool by calling quoteDomainSeparator() - this verifies it's a valid initialized CoverPool
        if (ICoverPool(pool_).quoteDomainSeparator() == bytes32(0)) {
            revert InvalidCoverPoolAddress();
        }

        _policyManager = IPolicyManager(policyManager_);
        claimManager = IClaimManager(claimManager_);
        coverPool = pool_;
    }

    // ========================================
    // Internal Functions
    // ========================================

    /**
     * @notice Internal function to file and resolve a claim against a policy atomically.
     * @dev Used by coverage adapters. CoveredVaultWrapper uses claimManager.fileClaim() directly.
     * @param policyId The policy ID to file claim against.
     * @param requestedAmount The requested payout amount in payout token terms.
     * @param evidenceHash Hash of evidence supporting the claim.
     * @param additionalData Optional ABI-encoded data for Spec evaluation.
     * @return claimId The unique identifier for the filed claim.
     */
    // slither-disable-next-line incorrect-equality
    function _fileAndResolveClaim(
        uint96 policyId,
        uint256 requestedAmount,
        bytes32 evidenceHash,
        bytes memory additionalData
    )
        internal
        returns (uint256 claimId)
    {
        if (evidenceHash == bytes32(0)) {
            revert InvalidEvidenceHash();
        }

        // Validate policy exists before filing claim
        IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);
        if (metadata.buyer == address(0)) {
            revert PolicyNotFound();
        }

        claimId = claimManager.fileClaim(policyId, requestedAmount, evidenceHash, additionalData);
    }

    /**
     * @notice Internal function to get the coverage parameters for a policy.
     * @param policyId The policy ID to query.
     * @return coverageLimit The maximum coverage amount in payout token terms.
     * @return payoutToken The token address used for claim payouts.
     */
    function _getCoverageParams(uint96 policyId) internal view returns (uint256 coverageLimit, address payoutToken) {
        IPolicyManager.PolicyMetadata memory metadata = _policyManager.policyMetadata(policyId);

        if (metadata.buyer == address(0)) {
            revert PolicyNotFound();
        }

        coverageLimit = metadata.coverageLimit;
        payoutToken = metadata.payoutToken;
    }

    /**
     * @notice Internal function to get the total amount of cover already paid out for a policy.
     * @param policyId The policy ID to query.
     * @return paidAmount The total amount paid out in payout token terms.
     */
    function _getPaidCover(uint96 policyId) internal view returns (uint256 paidAmount) {
        IClaimManager.PolicyClaim memory policyClaim = claimManager.policyClaim(policyId);
        paidAmount = policyClaim.totalPaidOut;
    }

    // ========================================
    // External Functions (ISpec Implementation)
    // ========================================

    /**
     * @notice External function to evaluate if a policy claim should be paid out.
     * @dev Inheriting contracts MUST override this function.
     * @param context Evaluation parameters including policy details and evidence.
     * @return result The evaluation result.
     */
    function evaluate(ISpec.EvaluationContext calldata context)
        external
        view
        virtual
        override
        returns (ISpec.EvaluationResult memory result);

    uint256[50] private __gap;
}
