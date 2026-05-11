// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPoolFactory} from "../../src/CoverPoolFactory.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";

contract CoverPoolFactoryTest is Test {
    bytes32 internal constant ADMIN_ROLE = 0x00;
    uint16 internal constant DEFAULT_POOL_FEE = 100;

    address internal admin;
    address internal creator;
    address internal policyManager;
    address internal stakeManager;
    address internal specRegistry;
    address internal curator;
    address internal quoteSigner;
    address internal operator;

    CoverPoolFactory internal factory;
    CoverPool internal implementation;
    bytes32 internal creatorRole;
    Options internal opts;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/
    function setUp() public {
        admin = makeAddr("admin");
        creator = makeAddr("creator");
        curator = makeAddr("curator");
        quoteSigner = makeAddr("quoteSigner");
        operator = makeAddr("operator");

        vm.label(admin, "Admin");
        vm.label(creator, "Creator");
        vm.label(curator, "Curator");
        vm.label(quoteSigner, "QuoteSigner");
        vm.label(operator, "Operator");

        opts.unsafeSkipAllChecks = true;

        implementation = new CoverPool();

        policyManager = address(new CoverPool());
        stakeManager = address(new CoverPool());
        specRegistry = address(new CoverPool());

        vm.label(policyManager, "PolicyManager");
        vm.label(stakeManager, "StakeManager");
        vm.label(specRegistry, "SpecRegistry");

        address proxy = Upgrades.deployUUPSProxy(
            "CoverPoolFactory.sol:CoverPoolFactory",
            abi.encodeCall(
                CoverPoolFactory.initialize,
                (admin, creator, address(implementation), policyManager, stakeManager, specRegistry)
            ),
            opts
        );
        factory = CoverPoolFactory(proxy);

        bytes32 pauserRole = factory.PAUSER_ROLE();
        vm.prank(admin);
        factory.grantRole(pauserRole, admin);

        creatorRole = factory.CREATOR_ROLE();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/
    function test_initialize_WhenAdminZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        CoverPoolFactory freshFactory = CoverPoolFactory(address(new ERC1967Proxy(address(factoryImpl), "")));
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        freshFactory.initialize(address(0), creator, address(implementation), policyManager, stakeManager, specRegistry);
    }

    function test_initialize_WhenCreatorZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize,
                (admin, address(0), address(implementation), policyManager, stakeManager, specRegistry)
            )
        );
    }

    function test_initialize_WhenValid_GrantsRoles() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        address testAdmin = makeAddr("testAdmin");
        address testCreator = makeAddr("testCreator");

        address proxy = address(
            new ERC1967Proxy(
                address(factoryImpl),
                abi.encodeCall(
                    CoverPoolFactory.initialize,
                    (testAdmin, testCreator, address(implementation), policyManager, stakeManager, specRegistry)
                )
            )
        );
        CoverPoolFactory testFactory = CoverPoolFactory(proxy);

        assertTrue(testFactory.hasRole(ADMIN_ROLE, testAdmin), "Admin role not granted");
        assertTrue(testFactory.hasRole(testFactory.CREATOR_ROLE(), testCreator), "Creator role not granted");
        assertEq(testFactory.coverPoolImplementation(), address(implementation), "Implementation not set");
        assertEq(testFactory.policyManager(), policyManager, "PolicyManager not set");
        assertEq(testFactory.stakeManager(), stakeManager, "StakeManager not set");
        assertEq(testFactory.specRegistry(), specRegistry, "SpecRegistry not set");
    }

    function test_initialize_WhenImplementationZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize, (admin, creator, address(0), policyManager, stakeManager, specRegistry)
            )
        );
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize,
                (admin, creator, address(implementation), address(0), stakeManager, specRegistry)
            )
        );
    }

    function test_initialize_WhenStakeManagerZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize,
                (admin, creator, address(implementation), policyManager, address(0), specRegistry)
            )
        );
    }

    function test_initialize_WhenSpecRegistryZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize,
                (admin, creator, address(implementation), policyManager, stakeManager, address(0))
            )
        );
    }

    function test_initialize_WhenImplementationNoCode_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        address eoa = makeAddr("eoa");
        vm.expectRevert(ICoverPoolFactory.InvalidImplementation.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize, (admin, creator, eoa, policyManager, stakeManager, specRegistry)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                                  PAUSE
    //////////////////////////////////////////////////////////////*/
    function test_pause_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, creator, factory.PAUSER_ROLE()
            )
        );
        vm.prank(creator);
        factory.pause();
    }

    function test_pause_WhenCalledByAdmin_PausesFactory() public {
        vm.prank(admin);
        factory.pause();
        assertTrue(factory.paused(), "Factory not paused");
    }

    /*//////////////////////////////////////////////////////////////
                                 UNPAUSE
    //////////////////////////////////////////////////////////////*/
    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        factory.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, creator, factory.PAUSER_ROLE()
            )
        );
        vm.prank(creator);
        factory.unpause();
    }

    function test_unpause_WhenCalledByAdmin_ClearsPause() public {
        vm.prank(admin);
        factory.pause();
        assertTrue(factory.paused(), "Factory not paused");

        vm.prank(admin);
        factory.unpause();
        assertFalse(factory.paused(), "Factory still paused");
    }

    function test_pause_WhenAdminLacksPauserRole_Reverts() public {
        address adminNoPauser = makeAddr("adminNoPauser");
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        factory.grantRole(adminRole, adminNoPauser);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, adminNoPauser, factory.PAUSER_ROLE()
            )
        );
        vm.prank(adminNoPauser);
        factory.pause();
    }

    function test_pause_WhenCallerOnlyHasPauserRole_Succeeds() public {
        address pauserOnly = makeAddr("pauserOnly");
        bytes32 pauserRole = factory.PAUSER_ROLE();
        vm.prank(admin);
        factory.grantRole(pauserRole, pauserOnly);

        vm.prank(pauserOnly);
        factory.pause();
        assertTrue(factory.paused(), "Factory not paused");

        vm.prank(pauserOnly);
        factory.unpause();
        assertFalse(factory.paused(), "Factory still paused");
    }

    function test_pause_WhenRandomCaller_Reverts() public {
        address random = makeAddr("random");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, random, factory.PAUSER_ROLE()
            )
        );
        vm.prank(random);
        factory.pause();
    }

    /*//////////////////////////////////////////////////////////////
                            CREATE COVER POOL
    //////////////////////////////////////////////////////////////*/
    function test_createCoverPool_WhenCallerNotCreator_Reverts() public {
        address notCreator = makeAddr("notCreator");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, notCreator, creatorRole)
        );
        vm.prank(notCreator);
        factory.createCoverPool(_defaultCreateParams());
    }

    function test_createCoverPool_WhenPaused_Reverts() public {
        vm.prank(admin);
        factory.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(creator);
        factory.createCoverPool(_defaultCreateParams());
    }

    function test_createCoverPool_WhenCuratorZero_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        params.curator = address(0);

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenQuoteSignerZero_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        params.quoteSigner = address(0);

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenFeeTooHigh_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        params.poolFeeBps = 2001;

        vm.expectRevert(ICoverPool.InvalidFeeBps.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenValid_RegistersPool() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        address expected = _predictCoverPoolAddress(params, factory.coverPoolImplementation(), factory.policyManager());
        assertEq(factory.computeCoverPoolAddress(params), expected, "Prediction mismatch");

        vm.expectEmit(false, true, true, true, address(factory));
        emit ICoverPoolFactory.CoverPoolCreated(
            address(0), params.curator, params.quoteSigner, policyManager, params.poolFeeBps
        );

        vm.prank(creator);
        factory.createCoverPool(params);

        assertEq(factory.totalCoverPools(), 1, "Unexpected total pools");
        assertTrue(factory.coverPoolExists(factory.coverPoolAt(0)), "Pool not exists");
        assertEq(factory.coverPoolAt(0), expected, "Unexpected pool address");

        address[] memory pools = factory.getCoverPools(0, 1);
        assertEq(pools.length, 1, "Unexpected pool count");

        CoverPool deployed = CoverPool(pools[0]);
        assertEq(deployed.owner(), params.curator, "Curator not set");
        assertTrue(deployed.hasRole(deployed.QUOTE_SIGNER_ROLE(), params.quoteSigner), "Quote signer role missing");
        assertEq(deployed.poolFeeBps(), params.poolFeeBps, "Pool fee mismatch");
    }

    function test_createCoverPool_WhenValid_PoolAddedToInternalSet() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        address predicted = factory.computeCoverPoolAddress(params);

        vm.prank(creator);
        factory.createCoverPool(params);

        assertTrue(factory.coverPoolExists(predicted), "Pool must be present in registry after creation");
        assertEq(factory.totalCoverPools(), 1, "totalCoverPools must reflect the addition");
        assertEq(factory.coverPoolAt(0), predicted, "coverPoolAt(0) must equal the predicted address");
    }

    function test_createCoverPool_WhenPoolAddressAlreadyInRegistry_RevertsWithCoverPoolCreationFailure() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        address predicted = factory.computeCoverPoolAddress(params);

        uint256 poolsSlot = 4;
        bytes32 valuesLenSlot = bytes32(poolsSlot);
        bytes32 valuesDataSlot = keccak256(abi.encode(valuesLenSlot));
        bytes32 positionsMappingSlot = bytes32(poolsSlot + 1);
        bytes32 entry = bytes32(uint256(uint160(predicted)));
        bytes32 positionKeySlot = keccak256(abi.encode(entry, positionsMappingSlot));

        vm.store(address(factory), valuesLenSlot, bytes32(uint256(1)));
        vm.store(address(factory), valuesDataSlot, entry);
        vm.store(address(factory), positionKeySlot, bytes32(uint256(1)));

        assertTrue(factory.coverPoolExists(predicted), "Precondition: predicted address must appear registered");

        vm.expectRevert(ICoverPoolFactory.CoverPoolCreationFailure.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenParamsReused_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();

        vm.prank(creator);
        factory.createCoverPool(params);

        vm.expectRevert(Errors.FailedDeployment.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

    function test_createCoverPool_WhenSameCuratorCreateMultiplePools_Succeeds() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params1 = _defaultCreateParams();
        params1.poolFeeBps = 100;

        vm.prank(creator);
        factory.createCoverPool(params1);
        assertEq(factory.totalCoverPools(), 1, "First pool not created");

        ICoverPoolFactory.CreateCoverPoolParams memory params2 = _defaultCreateParams();
        params2.poolFeeBps = 200;

        vm.prank(creator);
        factory.createCoverPool(params2);
        assertEq(factory.totalCoverPools(), 2, "Second pool not created");

        CoverPool pool1 = CoverPool(factory.coverPoolAt(0));
        assertEq(pool1.poolFeeBps(), 100, "First pool fee mismatch");
        assertEq(pool1.owner(), params1.curator, "First pool curator mismatch");

        CoverPool pool2 = CoverPool(factory.coverPoolAt(1));
        assertEq(pool2.poolFeeBps(), 200, "Second pool fee mismatch");
        assertEq(pool2.owner(), params2.curator, "Second pool curator mismatch");
    }

    function test_createCoverPool_CuratorBecomesPoolOperator() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();

        uint256 poolCountBefore = factory.totalCoverPools();
        vm.prank(creator);
        factory.createCoverPool(params);

        address poolAddress = factory.coverPoolAt(poolCountBefore);
        CoverPool pool = CoverPool(poolAddress);

        assertEq(pool.owner(), params.curator, "Curator should be pool owner/operator");
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), params.curator), "Curator should have admin role");
    }

    function test_createCoverPool_StoresPolicyManagerReference() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();

        uint256 poolCountBefore = factory.totalCoverPools();
        vm.prank(creator);
        factory.createCoverPool(params);

        address poolAddress = factory.coverPoolAt(poolCountBefore);
        CoverPool pool = CoverPool(poolAddress);

        assertEq(pool.policyManager(), policyManager, "PolicyManager should be set correctly");
    }

    function test_createCoverPool_MultipleCuratorsCreateIsolatedPools() public {
        address curator1 = makeAddr("curator1");
        address curator2 = makeAddr("curator2");

        ICoverPoolFactory.CreateCoverPoolParams memory params1 = _defaultCreateParams();
        params1.curator = curator1;
        params1.quoteSigner = makeAddr("signer1");

        ICoverPoolFactory.CreateCoverPoolParams memory params2 = _defaultCreateParams();
        params2.curator = curator2;
        params2.quoteSigner = makeAddr("signer2");

        uint256 poolCountBefore1 = factory.totalCoverPools();
        vm.prank(creator);
        factory.createCoverPool(params1);
        address pool1 = factory.coverPoolAt(poolCountBefore1);

        uint256 poolCountBefore2 = factory.totalCoverPools();
        vm.prank(creator);
        factory.createCoverPool(params2);
        address pool2 = factory.coverPoolAt(poolCountBefore2);

        assertEq(CoverPool(pool1).owner(), curator1, "Curator1 should own pool1");
        assertEq(CoverPool(pool2).owner(), curator2, "Curator2 should own pool2");
        assertNotEq(pool1, pool2, "Pools should be distinct");

        vm.expectRevert();
        vm.prank(curator1);
        CoverPool(pool2).setPoolFeeBps(200);
    }

    function test_createCoverPool_WhenImplementationChanges_AllowsRedeployWithSameParams() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();

        address firstPrediction =
            _predictCoverPoolAddress(params, factory.coverPoolImplementation(), factory.policyManager());
        assertEq(factory.computeCoverPoolAddress(params), firstPrediction, "Prediction mismatch");

        vm.prank(creator);
        factory.createCoverPool(params);
        assertEq(factory.coverPoolAt(0), firstPrediction, "First deployment mismatch");

        CoverPool newImplementation = new CoverPool();
        vm.prank(creator);
        factory.setCoverPoolImplementation(address(newImplementation));

        address secondPrediction =
            _predictCoverPoolAddress(params, factory.coverPoolImplementation(), factory.policyManager());
        assertEq(factory.computeCoverPoolAddress(params), secondPrediction, "Prediction mismatch");
        assertNotEq(secondPrediction, firstPrediction, "Implementation change should affect prediction");

        vm.prank(creator);
        factory.createCoverPool(params);

        assertEq(factory.totalCoverPools(), 2, "Unexpected total pools after second deployment");
        assertEq(factory.coverPoolAt(1), secondPrediction, "Second deployment mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                      SET COVER POOL IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/
    function test_setCoverPoolImplementation_WhenCallerNotCreator_Reverts() public {
        address caller = makeAddr("notCreator");
        CoverPool newImplementation = new CoverPool();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, creatorRole)
        );
        vm.prank(caller);
        factory.setCoverPoolImplementation(address(newImplementation));
    }

    function test_setCoverPoolImplementation_WhenValid_UpdatesStorage() public {
        CoverPool newImplementation = new CoverPool();

        vm.expectEmit(true, true, true, true, address(factory));
        emit ICoverPoolFactory.CoverPoolImplementationSet(address(implementation), address(newImplementation));

        vm.prank(creator);
        factory.setCoverPoolImplementation(address(newImplementation));

        assertEq(factory.coverPoolImplementation(), address(newImplementation), "Implementation not updated");
    }

    function test_setCoverPoolImplementation_WhenNoCode_Reverts() public {
        address eoa = makeAddr("eoa");

        vm.expectRevert(ICoverPoolFactory.InvalidImplementation.selector);
        vm.prank(creator);
        factory.setCoverPoolImplementation(eoa);
    }

    function test_setCoverPoolImplementation_WhenZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.setCoverPoolImplementation(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                           SET POLICY MANAGER
    //////////////////////////////////////////////////////////////*/
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

        assertEq(factory.policyManager(), newPolicyManager, "Policy manager not updated");
    }

    /*//////////////////////////////////////////////////////////////
                           SET STAKE MANAGER
    //////////////////////////////////////////////////////////////*/
    function test_setStakeManager_WhenCallerNotCreator_Reverts() public {
        address caller = makeAddr("notCreator");
        address newStakeManager = makeAddr("newStakeManager");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, creatorRole)
        );
        vm.prank(caller);
        factory.setStakeManager(newStakeManager);
    }

    function test_setStakeManager_WhenZeroAddress_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.setStakeManager(address(0));
    }

    function test_setStakeManager_Success() public {
        address newStakeManager = address(new CoverPool());

        vm.expectEmit(true, true, false, false);
        emit ICoverPoolFactory.StakeManagerSet(stakeManager, newStakeManager);
        vm.prank(creator);
        factory.setStakeManager(newStakeManager);

        assertEq(factory.stakeManager(), newStakeManager, "StakeManager not updated");
    }

    /*//////////////////////////////////////////////////////////////
                          SET SPEC REGISTRY
    //////////////////////////////////////////////////////////////*/
    function test_setSpecRegistry_WhenCallerNotCreator_Reverts() public {
        address caller = makeAddr("notCreatorSpec");
        address newSpecRegistry = makeAddr("specRegistry2");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, creatorRole)
        );
        vm.prank(caller);
        factory.setSpecRegistry(newSpecRegistry);
    }

    function test_setSpecRegistry_WhenZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.setSpecRegistry(address(0));
    }

    function test_setSpecRegistry_WhenValid_UpdatesState() public {
        address newSpecRegistry = makeAddr("specRegistryNew");

        vm.expectEmit(true, true, true, true, address(factory));
        emit ICoverPoolFactory.SpecRegistrySet(specRegistry, newSpecRegistry);

        vm.prank(creator);
        factory.setSpecRegistry(newSpecRegistry);

        assertEq(factory.specRegistry(), newSpecRegistry, "SpecRegistry not updated");
    }

    /*//////////////////////////////////////////////////////////////
                          AUTHORIZE UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_authorizeUpgrade_WhenCallerNotAdmin_Reverts() public {
        address newImplementation = address(new CoverPoolFactory());

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, creator, ADMIN_ROLE)
        );
        vm.prank(creator);
        factory.upgradeToAndCall(newImplementation, "");
    }

    function test_authorizeUpgrade_WhenZeroAddress_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(admin);
        factory.upgradeToAndCall(address(0), "");
    }

    function test_authorizeUpgrade_WhenCalledByAdmin_Succeeds() public {
        CoverPoolFactory newImplementation = new CoverPoolFactory();

        vm.prank(admin);
        factory.upgradeToAndCall(address(newImplementation), "");

        assertEq(factory.coverPoolImplementation(), address(implementation), "Implementation should persist");
        assertEq(factory.policyManager(), policyManager, "Policy manager should persist");
    }

    /*//////////////////////////////////////////////////////////////
                           COVER POOL EXISTS
    //////////////////////////////////////////////////////////////*/
    function test_coverPoolExists_WhenUnknown_ReturnsFalse() public view {
        assertFalse(factory.coverPoolExists(address(0x1234)));
    }

    /*//////////////////////////////////////////////////////////////
                             COVER POOL AT
    //////////////////////////////////////////////////////////////*/
    function test_coverPoolAt_WhenOutOfBounds_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidLimit.selector);
        factory.coverPoolAt(0);
    }

    function test_coverPoolAt_WhenPoolsDeployed_ReturnsExpectedAddress() public {
        address pool = _createPool("primary");
        assertEq(factory.coverPoolAt(0), pool, "Pool address mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                           TOTAL COVER POOLS
    //////////////////////////////////////////////////////////////*/
    function test_totalCoverPools_WhenNone_ReturnsZero() public view {
        assertEq(factory.totalCoverPools(), 0, "Expected zero pools");
    }

    function test_totalCoverPools_WhenMultiplePools_Increments() public {
        for (uint256 i = 0; i < 3; ++i) {
            ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
            params.curator = makeAddr(string.concat("curator", vm.toString(i)));
            params.quoteSigner = makeAddr(string.concat("quoteSigner", vm.toString(i)));

            vm.prank(creator);
            factory.createCoverPool(params);
        }

        assertEq(factory.totalCoverPools(), 3, "Unexpected total pools");
    }

    /*//////////////////////////////////////////////////////////////
                            GET COVER POOLS
    //////////////////////////////////////////////////////////////*/
    function test_getCoverPools_WhenLimitZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidLimit.selector);
        factory.getCoverPools(0, 0);
    }

    function test_getCoverPools_WhenOffsetPastEnd_ReturnsEmpty() public view {
        assertEq(factory.getCoverPools(5, 1).length, 0, "Expected empty array");
    }

    function test_getCoverPools_WhenMultiplePools_Paginates() public {
        for (uint256 i = 0; i < 3; ++i) {
            ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
            params.curator = makeAddr(string.concat("curator", vm.toString(i)));
            params.quoteSigner = makeAddr(string.concat("quoteSigner", vm.toString(i)));

            vm.prank(creator);
            factory.createCoverPool(params);
        }

        address[] memory firstPage = factory.getCoverPools(0, 2);
        address[] memory secondPage = factory.getCoverPools(2, 2);

        assertEq(firstPage.length, 2, "Unexpected first page size");
        assertEq(secondPage.length, 1, "Unexpected second page size");
        assertNotEq(firstPage[0], firstPage[1], "Duplicate pool on first page");
        assertNotEq(firstPage[0], secondPage[0], "Overlap across pages");
    }

    function test_getCoverPools_WhenOffsetNonZero_ReturnsSlice() public {
        address first = _createPool("first");
        address second = _createPool("second");
        assertNotEq(first, second, "Pools should differ");

        address[] memory slice = factory.getCoverPools(1, 1);
        assertEq(slice.length, 1, "Unexpected slice length");
        assertEq(slice[0], second, "Unexpected pool returned");
    }

    function test_getCoverPools_WhenLimitExceedsRemaining_Truncates() public {
        _createPool("a");
        _createPool("b");
        _createPool("c");

        uint256 total = factory.totalCoverPools();
        address[] memory slice = factory.getCoverPools(1, 10);
        assertEq(slice.length, total - 1, "Slice should truncate to remaining pools");

        for (uint256 i = 0; i < slice.length; ++i) {
            assertEq(slice[i], factory.coverPoolAt(i + 1), "Unexpected pool order");
        }
    }

    /*//////////////////////////////////////////////////////////////
                       COMPUTE COVER POOL ADDRESS
    //////////////////////////////////////////////////////////////*/

    function test_computeCoverPoolAddress_PredictsDeployment() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        address expected = _predictCoverPoolAddress(params, factory.coverPoolImplementation(), factory.policyManager());
        assertEq(factory.computeCoverPoolAddress(params), expected, "Prediction mismatch");

        vm.prank(creator);
        factory.createCoverPool(params);

        assertEq(factory.coverPoolAt(0), expected, "Predicted address mismatch");
    }

    function test_computeCoverPoolAddress_WhenPolicyManagerChanges_UpdatesSalt() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        address initialPrediction =
            _predictCoverPoolAddress(params, factory.coverPoolImplementation(), factory.policyManager());
        assertEq(factory.computeCoverPoolAddress(params), initialPrediction, "Prediction mismatch");

        address newPolicyManager = makeAddr("policyManagerNewSalt");
        vm.prank(creator);
        factory.setPolicyManager(newPolicyManager);

        address updatedPrediction =
            _predictCoverPoolAddress(params, factory.coverPoolImplementation(), factory.policyManager());
        assertEq(factory.computeCoverPoolAddress(params), updatedPrediction, "Prediction mismatch");
        assertNotEq(updatedPrediction, initialPrediction, "Expected salt to incorporate policy manager");

        vm.prank(creator);
        factory.createCoverPool(params);

        assertEq(factory.coverPoolAt(0), updatedPrediction, "Deployment should use updated prediction");
        CoverPool deployed = CoverPool(factory.coverPoolAt(0));
        assertEq(deployed.policyManager(), newPolicyManager, "Updated policy manager not set");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _predictCoverPoolAddress(
        ICoverPoolFactory.CreateCoverPoolParams memory params,
        address implementationAddress,
        address policyManagerAddress
    )
        internal
        view
        returns (address)
    {
        bytes32 salt = _computeSalt(params, policyManagerAddress);
        return Clones.predictDeterministicAddress(implementationAddress, salt, address(factory));
    }

    function _computeSalt(
        ICoverPoolFactory.CreateCoverPoolParams memory params,
        address policyManagerAddress
    )
        internal
        pure
        returns (bytes32)
    {
        return EfficientHashLib.hash(
            uint256(uint160(params.curator)),
            uint256(uint160(policyManagerAddress)),
            uint256(uint160(params.quoteSigner)),
            uint256(params.poolFeeBps)
        );
    }

    function _defaultCreateParams() internal view returns (ICoverPoolFactory.CreateCoverPoolParams memory params) {
        params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator, quoteSigner: quoteSigner, poolFeeBps: DEFAULT_POOL_FEE
        });
    }

    function _createPool(string memory label) internal returns (address pool) {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        params.curator = makeAddr(string.concat("curator_", label));
        params.quoteSigner = makeAddr(string.concat("signer_", label));

        vm.prank(creator);
        factory.createCoverPool(params);

        pool = factory.coverPoolAt(factory.totalCoverPools() - 1);
    }
}
