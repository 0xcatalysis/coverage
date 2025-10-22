// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {CoverPool} from "../src/CoverPool.sol";

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
     * @notice Emitted when a CoverPool deployment completes.
     * @param coverPool Address of the newly deployed CoverPool.
     */
    event CoverPoolDeployed(address indexed coverPool);

    /**
     * @notice Deploys a new CoverPool instance once the expected chain id is verified.
     * @return coverPool Address of the deployed CoverPool contract.
     * @dev Reverts when the active `block.chainid` does not match the expected value (if provided).
     */
    function run() external returns (address coverPool) {
        DeploymentConfig memory config = getDeploymentConfig();

        uint256 deployerPrivateKey = getDeployerPrivateKey();
        address deployer = vm.addr(deployerPrivateKey);

        if (config.expectedChainId != 0) {
            require(block.chainid == config.expectedChainId, string.concat("Must deploy on ", config.networkName));
        }

        vm.startBroadcast(deployerPrivateKey);
        coverPool = address(new CoverPool());
        vm.stopBroadcast();

        emit CoverPoolDeployed(coverPool);
        _logDeployment(config, coverPool, deployer);
    }

    /**
     * @notice Logs deployment metadata after a CoverPool is broadcast.
     * @param config Network specific deployment configuration.
     * @param coverPool Address of the deployed CoverPool instance.
     * @param deployer Address used to broadcast the deployment.
     */
    function _logDeployment(DeploymentConfig memory config, address coverPool, address deployer) internal view {
        console2.log("=== CoverPool Deployment Summary ===");
        console2.log("Network:", config.networkName);
        console2.log("Chain ID:", block.chainid);
        console2.log("CoverPool Address:", coverPool);
        console2.log("Deployer:", deployer);
        console2.log("Code Size:", coverPool.code.length);
        console2.log("====================================");
    }

    /**
     * @notice Provides the network name and expected chain id used for deployment validation.
     */
    function getDeploymentConfig() internal view virtual returns (DeploymentConfig memory);

    /**
     * @notice Reads the deployer private key from env or falls back to the default Anvil key.
     * @return privateKey Deployer private key used for broadcasting transactions.
     */
    function getDeployerPrivateKey() internal view returns (uint256 privateKey) {
        return vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
    }
}
