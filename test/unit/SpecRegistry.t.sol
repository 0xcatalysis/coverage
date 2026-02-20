// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISpecRegistry} from "../../src/interfaces/ISpecRegistry.sol";
import {MockSpec} from "../../src/mocks/MockSpec.sol";
import {SpecRegistry} from "../../src/SpecRegistry.sol";

contract SpecRegistryTest is Test {
    bytes32 internal constant ADMIN_ROLE = 0x00;

    SpecRegistry internal registry;
    address internal admin;
    address internal factory;
    address internal pool1;
    address internal pool2;
    address internal spec1;
    address internal spec2;
    bytes32 internal specId1;
    bytes32 internal specId2;
    Options internal opts;

    event SpecRegistered(address indexed pool, bytes32 indexed specId, address indexed spec);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        admin = makeAddr("admin");
        factory = makeAddr("factory");
        pool1 = makeAddr("pool1");
        pool2 = makeAddr("pool2");
        spec1 = address(new MockSpec());
        spec2 = address(new MockSpec());

        vm.label(admin, "Admin");
        vm.label(factory, "Factory");
        vm.label(pool1, "Pool1");
        vm.label(pool2, "Pool2");
        vm.label(spec1, "Spec1");
        vm.label(spec2, "Spec2");

        // Mock the factory to return true for pool1 and pool2
        vm.mockCall(
            factory, abi.encodeWithSelector(ICoverPoolFactory.coverPoolExists.selector, pool1), abi.encode(true)
        );
        vm.mockCall(
            factory, abi.encodeWithSelector(ICoverPoolFactory.coverPoolExists.selector, pool2), abi.encode(true)
        );

        opts.unsafeSkipAllChecks = true;

        address proxy = Upgrades.deployUUPSProxy(
            "SpecRegistry.sol:SpecRegistry", abi.encodeCall(SpecRegistry.initialize, (admin, factory)), opts
        );
        registry = SpecRegistry(proxy);

        specId1 = keccak256("MorphoSpec");
        specId2 = keccak256("MapleSpec");
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        SpecRegistry registryImpl = new SpecRegistry();
        vm.expectRevert(ISpecRegistry.ZeroAddress.selector);
        new ERC1967Proxy(address(registryImpl), abi.encodeCall(SpecRegistry.initialize, (address(0), factory)));
    }

    function test_initialize_WhenFactoryZero_Succeeds() public {
        SpecRegistry registryImpl = new SpecRegistry();
        address proxy = address(
            new ERC1967Proxy(address(registryImpl), abi.encodeCall(SpecRegistry.initialize, (admin, address(0))))
        );
        SpecRegistry testRegistry = SpecRegistry(proxy);

        assertTrue(testRegistry.hasRole(ADMIN_ROLE, admin), "Admin role not granted");
        assertEq(address(testRegistry.coverPoolFactory()), address(0), "Factory should remain unset");
    }

    function test_initialize_WhenValid_GrantsAdminRole() public {
        SpecRegistry registryImpl = new SpecRegistry();
        address testAdmin = makeAddr("testAdmin");
        address testFactory = makeAddr("testFactory");

        address proxy = address(
            new ERC1967Proxy(address(registryImpl), abi.encodeCall(SpecRegistry.initialize, (testAdmin, testFactory)))
        );
        SpecRegistry testRegistry = SpecRegistry(proxy);

        assertTrue(testRegistry.hasRole(ADMIN_ROLE, testAdmin), "Admin role not granted");
        assertEq(address(testRegistry.coverPoolFactory()), testFactory, "Factory not set correctly");
    }

    /*//////////////////////////////////////////////////////////////
                        SET COVER POOL FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_setCoverPoolFactory_WhenCallerNotAdmin_Reverts() public {
        SpecRegistry registryImpl = new SpecRegistry();
        address proxy = address(
            new ERC1967Proxy(address(registryImpl), abi.encodeCall(SpecRegistry.initialize, (admin, address(0))))
        );
        SpecRegistry emptyRegistry = SpecRegistry(proxy);

        address notAdmin = makeAddr("notAdmin");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notAdmin, ADMIN_ROLE)
        );
        vm.prank(notAdmin);
        emptyRegistry.setCoverPoolFactory(factory);
    }

    function test_setCoverPoolFactory_WhenZeroAddress_Reverts() public {
        SpecRegistry registryImpl = new SpecRegistry();
        address proxy = address(
            new ERC1967Proxy(address(registryImpl), abi.encodeCall(SpecRegistry.initialize, (admin, address(0))))
        );
        SpecRegistry emptyRegistry = SpecRegistry(proxy);

        vm.expectRevert(ISpecRegistry.ZeroAddress.selector);
        vm.prank(admin);
        emptyRegistry.setCoverPoolFactory(address(0));
    }

    function test_setCoverPoolFactory_WhenAlreadySet_Reverts() public {
        vm.expectRevert("CoverPoolFactory already set");
        vm.prank(admin);
        registry.setCoverPoolFactory(makeAddr("anotherFactory"));
    }

    function test_setCoverPoolFactory_WhenValid_SetsFactory() public {
        SpecRegistry registryImpl = new SpecRegistry();
        address proxy = address(
            new ERC1967Proxy(address(registryImpl), abi.encodeCall(SpecRegistry.initialize, (admin, address(0))))
        );
        SpecRegistry emptyRegistry = SpecRegistry(proxy);
        assertEq(address(emptyRegistry.coverPoolFactory()), address(0), "Factory should be unset initially");

        vm.expectEmit(true, true, true, true);
        emit ISpecRegistry.CoverPoolFactorySet(factory);

        vm.prank(admin);
        emptyRegistry.setCoverPoolFactory(factory);

        assertEq(address(emptyRegistry.coverPoolFactory()), factory, "Factory not set correctly");
    }

    /*//////////////////////////////////////////////////////////////
                                  PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_WhenCallerNotAdmin_Reverts() public {
        address notAdmin = makeAddr("notAdmin");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notAdmin, ADMIN_ROLE)
        );
        vm.prank(notAdmin);
        registry.pause();
    }

    function test_pause_WhenCalledByAdmin_PausesRegistry() public {
        vm.prank(admin);
        registry.pause();
        assertTrue(registry.paused(), "Registry not paused");
    }

    /*//////////////////////////////////////////////////////////////
                                 UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        registry.pause();

        address notAdmin = makeAddr("notAdmin");
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notAdmin, ADMIN_ROLE)
        );
        vm.prank(notAdmin);
        registry.unpause();
    }

    function test_unpause_WhenCalledByAdmin_ClearsPause() public {
        vm.prank(admin);
        registry.pause();
        assertTrue(registry.paused(), "Registry not paused");

        vm.prank(admin);
        registry.unpause();
        assertFalse(registry.paused(), "Registry still paused");
    }

    /*//////////////////////////////////////////////////////////////
                           REGISTER SPEC
    //////////////////////////////////////////////////////////////*/

    function test_registerSpec_WhenPaused_Reverts() public {
        vm.prank(admin);
        registry.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));
    }

    function test_registerSpec_WhenZeroSpecId_Reverts() public {
        vm.expectRevert(ISpecRegistry.InvalidSpecId.selector);
        vm.prank(pool1);
        registry.registerSpec(bytes32(0), ISpec(spec1));
    }

    function test_registerSpec_WhenZeroSpec_Reverts() public {
        vm.expectRevert(ISpecRegistry.InvalidSpec.selector);
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(address(0)));
    }

    function test_registerSpec_WhenSpecHasNoCode_Reverts() public {
        address eoa = makeAddr("eoaSpec");
        vm.expectRevert(ISpecRegistry.InvalidSpec.selector);
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(eoa));
    }

    function test_registerSpec_WhenFactoryNotSet_Reverts() public {
        SpecRegistry registryImpl = new SpecRegistry();
        address proxy = address(
            new ERC1967Proxy(address(registryImpl), abi.encodeCall(SpecRegistry.initialize, (admin, address(0))))
        );
        SpecRegistry emptyRegistry = SpecRegistry(proxy);

        vm.expectRevert(ISpecRegistry.ZeroAddress.selector);
        vm.prank(pool1);
        emptyRegistry.registerSpec(specId1, ISpec(spec1));
    }

    function test_registerSpec_WhenInvalidPool_Reverts() public {
        address invalidPool = makeAddr("invalidPool");
        vm.mockCall(
            factory, abi.encodeWithSelector(ICoverPoolFactory.coverPoolExists.selector, invalidPool), abi.encode(false)
        );

        vm.expectRevert(ISpecRegistry.InvalidCoverPool.selector);
        vm.prank(invalidPool);
        registry.registerSpec(specId1, ISpec(spec1));
    }

    function test_registerSpec_WhenValid_StoresMapping() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit SpecRegistered(pool1, specId1, spec1);

        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        ISpec resolved = registry.resolveSpec(pool1, specId1);
        assertEq(address(resolved), spec1, "Spec not registered correctly");
    }

    function test_registerSpec_WhenSameSpecReregistered_Idempotent() public {
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        ISpec resolved = registry.resolveSpec(pool1, specId1);
        assertEq(address(resolved), spec1, "Spec should remain unchanged");
    }

    function test_registerSpec_WhenDifferentSpecReregistered_Reverts() public {
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        vm.expectRevert(
            abi.encodeWithSelector(ISpecRegistry.SpecAlreadyRegistered.selector, pool1, specId1, spec1, spec2)
        );
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec2));
    }

    function test_registerSpec_WhenMultiplePoolsSameSpecId_IsolatesPerPool() public {
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        vm.prank(pool2);
        registry.registerSpec(specId1, ISpec(spec2));

        ISpec resolved1 = registry.resolveSpec(pool1, specId1);
        ISpec resolved2 = registry.resolveSpec(pool2, specId1);

        assertEq(address(resolved1), spec1, "Pool1 spec mismatch");
        assertEq(address(resolved2), spec2, "Pool2 spec mismatch");
    }

    function test_registerSpec_WhenMultipleSpecIdsSamePool_StoresBoth() public {
        vm.startPrank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));
        registry.registerSpec(specId2, ISpec(spec2));
        vm.stopPrank();

        ISpec resolved1 = registry.resolveSpec(pool1, specId1);
        ISpec resolved2 = registry.resolveSpec(pool1, specId2);

        assertEq(address(resolved1), spec1, "SpecId1 mismatch");
        assertEq(address(resolved2), spec2, "SpecId2 mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                           RESOLVE SPEC
    //////////////////////////////////////////////////////////////*/

    function test_resolveSpec_WhenNotRegistered_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ISpecRegistry.SpecNotRegistered.selector, pool1, specId1));
        registry.resolveSpec(pool1, specId1);
    }

    function test_resolveSpec_WhenRegistered_ReturnsSpec() public {
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        ISpec resolved = registry.resolveSpec(pool1, specId1);
        assertEq(address(resolved), spec1, "Resolved spec mismatch");
    }

    function test_resolveSpec_WhenDifferentPool_Reverts() public {
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        vm.expectRevert(abi.encodeWithSelector(ISpecRegistry.SpecNotRegistered.selector, pool2, specId1));
        registry.resolveSpec(pool2, specId1);
    }

    function test_resolveSpec_WhenDifferentSpecId_Reverts() public {
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        vm.expectRevert(abi.encodeWithSelector(ISpecRegistry.SpecNotRegistered.selector, pool1, specId2));
        registry.resolveSpec(pool1, specId2);
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_authorizeUpgrade_WhenCallerNotAdmin_Reverts() public {
        address newImplementation = address(new SpecRegistry());
        address notAdmin = makeAddr("notAdmin");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notAdmin, ADMIN_ROLE)
        );
        vm.prank(notAdmin);
        registry.upgradeToAndCall(newImplementation, "");
    }

    function test_authorizeUpgrade_WhenZeroAddress_Reverts() public {
        vm.expectRevert(ISpecRegistry.ZeroAddress.selector);
        vm.prank(admin);
        registry.upgradeToAndCall(address(0), "");
    }

    function test_authorizeUpgrade_WhenCalledByAdmin_Succeeds() public {
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        SpecRegistry newImplementation = new SpecRegistry();

        vm.prank(admin);
        registry.upgradeToAndCall(address(newImplementation), "");

        ISpec resolved = registry.resolveSpec(pool1, specId1);
        assertEq(address(resolved), spec1, "Spec data should persist after upgrade");
        assertTrue(registry.hasRole(ADMIN_ROLE, admin), "Admin role should persist after upgrade");
    }

    function test_authorizeUpgrade_WhenCalledByAdmin_PreservesAllData() public {
        vm.prank(pool1);
        registry.registerSpec(specId1, ISpec(spec1));

        vm.prank(pool1);
        registry.registerSpec(specId2, ISpec(spec2));

        vm.prank(pool2);
        registry.registerSpec(specId1, ISpec(spec2));

        SpecRegistry newImplementation = new SpecRegistry();

        vm.prank(admin);
        registry.upgradeToAndCall(address(newImplementation), "");

        assertEq(address(registry.resolveSpec(pool1, specId1)), spec1, "Pool1-SpecId1 mismatch");
        assertEq(address(registry.resolveSpec(pool1, specId2)), spec2, "Pool1-SpecId2 mismatch");
        assertEq(address(registry.resolveSpec(pool2, specId1)), spec2, "Pool2-SpecId1 mismatch");
    }
}
