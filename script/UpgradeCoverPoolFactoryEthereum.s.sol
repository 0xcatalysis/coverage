// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeCoverPoolFactory} from "./UpgradeCoverPoolFactory.s.sol";

/**
 * @title UpgradeCoverPoolFactoryEthereum
 * @notice Upgrades CoverPoolFactory contract on Ethereum mainnet.
 * @dev Environment variables required:
 *      - COVER_POOL_FACTORY_PROXY: Address of the deployed CoverPoolFactory proxy
 *      - PRIVATE_KEY: Private key with DEFAULT_ADMIN_ROLE on CoverPoolFactory
 *
 *      Usage:
 *        COVER_POOL_FACTORY_PROXY=0x... PRIVATE_KEY=0x... \
 *          forge script script/UpgradeCoverPoolFactoryEthereum.s.sol --broadcast --rpc-url $ETHEREUM_RPC_URL
 */
contract UpgradeCoverPoolFactoryEthereum is UpgradeCoverPoolFactory {
    /**
     * @inheritdoc UpgradeCoverPoolFactory
     * @return UpgradeConfig for Ethereum mainnet (chain id 1).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Ethereum", chainId: 1});
    }
}
