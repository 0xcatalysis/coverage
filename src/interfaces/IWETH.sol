// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IWETH
 * @notice Interface for Wrapped ETH (WETH) contract supporting deposit and withdrawal operations.
 * @dev Extends IERC20 to include native ETH wrapping/unwrapping functionality.
 */
interface IWETH is IERC20 {
    /**
     * @notice Wraps native ETH into WETH tokens.
     * @dev Accepts ETH via msg.value and mints equivalent WETH to msg.sender.
     */
    function deposit() external payable;

    /**
     * @notice Unwraps WETH tokens back into native ETH.
     * @dev Burns WETH from msg.sender and sends equivalent ETH.
     * @param amount Amount of WETH to unwrap.
     */
    function withdraw(uint256 amount) external;
}
