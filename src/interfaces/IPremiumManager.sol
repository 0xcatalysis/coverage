// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IPremiumManager
 * @notice Interface for collecting premiums, routing fees, and depositing restaker shares into escrow.
 */
interface IPremiumManager is IAccessControl {
    /**
     * @notice Premium allocation details for a single pool share.
     * @dev Allows platform fee math and curator payouts to be calculated deterministically per pool.
     */
    struct PoolShare {
        /// @notice Address of the CoverPool contract receiving the fee transfer.
        address coverPool;
        /// @notice Pool fee in basis points applied to the gross premium.
        uint16 poolFeeBps;
        /// @notice Recipient address for the pool's fee cut.
        address poolFeeRecipient;
        /// @notice Address of the operator backing this pool's coverage.
        address operator;
        /// @notice Gross premium amount attributable to this pool before fee splits.
        uint256 grossPremium;
    }

    /**
     * @notice Premium collection payload for a policy binding.
     */
    struct PremiumAllocation {
        /// @notice Identifier of the policy associated with the payment.
        uint256 policyId;
        /// @notice Deterministic hash representing the policy schedule.
        bytes32 policyCommit;
        /// @notice Base premium amount for the single pool.
        uint256 basePremium;
        /// @notice Policy buyer responsible for paying premiums.
        address buyer;
        /// @notice Restaking committee identifier backing this policy.
        uint96 committeeId;
        /// @notice ERC20 token used for the payment.
        address premiumToken;
        /// @notice Platform fee in basis points applied to the pool share.
        uint16 platformFeeBps;
        /// @notice Policy coverage start timestamp.
        uint64 startTime;
        /// @notice Policy coverage maturity timestamp.
        uint64 maturityTime;
        /// @notice Single pool share for this policy (Phase 1: single pool only).
        PoolShare poolShare;
    }

    /**
     * @notice Emitted when premiums are successfully collected.
     * @param policyId Identifier of the policy receiving coverage.
     * @param basePremium Base premium collected for the single pool.
     */
    event PremiumCollected(uint256 indexed policyId, uint256 basePremium);

    /**
     * @notice Emitted when the PremiumReserve dependency is set or updated.
     * @param premiumReserve_ Address of the premium reserve contract.
     */
    event PremiumReserveSet(address indexed premiumReserve_);

    /**
     * @notice Emitted when the platform treasury is set or updated.
     * @param platformTreasury_ Address of the platform treasury.
     */
    event PlatformTreasurySet(address indexed platformTreasury_);

    /**
     * @notice Reverts when a zero address is provided where not allowed.
     */
    error ZeroAddress();

    /**
     * @notice Reverts when a zero amount is provided where not allowed.
     */
    error ZeroAmount();

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
     * @notice Reverts when provided committee identifier is invalid.
     */
    error InvalidCommitteeId();

    /**
     * @notice Reverts when the sum of pool premiums does not match the expected total.
     * @param expected Expected aggregate value.
     * @param observed Observed sum across pool entries.
     */
    error PremiumTotalsMismatch(uint256 expected, uint256 observed);

    /**
     * @notice Reverts when combined platform and pool fees exceed 100%.
     * @param platformFeeBps Platform fee in basis points.
     * @param poolFeeBps Pool fee in basis points.
     * @param totalFeeBps Sum of both fees.
     */
    error ExcessiveCombinedFees(uint16 platformFeeBps, uint16 poolFeeBps, uint16 totalFeeBps);

    /**
     * @notice Pauses premium processing operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function pause() external;

    /**
     * @notice Resumes premium processing operations.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     */
    function unpause() external;

    /**
     * @notice Sets the PremiumReserve contract used for escrowed balances.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param reserve Address of the PremiumReserve implementation.
     */
    function setPremiumReserve(address reserve) external;

    /**
     * @notice Sets the platform treasury address.
     * @dev Requires DEFAULT_ADMIN_ROLE.
     * @param treasury Address of the platform treasury.
     */
    function setPlatformTreasury(address treasury) external;

    /**
     * @notice Collects premium funds, routes fees, and deposits restaker shares into PremiumReserve.
     * @dev Requires POLICY_MANAGER_ROLE.
     * @param allocation Struct describing the policy payment parameters.
     */
    function collectPremium(PremiumAllocation calldata allocation) external;

    /**
     * @notice Returns true when the contract is paused.
     */
    function paused() external view returns (bool);

    /**
     * @notice AccessControl identifier for the PolicyManager role.
     */
    function POLICY_MANAGER_ROLE() external view returns (bytes32);

    /**
     * @notice Returns the configured PremiumReserve address.
     */
    function premiumReserve() external view returns (address);

    /**
     * @notice Returns the configured platform treasury address.
     */
    function platformTreasury() external view returns (address);

    /**
     * @notice Calculates the platform, pool, and restaker premium splits for a given gross premium.
     * @param grossPremium Premium value to evaluate.
     * @param platformFeeBps Platform fee rate in basis points.
     * @param poolFeeBps Pool fee rate in basis points.
     * @return platformSplit Amount allocated to the platform.
     * @return poolSplit Amount allocated to the pool curator.
     * @return restakerSplit Amount remaining for restaker escrow after fees.
     */
    function getFeeSplits(
        uint256 grossPremium,
        uint16 platformFeeBps,
        uint16 poolFeeBps
    )
        external
        pure
        returns (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit);
}
