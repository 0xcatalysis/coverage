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
 *      This upgrade atomically calls ClaimManager.initializeV2(oraclePriceFeed, toleranceBps)
 *      via upgradeToAndCall. On-chain verification confirmed that initializeV2 has NOT been
 *      applied on the mainnet proxy (slot 9 = 0x0, priceDeviationToleranceBps() reverts).
 *
 *      POST-UPGRADE MIGRATION: Bundle grantRole(PAUSER_ROLE, <pauser>) and
 *      Swapper.setClaimManager(<claimManagerProxy>) in the same scheduleBatch as the upgrade.
 *      See docs/deployment/Upgrade-Ethereum.md for the full 14-call batch.
 *
 *      Environment Variables:
 *        - DEPLOYER_ADDRESS: Public address of the keystore signer
 *        - CLAIM_MANAGER_PROXY: Address of the deployed ClaimManager proxy (required)
 *        - TIMELOCK: TimelockController address (0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7)
 *        - ORACLE_PRICE_FEED: Address of the OraclePriceFeed contract (required)
 *        - PRICE_DEVIATION_TOLERANCE_BPS: Max DEX-vs-oracle deviation tolerance in bps
 *                                         (optional, defaults to 300 = 3%)
 */
contract UpgradeClaimManagerEthereum is UpgradeClaimManager {
    /**
     * @inheritdoc UpgradeClaimManager
     * @return UpgradeConfig for Ethereum mainnet (chain id 1).
     */
    function getUpgradeConfig() internal pure override returns (UpgradeConfig memory) {
        return UpgradeConfig({networkName: "Ethereum", chainId: 1});
    }
}
