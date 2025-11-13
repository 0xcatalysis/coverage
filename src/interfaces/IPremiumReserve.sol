// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IPremiumReserve
 * @notice Interface describing the premium escrow that holds restaker premiums and risk buffers per policy.
 */
interface IPremiumReserve is IAccessControl {
    /**
     * @notice Restaker premium ledger entry per pool.
     */
    struct PoolPremium {
        /// @notice Address of the pool whose restakers supplied coverage.
        address pool;
        /// @notice Operator whose delegation backs this premium slice.
        address operator;
        /// @notice Premium amount earmarked for the pool's restakers.
        uint256 restakerPremium;
    }

    /**
     * @notice Escrow state maintained for each bound policy.
     */
    struct EscrowPosition {
        /// @notice Identifier of the policy owning the escrow.
        uint256 policyId;
        /// @notice Deterministic hash representing the policy schedule.
        bytes32 policyCommit;
        /// @notice Sum of restaker premiums awaiting distribution.
        uint256 restakerPremiumTotal;
        /// @notice ERC20 token held in escrow.
        address premiumToken;
        /// @notice Policy buyer address.
        address buyer;
        /// @notice Policy coverage start timestamp.
        uint64 startTime;
        /// @notice Policy coverage maturity timestamp.
        uint64 maturityTime;
        /// @notice Indicates whether escrow is locked pending claim resolution.
        bool claimLocked;
        /// @notice Per-pool premium breakdown.
        PoolPremium[] poolPremiums;
    }

    /**
     * @notice Storage-friendly snapshot tracking escrow lifecycle and balances.
     * @dev Persists aggregate totals and flags that gate claim payouts and maturity releases.
     *      Note: PoolPremium arrays are stored separately in _poolPremiums mapping
     *      for gas efficiency. Use escrowPosition() to reconstruct the full EscrowPosition.
     */
    struct EscrowAccount {
        /// @notice Remaining restaker premiums held in escrow.
        uint256 restakerPremiumTotal;
        /// @notice Initial restaker premium total stored for allocation math.
        uint256 restakerPremiumInitial;
        /// @notice ERC20 premium token locked in escrow.
        address premiumToken;
        /// @notice Buyer responsible for the policy premiums.
        address buyer;
        /// @notice Deterministic hash representing the policy schedule.
        bytes32 policyCommit;
        /// @notice Coverage start timestamp encoded at bind.
        uint64 startTime;
        /// @notice Coverage maturity timestamp encoded at bind.
        uint64 maturityTime;
        /// @notice True when a claim lock is active for the policy.
        bool claimLocked;
        /// @notice True once the escrow has been fully released.
        bool released;
    }

    /**
     * @notice Emitted when a new escrow position is opened for a policy.
     * @param policyId Identifier of the policy.
     * @param premiumToken ERC20 token held in escrow.
     * @param restakerPremiumTotal Total restaker premium locked.
     */
    event EscrowOpened(uint256 indexed policyId, address premiumToken, uint256 restakerPremiumTotal);

    /**
     * @notice Emitted when claim lock status is toggled.
     * @param policyId Identifier of the policy escrow.
     * @param locked Latest lock flag value.
     */
    event ClaimLockStatusSet(uint256 indexed policyId, bool locked);

    /**
     * @notice Emitted when restaker premiums are released from escrow.
     * @param policyId Identifier of the policy escrow.
     * @param to Address receiving the released funds.
     * @param restakerShare Amount released.
     */
    event PremiumReleased(uint256 indexed policyId, address indexed to, uint256 restakerShare);

    /**
     * @notice Emitted when a specific pool's restaker premium is distributed.
     * @param policyId Identifier of the policy escrow.
     * @param pool Address of the pool being paid out.
     * @param amount Amount released to the pool's restakers.
     */
    event PoolPremiumReleased(uint256 indexed policyId, address indexed pool, uint256 amount);

    /**
     * @notice Emitted when escrowed funds are paid out against a claim.
     * @param policyId Identifier of the policy escrow.
     * @param settledAmount Amount applied toward the claim.
     */
    event ClaimPaid(uint256 indexed policyId, uint256 settledAmount);

    /**
     * @notice Reverts when a required address argument is zero.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when attempting to open an escrow that already exists.
     * @param policyId Identifier that already has an escrow position.
     */
    error EscrowAlreadyExists(uint256 policyId);

    /**
     * @notice Reverts when attempting to access an unknown escrow position.
     * @param policyId Identifier that failed the lookup.
     */
    error EscrowNotFound(uint256 policyId);

    /**
     * @notice Reverts when supplied coverage timestamps are invalid.
     * @param startTime Coverage start timestamp.
     * @param maturityTime Coverage maturity timestamp.
     */
    error InvalidCoverageWindow(uint64 startTime, uint64 maturityTime);

    /**
     * @notice Reverts when a required policy commit hash is empty.
     */
    error InvalidPolicyCommit();

    /**
     * @notice Reverts when provided pool premium data is malformed.
     */
    error InvalidPoolPremiums();

    /**
     * @notice Reverts when the pool premium breakdown does not match the aggregate total.
     * @param expected Expected aggregate value.
     * @param observed Observed sum across pool entries.
     */
    error PremiumTotalsMismatch(uint256 expected, uint256 observed);

    /**
     * @notice Reverts when attempting to pay a claim with a zero settled amount.
     */
    error ZeroSettledAmount();

    /**
     * @notice Reverts when attempting to open an escrow with zero restaker premium.
     */
    error ZeroRestakerPremium();

    /**
     * @notice Reverts when attempting to release funds while a claim lock is active.
     * @param policyId Identifier of the locked escrow.
     */
    error EscrowLocked(uint256 policyId);

    /**
     * @notice Reverts when attempting to draw claim funds without first locking the escrow.
     * @param policyId Identifier of the escrow.
     */
    error EscrowNotLocked(uint256 policyId);

    /**
     * @notice Reverts when attempting to process an escrow that is already released.
     * @param policyId Identifier of the escrow.
     */
    error EscrowAlreadyReleased(uint256 policyId);

    /**
     * @notice Reverts when attempting to release prior to maturity.
     * @param policyId Identifier of the escrow.
     * @param maturityTime Stored maturity timestamp.
     */
    error MaturityNotReached(uint256 policyId, uint64 maturityTime);

    /**
     * @notice Reverts when the escrow balance cannot satisfy a claim drawdown.
     * @param policyId Identifier of the escrow.
     * @param requested Amount requested for the claim.
     * @param available Maximum available balance across premiums and buffer.
     */
    error InsufficientEscrow(uint256 policyId, uint256 requested, uint256 available);

    /**
     * @notice Pauses premium reserve operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes premium reserve operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Opens an escrow position for a newly bound policy.
     * @dev Requires PREMIUM_MANAGER_ROLE.
     * @param position Struct containing initial escrow parameters.
     */
    function openEscrow(EscrowPosition calldata position) external;

    /**
     * @notice Sets claim lock status while a claim is being evaluated.
     * @dev Requires CLAIM_MANAGER_ROLE.
     * @param policyId Identifier of the policy escrow.
     * @param locked Boolean flag controlling lock state.
     */
    function setClaimLockStatus(uint256 policyId, bool locked) external;

    /**
     * @notice Pays a claim using escrowed funds and transfers to the payout recipient.
     * @dev Requires CLAIM_MANAGER_ROLE.
     * @param policyId Identifier of the policy escrow.
     * @param payoutRecipient Address receiving the payout.
     * @param settledAmount Amount to transfer.
     */
    function payClaim(uint256 policyId, address payoutRecipient, uint256 settledAmount) external;

    /**
     * @notice Releases restaker premiums when policy funds are ready to exit escrow.
     * @dev Requires POLICY_MANAGER_ROLE.
     * @param policyId Identifier of the policy escrow.
     * @param rewardsManager Address receiving restaker premiums for distribution.
     */
    function releasePremium(uint256 policyId, address rewardsManager) external;

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);

    /**
     * @notice AccessControl identifier for the PremiumManager role.
     */
    function PREMIUM_MANAGER_ROLE() external view returns (bytes32);

    /**
     * @notice AccessControl identifier for the ClaimManager role.
     */
    function CLAIM_MANAGER_ROLE() external view returns (bytes32);

    /**
     * @notice AccessControl identifier for the PolicyManager role.
     */
    function POLICY_MANAGER_ROLE() external view returns (bytes32);

    /**
     * @notice Returns the escrow position for a policy.
     * @param policyId Identifier to query.
     * @return EscrowPosition snapshot describing the escrow state.
     */
    function escrowPosition(uint256 policyId) external view returns (EscrowPosition memory);
}
