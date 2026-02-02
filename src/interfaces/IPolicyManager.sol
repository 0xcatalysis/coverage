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
     * @notice Request payload for binding a single-pool coverage policy.
     * @dev Phase 1 supports single pool bindings only; multi-pool aggregation is deferred.
     */
    struct BindPolicyRequest {
        /// @notice Pre-assigned policy identifier reserved at request time.
        uint256 policyId;
        /// @notice Policy buyer responsible for paying premiums.
        address buyer;
        /// @notice Beneficiary receiving payouts upon approved claims.
        address beneficiary;
        /// @notice Account authorized to trigger claims for the policy.
        address claimer;
        /// @notice ERC20 token used for premium payments.
        address premiumToken;
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
     * @notice Emitted when a policy draft is created.
     * @param policyId Identifier reserved for binding.
     * @param pool CoverPool where the draft was created.
     * @param buyer Buyer address requesting coverage.
     * @param beneficiary Beneficiary address for claims.
     * @param claimer Account authorized to trigger claims.
     * @param coverageAmount Requested coverage amount (stake requirement).
     */
    event PolicyDraftCreated(
        uint256 indexed policyId,
        address indexed pool,
        address indexed buyer,
        address beneficiary,
        address claimer,
        uint256 coverageAmount
    );

    /**
     * @notice Emitted when a policy draft is cancelled.
     * @param policyId Identifier of the cancelled draft.
     * @param pool CoverPool where the draft was created.
     */
    event PolicyDraftCancelled(uint256 indexed policyId, address indexed pool);

    /**
     * @notice Emitted when a policy is successfully bound.
     * @param policyId Identifier assigned to the policy.
     * @param buyer Policy buyer address.
     * @param beneficiary Beneficiary for claim payouts.
     * @param pool Address of the CoverPool providing coverage.
     * @param coverageLimit Coverage notional allocated from the pool.
     * @param basePremium Base premium paid by the buyer.
     * @param policyCommit Deterministic hash representing the policy schedule.
     */
    event PolicyBound(
        uint256 indexed policyId,
        address indexed buyer,
        address indexed beneficiary,
        address pool,
        uint256 coverageLimit,
        uint256 basePremium,
        bytes32 policyCommit
    );

    /**
     * @notice Emitted when the PremiumManager dependency is set or updated.
     * @param premiumManager_ Address of the premium manager contract.
     */
    event PremiumManagerSet(address indexed premiumManager_);

    /**
     * @notice Emitted when the Policy contract dependency is set or updated.
     * @param policy_ Address of the policy contract.
     */
    event PolicyContractSet(address indexed policy_);

    /**
     * @notice Emitted when the platform fee is updated.
     * @param platformFeeBps_ New platform fee in basis points.
     */
    event PlatformFeeSet(uint16 indexed platformFeeBps_);

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
     * @notice Reverts when platform fee exceeds maximum allowed.
     * @param feeBps The invalid fee value.
     */
    error InvalidPlatformFee(uint16 feeBps);

    /**
     * @notice Reverts when supplied coverage timestamps are invalid.
     * @param startTime Coverage start timestamp.
     * @param maturityTime Coverage maturity timestamp.
     */
    error InvalidCoverageWindow(uint64 startTime, uint64 maturityTime);

    /**
     * @notice Reverts when coverage limit is zero.
     */
    error InvalidCoverageLimit();

    /**
     * @notice Reverts when base premium is zero.
     */
    error InvalidBasePremium();

    /**
     * @notice Reverts when coverage amount is zero.
     */
    error InvalidCoverageAmount();

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
     * @notice Reverts when committee identifier is zero.
     */
    error InvalidCommitteeId();

    /**
     * @notice Reverts when policy ID would overflow uint96 committee ID limit.
     */
    error PolicyIdOverflow();

    /**
     * @notice Reverts when a policyId has not been reserved for the caller.
     * @param policyId Identifier that failed validation.
     */
    error PolicyIdNotReserved(uint256 policyId);

    /**
     * @notice Reverts when a policyId has already been bound.
     * @param policyId Identifier already bound.
     */
    error PolicyIdAlreadyBound(uint256 policyId);

    /**
     * @notice Reverts when committee doesn't have sufficient stake.
     * @param committeeId Committee identifier.
     * @param required Required stake amount.
     * @param actual Actual stake amount.
     */
    error InsufficientStake(uint96 committeeId, uint256 required, uint256 actual);

    /**
     * @notice Reverts when no vaults are bound to a committee.
     * @param committeeId Committee identifier without vaults.
     */
    error NoVaultsBound(uint96 committeeId);

    /**
     * @notice Reverts when a policy draft is not found.
     * @param policyId Identifier that failed lookup.
     */
    error PolicyDraftNotFound(uint256 policyId);

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
     * @notice Sets the PremiumManager contract used for premium collection.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param premiumManager_ Address of the PremiumManager implementation.
     */
    function setPremiumManager(address premiumManager_) external;

    /**
     * @notice Sets the Policy contract used for minting policy NFTs.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param policy_ Address of the Policy implementation.
     */
    function setPolicy(address policy_) external;

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
     * @notice Sets the platform fee charged on policy premiums.
     * @dev Requires DEFAULT_ADMIN_ROLE. Must not exceed 25% (2500 bps).
     * @param platformFeeBps_ Platform fee in basis points (1 bps = 0.01%).
     */
    function setPlatformFee(uint16 platformFeeBps_) external;

    /**
     * @notice Creates a policy draft for a specified pool (user-facing entrypoint).
     * @dev Allows users to create policy drafts by specifying which pool they want coverage from.
     *      The caller becomes the buyer and is responsible for paying premiums.
     * @param pool CoverPool address to create the draft with.
     * @param beneficiary Address receiving payouts upon approved claims.
     * @param claimer Account authorized to trigger claims for the policy.
     * @param premiumToken ERC20 token used for premium payments.
     * @param payoutToken ERC20 token used for claim payouts.
     * @param coverageAmount Requested coverage amount (stake requirement in USD with 8 decimals).
     * @return policyId Identifier reserved for binding and minting.
     */
    function createPolicyDraft(
        address pool,
        address beneficiary,
        address claimer,
        address premiumToken,
        address payoutToken,
        uint256 coverageAmount
    )
        external
        returns (uint256 policyId);

    /**
     * @notice Cancels a policy draft.
     * @dev Only the buyer can cancel, and only before binding.
     * @param policyId Identifier of the draft to cancel.
     */
    function cancelPolicyDraft(uint256 policyId) external;

    /**
     * @notice Binds a single-pool coverage policy by validating the quote, collecting premium,
     *         and minting a soulbound policy receipt.
     * @dev Only registered CoverPools may call this function.
     * @param request Struct containing all binding parameters and signed quote.
     */
    function bindPolicy(BindPolicyRequest calldata request) external;

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);

    /**
     * @notice Returns the configured PremiumManager address.
     */
    function premiumManager() external view returns (address);

    /**
     * @notice Returns the configured Policy contract address.
     */
    function policy() external view returns (address);

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
     * @notice Returns the platform fee in basis points.
     */
    function platformFeeBps() external view returns (uint16);

    /**
     * @notice Returns draft data for a policyId.
     * @param policyId Identifier of the draft to fetch.
     * @return PolicyDraft request snapshot.
     */
    function getPolicyDraft(uint256 policyId) external view returns (PolicyDraft memory);
}
