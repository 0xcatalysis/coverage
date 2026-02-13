// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IBindPolicyHook
 * @notice Callback interface allowing external contracts to be notified when a policy is successfully bound.
 * @dev The bindPolicyHook address is registered during `requestCoverage` and invoked atomically at the end of
 *      `bindPolicy`. If the hook reverts, the entire binding transaction reverts.
 */
interface IBindPolicyHook is IERC165 {
    /**
     * @notice Callback invoked when a policy is successfully bound.
     * @dev If this function reverts, the policy binding will fail atomically.
     * @param policyId The unique identifier of the bound policy.
     * @param coverageLimit The coverage notional allocated to the policy.
     */
    function onPolicyBound(uint96 policyId, uint256 coverageLimit) external;
}
