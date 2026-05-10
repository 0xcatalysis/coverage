// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ClaimManager} from "../src/ClaimManager.sol";
import {UpgradeBase} from "./UpgradeBase.s.sol";

/**
 * @title UpgradeClaimManager
 * @notice Shared upgrade logic for ClaimManager UUPS proxy upgrades.
 * @dev Executes an upgrade via OpenZeppelin's Upgrades library and atomically calls
 *      ClaimManager.initializeV2() via upgradeToAndCall to wire the new V2 storage fields.
 *
 *      WARNING: Storage layout checks are skipped. Manually verify layout before
 *      upgrading to avoid corrupting proxy state.
 *
 *      POST-UPGRADE MIGRATION: This version introduces PAUSER_ROLE. After the upgrade,
 *      the TimelockController must call grantRole(PAUSER_ROLE, <pauser>) on the proxy.
 *      Bundle this grantRole call in the same Safe TX Builder batch as the upgrade to
 *      avoid a window where no one can pause the contract.
 *
 *      Environment Variables:
 *        - PRIVATE_KEY: Deployer private key with DEFAULT_ADMIN_ROLE on ClaimManager
 *        - CLAIM_MANAGER_PROXY: Address of the deployed ClaimManager proxy (required)
 *        - ORACLE_PRICE_FEED: Address of the OraclePriceFeed contract (required)
 *        - PRICE_DEVIATION_TOLERANCE_BPS: Max DEX-vs-oracle deviation tolerance in bps
 *                                         (optional, defaults to 300 = 3%)
 */
abstract contract UpgradeClaimManager is UpgradeBase {
    /**
     * @notice Provides the network name and expected chain id used for upgrade validation.
     * @dev Must be overridden by network-specific upgrade scripts.
     * @return UpgradeConfig containing network name and chain id.
     */
    function getUpgradeConfig() internal view virtual override returns (UpgradeConfig memory);

    function contractArtifact() internal pure override returns (string memory) {
        return "ClaimManager.sol:ClaimManager";
    }

    function proxyEnvVar() internal pure override returns (string memory) {
        return "CLAIM_MANAGER_PROXY";
    }

    function contractName() internal pure override returns (string memory) {
        return "ClaimManager";
    }

    /**
     * @notice Returns initializeV2 calldata for the ClaimManager upgrade.
     * @dev Encoded as the data argument to upgradeToAndCall so the proxy atomically configures
     *      the V2 storage fields in the same transaction as the implementation swap.
     */
    function upgradeCalldata() internal view virtual override returns (bytes memory) {
        address oraclePriceFeed = vm.envAddress("ORACLE_PRICE_FEED");
        require(oraclePriceFeed != address(0), "ORACLE_PRICE_FEED required");
        uint16 toleranceBps = SafeCast.toUint16(vm.envOr("PRICE_DEVIATION_TOLERANCE_BPS", uint256(300)));
        return abi.encodeCall(ClaimManager.initializeV2, (oraclePriceFeed, toleranceBps));
    }
}
