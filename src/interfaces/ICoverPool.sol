// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";

/**
 * @title ICoverPool
 * @notice Interface defining curator-controlled pool functionality for coverage quotes and bindings.
 * @dev Uses AccessControlDefaultAdminRules for secure 2-step admin transfers with configurable delay.
 *      Implements IERC5313 for standardized owner() access (returns defaultAdmin).
 */
interface ICoverPool is IAccessControl, IAccessControlDefaultAdminRules, IERC5313 {
    /**
     * @notice Signed coverage quote inputs produced by the pool curator.
     * @dev Consumed by PolicyManager to derive deterministic policy commits.
     *      Each quote represents a complete policy from a single pool.
     */
    struct Quote {
        /// @notice Address of the CoverPool issuing the quote.
        address pool;
        /// @notice Restaking committee identifier associated with the policy.
        uint96 committeeId;
        /// @notice Maximum notional coverage in payout token units supplied by this pool.
        uint256 coverageLimit;
        /// @notice Base premium amount owed to the pool for this coverage.
        uint256 basePremium;
        /// @notice Spec identifier the pool intends to use for parametric claims.
        bytes32 specId;
        /// @notice Hash of the pool's policy terms document anchoring off-chain clauses.
        bytes32 termsHash;
        /// @notice Address that will receive claim payouts for this policy.
        address beneficiary;
        /// @notice Policy coverage start timestamp proposed in the quote.
        uint64 startTime;
        /// @notice Restaking operator whose delegation is being covered.
        address operator;
        /// @notice Policy coverage maturity timestamp proposed in the quote.
        uint64 maturityTime;
        /// @notice Expiration timestamp for the signed quote.
        uint64 expirationTime;
    }

    /**
     * @notice Binding metadata returned after a successful policy bind.
     * @dev Contains the confirmed terms and coverage details for the bound policy.
     */
    struct BoundPolicy {
        /// @notice Incremental identifier for the policy.
        uint96 policyId;
        /// @notice Deterministic hash representing the policy schedule.
        bytes32 policyCommit;
        /// @notice Spec identifier attached to the bound policy.
        bytes32 specId;
        /// @notice Terms hash anchored for the bound policy.
        bytes32 termsHash;
        /// @notice Coverage notional allocated from this pool.
        uint256 coverageLimit;
        /// @notice Destination address for potential claim payouts (the policy holder).
        address beneficiary;
        /// @notice Restaking committee identifier for the bound policy.
        uint96 committeeId;
        /// @notice Restaking operator whose delegation the coverage protects.
        address operator;
        /// @notice Policy coverage start timestamp confirmed at bind.
        uint64 startTime;
        /// @notice Policy coverage maturity timestamp confirmed at bind.
        uint64 maturityTime;
    }

    /**
     * @notice Emitted when a policy is successfully recorded and bound against the pool.
     * @param policyCommit Deterministic hash representing the policy.
     * @param policyId Incremental identifier for the policy.
     * @param coverageLimit Coverage notional locked from the pool.
     */
    event BoundPolicyRecorded(bytes32 indexed policyCommit, uint96 indexed policyId, uint256 coverageLimit);

    /**
     * @notice Emitted when the curator updates the pool fee basis points.
     * @param previousPoolFeeBps Pool fee basis points before the update.
     * @param newPoolFeeBps Pool fee basis points after the update.
     */
    event PoolFeeBpsSet(uint16 previousPoolFeeBps, uint16 newPoolFeeBps);

    /**
     * @notice Emitted when a policy is bound through bindPolicyForRequest.
     * @param policyId The policy identifier.
     * @param committeeId The committee identifier.
     * @param vaultCount The number of vaults bound to the committee.
     */
    event PolicyForRequestBound(uint96 indexed policyId, uint96 indexed committeeId, uint256 vaultCount);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when the provided pool address does not match contract storage.
     * @param expected Correct pool address.
     * @param actual Supplied pool address that failed validation.
     */
    error PoolAddressMismatch(address expected, address actual);

    /**
     * @notice Reverts when coverage start and maturity timestamps are mis-ordered.
     */
    error InvalidCoverageWindow();

    /**
     * @notice Reverts when a quote has already expired.
     * @param expirationTime Expiration timestamp encoded within the quote.
     * @param currentTimestamp Current block timestamp at validation.
     */
    error QuoteExpired(uint64 expirationTime, uint256 currentTimestamp);

    /**
     * @notice Reverts when an incoming quote specifies zero coverage.
     */
    error InvalidCoverageLimit();

    /**
     * @notice Reverts when the beneficiary address is zero.
     */
    error InvalidBeneficiary();

    /**
     * @notice Reverts when the operator address is zero.
     */
    error InvalidOperator();

    /**
     * @notice Reverts when a required spec identifier is empty.
     */
    error InvalidSpecId();

    /**
     * @notice Reverts when the terms hash is empty.
     */
    error InvalidTermsHash();

    /**
     * @notice Reverts when a quote is validated but its signature cannot be recovered to the authorized signer.
     */
    error InvalidQuoteSignature();

    /**
     * @notice Reverts when attempting to bind a policy with a commit hash that has already been processed.
     * @param policyCommit Commit hash that was previously bound.
     */
    error PolicyAlreadyBound(bytes32 policyCommit);

    /**
     * @notice Reverts when a supplied policy commit does not match the quote payload.
     * @param expected Recomputed commit derived from the quote payload.
     * @param actual Commit supplied by the caller that failed validation.
     */
    error PolicyCommitMismatch(bytes32 expected, bytes32 actual);

    /**
     * @notice Reverts when querying data for an unknown policy identifier.
     * @param policyId Identifier that failed the lookup.
     */
    error PolicyNotFound(uint96 policyId);

    /**
     * @notice Reverts when attempting to bind using an empty policy commit value.
     */
    error InvalidPolicyCommit();

    /**
     * @notice Reverts when supplied fee values exceed the defined basis-point cap.
     */
    error InvalidFeeBps();

    /**
     * @notice Reverts when attempting to bind an empty array of vaults.
     */
    error EmptyVaults();

    /**
     * @notice Reverts when committee identifier is invalid or mismatched.
     */
    error InvalidCommitteeId();

    /**
     * @notice Initializes the CoverPool clone with roles and quoting configuration.
     * @param curator_ Address assigned as the owner (curator) and operator.
     * @param policyManager_ Address receiving POLICY_MANAGER_ROLE.
     * @param quoteSigner_ Address granted QUOTE_SIGNER_ROLE.
     * @param stakeManager_ Address of the StakeManager contract for vault binding operations.
     * @param poolFeeBps_ Pool fee expressed in basis points and capped by protocol limits.
     */
    function initialize(
        address curator_,
        address policyManager_,
        address quoteSigner_,
        address stakeManager_,
        uint16 poolFeeBps_
    )
        external;

    /**
     * @notice Pauses quoting and policy binding on the pool.
     */
    function pause() external;

    /**
     * @notice Resumes quoting and policy binding on the pool.
     */
    function unpause() external;

    /**
     * @notice Updates the pool fee expressed in basis points.
     * @param poolFeeBps_ Pool fee expressed in basis points and capped by protocol limits.
     */
    function setPoolFeeBps(uint16 poolFeeBps_) external;

    /**
     * @notice Curator entrypoint to bind a policy draft via PolicyManager.
     * @dev Binds vaults, fetches draft from PolicyManager, and forwards binding request.
     * @param policyId Policy draft identifier from PolicyManager.
     * @param quote Quote struct signed by an authorized quote signer.
     * @param signature EIP-712 signature authorizing the quote.
     * @param vaults Vault addresses to bind to the committee.
     */
    function bindPolicyForRequest(
        uint96 policyId,
        Quote calldata quote,
        bytes calldata signature,
        address[] calldata vaults
    )
        external;

    /**
     * @notice Returns whether a policy commit has already been bound.
     * @param policyCommit Deterministic hash representing the policy.
     * @return True if the policy commit has been bound, false otherwise.
     */
    function boundPolicyCommits(bytes32 policyCommit) external view returns (bool);

    /**
     * @notice EIP-712 domain separator used when verifying quote signatures.
     * @return The EIP-712 domain separator hash.
     */
    function quoteDomainSeparator() external view returns (bytes32);

    /**
     * @notice Fetches bound policy metadata by incremental identifier.
     * @param policyId Identifier returned during binding.
     * @return BoundPolicy metadata describing the allocation.
     */
    function getBoundPolicy(uint96 policyId) external view returns (BoundPolicy memory);

    /**
     * @notice Pool fee expressed in basis points that is applied to premiums.
     * @return The pool fee in basis points.
     */
    function poolFeeBps() external view returns (uint16);

    /**
     * @notice Returns the PolicyManager address used for binding.
     */
    function policyManager() external view returns (address);

    /**
     * @notice Returns the StakeManager address used for vault binding operations.
     */
    function stakeManager() external view returns (address);

    /**
     * @notice AccessControl identifier for the PolicyManager binding role.
     * @return The role identifier hash.
     */
    function POLICY_MANAGER_ROLE() external pure returns (bytes32);

    /**
     * @notice AccessControl identifier for approved quote signers.
     * @return The role identifier hash.
     */
    function QUOTE_SIGNER_ROLE() external pure returns (bytes32);
}
