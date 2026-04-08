// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ICoveredVaultWrapper} from "../../src/defi/interfaces/ICoveredVaultWrapper.sol";

/// @title SetPremiumRate
/// @notice Two-step timelocked premium rate update for CoveredVaultWrapper.
///
/// @dev Premium rate uses a 2-hour OPERATIONAL_DELAY timelock:
///      Step 1 (propose):  forge script SetPremiumRate --sig "propose()" ...
///      Step 2 (execute):  forge script SetPremiumRate --sig "execute()" ...  (after 2 hours)
///
/// @dev Rate is WAD-scaled per second. Common values:
///      0.25% / year ≈ 79_274_479
///      0.3%  / year ≈ 95_129_375
///      0.5%  / year ≈ 158_548_959
///      1%    / year ≈ 317_097_919   (1e18 / 31_536_000 / 100)
///      5%    / year ≈ 1_585_489_599
///      10%   / year ≈ 3_170_979_198
///      50%   / year ≈ 15_854_895_991  (maximum allowed)
///
/// @dev Usage:
///   1. Copy `.env.example` to `.env` and fill in COVERED_VAULT, NEW_PREMIUM_RATE, PRIVATE_KEY.
///   2. Propose:
///      forge script script/adapter/SetPremiumRate.s.sol:SetPremiumRate \
///        --sig "propose()" \
///        --rpc-url <RPC_URL> --broadcast -vvvv
///   3. Wait 2 hours, then execute:
///      forge script script/adapter/SetPremiumRate.s.sol:SetPremiumRate \
///        --sig "execute()" \
///        --rpc-url <RPC_URL> --broadcast -vvvv
contract SetPremiumRate is Script {
    // Maximum allowed rate constant (mirrors CoveredVaultStorage)
    uint256 internal constant MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991;

    // ─── Helpers
    // ───────────────────────────────────────────────────────────────

    function _load() internal view returns (ICoveredVaultWrapper vault, uint256 newRate, uint256 deployerKey) {
        vault = ICoveredVaultWrapper(vm.envAddress("COVERED_VAULT"));
        newRate = vm.envUint("NEW_PREMIUM_RATE");
        deployerKey = vm.envUint("PRIVATE_KEY");

        require(address(vault) != address(0), "COVERED_VAULT not set");
        require(newRate <= MAX_PREMIUM_RATE_PER_SECOND, "NEW_PREMIUM_RATE exceeds max (15_854_895_991)");
    }

    // ─── Step 1: propose
    // ───────────────────────────────────────────────────────

    /// @notice Proposes a new premium rate. Wait 2 hours, then call execute().
    function propose() external {
        (ICoveredVaultWrapper vault, uint256 newRate, uint256 key) = _load();
        address caller = vm.addr(key);

        console.log("=== SetPremiumRate: propose ===");
        console.log("Vault:            ", address(vault));
        console.log("Caller:           ", caller);
        console.log("Current rate/sec: ", vault.premiumRatePerSecond());
        console.log("New rate/sec:     ", newRate);

        vm.startBroadcast(key);
        vault.setPremiumRate(newRate);
        vm.stopBroadcast();

        uint64 executeAfter = vault.pendingPremiumRateTimestamp();
        console.log("Pending rate:     ", vault.pendingPremiumRate());
        console.log("Execute after:    ", executeAfter, "(unix timestamp)");
        console.log("=== Proposal submitted. Call execute() after 2 hours. ===");
    }

    // ─── Step 2: execute
    // ───────────────────────────────────────────────────────

    /// @notice Executes the pending premium rate change after the 2-hour timelock.
    function execute() external {
        (ICoveredVaultWrapper vault,, uint256 key) = _load();
        address caller = vm.addr(key);

        uint64 executeAfter = vault.pendingPremiumRateTimestamp();
        uint256 pendingRate = vault.pendingPremiumRate();

        require(executeAfter != 0, "No pending premium rate change");
        require(block.timestamp >= executeAfter, "Timelock not elapsed yet");

        console.log("=== SetPremiumRate: execute ===");
        console.log("Vault:            ", address(vault));
        console.log("Caller:           ", caller);
        console.log("Old rate/sec:     ", vault.premiumRatePerSecond());
        console.log("New rate/sec:     ", pendingRate);

        vm.startBroadcast(key);
        vault.executePremiumRate();
        vm.stopBroadcast();

        console.log("Active rate/sec:  ", vault.premiumRatePerSecond());
        console.log("=== Premium rate updated. ===");
    }

    /// @notice Default entry point — runs propose() for convenience.
    function run() external {
        this.propose();
    }
}
