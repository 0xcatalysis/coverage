// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ISpecRegistry} from "../src/interfaces/ISpecRegistry.sol";

/**
 * @title ApproveSpec
 * @notice Approves an ISpec implementation in the SpecRegistry, enabling it to be registered
 *         by CoverPools during policy binding.
 * @dev Must be run before BindPolicy.s.sol.
 *
 *      bindPolicyForRequest() calls SpecRegistry.registerSpec() internally. If the spec
 *      address has not been approved by an admin, the call reverts with SpecNotApproved.
 *
 *      SPEC_ADDRESS is the CoveredVaultWrapper proxy address. CoveredVaultWrapper implements
 *      ISpec via BasePolicyInteractions and serves as the parametric claim evaluation contract
 *      for the policy.
 *
 * Usage:
 *   forge script script/ApproveSpec.s.sol:ApproveSpec \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag).
 *   - ADMIN: Holder of DEFAULT_ADMIN_ROLE on SpecRegistry. Defaults to DEPLOYER_ADDRESS.
 *            On mainnet this is the Gnosis Safe multisig — omit --broadcast and submit via Safe.
 *   - SPEC_REGISTRY: SpecRegistry proxy address (from Coverage deploy output)
 *   - SPEC_ADDRESS: ISpec implementation contract to approve
 *
 * Prerequisites:
 *   - Coverage contracts deployed (script/DeploySepolia.s.sol)
 *   - SPEC_ADDRESS is a deployed contract implementing ISpec
 *
 * Verify after running:
 *   cast call $SPEC_REGISTRY "isSpecApproved(address)(bool)" $SPEC_ADDRESS --rpc-url $RPC_URL
 *   # → true
 */
contract ApproveSpec is Script {
    /// @notice Emitted when a spec is approved.
    event SpecApproved(address indexed specRegistry, address indexed spec);

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        // DEFAULT_ADMIN_ROLE is transferred to ADMIN during Deploy.s.sol when deployer != admin.
        // On mainnet ADMIN is the multisig; omit --broadcast and submit the calldata via Safe.
        address admin = vm.envOr("ADMIN", deployer);
        address specRegistry = vm.envAddress("SPEC_REGISTRY");
        address specAddress = vm.envAddress("SPEC_ADDRESS");

        console.log("=== SPEC APPROVAL ===");
        console.log("Broadcaster (DEFAULT_ADMIN_ROLE holder):", admin);
        console.log("SpecRegistry:", specRegistry);
        console.log("Spec:        ", specAddress);

        if (ISpecRegistry(specRegistry).isSpecApproved(specAddress)) {
            console.log("\n[SKIP] Spec already approved -- nothing to do");
            emit SpecApproved(specRegistry, specAddress);
            return;
        }

        vm.startBroadcast(admin);
        ISpecRegistry(specRegistry).approveSpec(specAddress);
        vm.stopBroadcast();

        console.log("\n--- Verification ---");
        bool approved = ISpecRegistry(specRegistry).isSpecApproved(specAddress);
        console.log("isSpecApproved:", approved);
        require(approved, "Spec approval failed");
        console.log("[SUCCESS] Spec approved in SpecRegistry");

        console.log("\n=== SPEC APPROVAL COMPLETED ===");
        emit SpecApproved(specRegistry, specAddress);
    }
}
