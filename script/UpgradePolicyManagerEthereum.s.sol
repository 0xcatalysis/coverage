// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradePolicyManager} from "./UpgradePolicyManager.s.sol";

/**
 * @title UpgradePolicyManagerEthereum
 * @notice Upgrades PolicyManager contract on Ethereum mainnet.
 * @dev Set TIMELOCK to the TimelockController address so the script deploys the new
 *      implementation and prints schedule/execute calldata for Safe TX Builder rather
 *      than broadcasting the upgrade directly.
 *
 *      POST-UPGRADE MIGRATION: Bundle grantRole(PAUSER_ROLE, <pauser>) in the same
 *      scheduleBatch as the upgrade. See docs/deployment/Upgrade-PAUSER-ROLE-Mainnet.md.
 *
 *      Environment Variables:
 *        - DEPLOYER_ADDRESS: Public address of the keystore signer
 *        - POLICY_MANAGER_PROXY: Address of the deployed PolicyManager proxy (required)
 *        - TIMELOCK: TimelockController address (0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7)
 */
contract UpgradePolicyManagerEthereum is UpgradePolicyManager {
    /**
     * @inheritdoc UpgradePolicyManager
     * @return UpgradeConfig for Ethereum mainnet (chain id 1).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Ethereum", chainId: 1});
    }
}
