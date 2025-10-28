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
    address internal registrar;
    address internal curator;
    address internal pool;
    address internal updatedPool;
    address internal premiumToken;
    address internal payoutToken;

    function setUp() public {
        admin = makeAddr("admin");
        registrar = makeAddr("registrar");
        curator = makeAddr("curator");
        pool = makeAddr("pool");
        updatedPool = makeAddr("updatedPool");
        premiumToken = makeAddr("premiumToken");
        payoutToken = makeAddr("payoutToken");

        vm.label(admin, "Admin");
        vm.label(registrar, "Registrar");
        vm.label(curator, "Curator");
        vm.label(pool, "Pool");
        vm.label(updatedPool, "UpdatedPool");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");

        Options memory opts;
        opts.unsafeSkipAllChecks = true;
        address registryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolRegistry.sol:CoverPoolRegistry",
            abi.encodeCall(CoverPoolRegistry.initialize, (admin, registrar)),
            opts
        );
        registry = CoverPoolRegistry(registryProxy);
    }

    function test_initialize_WhenAdminZero_Reverts() public {
        CoverPoolRegistry registryImpl = new CoverPoolRegistry();
        vm.expectRevert(ICoverPoolRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(registryImpl), abi.encodeCall(CoverPoolRegistry.initialize, (address(0), registrar)));
    }

    function test_initialize_WhenRegistrarZero_Reverts() public {
        CoverPoolRegistry registryImpl = new CoverPoolRegistry();
        vm.expectRevert(ICoverPoolRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(registryImpl), abi.encodeCall(CoverPoolRegistry.initialize, (admin, address(0))));
    }

    function test_registerPool_WhenConfigValid_StoresConfiguration() public {
        ICoverPoolRegistry.PoolConfig memory config = _defaultConfig(true);

        vm.expectEmit(true, true, true, true, address(registry));
        emit ICoverPoolRegistry.PoolRegistered(1, config.pool, config.curator, config);

        vm.prank(registrar);
        uint256 poolId = registry.registerPool(config);

        assertEq(poolId, 1, "Pool id should start at 1");
        _assertPoolConfigEquals(poolId, config);
        assertEq(registry.resolvePool(pool), poolId, "Pool resolution mismatch");
    }

    function test_pause_WhenCalledByAdmin_Pauses() public {
        vm.prank(admin);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(registrar);
        registry.registerPool(_defaultConfig(true));
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
        vm.stopPrank();

        vm.prank(registrar);
        registry.registerPool(_defaultConfig(true));
    }

    function test_unpause_WhenCalledByNonAdmin_Reverts() public {
        vm.prank(admin);
        registry.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.unpause();
    }

    function test_registerPool_WhenPaused_Reverts() public {
        vm.prank(admin);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(registrar);
        registry.registerPool(_defaultConfig(true));
    }

    function test_registerPool_WhenCallerNotRegistrar_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.REGISTRAR_ROLE()
            )
        );
        registry.registerPool(_defaultConfig(true));
    }

    function test_registerPool_WhenPoolAlreadyRegistered_Reverts() public {
        _registerDefaultPool(true);

        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolAlreadyRegistered.selector, pool));
        vm.prank(registrar);
        registry.registerPool(_defaultConfig(true));
    }

    function test_registerPool_WhenFeeExceedsLimits_Reverts() public {
        ICoverPoolRegistry.PoolConfig memory config = _defaultConfig(true);
        config.poolFeeBps = 2001;

        vm.expectRevert(ICoverPoolRegistry.InvalidFeeBps.selector);
        vm.prank(registrar);
        registry.registerPool(config);
    }

    function test_registerPool_WhenFeeAtLimit_Succeeds() public {
        ICoverPoolRegistry.PoolConfig memory config = _defaultConfig(true);
        config.poolFeeBps = 2000;
        config.platformFeeBps = 0;

        vm.prank(registrar);
        uint256 poolId = registry.registerPool(config);

        assertEq(poolId, 1, "Pool id mismatch");
        _assertPoolConfigEquals(poolId, config);
    }

    function test_grantRole_WhenCalledByAdmin_AddsRegistrar() public {
        address newRegistrar = makeAddr("newRegistrar");
        bytes32 registrarRole = registry.REGISTRAR_ROLE();

        vm.prank(admin);
        registry.grantRole(registrarRole, newRegistrar);

        assertTrue(registry.hasRole(registrarRole, newRegistrar), "Registrar role not granted");
    }

    function test_grantRole_WhenCallerNotAdmin_Reverts() public {
        address newRegistrar = makeAddr("badRegistrar");
        bytes32 registrarRole = registry.REGISTRAR_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.grantRole(registrarRole, newRegistrar);
    }

    function test_revokeRole_WhenCalledByAdmin_RemovesRegistrar() public {
        address newRegistrar = makeAddr("tempRegistrar");
        bytes32 registrarRole = registry.REGISTRAR_ROLE();

        vm.startPrank(admin);
        registry.grantRole(registrarRole, newRegistrar);
        registry.revokeRole(registrarRole, newRegistrar);
        vm.stopPrank();

        assertFalse(registry.hasRole(registrarRole, newRegistrar), "Registrar role not revoked");
    }

    function test_revokeRole_WhenCallerNotAdmin_Reverts() public {
        address newRegistrar = makeAddr("tempRegistrar2");
        bytes32 registrarRole = registry.REGISTRAR_ROLE();

        vm.prank(admin);
        registry.grantRole(registrarRole, newRegistrar);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.DEFAULT_ADMIN_ROLE()
            )
        );
        registry.revokeRole(registrarRole, newRegistrar);
    }

    function test_updatePoolConfig_WhenCalledByRegistrar_UpdatesFields() public {
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
        vm.prank(registrar);
        registry.updatePoolConfig(poolId, updated);

        _assertPoolConfigEquals(poolId, updated);
    }

    function test_updatePoolConfig_WhenPaused_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.prank(admin);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(registrar);
        registry.updatePoolConfig(poolId, _defaultConfig(true));
    }

    function test_updatePoolConfig_WhenActiveFlagDiffers_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.expectRevert(ICoverPoolRegistry.PoolActiveStatusMismatch.selector);
        vm.prank(registrar);
        registry.updatePoolConfig(poolId, _defaultConfig(false));
    }

    function test_updatePoolConfig_WhenCallerNotRegistrar_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.REGISTRAR_ROLE()
            )
        );
        registry.updatePoolConfig(poolId, _defaultConfig(true));
    }

    function test_updatePoolConfig_WhenPoolAddressChanges_UpdatesMapping() public {
        uint256 poolId = _registerDefaultPool(true);

        ICoverPoolRegistry.PoolConfig memory updated = _defaultConfig(true);
        updated.pool = updatedPool;

        vm.prank(registrar);
        registry.updatePoolConfig(poolId, updated);

        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolNotRegistered.selector, pool));
        registry.resolvePool(pool);

        assertEq(registry.resolvePool(updatedPool), poolId, "Updated pool mapping incorrect");
    }

    function test_updatePoolConfig_WhenPoolAddressAlreadyRegistered_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        ICoverPoolRegistry.PoolConfig memory otherConfig = _makeIndexedConfig(1, true);
        vm.prank(registrar);
        registry.registerPool(otherConfig);

        ICoverPoolRegistry.PoolConfig memory updateConfig = _defaultConfig(true);
        updateConfig.pool = otherConfig.pool;

        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolAlreadyRegistered.selector, updateConfig.pool));
        vm.prank(registrar);
        registry.updatePoolConfig(poolId, updateConfig);
    }

    function test_setPoolStatus_WhenStatusChanges_UpdatesActiveFlag() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.expectEmit(true, false, false, true, address(registry));
        emit ICoverPoolRegistry.PoolStatusSet(poolId, false);
        vm.prank(registrar);
        registry.setPoolStatus(poolId, false);

        assertFalse(registry.getPoolConfig(poolId).active, "Pool should be inactive");
    }

    function test_setPoolStatus_WhenStatusUnchanged_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.expectRevert(ICoverPoolRegistry.PoolStatusUnchanged.selector);
        vm.prank(registrar);
        registry.setPoolStatus(poolId, true);
    }

    function test_setPoolStatus_WhenCallerNotRegistrar_Reverts() public {
        uint256 poolId = _registerDefaultPool(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), registry.REGISTRAR_ROLE()
            )
        );
        registry.setPoolStatus(poolId, false);
    }

    function test_listPools_WhenPaginated_ReturnsBatches() public {
        ICoverPoolRegistry.PoolConfig[] memory expected = new ICoverPoolRegistry.PoolConfig[](3);

        vm.startPrank(registrar);
        for (uint256 i = 0; i < expected.length; ++i) {
            expected[i] = _makeIndexedConfig(i, true);
            registry.registerPool(expected[i]);
        }
        vm.stopPrank();

        (uint256[] memory poolIds, ICoverPoolRegistry.PoolConfig[] memory configs) = registry.listPools(0, 2);

        assertEq(poolIds.length, 2, "First page size mismatch");
        assertEq(configs.length, 2, "First page configs size mismatch");
        assertEq(poolIds[0], 1, "First id incorrect");
        assertEq(poolIds[1], 2, "Second id incorrect");

        for (uint256 i = 0; i < configs.length; ++i) {
            _assertPoolConfigEqualsStruct(configs[i], expected[poolIds[i] - 1]);
        }

        (uint256[] memory poolIds2, ICoverPoolRegistry.PoolConfig[] memory configs2) = registry.listPools(2, 2);

        assertEq(poolIds2.length, 1, "Second page size mismatch");
        assertEq(configs2.length, 1, "Second page configs size mismatch");
        assertEq(poolIds2[0], 3, "Third id incorrect");
        _assertPoolConfigEqualsStruct(configs2[0], expected[poolIds2[0] - 1]);
    }

    function test_listPools_WhenLimitZero_Reverts() public {
        vm.prank(registrar);
        registry.registerPool(_makeIndexedConfig(0, true));

        vm.expectRevert(ICoverPoolRegistry.InvalidLimit.selector);
        registry.listPools(0, 0);
    }

    function test_listPools_WhenCursorPastEnd_ReturnsEmpty() public {
        vm.prank(registrar);
        registry.registerPool(_makeIndexedConfig(0, true));

        (uint256[] memory poolIds, ICoverPoolRegistry.PoolConfig[] memory configs) = registry.listPools(10, 2);
        assertEq(poolIds.length, 0, "Expected empty pool ids");
        assertEq(configs.length, 0, "Expected empty configs");
    }

    function test_getPoolConfig_WhenUnknownPool_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolNotFound.selector, 42));
        registry.getPoolConfig(42);
    }

    function test_resolvePool_WhenUnknownPool_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICoverPoolRegistry.PoolNotRegistered.selector, address(0x1234)));
        registry.resolvePool(address(0x1234));
    }

    function _registerDefaultPool(bool active) internal returns (uint256 poolId) {
        vm.prank(registrar);
        poolId = registry.registerPool(_defaultConfig(active));
    }

    function _assertPoolConfigEquals(
        uint256 poolId,
        ICoverPoolRegistry.PoolConfig memory expected
    )
        internal
        view
    {
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

    function _assertPoolConfigEqualsStruct(
        ICoverPoolRegistry.PoolConfig memory actual,
        ICoverPoolRegistry.PoolConfig memory expected
    )
        internal
        pure
    {
        assertEq(actual.curator, expected.curator, "Returned curator mismatch");
        assertEq(actual.pool, expected.pool, "Returned pool mismatch");
        assertEq(actual.premiumToken, expected.premiumToken, "Returned premium token mismatch");
        assertEq(actual.payoutToken, expected.payoutToken, "Returned payout token mismatch");
        assertEq(actual.defaultSpecId, expected.defaultSpecId, "Returned spec id mismatch");
        assertEq(actual.poolFeeBps, expected.poolFeeBps, "Returned pool fee mismatch");
        assertEq(actual.platformFeeBps, expected.platformFeeBps, "Returned platform fee mismatch");
        assertEq(actual.active, expected.active, "Returned active mismatch");
    }

    function _makeIndexedConfig(uint256 index, bool active) internal returns (ICoverPoolRegistry.PoolConfig memory) {
        string memory suffix = vm.toString(index);
        return ICoverPoolRegistry.PoolConfig({
            curator: makeAddr(string.concat("curator_", suffix)),
            pool: makeAddr(string.concat("pool_", suffix)),
            premiumToken: makeAddr(string.concat("premiumToken_", suffix)),
            payoutToken: makeAddr(string.concat("payoutToken_", suffix)),
            defaultSpecId: keccak256(bytes(string.concat("SPEC_", suffix))),
            // forge-lint: disable-next-line(unsafe-typecast)
            poolFeeBps: uint16(500 + index),
            platformFeeBps: 400,
            active: active
        });
    }
}
