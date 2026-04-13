// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2} from "forge-std/Script.sol";

import {CreateXDeployer} from "./CreateXDeployer.s.sol";

/**
 * @title ComputeAddresses
 * @notice Computes deterministic proxy addresses for a given deployer without deploying.
 * @dev Usage: forge script script/ComputeAddresses.s.sol --sig "run(address)" <DEPLOYER_ADDRESS>
 */
contract ComputeAddresses is CreateXDeployer {
    function run(address deployer) external pure {
        console2.log("=== Deterministic Proxy Addresses ===");
        console2.log("Deployer:", deployer);
        console2.log("");
        console2.log("Swapper:          ", _computeProxyAddress(deployer, "SwapperProxy"));
        console2.log("PremiumManager:   ", _computeProxyAddress(deployer, "PremiumManagerProxy"));
        console2.log("PolicyManager:    ", _computeProxyAddress(deployer, "PolicyManagerProxy"));
        console2.log("SpecRegistry:     ", _computeProxyAddress(deployer, "SpecRegistryProxy"));
        console2.log("ClaimManager:     ", _computeProxyAddress(deployer, "ClaimManagerProxy"));
        console2.log("CoverPoolFactory: ", _computeProxyAddress(deployer, "CoverPoolFactoryProxy"));
        console2.log("=====================================");
    }
}
