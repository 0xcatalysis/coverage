// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @title UpgradeBase
 * @notice Generic shared upgrade logic for UUPS proxy upgrades across Coverage contracts.
 * @dev Subclasses implement three pure methods that supply the contract-specific constants;
 *      network-specific scripts then override `getUpgradeConfig` as before.
 *
 *      WARNING: Storage layout checks are skipped. Manually verify layout before
 *      upgrading to avoid corrupting proxy state.
 *
 *      Required environment variables:
 *        - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag) with DEFAULT_ADMIN_ROLE
 * on the target proxy.
 *        - <proxyEnvVar()>: Address of the deployed proxy (e.g. CLAIM_MANAGER_PROXY).
 */
abstract contract UpgradeBase is Script {
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
     * @param proxy Address of the proxy being upgraded.
     * @param oldImplementation Address of the current implementation before upgrade.
     * @param newImplementation Address of the new implementation after upgrade.
     */
    struct UpgradeResult {
        address proxy;
        address oldImplementation;
        address newImplementation;
    }

    /**
     * @notice Provides the network name and expected chain id used for upgrade validation.
     * @dev Must be overridden by network-specific upgrade scripts.
     * @return UpgradeConfig containing network name and chain id.
     */
    function getUpgradeConfig() internal view virtual returns (UpgradeConfig memory);

    /**
     * @notice Returns the Forge artifact string passed to `Upgrades.upgradeProxy`.
     * @dev Example: "ClaimManager.sol:ClaimManager"
     */
    function contractArtifact() internal pure virtual returns (string memory);

    /**
     * @notice Returns the environment variable name that holds the proxy address.
     * @dev Example: "CLAIM_MANAGER_PROXY"
     */
    function proxyEnvVar() internal pure virtual returns (string memory);

    /**
     * @notice Returns the human-readable contract name used in log messages.
     * @dev Example: "ClaimManager"
     */
    function contractName() internal pure virtual returns (string memory);

    /**
     * @notice Upgrades the proxy to a new implementation.
     * @dev Validates chain id, loads proxy address from environment, checks admin role,
     *      performs the upgrade, and logs the results.
     * @return result Struct containing proxy and implementation addresses.
     */
    function run() external returns (UpgradeResult memory result) {
        UpgradeConfig memory config = getUpgradeConfig();
        require(config.chainId == block.chainid, string.concat("Must upgrade on ", config.networkName));

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        string memory envVar = proxyEnvVar();
        result.proxy = vm.envAddress(envVar);
        require(result.proxy != address(0), string.concat(envVar, " required"));

        result.oldImplementation = Upgrades.getImplementationAddress(result.proxy);

        require(
            IAccessControl(result.proxy).hasRole(bytes32(0), deployer),
            string.concat("Deployer must have DEFAULT_ADMIN_ROLE on ", contractName())
        );

        vm.startBroadcast(deployer);

        Options memory opts;
        opts.unsafeAllow = "constructor";
        opts.unsafeSkipStorageCheck = true;

        Upgrades.upgradeProxy(result.proxy, contractArtifact(), "", opts);

        vm.stopBroadcast();

        result.newImplementation = Upgrades.getImplementationAddress(result.proxy);

        _logUpgrade(config, deployer, result, contractName());

        return result;
    }

    function _logUpgrade(
        UpgradeConfig memory config,
        address deployer,
        UpgradeResult memory result,
        string memory name
    )
        private
        pure
    {
        console2.log("");
        console2.log(string.concat("=== ", name, " Upgrade on ", config.networkName, " ==="));
        console2.log("Chain ID:", config.chainId);
        console2.log("");

        console2.log("--- Accounts ---");
        console2.log("Upgrader:", deployer);
        console2.log("");

        console2.log("--- Upgrade Details ---");
        console2.log(string.concat(name, " Proxy:"), result.proxy);
        console2.log("Old Implementation:", result.oldImplementation);
        console2.log("New Implementation:", result.newImplementation);

        if (result.oldImplementation == result.newImplementation) {
            console2.log("");
            console2.log("Warning! Implementation address unchanged (no bytecode changes detected)");
        }

        console2.log("====================================");
    }
}
