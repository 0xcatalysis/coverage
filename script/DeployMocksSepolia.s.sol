// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {MockBindPolicyHook} from "../src/mocks/MockBindPolicyHook.sol";
import {MockSpec} from "../src/mocks/MockSpec.sol";

/**
 * @title DeployMocksSepolia
 * @notice Deploys MockBindPolicyHook and MockSpec on Sepolia for E2E testing.
 * @dev Usage:
 *   PRIVATE_KEY=0x... forge script script/DeployMocksSepolia.s.sol --broadcast --rpc-url $SEPOLIA_RPC_URL --verify
 */
contract DeployMocksSepolia is Script {
    uint256 internal constant SEPOLIA_CHAIN_ID = 11_155_111;

    function run() external {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Must run on Sepolia");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=== Deploying Test Mocks on Sepolia ===");
        console2.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        MockBindPolicyHook hook = new MockBindPolicyHook();
        console2.log("MockBindPolicyHook deployed at:", address(hook));

        MockSpec spec = new MockSpec();
        console2.log("MockSpec deployed at:", address(spec));

        vm.stopBroadcast();

        console2.log("");
        console2.log("=== Mock Deployment Complete ===");
        console2.log("BIND_POLICY_HOOK=", address(hook));
        console2.log("SPEC_ADDRESS=", address(spec));
    }
}
