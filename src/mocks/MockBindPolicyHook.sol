// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IBindPolicyHook} from "../interfaces/IBindPolicyHook.sol";

/**
 * @title MockBindPolicyHook
 * @notice No-op implementation of IBindPolicyHook for testnet deployments.
 * @dev Implements ERC-165 to satisfy PolicyManager.requestCoverage() validation.
 *      The onPolicyBound callback is intentionally empty -- it simply accepts the notification
 *      without performing any action.
 */
contract MockBindPolicyHook is IBindPolicyHook {
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBindPolicyHook
    function onPolicyBound(uint96, uint256) external pure override {
        // No-op: accept the policy binding notification without performing any action.
    }
}
