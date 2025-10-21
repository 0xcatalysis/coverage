// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

/**
 * @title Show
 * @notice Shared inspection logic used to summarise a CoverPool deployment.
 */
abstract contract Show is Script {
    /**
     * @notice Network metadata used to validate and label inspection runs.
     * @param networkName Human-readable network label.
     * @param chainIdEnvKey Environment variable holding the expected chain id.
     * @param defaultChainId Fallback chain id to use when the env variable is unset.
     */
    struct ShowConfig {
        string networkName;
        string chainIdEnvKey;
        uint256 defaultChainId;
    }

    /**
     * @notice Reads environment variables and prints deployment metadata for a target network.
     * @dev Reverts when the current chain id does not match `getShowConfig` or when `COVER_POOL_ADDRESS` is unset.
     */
    function run() external view {
        ShowConfig memory config = getShowConfig();

        uint256 expectedChainId = vm.envOr(config.chainIdEnvKey, config.defaultChainId);
        require(block.chainid == expectedChainId, string.concat("Must run on ", config.networkName));

        address coverPoolAddr = vm.envOr("COVER_POOL_ADDRESS", address(0));
        require(coverPoolAddr != address(0), "COVER_POOL_ADDRESS environment variable required");

        _printDeploymentBanner(config, coverPoolAddr);
    }

    /**
     * @notice Returns the network metadata used to validate and label a Show run.
     */
    function getShowConfig() internal view virtual returns (ShowConfig memory);

    /**
     * @notice Pretty-prints the CoverPool deployment information for the current network.
     * @param config Network specific metadata.
     * @param coverPoolAddr Address of the CoverPool deployment being inspected.
     */
    function _printDeploymentBanner(ShowConfig memory config, address coverPoolAddr) private view {
        console2.log(string.concat("=== ", config.networkName, " CoverPool Deployment ==="));
        console2.log("Network:", config.networkName);
        console2.log("Chain ID:", block.chainid);
        console2.log("CoverPool Address:", coverPoolAddr);
        console2.log("Code Size:", coverPoolAddr.code.length);
        console2.log("=====================================");
    }
}
