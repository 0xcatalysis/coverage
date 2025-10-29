// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPoolFactory} from "../../src/CoverPoolFactory.sol";
import {CoverPoolRegistry} from "../../src/CoverPoolRegistry.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {ICoverPoolRegistry} from "../../src/interfaces/ICoverPoolRegistry.sol";

contract CoverPoolFactoryTest is Test {
    CoverPoolFactory internal factory;
    CoverPool internal implementation;
    CoverPoolRegistry internal registry;

    address internal admin;
    address internal registrar;
    address internal policyManager;
    address internal curator;
    address internal quoteSigner;
    address internal premiumToken;
    address internal payoutToken;
    bytes32 internal registrarRole;
    bytes32 internal constant ADMIN_ROLE = 0x00;
    Options internal opts;

    function setUp() public {
        admin = makeAddr("admin");
        registrar = makeAddr("registrar");
        policyManager = makeAddr("policyManager");
        curator = makeAddr("curator");
        quoteSigner = makeAddr("quoteSigner");
        premiumToken = makeAddr("premiumToken");
        payoutToken = makeAddr("payoutToken");

        vm.label(admin, "Admin");
        vm.label(registrar, "Registrar");
        vm.label(policyManager, "PolicyManager");
        vm.label(curator, "Curator");
        vm.label(quoteSigner, "QuoteSigner");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");

        opts.unsafeSkipAllChecks = true;

        implementation = new CoverPool();

        address registryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolRegistry.sol:CoverPoolRegistry",
            abi.encodeCall(CoverPoolRegistry.initialize, (admin, registrar)),
            opts
        );
        registry = CoverPoolRegistry(registryProxy);

        address factoryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolFactory.sol:CoverPoolFactory",
            abi.encodeCall(
                CoverPoolFactory.initialize, (address(this), address(implementation), address(registry), policyManager)
            ),
            opts
        );
        factory = CoverPoolFactory(factoryProxy);

        registrarRole = registry.REGISTRAR_ROLE();

        vm.prank(admin);
        registry.grantRole(registrarRole, address(factory));
    }

    function test_initialize_WhenImplementationZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(CoverPoolFactory.initialize, (address(this), address(0), address(registry), policyManager))
        );
    }

    function test_initialize_WhenAdminZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize, (address(0), address(implementation), address(registry), policyManager)
            )
        );
    }

    function test_initialize_WhenRegistryZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize, (address(this), address(implementation), address(0), policyManager)
            )
        );
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize, (address(this), address(implementation), address(registry), address(0))
            )
        );
    }

    function test_setCoverPoolImplementation_WhenCallerNotOwner_Reverts() public {
        address caller = makeAddr("notOwner");
        CoverPool newImplementation = new CoverPool();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ADMIN_ROLE)
        );
        vm.prank(caller);
        factory.setCoverPoolImplementation(address(newImplementation));
    }

    function test_setCoverPoolImplementation_WhenImplementationHasNoCode_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidImplementation.selector);
        factory.setCoverPoolImplementation(address(0xdead));
    }

    function test_setCoverPoolImplementation_WhenValid_UpdatesStorage() public {
        CoverPool newImplementation = new CoverPool();

        vm.expectEmit(true, true, true, true, address(factory));
        emit ICoverPoolFactory.CoverPoolImplementationSet(address(implementation), address(newImplementation));

        factory.setCoverPoolImplementation(address(newImplementation));

        assertEq(factory.coverPoolImplementation(), address(newImplementation), "Implementation not updated");
    }

    function test_setCoverPoolRegistry_WhenCallerNotOwner_Reverts() public {
        address caller = makeAddr("registryNotOwner");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ADMIN_ROLE)
        );
        vm.prank(caller);
        factory.setCoverPoolRegistry(makeAddr("registry"));
    }

    function test_setCoverPoolRegistry_WhenZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        factory.setCoverPoolRegistry(address(0));
    }

    function test_setCoverPoolRegistry_WhenValid_UpdatesStorage() public {
        Options memory localOpts;
        localOpts.unsafeSkipAllChecks = true;
        address otherRegistryProxy = Upgrades.deployUUPSProxy(
            "CoverPoolRegistry.sol:CoverPoolRegistry",
            abi.encodeCall(CoverPoolRegistry.initialize, (admin, registrar)),
            localOpts
        );

        vm.expectEmit(true, true, true, true, address(factory));
        emit ICoverPoolFactory.CoverPoolRegistrySet(address(registry), otherRegistryProxy);

        factory.setCoverPoolRegistry(otherRegistryProxy);

        assertEq(factory.coverPoolRegistry(), otherRegistryProxy, "Registry not updated");
    }

    function test_setPolicyManager_WhenCallerNotOwner_Reverts() public {
        address caller = makeAddr("policyManagerNotOwner");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ADMIN_ROLE)
        );
        vm.prank(caller);
        factory.setPolicyManager(makeAddr("newPolicyManager"));
    }

    function test_setPolicyManager_WhenZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        factory.setPolicyManager(address(0));
    }

    function test_setPolicyManager_WhenValid_UpdatesStorage() public {
        address newPolicyManager = makeAddr("newPolicyManager");

        vm.expectEmit(true, true, true, true, address(factory));
        emit ICoverPoolFactory.PolicyManagerSet(policyManager, newPolicyManager);

        factory.setPolicyManager(newPolicyManager);

        assertEq(factory.policyManager(), newPolicyManager, "Policy manager not updated");
    }

    function test_createCoverPool_WhenCalledByOwner_DeploysRegistersAndInitializes() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: quoteSigner,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            defaultSpecId: keccak256("SPEC"),
            poolFeeBps: 500,
            platformFeeBps: 200,
            active: true
        });

        vm.expectEmit(true, false, true, true, address(factory));
        emit ICoverPoolFactory.CoverPoolCreated(1, address(0), params.curator, params.quoteSigner, policyManager);

        (address poolAddress, uint256 poolId) = factory.createCoverPool(params);

        assertEq(poolId, 1, "Pool id mismatch");
        assertTrue(poolAddress != address(0), "Pool address zero");
        assertTrue(poolAddress != address(implementation), "Pool address equals implementation");

        CoverPool pool = CoverPool(poolAddress);
        assertEq(pool.poolId(), poolId, "CoverPool stored pool id mismatch");
        assertEq(pool.owner(), params.curator, "CoverPool owner mismatch");

        bytes32 adminRole = pool.DEFAULT_ADMIN_ROLE();
        bytes32 policyManagerRole = pool.POLICY_MANAGER_ROLE();
        bytes32 quoteSignerRole = pool.QUOTE_SIGNER_ROLE();

        assertTrue(pool.hasRole(adminRole, params.curator), "Curator lacks admin role");
        assertTrue(pool.hasRole(policyManagerRole, policyManager), "Policy manager role missing");
        assertTrue(pool.hasRole(quoteSignerRole, params.quoteSigner), "Quote signer role missing");

        uint256 resolvedPoolId = registry.resolvePool(poolAddress);
        assertEq(resolvedPoolId, poolId, "Registry resolution mismatch");

        ICoverPoolRegistry.PoolConfig memory config = registry.getPoolConfig(poolId);
        _assertPoolConfigEquals(config, params, poolAddress);
    }

    function test_createCoverPool_WhenCalledTwice_IncrementsPoolId() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: quoteSigner,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            defaultSpecId: keccak256("SPEC"),
            poolFeeBps: 500,
            platformFeeBps: 200,
            active: true
        });

        factory.createCoverPool(params);

        params.curator = makeAddr("curator2");
        params.quoteSigner = makeAddr("quoteSigner2");

        vm.expectEmit(true, false, true, true, address(factory));
        emit ICoverPoolFactory.CoverPoolCreated(2, address(0), params.curator, params.quoteSigner, policyManager);

        (address poolAddress, uint256 poolId) = factory.createCoverPool(params);

        assertEq(poolId, 2, "Second pool id mismatch");
        assertEq(registry.resolvePool(poolAddress), poolId, "Registry resolution mismatch on second pool");
    }

    function test_createCoverPool_WhenCallerNotOwner_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: quoteSigner,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            defaultSpecId: bytes32(0),
            poolFeeBps: 0,
            platformFeeBps: 0,
            active: true
        });

        address caller = makeAddr("notOwner");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, ADMIN_ROLE)
        );
        vm.prank(caller);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenCuratorZero_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: address(0),
            quoteSigner: quoteSigner,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            defaultSpecId: bytes32(0),
            poolFeeBps: 0,
            platformFeeBps: 0,
            active: true
        });

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenQuoteSignerZero_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: address(0),
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            defaultSpecId: bytes32(0),
            poolFeeBps: 0,
            platformFeeBps: 0,
            active: true
        });

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenPremiumTokenZero_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: quoteSigner,
            premiumToken: address(0),
            payoutToken: payoutToken,
            defaultSpecId: bytes32(0),
            poolFeeBps: 0,
            platformFeeBps: 0,
            active: true
        });

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenFactoryLacksRegistrarRole_Reverts() public {
        vm.startPrank(admin);
        registry.revokeRole(registrarRole, address(factory));
        vm.stopPrank();

        ICoverPoolFactory.CreateCoverPoolParams memory params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator,
            quoteSigner: quoteSigner,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            defaultSpecId: bytes32(0),
            poolFeeBps: 0,
            platformFeeBps: 0,
            active: true
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(factory), registrarRole
            )
        );
        factory.createCoverPool(params);
    }

    function _assertPoolConfigEquals(
        ICoverPoolRegistry.PoolConfig memory config,
        ICoverPoolFactory.CreateCoverPoolParams memory params,
        address poolAddress
    )
        private
        pure
    {
        assertEq(config.pool, poolAddress, "Config pool mismatch");
        assertEq(config.curator, params.curator, "Config curator mismatch");
        assertEq(config.premiumToken, params.premiumToken, "Config premium token mismatch");
        assertEq(config.payoutToken, params.payoutToken, "Config payout token mismatch");
        assertEq(config.defaultSpecId, params.defaultSpecId, "Config spec id mismatch");
        assertEq(config.poolFeeBps, params.poolFeeBps, "Config pool fee mismatch");
        assertEq(config.platformFeeBps, params.platformFeeBps, "Config platform fee mismatch");
        assertEq(config.active, params.active, "Config active mismatch");
    }
}
