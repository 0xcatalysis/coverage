// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Script, console2} from "forge-std/Script.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoverPoolRegistry} from "../src/CoverPoolRegistry.sol";

/**
 * @title Deploy
 * @notice Shared deployment helper that broadcasts a CoverPool deployment.
 */
abstract contract Deploy is Script {
    uint256 internal constant DEFAULT_PRIVATE_KEY = uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);

    /**
     * @notice Network-specific metadata used to validate deployments.
     * @param networkName Human-readable network label used in logs.
     * @param expectedChainId Chain id required for the deployment run (0 to skip validation).
     */
    struct DeploymentConfig {
        string networkName;
        uint256 expectedChainId;
    }

    /**
     * @notice Deploys the CoverPool implementation and CoverPoolRegistry proxy after validating chain id.
     * @return coverPool Address of the deployed CoverPool contract.
     * @return coverPoolRegistry Address of the deployed CoverPoolRegistry proxy.
     */
    function run() external returns (address coverPool, address coverPoolRegistry) {
        DeploymentConfig memory config = getDeploymentConfig();

        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address deployer = vm.addr(deployerPrivateKey);
        address coverPoolRegistryAdmin = vm.envOr("COVER_POOL_REGISTRY_ADMIN", deployer);

        if (config.expectedChainId != 0) {
            require(block.chainid == config.expectedChainId, string.concat("Must deploy on ", config.networkName));
        }

        vm.startBroadcast(deployerPrivateKey);
        coverPool = address(new CoverPool());
        coverPoolRegistry = Upgrades.deployUUPSProxy(
            "CoverPoolRegistry.sol:CoverPoolRegistry", abi.encodeCall(CoverPoolRegistry.initialize, (coverPoolRegistryAdmin))
        );
        vm.stopBroadcast();

        console2.log(string.concat("=== ", config.networkName, " Deployment ==="));
        console2.log("Chain ID:", block.chainid);
        console2.log("CoverPool Address:", coverPool);
        console2.log("CoverPoolRegistry Address:", coverPoolRegistry);
        console2.log("CoverPoolRegistry Admin:", coverPoolRegistryAdmin);
        console2.log("Deployer:", deployer);
        console2.log("====================================");
    }

    /**
     * @notice Provides the network name and expected chain id used for deployment validation.
     */
    function getDeploymentConfig() internal view virtual returns (DeploymentConfig memory);
}
