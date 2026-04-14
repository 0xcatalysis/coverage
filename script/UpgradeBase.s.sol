// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
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
 *        - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag).
 *        - ADMIN: Holder of DEFAULT_ADMIN_ROLE on the target proxy. Defaults to DEPLOYER_ADDRESS.
 *                 On mainnet this is the Gnosis Safe multisig — omit --broadcast and submit via Safe.
 *        - <proxyEnvVar()>: Address of the deployed proxy (e.g. CLAIM_MANAGER_PROXY).
 *        - TIMELOCK (optional): TimelockController address. When set, the script deploys the new
 *                 implementation and outputs schedule/execute calldata for Safe TX Builder instead
 *                 of broadcasting the upgrade directly.
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
     *
     *      When the TIMELOCK env var is set, the script:
     *        1. Deploys the new implementation (broadcast from deployer)
     *        2. Logs TimelockController.schedule() and execute() calldata for Safe TX Builder
     *
     *      When TIMELOCK is not set, the script broadcasts the upgrade directly (testnet mode).
     * @return result Struct containing proxy and implementation addresses.
     */
    function run() external returns (UpgradeResult memory result) {
        UpgradeConfig memory config = getUpgradeConfig();
        require(config.chainId == block.chainid, string.concat("Must upgrade on ", config.networkName));

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address timelock = vm.envOr("TIMELOCK", address(0));

        string memory envVar = proxyEnvVar();
        result.proxy = vm.envAddress(envVar);
        require(result.proxy != address(0), string.concat(envVar, " required"));

        result.oldImplementation = Upgrades.getImplementationAddress(result.proxy);

        if (timelock != address(0)) {
            _upgradeViaTimelock(deployer, timelock, result, config);
        } else {
            _upgradeDirect(deployer, result, config);
        }

        return result;
    }

    /**
     * @notice Direct upgrade path — broadcasts upgradeProxy directly (testnet / EOA admin).
     */
    function _upgradeDirect(address deployer, UpgradeResult memory result, UpgradeConfig memory config) private {
        address admin = vm.envOr("ADMIN", deployer);

        require(
            IAccessControl(result.proxy).hasRole(bytes32(0), admin),
            string.concat("ADMIN must have DEFAULT_ADMIN_ROLE on ", contractName())
        );

        vm.startBroadcast(admin);

        Options memory opts;
        opts.unsafeAllow = "constructor";
        opts.unsafeSkipStorageCheck = true;

        Upgrades.upgradeProxy(result.proxy, contractArtifact(), "", opts);

        vm.stopBroadcast();

        result.newImplementation = Upgrades.getImplementationAddress(result.proxy);
        _logUpgrade(config, admin, result, contractName());
    }

    /**
     * @notice Timelock upgrade path — deploys new impl and outputs schedule/execute calldata.
     * @dev The deployer broadcasts only the new implementation deployment. The actual upgrade
     *      (upgradeToAndCall on the proxy) must be scheduled through the TimelockController
     *      by submitting the logged calldata via Gnosis Safe TX Builder.
     */
    function _upgradeViaTimelock(
        address deployer,
        address timelock,
        UpgradeResult memory result,
        UpgradeConfig memory config
    )
        private
    {
        require(
            IAccessControl(result.proxy).hasRole(bytes32(0), timelock),
            string.concat("TIMELOCK must have DEFAULT_ADMIN_ROLE on ", contractName())
        );

        // Deploy new implementation
        vm.startBroadcast(deployer);

        Options memory opts;
        opts.unsafeAllow = "constructor";
        opts.unsafeSkipStorageCheck = true;
        address newImpl = Upgrades.deployImplementation(contractArtifact(), opts);

        vm.stopBroadcast();

        result.newImplementation = newImpl;

        // Build the upgradeToAndCall calldata that the timelock will execute on the proxy
        bytes memory upgradeCalldata = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newImpl, ""));
        uint256 minDelay = TimelockController(payable(timelock)).getMinDelay();

        // Build TimelockController.schedule() calldata
        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule, (result.proxy, 0, upgradeCalldata, bytes32(0), bytes32(0), minDelay)
        );

        // Build TimelockController.execute() calldata
        bytes memory executeCalldata =
            abi.encodeCall(TimelockController.execute, (result.proxy, 0, upgradeCalldata, bytes32(0), bytes32(0)));

        _logUpgrade(config, timelock, result, contractName());

        console2.log("");
        console2.log("--- Timelock Calldata (submit via Safe TX Builder) ---");
        console2.log("TimelockController:", timelock);
        console2.log("Min Delay:", minDelay, "seconds");
        console2.log("");
        console2.log("Step 1 - Schedule (submit now):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(scheduleCalldata));
        console2.log("");
        console2.log("Step 2 - Execute (submit after delay):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(executeCalldata));
        console2.log("=============================================");
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
