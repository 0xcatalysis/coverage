// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IOwnable2Step} from "./IOwnable2Step.sol";

/**
 * @title ICoverPool
 * @notice Interface defining curator-controlled pool functionality for coverage quotes and bindings.
 */
interface ICoverPool is IAccessControlEnumerable, IOwnable2Step {
    /**
     * @notice Signed coverage quote inputs produced by the pool curator.
     * @dev Consumed by PolicyManager to derive deterministic policy commits.
     */
    struct QuoteData {
        /// @notice Registry identifier for the CoverPool issuing the quote.
        uint256 poolId;
        /// @notice Maximum notional coverage in payout token units supplied by this pool.
        uint256 coverageLimit;
        /// @notice Base premium amount owed to the pool for this coverage slice.
        uint256 basePremium;
        /// @notice Risk buffer deposit that must be escrowed alongside the premium.
        uint256 riskBufferDeposit;
        /// @notice Spec identifier the pool intends to use for parametric claims.
        bytes32 specId;
        /// @notice Hash of the pool's policy terms document anchoring off-chain clauses.
        bytes32 termsHash;
        /// @notice Address that will receive claim payouts for this pool slice.
        address payoutReceiver;
        /// @notice Restaking committee identifier associated with the policy slice.
        uint96 committeeId;
        /// @notice Operator address registered for this policy slice.
        address operator;
        /// @notice Policy coverage start timestamp proposed in the quote.
        uint64 startTime;
        /// @notice Policy coverage maturity timestamp proposed in the quote.
        uint64 maturityTime;
        /// @notice Expiration timestamp for the signed quote.
        uint64 quoteExpiry;
    }

    /**
     * @notice Pool-specific binding metadata returned after a successful bind.
     * @dev Persisted by PolicyManager and PolicyToken to reconstruct per-pool schedules.
     */
    struct BoundPolicy {
        /// @notice Pool-chosen identifier for the bound policy slice.
        bytes32 poolPolicyId;
        /// @notice Spec identifier attached to the bound policy slice.
        bytes32 specId;
        /// @notice Terms hash anchored for the bound policy slice.
        bytes32 termsHash;
        /// @notice Coverage notional allocated from this pool.
        uint256 coverageLimit;
        /// @notice Destination address for potential claim payouts.
        address payoutAddress;
        /// @notice Restaking committee identifier for the bound policy slice.
        uint96 committeeId;
        /// @notice Operator address responsible for this policy slice.
        address operator;
        /// @notice Policy coverage start timestamp confirmed at bind.
        uint64 startTime;
        /// @notice Policy coverage maturity timestamp confirmed at bind.
        uint64 maturityTime;
    }

    /**
     * @notice Emitted after a policy commit binds successfully against the pool.
     * @param policyCommit Deterministic hash referencing the multi-pool policy schedule.
     * @param poolPolicyId Pool-provided identifier for the policy slice.
     * @param coverageLimit Coverage notional locked from the pool.
     */
    event PolicyBound(bytes32 indexed policyCommit, bytes32 indexed poolPolicyId, uint256 coverageLimit);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when the provided pool id does not match contract storage.
     * @param expected Correct pool id stored on the contract.
     * @param actual Supplied pool id that failed validation.
     */
    error PoolIdMismatch(uint256 expected, uint256 actual);

    /**
     * @notice Reverts when coverage start and maturity timestamps are mis-ordered.
     */
    error InvalidCoverageWindow();

    /**
     * @notice Reverts when a quote has already expired.
     * @param quoteExpiry Expiration timestamp encoded within the quote.
     * @param currentTimestamp Current block timestamp at validation.
     */
    error QuoteExpired(uint64 quoteExpiry, uint256 currentTimestamp);

    /**
     * @notice Reverts when an incoming quote specifies zero coverage.
     */
    error InvalidCoverageLimit();

    /**
     * @notice Reverts when payout or operator addresses are missing.
     */
    error InvalidQuoteRecipient();

    /**
     * @notice Reverts when a quote is validated but its signature cannot be recovered to the authorized signer.
     */
    error QuoteSignatureInvalid();

    /**
     * @notice Reverts when attempting to initialize or operate on an invalid pool id.
     */
    error InvalidPoolId();

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
     * @param poolPolicyId Identifier that failed the lookup.
     */
    error PolicyNotFound(bytes32 poolPolicyId);

    /**
     * @notice Reverts when attempting to bind using an empty policy commit value.
     */
    error InvalidPolicyCommit();

    /**
     * @notice Initializes the CoverPool clone with roles and quoting configuration.
     * @param poolId_ Pool identifier assigned by the CoverPoolRegistry.
     * @param curator_ Address assigned as the owner (curator).
     * @param policyManager_ Address receiving POLICY_MANAGER_ROLE.
     * @param quoteSigner_ Address granted QUOTE_SIGNER_ROLE.
     */
    function initialize(
        uint256 poolId_,
        address curator_,
        address policyManager_,
        address quoteSigner_
    )
        external;

    /**
     * @notice Locks coverage for a previously validated policy commit.
     * @dev Requires POLICY_MANAGER_ROLE.
     * @param policyCommit Deterministic hash for the overall policy schedule.
     * @param quote Quote data that has been validated for binding.
     * @return BoundPolicy metadata describing the pool's final allocation.
     */
    function bindPolicy(bytes32 policyCommit, QuoteData calldata quote) external returns (BoundPolicy memory);

    /**
     * @notice Returns the registry identifier of this CoverPool.
     */
    function poolId() external view returns (uint256);

    /**
     * @notice Returns whether a policy commit has already been bound.
     */
    function policyCommitBound(bytes32 policyCommit) external view returns (bool);

    /**
     * @notice EIP-712 domain separator used when verifying quote signatures.
     */
    function quoteDomainSeparator() external view returns (bytes32);

    /**
     * @notice Fetches bound policy metadata by pool-specific identifier.
     * @param poolPolicyId Identifier returned during binding.
     * @return BoundPolicy metadata describing the allocation.
     */
    function getPoolPolicy(bytes32 poolPolicyId) external view returns (BoundPolicy memory);

    /**
     * @notice Verifies a quoted policy slice and returns the resulting policy commit hash.
     * @param quote Quote data struct signed by an authorized quote signer.
     * @param signature EIP-712 signature authorizing the quote.
     * @return policyCommit Hash tying the quote to the global policy schedule.
     */
    function validateQuote(
        QuoteData calldata quote,
        bytes calldata signature
    )
        external
        view
        returns (bytes32 policyCommit);

    /**
     * @notice AccessControl identifier for the PolicyManager binding role.
     */
    function POLICY_MANAGER_ROLE() external pure returns (bytes32);

    /**
     * @notice AccessControl identifier for approved quote signers.
     */
    function QUOTE_SIGNER_ROLE() external pure returns (bytes32);
}
