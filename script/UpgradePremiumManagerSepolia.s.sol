// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradePremiumManager} from "./UpgradePremiumManager.s.sol";

/**
 * @title UpgradePremiumManagerSepolia
 * @notice Upgrades PremiumManager contract on Sepolia testnet.
 * @dev Environment variables required:
 *      - PREMIUM_MANAGER_PROXY: Address of the deployed PremiumManager proxy
 *      - PRIVATE_KEY: Private key with DEFAULT_ADMIN_ROLE on PremiumManager
 *
 *      After the upgrade, run:
 *        cast send $PREMIUM_MANAGER_PROXY "approveSpender(address,address,uint256)" \
 *          $WETH $SSP_ROUTER $(cast max-uint) --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
 *
 *      Usage:
 *        PREMIUM_MANAGER_PROXY=0x746DAa7Eb8D2a4407C19b4D9Cc2Cd6B839dbB720 \
 *          forge script script/UpgradePremiumManagerSepolia.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL
 */
contract UpgradePremiumManagerSepolia is UpgradePremiumManager {
    /**
     * @inheritdoc UpgradePremiumManager
     * @return UpgradeConfig for Sepolia testnet (chain id 11155111).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Sepolia", chainId: 11_155_111});
    }
}
