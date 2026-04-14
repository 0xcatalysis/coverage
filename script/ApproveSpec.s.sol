// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {console2} from "forge-std/console2.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
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
 *      When TIMELOCK is set (mainnet), DEFAULT_ADMIN_ROLE on SpecRegistry is held by the
 *      TimelockController. The script logs schedule/execute calldata for submission via Safe
 *      TX Builder instead of broadcasting directly.
 *      When TIMELOCK is not set (testnet), the call broadcasts directly from admin.
 *
 * Usage (testnet, no timelock):
 *   forge script script/ApproveSpec.s.sol:ApproveSpec \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Usage (mainnet, TIMELOCK set):
 *   forge script script/ApproveSpec.s.sol:ApproveSpec \
 *     --rpc-url $RPC_URL --slow -vvvv
 *   (Copy the printed schedule calldata and submit via Safe TX Builder)
 *   (After delay, submit the execute calldata)
 *
 * Required Environment Variables:
 *   - DEPLOYER_ADDRESS: Public address of the keystore signer (used with --keystore flag).
 *   - ADMIN: Holder of PROPOSER_ROLE on the TimelockController (mainnet) or DEFAULT_ADMIN_ROLE
 *            on SpecRegistry (testnet). Defaults to DEPLOYER_ADDRESS.
 *   - TIMELOCK (optional): TimelockController address. When set, routes approveSpec through
 *            the timelock and logs calldata for Safe TX Builder.
 *   - SPEC_REGISTRY: SpecRegistry proxy address (from Coverage deploy output)
 *   - SPEC_ADDRESS: ISpec implementation contract to approve
 *
 * Prerequisites:
 *   - Coverage contracts deployed (script/DeploySepolia.s.sol)
 *   - SPEC_ADDRESS is a deployed contract implementing ISpec
 *
 * Verify after running:
 *   cast call $SPEC_REGISTRY "isSpecApproved(address)(bool)" $SPEC_ADDRESS --rpc-url $RPC_URL
 *   # -> true
 */
contract ApproveSpec is Script {
    /// @notice Emitted when a spec is approved.
    event SpecApproved(address indexed specRegistry, address indexed spec);

    function run() external {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address admin = vm.envOr("ADMIN", deployer);
        address timelock = vm.envOr("TIMELOCK", address(0));
        address specRegistry = vm.envAddress("SPEC_REGISTRY");
        address specAddress = vm.envAddress("SPEC_ADDRESS");

        console.log("=== SPEC APPROVAL ===");
        console.log("SpecRegistry:", specRegistry);
        console.log("Spec:        ", specAddress);

        if (ISpecRegistry(specRegistry).isSpecApproved(specAddress)) {
            console.log("\n[SKIP] Spec already approved -- nothing to do");
            emit SpecApproved(specRegistry, specAddress);
            return;
        }

        if (timelock != address(0)) {
            _approveViaTimelock(admin, timelock, specRegistry, specAddress);
            // Calldata has been printed; approval is pending Safe TX Builder submission.
            // Do NOT emit SpecApproved or log completion — the spec is not approved yet.
            return;
        }

        _approveDirect(admin, specRegistry, specAddress);
    }

    /**
     * @notice Direct path (testnet / no timelock): broadcasts approveSpec from admin.
     */
    function _approveDirect(address admin, address specRegistry, address specAddress) private {
        require(
            IAccessControl(specRegistry).hasRole(bytes32(0), admin),
            "ADMIN must have DEFAULT_ADMIN_ROLE on SpecRegistry"
        );

        console.log("Broadcaster (DEFAULT_ADMIN_ROLE holder):", admin);

        vm.startBroadcast(admin);
        ISpecRegistry(specRegistry).approveSpec(specAddress);
        vm.stopBroadcast();

        console.log("\n--- Verification ---");
        bool approved = ISpecRegistry(specRegistry).isSpecApproved(specAddress);
        console.log("isSpecApproved:", approved);
        require(approved, "Spec approval failed");
        console.log("[SUCCESS] Spec approved in SpecRegistry");

        emit SpecApproved(specRegistry, specAddress);
        console.log("\n=== SPEC APPROVAL COMPLETED ===");
    }

    /**
     * @notice Timelock path (mainnet): logs schedule/execute calldata for Safe TX Builder.
     * @dev approveSpec requires DEFAULT_ADMIN_ROLE, held by TimelockController on mainnet.
     *      The admin (multisig) submits the schedule calldata now and the execute calldata
     *      after the timelock delay has elapsed.
     */
    function _approveViaTimelock(
        address admin,
        address timelock,
        address specRegistry,
        address specAddress
    )
        private
        view
    {
        require(
            IAccessControl(specRegistry).hasRole(bytes32(0), timelock),
            "TIMELOCK must have DEFAULT_ADMIN_ROLE on SpecRegistry"
        );

        console.log("Timelock (DEFAULT_ADMIN_ROLE holder):", timelock);
        console.log("Admin (proposer/executor):", admin);

        bytes memory approveCalldata = abi.encodeCall(ISpecRegistry.approveSpec, (specAddress));
        uint256 minDelay = TimelockController(payable(timelock)).getMinDelay();

        bytes memory scheduleCalldata = abi.encodeCall(
            TimelockController.schedule, (specRegistry, 0, approveCalldata, bytes32(0), bytes32(0), minDelay)
        );
        bytes memory executeCalldata =
            abi.encodeCall(TimelockController.execute, (specRegistry, 0, approveCalldata, bytes32(0), bytes32(0)));

        console2.log("");
        console2.log("--- Timelock Calldata (submit via Safe TX Builder) ---");
        console2.log("TimelockController:", timelock);
        console2.log("Min Delay:", minDelay, "seconds");
        console2.log("");
        console2.log("Step 1 - Schedule (submit now):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(scheduleCalldata));
        console2.log("");
        console2.log("Step 2 - Execute (submit after delay):");
        console2.log("  To:", timelock);
        console2.log("  Data:", vm.toString(executeCalldata));
        console2.log("=====================================================");
    }
}
