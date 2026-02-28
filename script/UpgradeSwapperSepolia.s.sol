// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeSwapper} from "./UpgradeSwapper.s.sol";

/**
 * @title UpgradeSwapperSepolia
 * @notice Upgrades Swapper contract on Sepolia testnet.
 * @dev Environment variables required:
 *      - SWAPPER_PROXY: Address of the deployed Swapper proxy
 *      - PRIVATE_KEY: Private key with DEFAULT_ADMIN_ROLE on Swapper
 *
 *      Usage:
 *        SWAPPER_PROXY=0x... \
 *          forge script script/UpgradeSwapperSepolia.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL
 */
contract UpgradeSwapperSepolia is UpgradeSwapper {
    /**
     * @inheritdoc UpgradeSwapper
     * @return UpgradeConfig for Sepolia testnet (chain id 11155111).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Sepolia", chainId: 11_155_111});
    }
}
