// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPoolFactory} from "../../src/CoverPoolFactory.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";

contract CoverPoolFactoryTest is Test {
    CoverPoolFactory internal factory;
    CoverPool internal implementation;

    address internal admin;
    address internal creator;
    address internal policyManager;
    address internal curator;
    address internal quoteSigner;
    address internal premiumToken;
    address internal payoutToken;

    bytes32 internal constant ADMIN_ROLE = 0x00;
    bytes32 internal creatorRole;

    Options internal opts;

    function setUp() public {
        admin = makeAddr("admin");
        creator = makeAddr("creator");
        policyManager = makeAddr("policyManager");
        curator = makeAddr("curator");
        quoteSigner = makeAddr("quoteSigner");
        premiumToken = makeAddr("premiumToken");
        payoutToken = makeAddr("payoutToken");

        vm.label(admin, "Admin");
        vm.label(creator, "Creator");
        vm.label(policyManager, "PolicyManager");
        vm.label(curator, "Curator");
        vm.label(quoteSigner, "QuoteSigner");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");

        opts.unsafeSkipAllChecks = true;

        implementation = new CoverPool();

        address proxy = Upgrades.deployUUPSProxy(
            "CoverPoolFactory.sol:CoverPoolFactory",
            abi.encodeCall(CoverPoolFactory.initialize, (admin, creator, address(implementation), policyManager)),
            opts
        );
        factory = CoverPoolFactory(proxy);

        creatorRole = factory.CREATOR_ROLE();
    }

    function test_initialize_WhenImplementationZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(CoverPoolFactory.initialize, (admin, creator, address(0), policyManager))
        );
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(CoverPoolFactory.initialize, (admin, creator, address(implementation), address(0)))
        );
    }

    function test_setCoverPoolImplementation_WhenCallerNotCreator_Reverts() public {
        address caller = makeAddr("notCreator");
        CoverPool newImplementation = new CoverPool();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, creatorRole)
        );
        vm.prank(caller);
        factory.setCoverPoolImplementation(address(newImplementation));
    }

    function test_setCoverPoolImplementation_WhenImplementationHasNoCode_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidImplementation.selector);
        vm.prank(creator);
        factory.setCoverPoolImplementation(address(0xdead));
    }

    function test_setCoverPoolImplementation_WhenValid_UpdatesStorage() public {
        CoverPool newImplementation = new CoverPool();

        vm.expectEmit(true, true, true, true, address(factory));
        emit ICoverPoolFactory.CoverPoolImplementationSet(address(implementation), address(newImplementation));

        vm.prank(creator);
        factory.setCoverPoolImplementation(address(newImplementation));

        assertEq(factory.coverPoolImplementation(), address(newImplementation), "Implementation not updated");
    }

    function test_setPolicyManager_WhenCallerNotCreator_Reverts() public {
        address caller = makeAddr("notCreatorPolicy");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, creatorRole)
        );
        vm.prank(caller);
        factory.setPolicyManager(makeAddr("policy2"));
    }

    function test_setPolicyManager_WhenZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.setPolicyManager(address(0));
    }

    function test_setPolicyManager_WhenValid_UpdatesState() public {
        address newPolicyManager = makeAddr("policyManagerNew");

        vm.expectEmit(true, true, true, true, address(factory));
        emit ICoverPoolFactory.PolicyManagerSet(policyManager, newPolicyManager);

        vm.prank(creator);
        factory.setPolicyManager(newPolicyManager);

        assertEq(factory.policyManager(), newPolicyManager, "Policy manager not updatedConfig");
    }

    function test_createCoverPool_WhenPaused_Reverts() public {
        vm.prank(admin);
        factory.pause();

        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenValid_RegistersPool() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);

        vm.prank(creator);
        factory.createCoverPool(params);

        (address[] memory pools, ICoverPoolFactory.PoolConfig[] memory configs) = factory.listPools(0, 1);
        assertEq(pools.length, 1, "Expected single pool id");
        assertEq(configs.length, 1, "Expected single config");

        address pool = pools[0];
        assertEq(pool, configs[0].pool, "Pool mismatch");
        assertTrue(factory.isPoolRegistered(pool), "Resolve mismatch");

        ICoverPoolFactory.PoolConfig memory stored = factory.getPoolConfig(pool);
        _assertEqualConfig(stored, _expectedConfig(pool, params, true));
    }

    function test_createCoverPool_WhenQuoteSignerZero_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        params.quoteSigner = address(0);

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenPremiumTokenZero_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        params.premiumToken = address(0);

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenPayoutTokenZero_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        params.payoutToken = address(0);

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenFeeTooHigh_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        params.poolFeeBps = 3000;

        vm.expectRevert(ICoverPoolFactory.InvalidFeeBps.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_updatePoolConfig_WhenValid_UpdatesStorage() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        vm.prank(creator);
        factory.createCoverPool(params);

        (address[] memory pools,) = factory.listPools(0, 1);
        address pool = pools[0];

        ICoverPoolFactory.PoolConfig memory updatedConfig = ICoverPoolFactory.PoolConfig({
            pool: pool,
            curator: makeAddr("newCurator"),
            premiumToken: makeAddr("newPremium"),
            payoutToken: makeAddr("newPayout"),
            defaultSpecId: bytes32("newSpec"),
            poolFeeBps: 150,
            platformFeeBps: 175,
            active: true
        });

        vm.prank(creator);
        factory.updatePoolConfig(updatedConfig);

        _assertEqualConfig(factory.getPoolConfig(pool), updatedConfig);
        assertTrue(factory.isPoolRegistered(pool), "Resolve mismatch");
    }

    function test_updatePoolConfig_WhenPoolMissing_Reverts() public {
        address missingPool = makeAddr("missingPool");
        ICoverPoolFactory.PoolConfig memory updatedConfig =
            _expectedConfig(missingPool, _defaultCreateParams(true), true);

        vm.expectRevert(abi.encodeWithSelector(ICoverPoolFactory.PoolNotRegistered.selector, missingPool));
        vm.prank(creator);
        factory.updatePoolConfig(updatedConfig);
    }

    function test_updatePoolConfig_WhenActiveMismatch_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        vm.prank(creator);
        factory.createCoverPool(params);

        (address[] memory pools,) = factory.listPools(0, 1);
        address pool = pools[0];

        ICoverPoolFactory.PoolConfig memory updatedConfig = _expectedConfig(pool, params, false);

        vm.expectRevert(ICoverPoolFactory.PoolActiveStatusMismatch.selector);
        vm.prank(creator);
        factory.updatePoolConfig(updatedConfig);
    }

    function test_setPoolStatus_WhenValid_TogglesFlag() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        vm.prank(creator);
        factory.createCoverPool(params);

        (address[] memory pools,) = factory.listPools(0, 1);
        address pool = pools[0];

        vm.expectEmit(true, true, true, true, address(factory));
        emit ICoverPoolFactory.PoolStatusSet(pool, false);

        vm.prank(creator);
        factory.setPoolStatus(pool, false);

        assertFalse(factory.getPoolConfig(pool).active, "Active flag not updatedConfig");
    }

    function test_setPoolStatus_WhenPoolMissing_Reverts() public {
        address missingPool = makeAddr("missingPool");
        vm.expectRevert(abi.encodeWithSelector(ICoverPoolFactory.PoolNotRegistered.selector, missingPool));
        vm.prank(creator);
        factory.setPoolStatus(missingPool, false);
    }

    function test_setPoolStatus_WhenNoChange_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        vm.prank(creator);
        factory.createCoverPool(params);

        (address[] memory pools,) = factory.listPools(0, 1);
        address pool = pools[0];

        vm.expectRevert(ICoverPoolFactory.PoolStatusUnchanged.selector);
        vm.prank(creator);
        factory.setPoolStatus(pool, true);
    }

    function test_listPools_WhenMultiplePools_Paginates() public {
        for (uint256 i = 0; i < 3; ++i) {
            ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
            params.curator = makeAddr(string(abi.encodePacked("curator", vm.toString(i))));
            params.quoteSigner = makeAddr(string(abi.encodePacked("quoteSigner", vm.toString(i))));
            params.premiumToken = makeAddr(string(abi.encodePacked("premium", vm.toString(i))));
            params.payoutToken = makeAddr(string(abi.encodePacked("payout", vm.toString(i))));

            vm.prank(creator);
            factory.createCoverPool(params);
        }

        (address[] memory pools, ICoverPoolFactory.PoolConfig[] memory configs) = factory.listPools(0, 2);
        assertEq(pools.length, 2, "Unexpected page size");
        assertEq(configs.length, 2, "Config length mismatch");
        assertEq(pools[0], configs[0].pool, "Unexpected first pool");
        assertEq(pools[1], configs[1].pool, "Unexpected second pool");
    }

    function test_listPools_WhenLimitZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidLimit.selector);
        factory.listPools(0, 0);
    }

    function test_listPools_WhenOffsetPastEnd_ReturnsEmpty() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams(true);
        vm.prank(creator);
        factory.createCoverPool(params);

        (address[] memory pools, ICoverPoolFactory.PoolConfig[] memory configs) = factory.listPools(5, 2);
        assertEq(pools.length, 0, "Expected empty pool ids");
        assertEq(configs.length, 0, "Expected empty configs");
    }

    function test_getPoolConfig_WhenUnknown_Reverts() public {
        address missingPool = makeAddr("missingPool");
        vm.expectRevert(abi.encodeWithSelector(ICoverPoolFactory.PoolNotFound.selector, missingPool));
        factory.getPoolConfig(missingPool);
    }

    function test_isPoolRegistered_WhenUnknown_ReturnsFalse() public view {
        assertFalse(factory.isPoolRegistered(address(0x1234)));
    }

    function _defaultCreateParams(bool active)
        internal
        view
        returns (ICoverPoolFactory.CreateCoverPoolParams memory params)
    {
        params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: quoteSigner,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            defaultSpecId: bytes32("spec"),
            poolFeeBps: 100,
            platformFeeBps: 200,
            active: active
        });
    }

    function _expectedConfig(
        address pool,
        ICoverPoolFactory.CreateCoverPoolParams memory params,
        bool active
    )
        internal
        pure
        returns (ICoverPoolFactory.PoolConfig memory)
    {
        return ICoverPoolFactory.PoolConfig({
            pool: pool,
            curator: params.curator,
            premiumToken: params.premiumToken,
            payoutToken: params.payoutToken,
            defaultSpecId: params.defaultSpecId,
            poolFeeBps: params.poolFeeBps,
            platformFeeBps: params.platformFeeBps,
            active: active
        });
    }

    function _assertEqualConfig(
        ICoverPoolFactory.PoolConfig memory actual,
        ICoverPoolFactory.PoolConfig memory expected
    )
        internal
        pure
    {
        assertEq(actual.pool, expected.pool, "Pool mismatch");
        assertEq(actual.curator, expected.curator, "Curator mismatch");
        assertEq(actual.premiumToken, expected.premiumToken, "Premium token mismatch");
        assertEq(actual.payoutToken, expected.payoutToken, "Payout token mismatch");
        assertEq(actual.defaultSpecId, expected.defaultSpecId, "Spec mismatch");
        assertEq(actual.poolFeeBps, expected.poolFeeBps, "Pool fee mismatch");
        assertEq(actual.platformFeeBps, expected.platformFeeBps, "Platform fee mismatch");
        assertEq(actual.active, expected.active, "Active mismatch");
    }
}
