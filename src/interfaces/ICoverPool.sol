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
        address payoutReceiver;
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
     * @notice Status of a policy draft within the CoverPool.
     */
    enum PolicyStatus {
        None,
        Created,
        Cancelled,
        Bound
    }

    /**
     * @notice Buyer request data stored before a policy is bound.
     */
    struct PolicyDraft {
        /// @notice Buyer wallet responsible for paying premiums.
        address buyer;
        /// @notice Beneficiary receiving payouts upon approved claims.
        address beneficiary;
        /// @notice Account authorized to trigger claims for the policy.
        address claimer;
        /// @notice ERC20 token used for premium payments.
        address premiumToken;
        /// @notice ERC20 token used for claim payouts.
        address payoutToken;
        /// @notice Coverage amount requested (stake requirement in USD with 8 decimals).
        uint256 coverageAmount;
        /// @notice Restaking committee identifier created for this policy.
        uint96 committeeId;
        /// @notice Draft lifecycle status.
        PolicyStatus status;
    }

    /**
     * @notice Binding metadata returned after a successful policy bind.
     * @dev Contains the confirmed terms and coverage details for the bound policy.
     */
    struct BoundPolicy {
        /// @notice Pool-provided identifier for the policy.
        uint256 policyId;
        /// @notice Spec identifier attached to the bound policy.
        bytes32 specId;
        /// @notice Terms hash anchored for the bound policy.
        bytes32 termsHash;
        /// @notice Coverage notional allocated from this pool.
        uint256 coverageLimit;
        /// @notice Destination address for potential claim payouts (the policy holder).
        address payoutReceiver;
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
     * @param policyId Pool-provided identifier for the policy.
     * @param coverageLimit Coverage notional locked from the pool.
     */
    event BoundPolicyRecorded(bytes32 indexed policyCommit, uint256 indexed policyId, uint256 coverageLimit);

    /**
     * @notice Emitted when a buyer requests coverage, creating a policy draft.
     * @param policyId Pool-assigned identifier reserved for binding.
     * @param buyer Buyer address requesting coverage.
     * @param beneficiary Beneficiary address for claims.
     * @param claimer Account authorized to trigger claims.
     * @param coverageAmount Requested coverage amount (stake requirement).
     */
    event CoverageRequested(
        uint256 indexed policyId,
        address indexed buyer,
        address indexed beneficiary,
        address claimer,
        uint256 coverageAmount
    );

    /**
     * @notice Emitted when a buyer cancels a draft coverage request before binding.
     * @param policyId Identifier of the cancelled coverage request.
     */
    event CoverageRequestCancelled(uint256 indexed policyId);

    /**
     * @notice Emitted when the curator updates the pool fee basis points.
     * @param previousPoolFeeBps Pool fee basis points before the update.
     * @param newPoolFeeBps Pool fee basis points after the update.
     */
    event PoolFeeBpsSet(uint16 previousPoolFeeBps, uint16 newPoolFeeBps);

    /**
     * @notice Emitted when the default operator is updated.
     * @param previousOperator Operator before the update.
     * @param newOperator Operator after the update.
     */
    event PoolOperatorSet(address indexed previousOperator, address indexed newOperator);

    /**
     * @notice Emitted when the curator binds vaults to a committee.
     * @param committeeId The committee identifier.
     * @param vaultCount The number of vaults bound to the committee.
     */
    event VaultsBound(uint96 indexed committeeId, uint256 vaultCount);

    /**
     * @notice Emitted when a policy is bound through bindPolicyForRequest.
     * @param policyId The policy identifier.
     * @param committeeId The committee identifier.
     * @param vaultCount The number of vaults bound to the committee.
     */
    event PolicyForRequestBound(uint256 indexed policyId, uint96 indexed committeeId, uint256 vaultCount);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when a requested coverage amount is zero.
     */
    error InvalidCoverageAmount();

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
     * @notice Reverts when the payout receiver address is zero.
     */
    error InvalidPayoutReceiver();

    /**
     * @notice Reverts when the operator address is zero.
     */
    error InvalidOperator();

    /**
     * @notice Reverts when the pool operator address is zero.
     */
    error InvalidPoolOperator();

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
     * @notice Reverts when querying data for an unknown pool policy identifier.
     * @param policyId Identifier that failed the lookup.
     */
    error PolicyNotFound(uint256 policyId);

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
     * @notice Reverts when an invalid policy identifier is supplied.
     */
    error InvalidPolicyId();

    /**
     * @notice Reverts when a policy is not in the expected draft status.
     * @param status Current status of the policy draft.
     */
    error InvalidPolicyStatus(PolicyStatus status);

    /**
     * @notice Reverts when a policy draft has not been created.
     * @param policyId Identifier that failed lookup.
     */
    error PolicyDraftNotFound(uint256 policyId);

    /**
     * @notice Reverts when a quote committeeId does not match the draft committeeId.
     * @param expected Committee identifier stored on the draft.
     * @param actual Committee identifier supplied in the quote.
     */
    error CommitteeIdMismatch(uint96 expected, uint96 actual);

    /**
     * @notice Reverts when a quote operator does not match the draft operator.
     * @param expected Operator stored on the draft.
     * @param actual Operator supplied in the quote.
     */
    error OperatorMismatch(address expected, address actual);

    /**
     * @notice Reverts when a non-buyer attempts to cancel a draft.
     * @param caller Address that attempted cancellation.
     */
    error NotPolicyBuyer(address caller);

    /**
     * @notice Reverts when payout receiver does not match the draft beneficiary.
     * @param expected Beneficiary stored on the draft.
     * @param actual Payout receiver supplied in the quote.
     */
    error PayoutReceiverMismatch(address expected, address actual);

    /**
     * @notice Initializes the CoverPool clone with roles and quoting configuration.
     * @param curator_ Address assigned as the owner (curator).
     * @param policyManager_ Address receiving POLICY_MANAGER_ROLE.
     * @param quoteSigner_ Address granted QUOTE_SIGNER_ROLE.
     * @param stakeManager_ Address of the StakeManager contract for vault binding operations.
     * @param poolFeeBps_ Pool fee expressed in basis points and capped by protocol limits.
     * @param poolOperator_ Default operator address used for new policy drafts.
     */
    function initialize(
        address curator_,
        address policyManager_,
        address quoteSigner_,
        address stakeManager_,
        uint16 poolFeeBps_,
        address poolOperator_
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
     * @notice Sets the default operator used for new policy drafts.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param operator_ Operator address to set.
     */
    function setPoolOperator(address operator_) external;

    /**
     * @notice Creates a policy draft and prepares the committee for coverage.
     * @dev Returns a policyId that will be minted upon binding. No NFT is minted here.
     * @param beneficiary Address receiving payouts upon approved claims.
     * @param claimer Account authorized to trigger claims for the policy.
     * @param premiumToken ERC20 token used for premium payments.
     * @param payoutToken ERC20 token used for claim payouts.
     * @param coverageAmount Requested coverage amount (stake requirement in USD with 8 decimals).
     * @return policyId Identifier reserved for binding and minting.
     */
    function requestCoverage(
        address beneficiary,
        address claimer,
        address premiumToken,
        address payoutToken,
        uint256 coverageAmount
    )
        external
        returns (uint256 policyId);

    /**
     * @notice Cancels a previously created policy draft.
     * @dev Only the original buyer can cancel, and only before binding.
     * @param policyId Identifier of the draft to cancel.
     */
    function cancelCoverageRequest(uint256 policyId) external;

    /**
     * @notice Curator entrypoint to bind a policy draft via PolicyManager.
     * @dev Binds vaults, assembles BindPolicyRequest, and forwards to PolicyManager.
     * @param policyId Policy draft identifier returned during requestCoverage.
     * @param quote Quote struct signed by an authorized quote signer.
     * @param signature EIP-712 signature authorizing the quote.
     * @param vaults Vault addresses to bind to the committee.
     */
    function bindPolicyForRequest(
        uint256 policyId,
        Quote calldata quote,
        bytes calldata signature,
        address[] calldata vaults
    )
        external;

    /**
     * @notice Locks coverage for a previously validated policy commit.
     * @dev Requires POLICY_MANAGER_ROLE. Each binding represents a complete policy from this pool.
     *      Signature validation must be performed by the caller via verifyQuote() before calling this function.
     * @param policyId Pool-provided identifier for the policy.
     * @param policyCommit Deterministic hash representing the policy.
     * @param quote Quote that has been validated for binding.
     * @return BoundPolicy metadata describing the pool's coverage allocation.
     */
    function recordBoundPolicy(
        uint256 policyId,
        bytes32 policyCommit,
        Quote calldata quote
    )
        external
        returns (BoundPolicy memory);

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
     * @notice Returns draft request data for a policyId.
     * @param policyId Identifier of the draft to fetch.
     * @return PolicyDraft request snapshot.
     */
    function getCoverageRequest(uint256 policyId) external view returns (PolicyDraft memory);

    /**
     * @notice Fetches bound policy metadata by pool-specific identifier.
     * @param policyId Identifier returned during binding.
     * @return BoundPolicy metadata describing the allocation.
     */
    function getBoundPolicy(uint256 policyId) external view returns (BoundPolicy memory);

    /**
     * @notice Verifies a coverage quote and returns the resulting policy commit hash.
     * @param quote Quote struct signed by an authorized quote signer.
     * @param signature EIP-712 signature authorizing the quote.
     * @return policyCommit Deterministic hash representing the policy.
     */
    function verifyQuote(Quote calldata quote, bytes calldata signature) external view returns (bytes32 policyCommit);

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

    /**
     * @notice Pool fee expressed in basis points that is applied to premiums.
     * @return The pool fee in basis points.
     */
    function poolFeeBps() external view returns (uint16);

    /**
     * @notice Returns the default operator address used for new policy drafts.
     */
    function poolOperator() external view returns (address);

    /**
     * @notice Returns the PolicyManager address used for binding.
     */
    function policyManager() external view returns (address);
}
