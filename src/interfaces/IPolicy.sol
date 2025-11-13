// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";

/**
 * @title IPolicy
 * @notice Interface describing the Catalysis soulbound policy receipt.
 */
interface IPolicy is IAccessControl, IERC721Metadata {
    /**
     * @notice Comprehensive metadata persisted alongside each policy.
     * @dev Serves as canonical storage for policy, buyer, and pool schedule information.
     *      Each policy represents coverage from a single pool.
     */
    struct PolicyMetadata {
        /// @notice Buyer wallet responsible for paying premiums.
        address buyer;
        /// @notice Beneficiary receiving payouts upon approved claims.
        address beneficiary;
        /// @notice ERC20 token used for premium payments.
        address premiumToken;
        /// @notice Base premium paid by the buyer for coverage (excluding refundable deposits).
        uint256 basePremium;
        /// @notice ERC20 token used for claim payouts.
        address payoutToken;
        /// @notice Address of the pool providing coverage.
        address pool;
        /// @notice Coverage notional allocated from the pool.
        uint256 coverageLimit;
        /// @notice Destination address for claim payouts.
        address payoutReceiver;
        /// @notice Pool-provided identifier for the policy.
        bytes32 poolPolicyId;
        /// @notice Hash of referenced terms governing this policy.
        bytes32 termsHash;
        /// @notice Deterministic hash representing the policy schedule.
        bytes32 policyCommit;
        /// @notice Restaking committee identifier that backs this policy.
        uint96 committeeId;
        /// @notice Policy coverage start timestamp.
        uint64 startTime;
        /// @notice Policy coverage end timestamp.
        uint64 maturityTime;
        /// @notice Operator address delegated for this policy.
        address operator;
    }

    /**
     * @notice Emitted when a new policy token is minted to represent bound coverage.
     * @param policyId Non-transferable token identifier.
     * @param to Recipient address receiving the policy SBT.
     * @param pool Address of the pool providing coverage.
     * @param startTime Coverage start timestamp.
     * @param maturityTime Coverage maturity timestamp.
     * @param coverageLimit Coverage notional from the pool.
     * @param policyCommit Schedule commit hash associated with the policy.
     */
    event PolicyMinted(
        uint256 indexed policyId,
        address indexed to,
        address indexed pool,
        uint64 startTime,
        uint64 maturityTime,
        uint256 coverageLimit,
        bytes32 policyCommit
    );

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when attempting to mint a policy that already exists.
     * @param policyId Identifier that conflicted with existing state.
     */
    error PolicyAlreadyMinted(uint256 policyId);

    /**
     * @notice Reverts when supplied policy metadata specifies an invalid coverage window.
     * @param startTime Coverage start timestamp.
     * @param maturityTime Coverage maturity timestamp.
     */
    error InvalidCoverageWindow(uint64 startTime, uint64 maturityTime);

    /**
     * @notice Reverts when a policy commit hash is empty.
     */
    error InvalidPolicyCommit();

    /**
     * @notice Reverts when attempting to store duplicate policy commits.
     * @param policyCommit Commit hash that already exists.
     */
    error PolicyCommitAlreadyRegistered(bytes32 policyCommit);

    /**
     * @notice Reverts when coverage limit is zero.
     */
    error InvalidCoverageLimit();

    /**
     * @notice Reverts when base premium is zero.
     */
    error InvalidBasePremium();

    /**
     * @notice Reverts when required policy metadata fields are invalid.
     */
    error InvalidPolicyMetadata();

    /**
     * @notice Reverts when attempting to reference a policy that has not been minted.
     * @param policyId Identifier that failed the lookup.
     */
    error PolicyNotFound(uint256 policyId);

    /**
     * @notice Reverts when attempting to transfer a soulbound policy while locked.
     * @param policyId Identifier of the policy token.
     */
    error TransfersLocked(uint256 policyId);

    /**
     * @notice Mints a new policy SBT and stores associated metadata.
     * @dev Requires POLICY_MANAGER_ROLE.
     * @param to Recipient address for the policy token.
     * @param policyId Identifier to mint.
     * @param metadata Full policy metadata snapshot.
     */
    function mintPolicy(address to, uint256 policyId, PolicyMetadata calldata metadata) external;

    /**
     * @notice Fetches stored metadata for a policy token.
     * @param policyId Identifier to query.
     * @return PolicyMetadata snapshot for the policy.
     */
    function policyMetadata(uint256 policyId) external view returns (PolicyMetadata memory);

    /**
     * @notice AccessControl identifier that allows minting new policy receipts.
     */
    function POLICY_MANAGER_ROLE() external view returns (bytes32);
}
