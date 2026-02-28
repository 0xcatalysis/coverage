// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradePremiumCollector} from "./UpgradePremiumCollector.s.sol";

/**
 * @title UpgradePremiumCollectorSepolia
 * @notice Upgrades PremiumCollector contract on Sepolia testnet.
 * @dev Environment variables required:
 *      - PREMIUM_COLLECTOR_PROXY: Address of the deployed PremiumCollector proxy
 *      - PRIVATE_KEY: Private key with DEFAULT_ADMIN_ROLE on PremiumCollector
 *      Optional (initialise new storage slot from the BugPoCer fixes):
 *      - COVER_POOL_FACTORY: CoverPoolFactory proxy address
 *
 *      Usage:
 *        PREMIUM_COLLECTOR_PROXY=0x... COVER_POOL_FACTORY=0x... \
 *          forge script script/UpgradePremiumCollectorSepolia.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL
 */
contract UpgradePremiumCollectorSepolia is UpgradePremiumCollector {
    /**
     * @inheritdoc UpgradePremiumCollector
     * @return UpgradeConfig for Sepolia testnet (chain id 11155111).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Sepolia", chainId: 11_155_111});
    }
}
