// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IRewardsManager
 * @notice Interface for Catalysis Core's RewardsManager that distributes rewards to restakers.
 */
interface IRewardsManager {
    /**
     * @notice Distributes rewards for a policy's restaker premium to the appropriate policy/operator.
     * @dev Called by PremiumReserve after policy maturity to distribute escrowed premiums.
     * @param policyId The policy identifier backing the coverage (1:1 with committee).
     * @param operator The operator address whose stake backed the coverage.
     * @param rewardAmount Amount of reward token to distribute.
     * @param rewardToken The ERC20 token used for rewards.
     * @param taskId Unique identifier for this distribution task, used to prevent replay attacks.
     */
    function distributeRewards(
        uint96 policyId,
        address operator,
        uint256 rewardAmount,
        IERC20 rewardToken,
        bytes32 taskId
    )
        external;
}
