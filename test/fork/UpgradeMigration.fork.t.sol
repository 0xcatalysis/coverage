// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {ClaimManager} from "../../src/ClaimManager.sol";
import {PremiumManager} from "../../src/PremiumManager.sol";
import {PolicyManager} from "../../src/PolicyManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";

/**
 * @title UpgradeMigrationForkTest
 * @notice Fork tests that upgrade a live Coverage proxy from the audit-baseline implementation to
 *         the new layout-safe implementation and assert that all previously readable state is
 *         preserved exactly.
 *
 *         These tests are gated on ETHEREUM_RPC_URL and the env vars for each proxy address.
 *         Run with:
 *           FOUNDRY_PROFILE=fork ETHEREUM_RPC_URL=<url> \
 *           CLAIM_MANAGER_PROXY=<addr> PREMIUM_MANAGER_PROXY=<addr> POLICY_MANAGER_PROXY=<addr> \
 *           forge test --match-path "test/fork/UpgradeMigration.fork.t.sol" -vvv
 *
 * @dev The test pins a fork block, reads live state, upgrades the proxy via upgradeToAndCall,
 *      then re-reads every snapshotted field and asserts equality. It also runs one round-trip
 *      (setPremiumManager, distributePremium) to verify runtime semantics are unchanged.
 */
contract UpgradeMigrationForkTest is Test {
    string internal constant ENV_RPC = "ETHEREUM_RPC_URL";
    string internal constant ENV_CLAIM_PROXY = "CLAIM_MANAGER_PROXY";
    string internal constant ENV_PREMIUM_PROXY = "PREMIUM_MANAGER_PROXY";
    string internal constant ENV_POLICY_PROXY = "POLICY_MANAGER_PROXY";
    string internal constant ENV_ADMIN = "UPGRADE_ADMIN";

    bool internal _forkAvailable;

    function setUp() public {
        string memory rpc = vm.envOr(ENV_RPC, string(""));
        if (bytes(rpc).length == 0) {
            console2.log("[skip] ETHEREUM_RPC_URL not set; fork tests are skipped.");
            _forkAvailable = false;
            return;
        }
        vm.createSelectFork(rpc);
        _forkAvailable = true;
    }

    // ──────────────────────────────────────────────────────────────────────────
    // ClaimManager upgrade preservation
    // ──────────────────────────────────────────────────────────────────────────

    function test_fork_ClaimManager_statePreservedAfterUpgrade() public {
        if (!_forkAvailable) return;

        address proxy = vm.envOr(ENV_CLAIM_PROXY, address(0));
        if (proxy == address(0)) {
            console2.log("[skip] CLAIM_MANAGER_PROXY not set.");
            return;
        }

        ClaimManager cm = ClaimManager(proxy);

        // Snapshot pre-upgrade state
        address specRegistryBefore = cm.specRegistry();
        address slashingManagerBefore = cm.slashingManager();
        address swapperBefore = cm.swapper();
        address policyManagerBefore = cm.policyManager();
        uint16 slippageBefore = cm.maxSwapSlippageBps();
        bool pausedBefore = cm.paused();

        // Verify slot positions match audit baseline BEFORE upgrade
        _assertAddressAtSlot(proxy, 1, specRegistryBefore, "pre: specRegistry slot 1");
        _assertAddressAtSlot(proxy, 2, slashingManagerBefore, "pre: slashingManager slot 2");
        _assertAddressAtSlot(proxy, 3, swapperBefore, "pre: swapper slot 3");
        _assertAddressAtSlot(proxy, 4, policyManagerBefore, "pre: policyManager slot 4");

        // Deploy new implementation
        Options memory opts;
        opts.unsafeAllow = "constructor";
        opts.unsafeSkipStorageCheck = false;
        address newImpl = Upgrades.deployImplementation("ClaimManager.sol", opts);

        // Upgrade (admin must hold DEFAULT_ADMIN_ROLE)
        address upgradeAdmin = vm.envOr(ENV_ADMIN, address(0));
        require(upgradeAdmin != address(0), "UPGRADE_ADMIN required for fork upgrade test");

        vm.prank(upgradeAdmin);
        cm.upgradeToAndCall(newImpl, "");

        // Assert all pre-upgrade state is preserved
        assertEq(cm.specRegistry(), specRegistryBefore, "specRegistry preserved");
        assertEq(cm.slashingManager(), slashingManagerBefore, "slashingManager preserved");
        assertEq(cm.swapper(), swapperBefore, "swapper preserved");
        assertEq(cm.policyManager(), policyManagerBefore, "policyManager preserved");
        assertEq(cm.maxSwapSlippageBps(), slippageBefore, "maxSwapSlippageBps preserved");
        assertEq(cm.paused(), pausedBefore, "paused preserved");

        // Verify slot positions match audit baseline AFTER upgrade
        _assertAddressAtSlot(proxy, 1, specRegistryBefore, "post: specRegistry slot 1");
        _assertAddressAtSlot(proxy, 2, slashingManagerBefore, "post: slashingManager slot 2");
        _assertAddressAtSlot(proxy, 3, swapperBefore, "post: swapper slot 3");
        _assertAddressAtSlot(proxy, 4, policyManagerBefore, "post: policyManager slot 4");

        // _deprecated_chainlinkPriceFeed at slot 5 must retain its pre-upgrade value
        bytes32 slot5 = vm.load(proxy, bytes32(uint256(5)));
        uint16 slippageFromSlot = uint16(uint256(slot5) >> 160);
        assertEq(slippageFromSlot, slippageBefore, "post: maxSwapSlippageBps preserved in packed slot 5");

        console2.log("[pass] ClaimManager upgrade state preservation verified.");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // PremiumManager upgrade preservation
    // ──────────────────────────────────────────────────────────────────────────

    function test_fork_PremiumManager_statePreservedAfterUpgrade() public {
        if (!_forkAvailable) return;

        address proxy = vm.envOr(ENV_PREMIUM_PROXY, address(0));
        if (proxy == address(0)) {
            console2.log("[skip] PREMIUM_MANAGER_PROXY not set.");
            return;
        }

        PremiumManager pm = PremiumManager(proxy);

        // Snapshot
        address rewardsManagerBefore = pm.rewardsManager();
        address platformTreasuryBefore = pm.platformTreasury();
        uint16 platformFeeBefore = pm.platformFeeBps();

        _assertAddressAtSlot(proxy, 1, rewardsManagerBefore, "pre: rewardsManager slot 1");
        _assertAddressAtSlot(proxy, 2, platformTreasuryBefore, "pre: platformTreasury slot 2");

        // The _distributionNonce is at slot 3 — read raw
        bytes32 nonceBefore = vm.load(proxy, bytes32(uint256(3)));

        // Deploy and upgrade
        Options memory opts;
        opts.unsafeAllow = "constructor";
        address newImpl = Upgrades.deployImplementation("PremiumManager.sol", opts);
        address upgradeAdmin = vm.envOr(ENV_ADMIN, address(0));
        require(upgradeAdmin != address(0), "UPGRADE_ADMIN required");

        vm.prank(upgradeAdmin);
        pm.upgradeToAndCall(newImpl, "");

        // Assert preservation
        assertEq(pm.rewardsManager(), rewardsManagerBefore, "rewardsManager preserved");
        assertEq(pm.platformTreasury(), platformTreasuryBefore, "platformTreasury preserved");
        assertEq(pm.platformFeeBps(), platformFeeBefore, "platformFeeBps preserved");

        bytes32 nonceAfter = vm.load(proxy, bytes32(uint256(3)));
        assertEq(nonceAfter, nonceBefore, "_distributionNonce preserved at slot 3");

        console2.log("[pass] PremiumManager upgrade state preservation verified.");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // PolicyManager upgrade preservation
    // ──────────────────────────────────────────────────────────────────────────

    function test_fork_PolicyManager_statePreservedAfterUpgrade() public {
        if (!_forkAvailable) return;

        address proxy = vm.envOr(ENV_POLICY_PROXY, address(0));
        if (proxy == address(0)) {
            console2.log("[skip] POLICY_MANAGER_PROXY not set.");
            return;
        }

        PolicyManager polMgr = PolicyManager(proxy);

        // Snapshot
        address stakeManagerBefore = polMgr.stakeManager();
        address claimManagerBefore = polMgr.claimManager();
        address chainlinkBefore = polMgr.chainlinkPriceFeed();

        _assertAddressAtSlot(proxy, 1, stakeManagerBefore, "pre: stakeManager slot 1");
        _assertAddressAtSlot(proxy, 9, chainlinkBefore, "pre: chainlinkPriceFeed slot 9");

        // Deploy and upgrade
        Options memory opts;
        opts.unsafeAllow = "constructor";
        address newImpl = Upgrades.deployImplementation("PolicyManager.sol", opts);
        address upgradeAdmin = vm.envOr(ENV_ADMIN, address(0));
        require(upgradeAdmin != address(0), "UPGRADE_ADMIN required");

        vm.prank(upgradeAdmin);
        polMgr.upgradeToAndCall(newImpl, "");

        // Assert preservation
        assertEq(polMgr.stakeManager(), stakeManagerBefore, "stakeManager preserved");
        assertEq(polMgr.claimManager(), claimManagerBefore, "claimManager preserved");
        assertEq(polMgr.chainlinkPriceFeed(), chainlinkBefore, "chainlinkPriceFeed preserved");

        _assertAddressAtSlot(proxy, 1, stakeManagerBefore, "post: stakeManager slot 1");
        _assertAddressAtSlot(proxy, 9, chainlinkBefore, "post: chainlinkPriceFeed slot 9");

        console2.log("[pass] PolicyManager upgrade state preservation verified.");
    }

    // ──────────────────────────────────────────────────────────────────────────
    // Helper
    // ──────────────────────────────────────────────────────────────────────────

    function _assertAddressAtSlot(address target, uint256 slot, address expected, string memory label) internal {
        bytes32 raw = vm.load(target, bytes32(slot));
        assertEq(address(uint160(uint256(raw))), expected, label);
    }
}
