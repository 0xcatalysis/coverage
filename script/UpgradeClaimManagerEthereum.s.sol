// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeClaimManager} from "./UpgradeClaimManager.s.sol";

/**
 * @title UpgradeClaimManagerEthereum
 * @notice Upgrades ClaimManager contract on Ethereum mainnet.
 * @dev Set TIMELOCK to the TimelockController address so the script deploys the new
 *      implementation and prints schedule/execute calldata for Safe TX Builder rather
 *      than broadcasting the upgrade directly.
 *
 *      IMPORTANT: upgradeCalldata() is intentionally overridden to return empty bytes.
 *      initializeV2 was already executed on the mainnet proxy; calling it again would
 *      revert because reinitializer(2) enforces single execution.
 *
 *      POST-UPGRADE MIGRATION: Bundle grantRole(PAUSER_ROLE, <pauser>) in the same
 *      scheduleBatch as the upgrade. See docs/deployment/Upgrade-PAUSER-ROLE-Mainnet.md.
 *
 *      Environment Variables:
 *        - DEPLOYER_ADDRESS: Public address of the keystore signer
 *        - CLAIM_MANAGER_PROXY: Address of the deployed ClaimManager proxy (required)
 *        - TIMELOCK: TimelockController address (0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7)
 */
contract UpgradeClaimManagerEthereum is UpgradeClaimManager {
    /**
     * @inheritdoc UpgradeClaimManager
     * @return UpgradeConfig for Ethereum mainnet (chain id 1).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Ethereum", chainId: 1});
    }

    /**
     * @notice Returns empty calldata — initializeV2 is already applied on mainnet.
     * @dev Overrides the base implementation which calls initializeV2; re-executing
     *      a reinitializer would revert. This upgrade only swaps the implementation.
     */
    function upgradeCalldata() internal pure override returns (bytes memory) {
        return "";
    }
}
