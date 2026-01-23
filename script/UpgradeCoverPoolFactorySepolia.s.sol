// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeCoverPoolFactory} from "./UpgradeCoverPoolFactory.s.sol";

/**
 * @title UpgradeCoverPoolFactorySepolia
 * @notice Upgrades CoverPoolFactory contract on Sepolia testnet.
 * @dev Environment variables required:
 *      - COVER_POOL_FACTORY_PROXY: Address of the deployed CoverPoolFactory proxy
 *      - PRIVATE_KEY: Private key with DEFAULT_ADMIN_ROLE on CoverPoolFactory
 *
 *      Usage:
 *        COVER_POOL_FACTORY_PROXY=0x... PRIVATE_KEY=0x... \
 *          forge script script/UpgradeCoverPoolFactorySepolia.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL
 */
contract UpgradeCoverPoolFactorySepolia is UpgradeCoverPoolFactory {
    /**
     * @inheritdoc UpgradeCoverPoolFactory
     * @return UpgradeConfig for Sepolia testnet (chain id 11155111).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Sepolia", chainId: 11_155_111});
    }
}
