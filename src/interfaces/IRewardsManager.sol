// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IRewardsManager
 * @notice Interface for Catalysis Core's RewardsManager that distributes rewards to restakers.
 */
interface IRewardsManager {
    /**
     * @notice Distributes rewards for a policy's restaker premium to the appropriate committee/operator.
     * @dev Called by PremiumReserve after policy maturity to distribute escrowed premiums.
     * @param committeeId The restaking committee identifier backing the policy.
     * @param operator The operator address whose stake backed the coverage.
     * @param rewardAmount Amount of reward token to distribute.
     * @param rewardToken The ERC20 token used for rewards.
     */
    function distributeRewards(uint96 committeeId, address operator, uint256 rewardAmount, IERC20 rewardToken) external;
}
