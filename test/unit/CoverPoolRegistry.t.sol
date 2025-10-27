// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPoolRegistry} from "../../src/CoverPoolRegistry.sol";
import {ICoverPoolRegistry} from "../../src/interfaces/ICoverPoolRegistry.sol";

contract CoverPoolRegistryTest is Test {
    bytes32 internal constant DEFAULT_SPEC_ID = keccak256("DEFAULT_SPEC");

    CoverPoolRegistry internal registry;
    address internal admin;
    address internal curator;
    address internal pool;
    address internal updatedPool;
    address internal premiumToken;
    address internal payoutToken;

    function setUp() public {
        admin = makeAddr("admin");
        curator = makeAddr("curator");
        pool = makeAddr("pool");
        updatedPool = makeAddr("updatedPool");
        premiumToken = makeAddr("premiumToken");
        payoutToken = makeAddr("payoutToken");

        vm.label(admin, "Admin");
        vm.label(curator, "Curator");
        vm.label(pool, "Pool");
        vm.label(updatedPool, "UpdatedPool");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");

        Options memory opts;
        opts.unsafeSkipAllChecks = true;
        address registryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolRegistry.sol:CoverPoolRegistry", abi.encodeCall(CoverPoolRegistry.initialize, (admin)), opts
        );
        registry = CoverPoolRegistry(registryProxy);
    }

    function test_initialize_WhenAdminZero_Reverts() public {
        CoverPoolRegistry registryImpl = new CoverPoolRegistry();
        vm.expectRevert(ICoverPoolRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(registryImpl), abi.encodeCall(CoverPoolRegistry.initialize, (address(0))));
    }

    function test_registerPool_WhenConfigValid_StoresConfiguration() public {
        ICoverPoolRegistry.PoolConfig memory config = _defaultConfig(true);

        vm.expectEmit(true, true, true, true, address(registry));
        emit ICoverPoolRegistry.PoolRegistered(1, config.pool, config.curator, config);

        vm.startPrank(admin);
        uint256 poolId = registry.registerPool(config);
        vm.stopPrank();

        assertEq(poolId, 1, "Pool id should start at 1");
        _assertPoolConfigEquals(poolId, config);
        assertEq(registry.resolvePool(pool), poolId, "Pool resolution mismatch");
    }

    function test_pause_WhenCalledByAdmin_Pauses() public {
        vm.startPrank(admin);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        registry.registerPool(_defaultConfig(true));
        vm.stopPrank();
    }

    function test_pause_WhenCalledByNonAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.pause();
    }

    function test_unpause_WhenCalledByAdmin_Unpauses() public {
        vm.startPrank(admin);
        registry.pause();
        registry.unpause();
        registry.registerPool(_defaultConfig(true));
        vm.stopPrank();
    }

    function test_unpause_WhenCalledByNonAdmin_Reverts() public {
        vm.startPrank(admin);
        registry.pause();
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.unpause();
    }

    function test_registerPool_WhenPaused_Reverts() public {
        vm.startPrank(admin);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        registry.registerPool(_defaultConfig(true));
        vm.stopPrank();
    }

    function test_registerPool_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.registerPool(_defaultConfig(true));
    }

    function test_registerPool_WhenPoolAlreadyRegistered_Reverts() public {
        _registerDefaultPool(true);

        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolAlreadyRegistered.selector, pool));
        vm.startPrank(admin);
        registry.registerPool(_defaultConfig(true));
        vm.stopPrank();
    }

    function test_registerPool_WhenFeeSumInvalid_Reverts() public {
        ICoverPoolRegistry.PoolConfig memory config = _defaultConfig(true);
        config.poolFeeBps = 6000;
        config.platformFeeBps = 5000;

        vm.expectRevert(ICoverPoolRegistry.InvalidFeeSum.selector);
        vm.startPrank(admin);
        registry.registerPool(config);
        vm.stopPrank();
    }

    function test_updatePoolConfig_WhenCalledByAdmin_UpdatesFields() public {
        uint256 poolId = _registerDefaultPool(true);

        ICoverPoolRegistry.PoolConfig memory updated = ICoverPoolRegistry.PoolConfig({
            curator: makeAddr("newCurator"),
            pool: pool,
            premiumToken: makeAddr("newPremiumToken"),
            payoutToken: makeAddr("newPayoutToken"),
            defaultSpecId: keccak256("NEW_SPEC"),
            poolFeeBps: 700,
            platformFeeBps: 200,
            active: true
        });

        vm.expectEmit(true, false, false, true, address(registry));
        emit ICoverPoolRegistry.PoolConfigUpdated(poolId, updated);
        vm.startPrank(admin);
        registry.updatePoolConfig(poolId, updated);
        vm.stopPrank();

        _assertPoolConfigEquals(poolId, updated);
    }

    function test_updatePoolConfig_WhenPaused_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.startPrank(admin);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        registry.updatePoolConfig(poolId, _defaultConfig(true));
        vm.stopPrank();
    }

    function test_updatePoolConfig_WhenActiveFlagDiffers_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.expectRevert(ICoverPoolRegistry.ActiveStatusMismatch.selector);
        vm.startPrank(admin);
        registry.updatePoolConfig(poolId, _defaultConfig(false));
        vm.stopPrank();
    }

    function test_updatePoolConfig_WhenPoolAddressChanges_UpdatesMapping() public {
        uint256 poolId = _registerDefaultPool(true);

        ICoverPoolRegistry.PoolConfig memory updated = _defaultConfig(true);
        updated.pool = updatedPool;

        vm.startPrank(admin);
        registry.updatePoolConfig(poolId, updated);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolNotRegistered.selector, pool));
        registry.resolvePool(pool);

        assertEq(registry.resolvePool(updatedPool), poolId, "Updated pool mapping incorrect");
    }

    function test_setPoolStatus_WhenStatusChanges_UpdatesActiveFlag() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.expectEmit(true, false, false, true, address(registry));
        emit ICoverPoolRegistry.PoolStatusSet(poolId, false);
        vm.prank(admin);
        registry.setPoolStatus(poolId, false);

        assertFalse(registry.getPoolConfig(poolId).active, "Pool should be inactive");
    }

    function test_setPoolStatus_WhenStatusUnchanged_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.expectRevert(ICoverPoolRegistry.PoolStatusUnchanged.selector);
        vm.startPrank(admin);
        registry.setPoolStatus(poolId, true);
        vm.stopPrank();
    }

    function test_resolvePool_WhenUnknownPool_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolNotRegistered.selector, address(0x1234)));
        registry.resolvePool(address(0x1234));
    }

    function test_getPoolConfig_WhenUnknownPool_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolNotFound.selector, 42));
        registry.getPoolConfig(42);
    }

    function _registerDefaultPool(bool active) internal returns (uint256 poolId) {
        vm.startPrank(admin);
        poolId = registry.registerPool(_defaultConfig(active));
        vm.stopPrank();
    }

    function _assertPoolConfigEquals(uint256 poolId, ICoverPoolRegistry.PoolConfig memory expected) internal view {
        ICoverPoolRegistry.PoolConfig memory stored = registry.getPoolConfig(poolId);
        assertEq(stored.curator, expected.curator, "Curator mismatch");
        assertEq(stored.pool, expected.pool, "Pool mismatch");
        assertEq(stored.premiumToken, expected.premiumToken, "Premium token mismatch");
        assertEq(stored.payoutToken, expected.payoutToken, "Payout token mismatch");
        assertEq(stored.defaultSpecId, expected.defaultSpecId, "Spec id mismatch");
        assertEq(stored.poolFeeBps, expected.poolFeeBps, "Pool fee mismatch");
        assertEq(stored.platformFeeBps, expected.platformFeeBps, "Platform fee mismatch");
        assertEq(stored.active, expected.active, "Active mismatch");
    }

    function _defaultConfig(bool active) internal view returns (ICoverPoolRegistry.PoolConfig memory) {
        return ICoverPoolRegistry.PoolConfig({
            curator: curator,
            pool: pool,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            defaultSpecId: DEFAULT_SPEC_ID,
            poolFeeBps: 500,
            platformFeeBps: 400,
            active: active
        });
    }
}
