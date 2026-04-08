// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";

interface ICoveredVaultWrapperUpgrade {
    function proposeUpgrade(address newImplementation) external;
    function executeUpgrade() external;
    function pendingImplementation() external view returns (address);
    function pendingUpgradeTimestamp() external view returns (uint64);
    function owner() external view returns (address);
}

/**
 * @title UpgradeCoveredVaultWrapper
 * @notice Manages the two-step timelocked UUPS upgrade for a CoveredVaultWrapper proxy.
 * @dev CoveredVaultWrapper uses a custom timelocked upgrade path (not the standard
 *      OpenZeppelin `upgradeProxy` helper) that requires two transactions separated by
 *      UPGRADE_DELAY (7 days):
 *
 *        Step 1 — propose: proposeUpgrade(NEW_IMPLEMENTATION), starts the delay
 *        Step 2 — execute: executeUpgrade() once UPGRADE_DELAY has elapsed
 *
 *      CoveredVaultWrapper uses Ownable2Step, so only the current owner can call both
 *      functions. The standard UpgradeBase script cannot be reused here.
 *
 *      This script is state-aware and selects the correct action automatically:
 *        • No pending upgrade:   broadcasts proposeUpgrade() and reports when to run Step 2
 *        • Timelock elapsed:     broadcasts executeUpgrade() and verifies the new implementation
 *        • Timelock pending:     logs the remaining wait time and exits without broadcasting
 *
 * Usage (Step 1 — propose):
 *   NEW_IMPLEMENTATION=<addr> forge script script/adapter/UpgradeCoveredVaultWrapper.s.sol \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Usage (Step 2 — execute, run after UPGRADE_DELAY has elapsed):
 *   forge script script/adapter/UpgradeCoveredVaultWrapper.s.sol \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY:        Key that holds ownership of the CoveredVaultWrapper (owner role)
 *   - COVERED_VAULT:      CoveredVaultWrapper proxy address
 *   - NEW_IMPLEMENTATION: Address of the new CoveredVaultWrapper implementation (Step 1 only)
 */
contract UpgradeCoveredVaultWrapper is Script {
    /// @notice Emitted when an upgrade is proposed.
    event UpgradeProposed(address indexed proxy, address indexed newImpl, uint256 effectiveAt);

    /// @notice Emitted when an upgrade is executed.
    event UpgradeExecuted(address indexed proxy, address indexed newImpl);

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address proxy = vm.envAddress("COVERED_VAULT");

        ICoveredVaultWrapperUpgrade wrapper = ICoveredVaultWrapperUpgrade(proxy);

        address owner = wrapper.owner();
        address pendingImpl = wrapper.pendingImplementation();
        uint64 pendingTimestamp = wrapper.pendingUpgradeTimestamp();

        console.log("=== UPGRADE COVERED VAULT WRAPPER ===");
        console.log("Proxy:                 ", proxy);
        console.log("Deployer:              ", deployer);
        console.log("Owner:                 ", owner);
        console.log("Pending implementation:", pendingImpl);
        console.log("Pending timestamp:     ", pendingTimestamp);
        console.log("Block timestamp:       ", block.timestamp);

        require(owner == deployer, "Caller is not the CoveredVaultWrapper owner");

        if (pendingTimestamp == 0) {
            // ── Step 1: No pending upgrade — propose a new implementation ───────────
            address newImpl = vm.envAddress("NEW_IMPLEMENTATION");
            require(newImpl != address(0), "NEW_IMPLEMENTATION must not be zero address");
            require(newImpl.code.length > 0, "NEW_IMPLEMENTATION has no code");

            console.log("\n[STEP 1] No pending upgrade -- proposing new implementation:", newImpl);

            vm.startBroadcast(deployerKey);
            wrapper.proposeUpgrade(newImpl);
            vm.stopBroadcast();

            uint64 effectiveAt = wrapper.pendingUpgradeTimestamp();
            address confirmedPending = wrapper.pendingImplementation();
            require(effectiveAt > 0, "Proposal not recorded: pendingUpgradeTimestamp still zero");
            require(confirmedPending == newImpl, "Proposal not recorded: pendingImplementation mismatch");

            console.log("\n[OK] Upgrade proposal submitted and verified");
            console.log("Pending implementation:", confirmedPending);
            console.log("Effective at (unix):   ", effectiveAt);
            console.log("Run this script again after that timestamp to execute the upgrade.");
            emit UpgradeProposed(proxy, newImpl, effectiveAt);
        } else if (block.timestamp >= pendingTimestamp) {
            // ── Step 2: Timelock elapsed — execute the pending upgrade ────────────
            console.log("\n[STEP 2] Timelock elapsed -- executing upgrade to:", pendingImpl);

            vm.startBroadcast(deployerKey);
            wrapper.executeUpgrade();
            vm.stopBroadcast();

            address activeImpl = Upgrades.getImplementationAddress(proxy);
            console.log("\n--- Verification ---");
            console.log("Active implementation:", activeImpl);
            require(wrapper.pendingUpgradeTimestamp() == 0, "Pending state not cleared after executeUpgrade");
            require(activeImpl == pendingImpl, "Active implementation does not match executed pending");

            console.log("[SUCCESS] CoveredVaultWrapper upgraded");
            console.log("\n=== UPGRADE COMPLETED ===");
            emit UpgradeExecuted(proxy, activeImpl);
        } else {
            // ── Timelock still pending — inform and exit
            // ──────────────────────────
            uint256 remaining = pendingTimestamp - block.timestamp;
            console.log("\n[WAIT] Upgrade timelock still active.");
            console.log("Pending implementation:", pendingImpl);
            console.log("Seconds remaining:     ", remaining);
            console.log("Run this script again after the timestamp has passed to execute.");
        }
    }
}
