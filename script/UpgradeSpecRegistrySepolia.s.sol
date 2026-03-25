// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeSpecRegistry} from "./UpgradeSpecRegistry.s.sol";

/**
 * @title UpgradeSpecRegistrySepolia
 * @notice Upgrades SpecRegistry contract on Sepolia testnet.
 * @dev Environment variables required:
 *      - SPEC_REGISTRY_PROXY: Address of the deployed SpecRegistry proxy
 *      - PRIVATE_KEY: Private key with DEFAULT_ADMIN_ROLE on SpecRegistry
 *
 *      Usage:
 *        SPEC_REGISTRY_PROXY=0x... \
 *          forge script script/UpgradeSpecRegistrySepolia.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL
 *
 *      Post-upgrade: call approveSpec(specAddress) for each trusted ISpec implementation.
 */
contract UpgradeSpecRegistrySepolia is UpgradeSpecRegistry {
    /**
     * @inheritdoc UpgradeSpecRegistry
     * @return UpgradeConfig for Sepolia testnet (chain id 11155111).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Sepolia", chainId: 11_155_111});
    }
}
