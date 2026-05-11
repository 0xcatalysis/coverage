// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpgradeBase} from "./UpgradeBase.s.sol";

/**
 * @title UpgradeSwapper
 * @notice Shared upgrade logic for Swapper UUPS proxy upgrades.
 * @dev Executes an upgrade via OpenZeppelin's Upgrades library.
 *
 *      WARNING: Storage layout checks are skipped. Manually verify layout before
 *      upgrading to avoid corrupting proxy state.
 *
 *      POST-UPGRADE MIGRATION: This version introduces PAUSER_ROLE. After the upgrade,
 *      the TimelockController must call grantRole(PAUSER_ROLE, <pauser>) on the proxy.
 *      Bundle this grantRole call in the same Safe TX Builder batch as the upgrade to
 *      avoid a window where no one can pause the contract.
 *      Note: setNativeWrapper() requires whenPaused — the PAUSER_ROLE holder must pause
 *      before admin can call it; and unpause afterwards.
 *
 *      Environment Variables:
 *        - PRIVATE_KEY: Deployer private key with DEFAULT_ADMIN_ROLE on Swapper
 *        - SWAPPER_PROXY: Address of the deployed Swapper proxy (required)
 */
abstract contract UpgradeSwapper is UpgradeBase {
    /**
     * @notice Provides the network name and expected chain id used for upgrade validation.
     * @dev Must be overridden by network-specific upgrade scripts.
     * @return UpgradeConfig containing network name and chain id.
     */
    function getUpgradeConfig() internal view virtual override returns (UpgradeConfig memory);

    function contractArtifact() internal pure override returns (string memory) {
        return "Swapper.sol:Swapper";
    }

    function proxyEnvVar() internal pure override returns (string memory) {
        return "SWAPPER_PROXY";
    }

    function contractName() internal pure override returns (string memory) {
        return "Swapper";
    }
}
