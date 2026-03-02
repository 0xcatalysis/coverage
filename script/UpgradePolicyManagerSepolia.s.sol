// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradePolicyManager} from "./UpgradePolicyManager.s.sol";

/**
 * @title UpgradePolicyManagerSepolia
 * @notice Upgrades PolicyManager contract on Sepolia testnet.
 * @dev Environment variables required:
 *      - POLICY_MANAGER_PROXY: Address of the deployed PolicyManager proxy
 *      - PRIVATE_KEY: Private key with DEFAULT_ADMIN_ROLE on PolicyManager
 *
 *      Usage:
 *        POLICY_MANAGER_PROXY=0xaA254C2C00F1dF3635e47F51cA1fe1fD04335742 \
 *          forge script script/UpgradePolicyManagerSepolia.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL
 */
contract UpgradePolicyManagerSepolia is UpgradePolicyManager {
    /**
     * @inheritdoc UpgradePolicyManager
     * @return UpgradeConfig for Sepolia testnet (chain id 11155111).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Sepolia", chainId: 11_155_111});
    }
}
