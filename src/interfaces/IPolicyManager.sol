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
     * @notice Request payload for binding a single-pool coverage policy.
     * @dev Phase 1 supports single pool bindings only; multi-pool aggregation is deferred.
     */
    struct BindPolicyRequest {
        /// @notice Policy buyer responsible for paying premiums.
        address buyer;
        /// @notice Beneficiary receiving payouts upon approved claims.
        address beneficiary;
        /// @notice ERC20 token used for premium payments.
        address premiumToken;
        /// @notice ERC20 token used for claim payouts.
        address payoutToken;
        /// @notice Coverage amount as the stake requirement for committee creation (in USD with 8 decimals).
        uint256 coverageAmount;
        /// @notice Coverage quote data from a single CoverPool.
        ICoverPool.QuoteData quote;
        /// @notice EIP-712 signature from the pool's authorized quote signer.
        bytes signature;
    }

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
     * @notice Reverts when the quote pool address does not match expected pool.
     */
    error InvalidQuotePool();

    /**
     * @notice Reverts when required policy commit hash is empty.
     */
    error InvalidPolicyCommit();

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
     * @notice Sets the platform fee charged on policy premiums.
     * @dev Requires DEFAULT_ADMIN_ROLE. Must not exceed 25% (2500 bps).
     * @param platformFeeBps_ Platform fee in basis points (1 bps = 0.01%).
     */
    function setPlatformFee(uint16 platformFeeBps_) external;

    /**
     * @notice Binds a single-pool coverage policy by validating the quote, collecting premium,
     *         and minting a soulbound policy receipt.
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
     * @notice Returns the platform fee in basis points.
     */
    function platformFeeBps() external view returns (uint16);
}
