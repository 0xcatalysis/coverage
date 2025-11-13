// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/**
 * @title IRewardsManager
 * @notice Minimal interface for the Catalysis Core rewards distributor.
 */
interface IRewardsManager {
    /**
     * @notice Notifies the RewardsManager of premium value ready for distribution.
     * @param taskType Identifier describing the coverage product (e.g. "COVERAGE_POLICY").
     * @param taskPerformer Restaking operator associated with the payout.
     * @param taskDefinitionId Deterministic hash representing the policy schedule.
     * @param rewardAmount Amount of reward token allocated to the operator.
     */
    function distributeRewards(
        bytes calldata taskType,
        address taskPerformer,
        bytes32 taskDefinitionId,
        uint256 rewardAmount
    )
        external;
}
