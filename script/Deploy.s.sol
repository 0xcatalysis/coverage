// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {CoverPool} from "../src/CoverPool.sol";

/**
 * @title Deploy
 * @notice Shared deployment helper that broadcasts a CoverPool deployment.
 */
abstract contract Deploy is Script {
    struct DeploymentConfig {
        string networkName;
        uint256 expectedChainId;
    }

    event CoverPoolDeployed(address indexed coverPool);

    /**
     * @notice Deploys a new CoverPool instance once the expected chain id is verified.
     * @return coverPool Address of the deployed CoverPool contract.
     * @dev Reverts when the active `block.chainid` does not match the expected value (if provided).
     */
    function run() external returns (address coverPool) {
        DeploymentConfig memory config = getDeploymentConfig();

        if (config.expectedChainId != 0) {
            require(block.chainid == config.expectedChainId, string.concat("Must deploy on ", config.networkName));
        }

        vm.startBroadcast();
        coverPool = address(new CoverPool());
        vm.stopBroadcast();

        emit CoverPoolDeployed(coverPool);
        _logDeployment(config, coverPool);
    }

    /// @notice Logs deployment metadata after a CoverPool is broadcast.
    /// @param config Network specific deployment configuration.
    /// @param coverPool Address of the deployed CoverPool instance.
    function _logDeployment(DeploymentConfig memory config, address coverPool) internal view {
        console2.log("=== CoverPool Deployment Summary ===");
        console2.log("Network:", config.networkName);
        console2.log("Chain ID:", block.chainid);
        console2.log("CoverPool Address:", coverPool);
        console2.log("Code Size:", coverPool.code.length);
        console2.log("====================================");
    }

    /// @notice Provides the network name and expected chain id used for deployment validation.
    function getDeploymentConfig() internal view virtual returns (DeploymentConfig memory);
}
