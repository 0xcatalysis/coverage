// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Script, console2} from "forge-std/Script.sol";
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
     * @param expectedChainId Chain id required for the deployment run.
     */
    struct DeploymentConfig {
        string networkName;
        uint256 expectedChainId;
    }

    /**
     * @notice Deploys the CoverPool implementation and CoverPoolRegistry proxy after validating chain id.
     */
    function run() external {
        DeploymentConfig memory config = getDeploymentConfig();
        require(config.expectedChainId == block.chainid, string.concat("Must deploy on ", config.networkName));

        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address deployer = vm.addr(deployerPrivateKey);

        address coverPoolRegistryAdmin = vm.envOr("COVER_POOL_REGISTRY_ADMIN", deployer);
        address coverPoolRegistryRegistrar = vm.envOr("COVER_POOL_REGISTRY_REGISTRAR", coverPoolRegistryAdmin);

        vm.startBroadcast(deployerPrivateKey);

        address coverPoolRegistryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolRegistry.sol:CoverPoolRegistry",
            abi.encodeCall(CoverPoolRegistry.initialize, (coverPoolRegistryAdmin, coverPoolRegistryRegistrar))
        );

        vm.stopBroadcast();

        address coverPoolRegistryImpl = Upgrades.getImplementationAddress(coverPoolRegistryProxy);

        console2.log(string.concat("=== ", config.networkName, " Deployment ==="));
        console2.log("Chain ID:", block.chainid);
        console2.log("CoverPoolRegistry Proxy:", coverPoolRegistryProxy);
        console2.log("CoverPoolRegistry Implementation:", coverPoolRegistryImpl);
        console2.log("CoverPoolRegistry Admin:", coverPoolRegistryAdmin);
        console2.log("CoverPoolRegistry Registrar:", coverPoolRegistryRegistrar);
        console2.log("====================================");
    }

    /**
     * @notice Provides the network name and expected chain id used for deployment validation.
     */
    function getDeploymentConfig() internal view virtual returns (DeploymentConfig memory);
}
