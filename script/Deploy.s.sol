// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Script, console2} from "forge-std/Script.sol";
import {CoverPool} from "../src/CoverPool.sol";
import {CoverPoolFactory} from "../src/CoverPoolFactory.sol";
import {CoverPoolRegistry} from "../src/CoverPoolRegistry.sol";

/**
 * @title Deploy
 * @notice Shared deployment helper that broadcasts a CoverPool deployment.
 */
abstract contract Deploy is Script {
    uint256 internal constant DEFAULT_PRIVATE_KEY =
        uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);

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
     * @notice Deploys the CoverPool implementation, CoverPoolFactory proxy, and CoverPoolRegistry proxy.
     * @return coverPoolFactoryProxy Address of the deployed CoverPoolFactory proxy.
     * @return coverPoolFactoryImpl Implementation address for the CoverPoolFactory proxy.
     * @return coverPoolRegistryProxy Address of the deployed CoverPoolRegistry proxy.
     * @return coverPoolRegistryImpl Implementation address for the CoverPoolRegistry proxy.
     */
    function run()
        external
        returns (
            address coverPoolFactoryProxy,
            address coverPoolFactoryImpl,
            address coverPoolRegistryProxy,
            address coverPoolRegistryImpl
        )
    {
        DeploymentConfig memory config = getDeploymentConfig();
        require(config.expectedChainId == block.chainid, string.concat("Must deploy on ", config.networkName));

        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address deployer = vm.addr(deployerPrivateKey);

        address coverPoolFactoryAdmin = vm.envOr("COVER_POOL_FACTORY_ADMIN", deployer);
        address coverPoolFactoryCreator = vm.envOr("COVER_POOL_FACTORY_CREATOR", coverPoolFactoryAdmin);
        address coverPoolPolicyManager = vm.envOr("COVER_POOL_POLICY_MANAGER", deployer);
        address coverPoolRegistryAdmin = vm.envOr("COVER_POOL_REGISTRY_ADMIN", deployer);
        address coverPoolRegistryRegistrar = vm.envOr("COVER_POOL_REGISTRY_REGISTRAR", coverPoolRegistryAdmin);

        vm.startBroadcast(deployerPrivateKey);

        address coverPoolImplementation = address(new CoverPool());

        coverPoolFactoryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolFactory.sol:CoverPoolFactory",
            abi.encodeCall(
                CoverPoolFactory.initialize,
                (coverPoolFactoryAdmin, coverPoolFactoryCreator, coverPoolImplementation, coverPoolPolicyManager)
            )
        );
        coverPoolFactoryImpl = Upgrades.getImplementationAddress(coverPoolFactoryProxy);

        coverPoolRegistryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolRegistry.sol:CoverPoolRegistry",
            abi.encodeCall(CoverPoolRegistry.initialize, (coverPoolRegistryAdmin, coverPoolRegistryRegistrar))
        );
        coverPoolRegistryImpl = Upgrades.getImplementationAddress(coverPoolRegistryProxy);

        vm.stopBroadcast();

        console2.log(string.concat("=== ", config.networkName, " Deployment ==="));
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("CoverPool Implementation:", coverPoolImplementation);
        console2.log("CoverPoolFactory Proxy:", coverPoolFactoryProxy);
        console2.log("CoverPoolFactory Implementation:", coverPoolFactoryImpl);
        console2.log("CoverPoolFactory Admin:", coverPoolFactoryAdmin);
        console2.log("CoverPoolFactory Creator:", coverPoolFactoryCreator);
        console2.log("Policy Manager:", coverPoolPolicyManager);
        console2.log("CoverPoolRegistry Proxy:", coverPoolRegistryProxy);
        console2.log("CoverPoolRegistry Implementation:", coverPoolRegistryImpl);
        console2.log("CoverPoolRegistry Admin:", coverPoolRegistryAdmin);
        console2.log("CoverPoolRegistry Registrar:", coverPoolRegistryRegistrar);
        console2.log("====================================");

        return (coverPoolFactoryProxy, coverPoolFactoryImpl, coverPoolRegistryProxy, coverPoolRegistryImpl);
    }

    /**
     * @notice Provides the network name and expected chain id used for deployment validation.
     */
    function getDeploymentConfig() internal view virtual returns (DeploymentConfig memory);
}
