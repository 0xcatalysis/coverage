// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @title Show
 * @notice Shared inspection logic used to summarise CoverPool deployments from broadcast artifacts.
 */
abstract contract Show is Script {
    /**
     * @notice Metadata describing how to locate a broadcast artifact for a network.
     * @param networkName Human-readable network label logged in the summary.
     * @param chainIdEnvKey Environment variable containing the expected chain id.
     * @param defaultChainId Fallback chain id used when the environment variable is unset.
     * @param deploymentScript Name of the Forge script whose broadcast output should be inspected.
     * @param runFile Broadcast artifact filename (typically `run-latest.json`).
     */
    struct ShowConfig {
        string networkName;
        string chainIdEnvKey;
        uint256 defaultChainId;
        string deploymentScript;
        string runFile;
    }

    /**
     * @notice Loads the latest broadcast artifact for the target network and prints all contract addresses.
     * @dev Reverts when the active chain id does not match `getShowConfig` or when the broadcast artifact is missing.
     *      Reads all proxy and implementation addresses from the named return values of the Deploy script.
     */
    function run() external view {
        ShowConfig memory config = getShowConfig();

        uint256 chainId = vm.envOr(config.chainIdEnvKey, config.defaultChainId);
        require(block.chainid == chainId, string.concat("Must run on ", config.networkName));

        string memory runFile = bytes(config.runFile).length == 0 ? "run-latest.json" : config.runFile;
        string memory artifactPath =
            string.concat("broadcast/", config.deploymentScript, "/", vm.toString(block.chainid), "/", runFile);

        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory artifact = vm.readFile(artifactPath);

        address coverPoolImpl = abi.decode(vm.parseJson(artifact, ".returns.coverPoolImplementation.value"), (address));
        address coverPoolFactoryProxy =
            abi.decode(vm.parseJson(artifact, ".returns.coverPoolFactoryProxy.value"), (address));
        address coverPoolFactoryImpl =
            abi.decode(vm.parseJson(artifact, ".returns.coverPoolFactoryImpl.value"), (address));
        address swapperProxy = abi.decode(vm.parseJson(artifact, ".returns.swapperProxy.value"), (address));
        address swapperImpl = abi.decode(vm.parseJson(artifact, ".returns.swapperImpl.value"), (address));
        address premiumManagerProxy =
            abi.decode(vm.parseJson(artifact, ".returns.premiumManagerProxy.value"), (address));
        address premiumManagerImpl = abi.decode(vm.parseJson(artifact, ".returns.premiumManagerImpl.value"), (address));
        address claimManagerProxy = abi.decode(vm.parseJson(artifact, ".returns.claimManagerProxy.value"), (address));
        address claimManagerImpl = abi.decode(vm.parseJson(artifact, ".returns.claimManagerImpl.value"), (address));
        address policyManagerProxy = abi.decode(vm.parseJson(artifact, ".returns.policyManagerProxy.value"), (address));
        address policyManagerImpl = abi.decode(vm.parseJson(artifact, ".returns.policyManagerImpl.value"), (address));
        address specRegistryProxy = abi.decode(vm.parseJson(artifact, ".returns.specRegistryProxy.value"), (address));
        address specRegistryImpl = abi.decode(vm.parseJson(artifact, ".returns.specRegistryImpl.value"), (address));

        console2.log(string.concat("=== ", config.networkName, " Deployment ==="));
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployment Script:", config.deploymentScript);
        console2.log("");
        console2.log("CoverPool Implementation:       ", coverPoolImpl);
        console2.log("");
        console2.log("Swapper Proxy:                  ", swapperProxy);
        console2.log("Swapper Implementation:         ", swapperImpl);
        console2.log("");
        console2.log("PremiumManager Proxy:           ", premiumManagerProxy);
        console2.log("PremiumManager Implementation:  ", premiumManagerImpl);
        console2.log("");
        console2.log("ClaimManager Proxy:             ", claimManagerProxy);
        console2.log("ClaimManager Implementation:    ", claimManagerImpl);
        console2.log("");
        console2.log("PolicyManager Proxy:            ", policyManagerProxy);
        console2.log("PolicyManager Implementation:   ", policyManagerImpl);
        console2.log("");
        console2.log("CoverPoolFactory Proxy:         ", coverPoolFactoryProxy);
        console2.log("CoverPoolFactory Implementation:", coverPoolFactoryImpl);
        console2.log("");
        console2.log("SpecRegistry Proxy:             ", specRegistryProxy);
        console2.log("SpecRegistry Implementation:    ", specRegistryImpl);
        console2.log("=====================================");
    }

    /**
     * @notice Returns the network metadata used to validate and label a Show run.
     */
    function getShowConfig() internal view virtual returns (ShowConfig memory);
}
