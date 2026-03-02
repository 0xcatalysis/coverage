// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ICoverPool} from "./ICoverPool.sol";

/**
 * @title IPolicyManager
 * @notice Interface for orchestrating policy bindings, premium settlement, and policy receipt minting.
 */
interface IPolicyManager is IAccessControl {
    /**
     * @notice Status of a policy draft.
     */
    enum PolicyStatus {
        None,
        Created,
        Cancelled,
        Bound
    }

    /**
     * @notice Policy draft data stored before a policy is bound.
     */
    struct PolicyDraft {
        /// @notice Cover pool where this draft was created.
        address pool;
        /// @notice Buyer wallet responsible for paying premiums.
        address buyer;
        /// @notice Beneficiary receiving payouts upon approved claims.
        address beneficiary;
        /// @notice Account authorized to trigger claims for the policy.
        address claimer;
        /// @notice ERC20 token used for claim payouts.
        address payoutToken;
        /// @notice Coverage amount requested (stake requirement in USD with 8 decimals).
        uint256 coverageAmount;
        /// @notice Coverage duration requested (in seconds).
        uint32 duration;
        /// @notice Policy identifier (1:1 with committee).
        uint96 policyId;
        /// @notice Draft lifecycle status.
        PolicyStatus status;
        /// @notice Callback target invoked when policy is bound (required).
        address bindPolicyHook;
    }

    /**
     * @notice Comprehensive metadata persisted alongside each policy.
     * @dev Serves as canonical storage for policy, buyer, and pool schedule information.
     *      Each policy represents coverage from a single pool.
     */
    struct PolicyMetadata {
        /// @notice Buyer wallet responsible for paying premiums.
        address buyer;
        /// @notice Policy identifier (1:1 with committee).
        uint96 policyId;
        /// @notice Beneficiary receiving payouts upon approved claims.
        address beneficiary;
        /// @notice Account authorized to trigger claims for the policy.
        address claimer;
        /// @notice Policy coverage start timestamp.
        uint32 startTime;
        /// @notice Policy coverage end timestamp.
        uint32 maturityTime;
        /// @notice ERC20 token used for claim payouts.
        address payoutToken;
        /// @notice Address of the pool providing coverage.
        address pool;
        /// @notice Coverage notional allocated from the pool.
        uint256 coverageLimit;
        /// @notice Spec identifier for parametric claim evaluation (e.g., MorphoSpec, MapleSpec).
        bytes32 specId;
        /// @notice Hash of referenced terms governing this policy.
        bytes32 termsHash;
        /// @notice Deterministic hash representing the policy schedule.
        bytes32 policyCommit;
    }

    /**
     * @notice Request payload for binding a single-pool coverage policy.
     * @dev Phase 1 supports single pool bindings only; multi-pool aggregation is deferred.
     */
    struct BindPolicyRequest {
        /// @notice Pre-assigned policy identifier reserved at request time.
        uint96 policyId;
        /// @notice Policy buyer responsible for paying premiums.
        address buyer;
        /// @notice Beneficiary receiving payouts upon approved claims.
        address beneficiary;
        /// @notice Account authorized to trigger claims for the policy.
        address claimer;
        /// @notice ERC20 token used for claim payouts.
        address payoutToken;
        /// @notice Coverage amount as the stake requirement for committee creation (in USD with 8 decimals).
        uint256 coverageAmount;
        /// @notice Coverage quote from a single CoverPool.
        ICoverPool.Quote quote;
        /// @notice EIP-712 signature from the pool's authorized quote signer.
        bytes signature;
    }

    /**
     * @notice Emitted when coverage is requested via a policy draft.
     * @param policyId Identifier reserved for binding.
     * @param pool CoverPool where coverage was requested.
     * @param buyer Buyer address requesting coverage.
     * @param beneficiary Beneficiary address for claims.
     * @param claimer Account authorized to trigger claims.
     * @param coverageAmount Requested coverage amount (stake requirement).
     * @param duration Requested coverage duration (in seconds).
     */
    event CoverageRequested(
        uint96 indexed policyId,
        address indexed pool,
        address indexed buyer,
        address beneficiary,
        address claimer,
        uint256 coverageAmount,
        uint32 duration
    );

    /**
     * @notice Emitted when a policy draft is cancelled.
     * @param policyId Identifier of the cancelled draft.
     * @param pool CoverPool where the draft was created.
     */
    event PolicyDraftCancelled(uint96 indexed policyId, address indexed pool);

    /**
     * @notice Emitted when a policy is successfully bound.
     * @param policyId Identifier assigned to the policy.
     * @param buyer Policy buyer address.
     * @param beneficiary Beneficiary for claim payouts.
     * @param pool Address of the CoverPool providing coverage.
     * @param coverageLimit Coverage notional allocated from the pool.
     * @param policyCommit Deterministic hash representing the policy schedule.
     * @param bindPolicyHook Address of the hook contract that was called.
     */
    event PolicyBound(
        uint96 indexed policyId,
        address indexed buyer,
        address indexed beneficiary,
        address pool,
        uint256 coverageLimit,
        bytes32 policyCommit,
        address bindPolicyHook
    );

    /**
     * @notice Emitted when the StakeManager dependency is set or updated.
     * @param stakeManager_ Address of the stake manager contract.
     */
    event StakeManagerSet(address indexed stakeManager_);

    /**
     * @notice Emitted when the ClaimManager dependency is set or updated.
     * @param claimManager_ Address of the claim manager contract.
     */
    event ClaimManagerSet(address indexed claimManager_);

    /**
     * @notice Emitted when the CoverPoolFactory dependency is set or updated.
     * @param coverPoolFactory_ Address of the cover pool factory contract.
     */
    event CoverPoolFactorySet(address indexed coverPoolFactory_);

    /**
     * @notice Reverts when a zero address is provided where not allowed.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when supplied coverage timestamps are invalid.
     * @param startTime Coverage start timestamp.
     * @param maturityTime Coverage maturity timestamp.
     */
    error InvalidCoverageWindow(uint32 startTime, uint32 maturityTime);

    /**
     * @notice Reverts when coverage limit is zero.
     */
    error InvalidCoverageLimit();

    /**
     * @notice Reverts when coverage amount is zero.
     */
    error InvalidCoverageAmount();

    /**
     * @notice Reverts when coverage duration is zero.
     */
    error InvalidDuration();

    /**
     * @notice Reverts when the cover pool address is not registered in the factory.
     * @param pool Pool address that failed validation.
     */
    error InvalidCoverPool(address pool);

    /**
     * @notice Reverts when required policy commit hash is empty.
     */
    error InvalidPolicyCommit();

    /**
     * @notice Reverts when caller is not authorized for the operation.
     */
    error UnauthorizedCaller();

    /**
     * @notice Reverts when policy identifier is zero.
     */
    error InvalidPolicyId();

    /**
     * @notice Reverts when policy doesn't have sufficient stake.
     * @param policyId Policy identifier.
     * @param required Required stake amount.
     * @param actual Actual stake amount.
     */
    error InsufficientStake(uint96 policyId, uint256 required, uint256 actual);

    /**
     * @notice Reverts when no vaults are bound to a policy.
     * @param policyId Policy identifier without vaults.
     */
    error NoVaultsBound(uint96 policyId);

    /**
     * @notice Reverts when a policy draft is not found.
     * @param policyId Identifier that failed lookup.
     */
    error PolicyDraftNotFound(uint96 policyId);

    /**
     * @notice Reverts when a policy is not in the expected status.
     * @param status Current status of the policy draft.
     */
    error InvalidPolicyStatus(PolicyStatus status);

    /**
     * @notice Reverts when a non-buyer attempts to cancel a draft.
     * @param caller Address that attempted cancellation.
     */
    error NotPolicyBuyer(address caller);

    /**
     * @notice Reverts when pool operator is invalid or not set.
     */
    error InvalidPoolOperator();

    /**
     * @notice Reverts when request parameters don't match the stored draft.
     */
    error RequestDraftMismatch();

    /**
     * @notice Reverts when attempting to register a policy with a commit that's already been used.
     * @param policyCommit The duplicate policy commit hash.
     */
    error PolicyCommitAlreadyRegistered(bytes32 policyCommit);

    /**
     * @notice Reverts when attempting to access a policy that doesn't exist.
     * @param policyId The policy identifier that wasn't found.
     */
    error PolicyNotFound(uint96 policyId);

    /**
     * @notice Reverts when bindPolicyHook is the zero address.
     */
    error InvalidBindPolicyHook();

    /**
     * @notice Reverts when the bound policy duration doesn't match the requested duration.
     * @param requested Requested duration from the policy draft.
     * @param actual Actual duration from the bound policy (maturityTime - startTime).
     */
    error DurationMismatch(uint32 requested, uint32 actual);

    /**
     * @notice Pauses policy binding operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes policy binding operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Sets the StakeManager contract used for committee creation.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param stakeManager_ Address of the StakeManager implementation.
     */
    function setStakeManager(address stakeManager_) external;

    /**
     * @notice Sets the ClaimManager contract reference.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param claimManager_ Address of the ClaimManager implementation.
     */
    function setClaimManager(address claimManager_) external;

    /**
     * @notice Sets the CoverPoolFactory contract reference.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param coverPoolFactory_ Address of the CoverPoolFactory implementation.
     */
    function setCoverPoolFactory(address coverPoolFactory_) external;

    /**
     * @notice Requests coverage from a specified pool (user-facing entrypoint).
     * @dev Allows users to request coverage by specifying which pool they want coverage from.
     *      The caller becomes the buyer and is responsible for paying premiums.
     *      Creates a policy draft that must be bound by the pool curator.
     * @param pool CoverPool address to request coverage from.
     * @param beneficiary Address receiving payouts upon approved claims.
     * @param claimer Account authorized to trigger claims for the policy.
     * @param payoutToken ERC20 token used for claim payouts.
     * @param coverageAmount Requested coverage amount (stake requirement in USD with 8 decimals).
     * @param duration Requested coverage duration (in seconds).
     * @param bindPolicyHook Callback target invoked when policy is bound.
     * @return policyId Identifier reserved for binding and minting.
     */
    function requestCoverage(
        address pool,
        address beneficiary,
        address claimer,
        address payoutToken,
        uint256 coverageAmount,
        uint32 duration,
        address bindPolicyHook
    )
        external
        returns (uint96 policyId);

    /**
     * @notice Cancels a policy draft.
     * @dev Only the buyer can cancel, and only before binding.
     * @param policyId Identifier of the draft to cancel.
     */
    function cancelPolicyDraft(uint96 policyId) external;

    /**
     * @notice Binds a single-pool coverage policy by validating the quote, collecting premium,
     *         and minting a soulbound policy receipt.
     * @dev Only registered CoverPools may call this function.
     * @param request Struct containing all binding parameters and signed quote.
     * @param boundPolicy Bound policy metadata from the pool.
     */
    function bindPolicy(
        BindPolicyRequest calldata request,
        ICoverPool.BoundPolicy calldata boundPolicy
    )
        external;

    /**
     * @notice Returns draft data for a policyId.
     * @param policyId Identifier of the draft to fetch.
     * @return PolicyDraft request snapshot.
     */
    function getPolicyDraft(uint96 policyId) external view returns (PolicyDraft memory);

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);

    /**
     * @notice Returns the configured StakeManager address.
     */
    function stakeManager() external view returns (address);

    /**
     * @notice Returns the configured ClaimManager address.
     */
    function claimManager() external view returns (address);

    /**
     * @notice Returns the configured CoverPoolFactory address.
     */
    function coverPoolFactory() external view returns (address);

    /**
     * @notice Returns policy metadata for a given policy ID.
     * @param policyId The policy identifier.
     * @return metadata The policy metadata struct.
     */
    function policyMetadata(uint96 policyId) external view returns (PolicyMetadata memory metadata);
}
