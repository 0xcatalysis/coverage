// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IBindPolicyHook} from "../interfaces/IBindPolicyHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title MockBindPolicyHook
 * @notice No-op IBindPolicyHook implementation for fork testing.
 * @dev Used as the `bindPolicyHook` argument in `PolicyManager.requestCoverage()`,
 *      which requires a non-zero address that implements IBindPolicyHook via ERC-165.
 */
contract MockBindPolicyHook is IBindPolicyHook {
    function onPolicyBound(uint96, uint256) external override {}

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
