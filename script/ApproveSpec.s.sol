// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ISpecRegistry} from "../src/interfaces/ISpecRegistry.sol";

/**
 * @title ApproveSpec
 * @notice Approves a spec implementation contract in SpecRegistry, allowing it to be used
 *         in policy bindings. Must be run before bindPolicyForRequest() is called.
 *
 * @dev Required role: DEFAULT_ADMIN_ROLE on SpecRegistry (held by deployer after Phase 2).
 *
 *      For standard CoveredVaultWrapper deployments, SPEC_ADDRESS is the CoveredVaultWrapper
 *      proxy address — it implements ISpec via BasePolicyInteractions.
 *
 *      SpecRegistry.approveSpec() validates that the address is a deployed contract
 *      (code.length > 0), so this script must be run AFTER Phase 6 (CoveredVaultWrapper deploy).
 *
 * Usage:
 *   SPEC_REGISTRY=0x... SPEC_ADDRESS=0x... PRIVATE_KEY=0x... \
 *     forge script script/ApproveSpec.s.sol:ApproveSpec \
 *       --rpc-url $RPC_URL --broadcast -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY:    Admin private key (must hold DEFAULT_ADMIN_ROLE on SpecRegistry)
 *   - SPEC_REGISTRY:  SpecRegistry proxy address (from Phase 2)
 *   - SPEC_ADDRESS:   ISpec implementation to approve (CoveredVaultWrapper proxy for standard deployments)
 */
contract ApproveSpec is Script {
    function run() external {
        uint256 adminKey = vm.envUint("PRIVATE_KEY");
        address specRegistry = vm.envAddress("SPEC_REGISTRY");
        address specAddress = vm.envAddress("SPEC_ADDRESS");

        console.log("=== APPROVE SPEC ===");
        console.log("Admin:        ", vm.addr(adminKey));
        console.log("SpecRegistry: ", specRegistry);
        console.log("Spec address: ", specAddress);

        bool alreadyApproved = ISpecRegistry(specRegistry).isSpecApproved(specAddress);
        if (alreadyApproved) {
            console.log("Spec is already approved, nothing to do.");
            return;
        }

        vm.startBroadcast(adminKey);
        ISpecRegistry(specRegistry).approveSpec(specAddress);
        vm.stopBroadcast();

        console.log("\n=== VERIFICATION ===");
        bool approved = ISpecRegistry(specRegistry).isSpecApproved(specAddress);
        console.log("isSpecApproved:", approved);
        require(approved, "ApproveSpec: approval not reflected on-chain");
        console.log("===================");
    }
}
