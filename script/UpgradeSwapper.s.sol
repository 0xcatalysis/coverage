// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Script, console2} from "forge-std/Script.sol";
import {Swapper} from "../src/Swapper.sol";

/**
 * @title UpgradeSwapper
 * @notice Shared upgrade logic for Swapper UUPS proxy upgrades.
 * @dev Executes an upgrade via OpenZeppelin's Upgrades library.
 *
 *      WARNING: Storage layout checks are skipped. Manually verify layout before
 *      upgrading to avoid corrupting proxy state.
 *
 *      Environment Variables:
 *        - PRIVATE_KEY: Deployer private key with DEFAULT_ADMIN_ROLE on Swapper
 *        - SWAPPER_PROXY: Address of the deployed Swapper proxy (required)
 */
abstract contract UpgradeSwapper is Script {
    /**
     * @notice Network-specific metadata used to validate upgrades.
     * @param networkName Human-readable network label used in logs.
     * @param chainId Chain id required for the upgrade run.
     */
    struct UpgradeConfig {
        string networkName;
        uint256 chainId;
    }

    /**
     * @notice Collection of upgrade-related addresses.
     * @param proxy Address of the Swapper proxy.
     * @param oldImplementation Address of the current implementation before upgrade.
     * @param newImplementation Address of the new implementation after upgrade.
     */
    struct UpgradeResult {
        address proxy;
        address oldImplementation;
        address newImplementation;
    }

    /**
     * @notice Upgrades the Swapper proxy to a new implementation.
     * @dev Validates chain id, loads proxy address from environment, performs the upgrade,
     *      and logs the results. Reverts if chain id mismatch or proxy address is missing.
     * @return result Struct containing proxy and implementation addresses.
     */
    function run() external returns (UpgradeResult memory result) {
        UpgradeConfig memory config = getUpgradeConfig();
        require(config.chainId == block.chainid, string.concat("Must upgrade on ", config.networkName));

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        result.proxy = vm.envAddress("SWAPPER_PROXY");
        require(result.proxy != address(0), "SWAPPER_PROXY required");

        result.oldImplementation = Upgrades.getImplementationAddress(result.proxy);

        Swapper swapper = Swapper(payable(result.proxy));
        require(swapper.hasRole(swapper.DEFAULT_ADMIN_ROLE(), deployer), "Deployer must have DEFAULT_ADMIN_ROLE on Swapper");

        vm.startBroadcast(deployerPrivateKey);

        Options memory opts;
        opts.unsafeAllow = "constructor";
        opts.unsafeSkipStorageCheck = true;

        Upgrades.upgradeProxy(result.proxy, "Swapper.sol:Swapper", "", opts);

        vm.stopBroadcast();

        result.newImplementation = Upgrades.getImplementationAddress(result.proxy);

        _logUpgrade(config, deployer, result);

        return result;
    }

    /**
     * @notice Provides the network name and expected chain id used for upgrade validation.
     * @dev Must be overridden by network-specific upgrade scripts.
     * @return UpgradeConfig containing network name and chain id.
     */
    function getUpgradeConfig() internal view virtual returns (UpgradeConfig memory);

    function _logUpgrade(UpgradeConfig memory config, address deployer, UpgradeResult memory result) private pure {
        console2.log("");
        console2.log(string.concat("=== Swapper Upgrade on ", config.networkName, " ==="));
        console2.log("Chain ID:", config.chainId);
        console2.log("");

        console2.log("--- Accounts ---");
        console2.log("Upgrader:", deployer);
        console2.log("");

        console2.log("--- Upgrade Details ---");
        console2.log("Swapper Proxy:", result.proxy);
        console2.log("Old Implementation:", result.oldImplementation);
        console2.log("New Implementation:", result.newImplementation);

        if (result.oldImplementation == result.newImplementation) {
            console2.log("");
            console2.log("Warning! Implementation address unchanged (no bytecode changes detected)");
        }

        console2.log("====================================");
    }
}
