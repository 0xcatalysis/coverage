// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockERC4626Vault
 * @notice Minimal ERC-4626 vault wrapping any ERC-20 token. Used for E2E testing
 *         of the PremiumCollector flow on Sepolia where a real managed vault is
 *         not available. Deposits and withdrawals work 1:1 with the underlying.
 */
contract MockERC4626Vault is ERC4626 {
    constructor(
        address underlying,
        string memory name,
        string memory symbol
    )
        ERC20(name, symbol)
        ERC4626(IERC20(underlying))
    {}
}
