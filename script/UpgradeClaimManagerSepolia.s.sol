// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeClaimManager} from "./UpgradeClaimManager.s.sol";

/**
 * @title UpgradeClaimManagerSepolia
 * @notice Upgrades ClaimManager contract on Sepolia testnet.
 * @dev Environment variables required:
 *      - CLAIM_MANAGER_PROXY: Address of the deployed ClaimManager proxy
 *      - PRIVATE_KEY: Private key with DEFAULT_ADMIN_ROLE on ClaimManager
 *
 *      Usage:
 *        CLAIM_MANAGER_PROXY=0x... \
 *          forge script script/UpgradeClaimManagerSepolia.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL
 */
contract UpgradeClaimManagerSepolia is UpgradeClaimManager {
    /**
     * @inheritdoc UpgradeClaimManager
     * @return UpgradeConfig for Sepolia testnet (chain id 11155111).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Sepolia", chainId: 11_155_111});
    }
}
