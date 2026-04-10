// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

interface ICoveredVaultWrapperRate {
    function setPremiumRate(uint256 newRate) external;
    function executePremiumRate() external;
    function premiumRatePerSecond() external view returns (uint256);
    function pendingPremiumRate() external view returns (uint256);
    function pendingPremiumRateTimestamp() external view returns (uint64);
}

/**
 * @title SetPremiumRate
 * @notice Manages premium rate changes on a CoveredVaultWrapper, with automatic fast-path detection.
 * @dev The premium rate controls how quickly
 *      covered depositors' principal is charged for insurance coverage:
 *
 *          premium accrued per second ≈ totalPrincipal × premiumRatePerSecond / 1e18
 *
 *      Without a non-zero rate, no premium accrues and DistributePremium.s.sol is a no-op.
 *      Call this script after policy binding (BindPolicy.s.sol) so deposits are open.
 *
 *      The contract supports two paths depending on whether a rate has already been applied
 *      this policy period (premiumRateInitialized flag):
 *
 *        Fast-path (first-time setting after policy binding):
 *          setPremiumRate() applies the rate immediately with NO timelock.
 *          Triggered when policy is bound but no rate has been set this period.
 *
 *        Normal path (subsequent rate changes):
 *          Two-step timelocked flow with OPERATIONAL_DELAY (2 hours):
 *            Step 1 — propose: call setPremiumRate(PREMIUM_RATE), starts the timelock
 *            Step 2 — execute: call executePremiumRate() once the delay has elapsed
 *
 *      This script is state-aware and selects the correct action automatically:
 *        • No pending change: broadcasts setPremiumRate(); if fast-path fires the rate is
 *          live immediately, otherwise reports when to run Step 2
 *        • Timelock elapsed:  broadcasts executePremiumRate() and verifies the new rate
 *        • Timelock pending:  logs the remaining wait time and exits without broadcasting
 *
 * @dev Rate is WAD-scaled per second. Common values:
 *        0.25% / year ≈ 79_274_479
 *        0.3%  / year ≈ 95_129_375
 *        0.5%  / year ≈ 158_548_959
 *        1%    / year ≈ 317_097_919    (1e18 / 31_536_000 / 100)
 *        5%    / year ≈ 1_585_489_599
 *        10%   / year ≈ 3_170_979_198
 *        50%   / year ≈ 15_854_895_991  (maximum allowed)
 *
 * Usage (first-time or propose):
 *   PREMIUM_RATE=<rate> forge script script/testing/SetPremiumRate.s.sol:SetPremiumRate \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Usage (Step 2 — execute, run after OPERATIONAL_DELAY has elapsed):
 *   forge script script/testing/SetPremiumRate.s.sol:SetPremiumRate \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Key that holds ownership of the CoveredVaultWrapper (owner role)
 *   - COVERED_VAULT: CoveredVaultWrapper proxy address
 *   - PREMIUM_RATE: Desired rate in wei per second (WAD-scaled, i.e. rate × 1e18 / 1e18).
 *       Max value: 15_854_895_991 (~50% per year).
 *       Example for 10%/year: 3_170_979_198
 *       Only read on initial propose; ignored when executing a pending timelock.
 *
 * Prerequisites:
 *   - Policy must be bound (BindPolicy.s.sol) so deposits are open and accrual is meaningful
 *   - Caller must be the CoveredVaultWrapper owner
 */
contract SetPremiumRate is Script {
    /// @notice Maximum premium rate per second (~50% per year, WAD-scaled).
    uint256 internal constant MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991;

    /// @notice Emitted when a rate change is proposed.
    event PremiumRateProposed(address indexed vault, uint256 newRate, uint256 effectiveAt);

    /// @notice Emitted when a rate change is executed.
    event PremiumRateExecuted(address indexed vault, uint256 newRate);

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address vault = vm.envAddress("COVERED_VAULT");
        uint256 premiumRate = vm.envOr("PREMIUM_RATE", uint256(0));

        ICoveredVaultWrapperRate wrapper = ICoveredVaultWrapperRate(vault);

        uint256 currentRate = wrapper.premiumRatePerSecond();
        uint256 pendingRate = wrapper.pendingPremiumRate();
        uint64 pendingTimestamp = wrapper.pendingPremiumRateTimestamp();

        console.log("=== SET PREMIUM RATE ===");
        console.log("CoveredVault:          ", vault);
        console.log("Current rate (wei/s):  ", currentRate);
        console.log("Pending rate (wei/s):  ", pendingRate);
        console.log("Pending timestamp:     ", pendingTimestamp);
        console.log("Block timestamp:       ", block.timestamp);

        if (pendingTimestamp == 0) {
            // ── No pending change — set rate (fast-path or propose) ────────────
            require(premiumRate > 0, "PREMIUM_RATE env var required to set a rate");
            require(premiumRate <= MAX_PREMIUM_RATE_PER_SECOND, "PREMIUM_RATE exceeds maximum allowed");

            console.log("\n[STEP 1] No pending rate change -- setting new rate:", premiumRate);

            vm.startBroadcast(deployerKey);
            wrapper.setPremiumRate(premiumRate);
            vm.stopBroadcast();

            uint64 effectiveAt = wrapper.pendingPremiumRateTimestamp();
            if (effectiveAt == 0) {
                // Fast-path: first-time rate setting after policy binding — applied immediately.
                uint256 activeRate = wrapper.premiumRatePerSecond();
                require(activeRate == premiumRate, "Fast-path failed: premiumRatePerSecond mismatch");
                console.log("\n[OK] First-time rate applied immediately (no timelock required)");
                console.log("Active rate (wei/s):", activeRate);
                emit PremiumRateExecuted(vault, activeRate);
            } else {
                // Normal propose path: timelock started, execution required after delay.
                uint256 confirmedPending = wrapper.pendingPremiumRate();
                require(confirmedPending == premiumRate, "Proposal not recorded: pendingPremiumRate mismatch");
                console.log("\n[OK] Rate proposal submitted and verified");
                console.log("Effective at (unix):", effectiveAt);
                console.log("Run this script again after that timestamp to execute the rate change.");
                emit PremiumRateProposed(vault, premiumRate, effectiveAt);
            }
        } else if (block.timestamp >= pendingTimestamp) {
            // ── Step 2: Timelock elapsed — execute the pending rate ──────────────
            console.log("\n[STEP 2] Timelock elapsed -- executing pending rate:", pendingRate);

            vm.startBroadcast(deployerKey);
            wrapper.executePremiumRate();
            vm.stopBroadcast();

            uint256 newRate = wrapper.premiumRatePerSecond();
            console.log("\n--- Verification ---");
            console.log("New active rate (wei/s):", newRate);
            require(wrapper.pendingPremiumRateTimestamp() == 0, "Pending state not cleared after execution");
            require(newRate == pendingRate, "Active rate does not match executed pending rate");
            console.log("[SUCCESS] Premium rate updated");

            console.log("\n=== PREMIUM RATE CHANGE COMPLETED ===");
            emit PremiumRateExecuted(vault, newRate);
        } else {
            // ── Timelock still pending — inform and exit
            // ─────────────────────────
            uint256 remaining = pendingTimestamp - block.timestamp;
            console.log("\n[WAIT] Rate change timelock still active.");
            console.log("Pending rate (wei/s):   ", pendingRate);
            console.log("Seconds remaining:      ", remaining);
            console.log("Run this script again after the timestamp has passed to execute.");
        }
    }
}
