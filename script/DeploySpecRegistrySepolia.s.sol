// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MockSpec} from "../src/mocks/MockSpec.sol";
import {MockSpecRegistry} from "../src/mocks/MockSpecRegistry.sol";

/**
 * @title DeploySpecRegistrySepolia
 * @notice Standalone deployment script for SpecRegistry mock contracts on Sepolia.
 * @dev This script deploys the mock Spec and SpecRegistry contracts for testing ClaimManager
 *      on Sepolia.
 *
 *      Usage:
 *        PRIVATE_KEY=0x... forge script script/DeploySpecRegistrySepolia.s.sol \
 *          --broadcast --rpc-url sepolia --verify
 *
 *      The script will output deployed addresses which you can then use in your .env file:
 *        SPEC_REGISTRY=0x...  # Use this in your Coverage deployment
 */
contract DeploySpecRegistrySepolia is Script {
    uint256 internal constant DEFAULT_PRIVATE_KEY =
        uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80);

    function run() external returns (address mockSpec, address mockSpecRegistry) {
        require(block.chainid == 11_155_111, "Must deploy on Sepolia (chainId: 11155111)");

        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", DEFAULT_PRIVATE_KEY);
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("");
        console2.log("=== Deploying SpecRegistry Mocks to Sepolia ===");
        console2.log("Chain ID:", block.chainid);
        console2.log("Deployer:", deployer);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        mockSpec = address(new MockSpec());
        mockSpecRegistry = address(new MockSpecRegistry(mockSpec));

        vm.stopBroadcast();

        _logDeployment(deployer, mockSpec, mockSpecRegistry);

        return (mockSpec, mockSpecRegistry);
    }

    function _logDeployment(address deployer, address mockSpec, address mockSpecRegistry) private pure {
        console2.log("--- Deployment Complete ---");
        console2.log("MockSpec:", mockSpec);
        console2.log("MockSpecRegistry:", mockSpecRegistry);
        console2.log("Owner:", deployer);
    }
}
