// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";

interface ICoveredVaultWrapperReset {
    function resetPolicyBinding() external;
    function policyId() external view returns (uint96);
    function policyBoundExecuted() external view returns (bool);
    function depositCap() external view returns (uint256);
}

/**
 * @title ResetPolicyBinding
 * @notice Resets a CoveredVaultWrapper's policy binding after the policy has matured,
 *         enabling a successive coverage period.
 * @dev Must be called after:
 *        block.timestamp >= policy.maturityTime
 *      The contract enforces this and reverts with InvalidParameters if called early.
 *
 *      resetPolicyBinding() does the following atomically:
 *        1. Accrues any remaining premium up to maturityTime
 *        2. Flushes pending premium through PremiumManager.distributePremium() so
 *           pool curator fees and restaker rewards are correctly split
 *        3. Clears policyId, policyBoundExecuted, depositCap, policyStartTime
 *        4. Clears all pending timelocked state (depositCap, deductible, premiumRate,
 *           premiumRecipient proposals) so they do not leak into the next policy epoch
 *
 *      After this call:
 *        - maxDeposit() returns 0 (deposit cap cleared — no new deposits until next binding)
 *        - A new requestCoverage() + bindPolicyForRequest() cycle can begin
 *        - policyId() == 0 and policyBoundExecuted() == false
 *
 * Usage:
 *   forge script script/testing/ResetPolicyBinding.s.sol:ResetPolicyBinding \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Key that holds ownership of the CoveredVaultWrapper
 *   - COVERED_VAULT: CoveredVaultWrapper proxy address
 *   - POLICY_MANAGER: PolicyManager proxy address (used for pre-flight maturity check)
 *
 * Prerequisites:
 *   - Policy coverage window has expired (block.timestamp >= maturityTime)
 *   - All claims have been filed (remaining coverage snapshot is informational only)
 *   - Caller is the CoveredVaultWrapper owner
 */
contract ResetPolicyBinding is Script {
    /// @notice Emitted when policy binding is successfully reset.
    event PolicyBindingReset(address indexed vault, uint96 previousPolicyId);

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vault = vm.envAddress("COVERED_VAULT");
        address policyMgr = vm.envAddress("POLICY_MANAGER");

        ICoveredVaultWrapperReset wrapper = ICoveredVaultWrapperReset(vault);
        IPolicyManager pm = IPolicyManager(policyMgr);

        uint96 currentPolicyId = wrapper.policyId();
        bool boundExecuted = wrapper.policyBoundExecuted();
        uint256 cap = wrapper.depositCap();

        console.log("=== RESET POLICY BINDING ===");
        console.log("CoveredVault:        ", vault);
        console.log("Current policyId:    ", currentPolicyId);
        console.log("policyBoundExecuted: ", boundExecuted);
        console.log("depositCap:          ", cap);

        if (currentPolicyId == 0) {
            console.log("\n[SKIP] No active policy binding -- nothing to reset");
            return;
        }

        _verifyMaturity(pm, currentPolicyId);

        vm.startBroadcast(deployerKey);
        wrapper.resetPolicyBinding();
        vm.stopBroadcast();

        console.log("\n--- Verification ---");
        uint96 newPolicyId = wrapper.policyId();
        bool newBoundExecuted = wrapper.policyBoundExecuted();
        uint256 newCap = wrapper.depositCap();

        console.log("policyId after reset:          ", newPolicyId);
        console.log("policyBoundExecuted after reset:", newBoundExecuted);
        console.log("depositCap after reset:         ", newCap);

        require(newPolicyId == 0, "policyId not cleared");
        require(!newBoundExecuted, "policyBoundExecuted not cleared");
        require(newCap == 0, "depositCap not cleared");

        console.log("[SUCCESS] Policy binding reset -- vault ready for next coverage period");
        console.log("\n=== RESET COMPLETED ===");
        console.log("Next steps:");
        console.log("  1. Run RequestCoverage.s.sol to open a new policy draft");
        console.log("  2. Run BindPolicy.s.sol to activate the new coverage period");

        emit PolicyBindingReset(vault, currentPolicyId);
    }

    function _verifyMaturity(IPolicyManager pm, uint96 policyId) internal view {
        console.log("\n--- Pre-flight: Maturity Check ---");
        IPolicyManager.PolicyMetadata memory meta = pm.policyMetadata(policyId);
        console.log("Policy maturityTime:", meta.maturityTime);
        console.log("Block timestamp:    ", block.timestamp);

        if (block.timestamp < meta.maturityTime) {
            uint256 remaining = meta.maturityTime - block.timestamp;
            console.log("[FAIL] Policy has not matured yet. Seconds remaining:", remaining);
            revert("Policy has not matured -- cannot reset before maturityTime");
        }
        console.log("[OK] Policy has matured -- reset is allowed");
    }
}
