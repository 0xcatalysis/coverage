// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {console2, Script} from "forge-std/Script.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {CreateXDeployer} from "./CreateXDeployer.s.sol";

/**
 * @title MigrateToTimelock
 * @notice Migrates existing coverage deployments to use a TimelockController as DEFAULT_ADMIN_ROLE holder.
 * @dev Two-phase migration for production deployments where contracts already exist with a multisig admin:
 *
 *      Phase 1 — deployTimelock(): Deploy TimelockController via CreateX. Run by deployer EOA.
 *      Phase 2 — migrateRoles(): Grant DEFAULT_ADMIN_ROLE to timelock, revoke from current admin.
 *                Must be run by the current ADMIN (multisig on mainnet — submit as Safe batch).
 *
 *      The grant-then-revoke order is critical: grants execute first so at least one admin
 *      always exists on every contract. If grant succeeds but revoke fails, both the timelock
 *      and old admin have the role — not ideal but not catastrophic. If revoke ran first,
 *      the admin role would be lost.
 *
 *      Environment Variables:
 *        - DEPLOYER_ADDRESS: EOA that deploys the TimelockController (Phase 1)
 *        - ADMIN: Current DEFAULT_ADMIN_ROLE holder (multisig) — used in Phase 2
 *        - TIMELOCK_MIN_DELAY: Minimum delay in seconds (defaults to 2 days)
 *        - SWAPPER_PROXY, PREMIUM_MANAGER_PROXY, CLAIM_MANAGER_PROXY,
 *          POLICY_MANAGER_PROXY, COVER_POOL_FACTORY_PROXY, SPEC_REGISTRY_PROXY: Proxy addresses
 */
contract MigrateToTimelock is CreateXDeployer {
    /**
     * @notice Phase 1: Deploy TimelockController. Run by deployer EOA.
     * @return timelock Address of the deployed TimelockController.
     */
    function deployTimelock() external returns (address timelock) {
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        address admin = vm.envOr("ADMIN", deployer);
        uint256 minDelay = vm.envOr("TIMELOCK_MIN_DELAY", uint256(2 days));

        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;

        _ensureCreateX();

        vm.startBroadcast(deployer);

        bytes memory initCode = abi.encodePacked(
            type(TimelockController).creationCode, abi.encode(minDelay, proposers, executors, address(0))
        );
        timelock = _deploy3(deployer, "TimelockController", initCode);

        vm.stopBroadcast();

        console2.log("=== TimelockController Deployed ===");
        console2.log("Address:", timelock);
        console2.log("Min Delay:", minDelay, "seconds");
        console2.log("Proposer/Executor/Canceller:", admin);
        console2.log("Admin: self-administered (address(0))");
        console2.log("===================================");
    }

    /**
     * @notice Phase 2: Grant DEFAULT_ADMIN_ROLE to timelock and revoke from current admin.
     * @dev Must be executed by the current ADMIN. On mainnet, omit --broadcast and submit
     *      all calls as a single Gnosis Safe multi-send batch for atomicity.
     */
    function migrateRoles() external {
        address admin = vm.envAddress("ADMIN");
        address timelock = vm.envAddress("TIMELOCK");

        address[6] memory proxies = [
            vm.envAddress("SWAPPER_PROXY"),
            vm.envAddress("PREMIUM_MANAGER_PROXY"),
            vm.envAddress("CLAIM_MANAGER_PROXY"),
            vm.envAddress("POLICY_MANAGER_PROXY"),
            vm.envAddress("COVER_POOL_FACTORY_PROXY"),
            vm.envAddress("SPEC_REGISTRY_PROXY")
        ];

        bytes32 defaultAdminRole = bytes32(0);

        vm.startBroadcast(admin);

        // Step 1: Grant DEFAULT_ADMIN_ROLE to TimelockController on all contracts
        for (uint256 i = 0; i < proxies.length; i++) {
            IAccessControl(proxies[i]).grantRole(defaultAdminRole, timelock);
        }

        // Step 2: Revoke DEFAULT_ADMIN_ROLE from current admin on all contracts
        for (uint256 i = 0; i < proxies.length; i++) {
            IAccessControl(proxies[i]).revokeRole(defaultAdminRole, admin);
        }

        vm.stopBroadcast();

        console2.log("=== Role Migration Complete ===");
        console2.log("TimelockController:", timelock);
        console2.log("Old Admin (revoked):", admin);
        for (uint256 i = 0; i < proxies.length; i++) {
            console2.log("  Migrated:", proxies[i]);
        }
        console2.log("===============================");
    }
}
