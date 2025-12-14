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
import {IStakeManager} from "../../src/interfaces/IStakeManager.sol";

contract CoverPoolFactoryTest is Test {
    bytes32 internal constant ADMIN_ROLE = 0x00;
    uint16 internal constant DEFAULT_POOL_FEE = 100;

    address internal admin;
    address internal creator;
    address internal policyManager;
    address internal stakeManager;
    address internal curator;
    address internal quoteSigner;

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
        policyManager = makeAddr("policyManager");
        stakeManager = makeAddr("stakeManager");
        curator = makeAddr("curator");
        quoteSigner = makeAddr("quoteSigner");

        vm.label(admin, "Admin");
        vm.label(creator, "Creator");
        vm.label(policyManager, "PolicyManager");
        vm.label(stakeManager, "StakeManager");
        vm.label(curator, "Curator");
        vm.label(quoteSigner, "QuoteSigner");

        opts.unsafeSkipAllChecks = true;

        implementation = new CoverPool();

        address proxy = Upgrades.deployUUPSProxy(
            "CoverPoolFactory.sol:CoverPoolFactory",
            abi.encodeCall(
                CoverPoolFactory.initialize, (admin, creator, address(implementation), policyManager, stakeManager)
            ),
            opts
        );
        factory = CoverPoolFactory(proxy);

        creatorRole = factory.CREATOR_ROLE();
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/
    function test_initialize_WhenImplementationZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(CoverPoolFactory.initialize, (admin, creator, address(0), policyManager, stakeManager))
        );
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize, (admin, creator, address(implementation), address(0), stakeManager)
            )
        );
    }

    function test_initialize_WhenStakeManagerZero_Reverts() public {
        CoverPoolFactory factoryImpl = new CoverPoolFactory();
        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        new ERC1967Proxy(
            address(factoryImpl),
            abi.encodeCall(
                CoverPoolFactory.initialize, (admin, creator, address(implementation), policyManager, address(0))
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                              CONFIGURATION
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

        assertEq(factory.policyManager(), newPolicyManager, "Policy manager not updated");
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSING
    //////////////////////////////////////////////////////////////*/
    function test_pause_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, creator, ADMIN_ROLE)
        );
        vm.prank(creator);
        factory.pause();
    }

    function test_pause_WhenCalledByAdmin_PausesFactory() public {
        vm.prank(admin);
        factory.pause();
        assertTrue(factory.paused(), "Factory not paused");
    }

    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        factory.pause();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, creator, ADMIN_ROLE)
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

    /*//////////////////////////////////////////////////////////////
                               POOL CREATION
    //////////////////////////////////////////////////////////////*/
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

        assertEq(factory.coverTotalPools(), 1, "Unexpected total pools");
        assertTrue(factory.coverPoolExists(factory.coverPoolAt(0)), "Pool not exists");
        assertEq(factory.coverPoolAt(0), expected, "Unexpected pool address");

        address[] memory pools = factory.getCoverPools(0, 1);
        assertEq(pools.length, 1, "Unexpected pool count");

        CoverPool deployed = CoverPool(pools[0]);
        assertEq(deployed.owner(), params.curator, "Curator not set");
        assertTrue(deployed.hasRole(deployed.POLICY_MANAGER_ROLE(), policyManager), "Policy manager role missing");
        assertTrue(deployed.hasRole(deployed.QUOTE_SIGNER_ROLE(), params.quoteSigner), "Quote signer role missing");
        assertEq(deployed.poolFeeBps(), params.poolFeeBps, "Pool fee mismatch");
    }

    function test_createCoverPool_WhenParamsReused_Reverts() public {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        vm.prank(creator);
        factory.createCoverPool(params);

        vm.expectRevert(Errors.FailedDeployment.selector);
        vm.prank(creator);
        factory.createCoverPool(params);
    }

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
        assertTrue(deployed.hasRole(deployed.POLICY_MANAGER_ROLE(), newPolicyManager), "Updated policy manager not set");
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

        assertEq(factory.coverTotalPools(), 2, "Unexpected total pools after second deployment");
        assertEq(factory.coverPoolAt(1), secondPrediction, "Second deployment mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/
    function test_totalPools_WhenMultiplePools_Increments() public {
        for (uint256 i = 0; i < 3; ++i) {
            ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
            params.curator = makeAddr(string.concat("curator", vm.toString(i)));
            params.quoteSigner = makeAddr(string.concat("quoteSigner", vm.toString(i)));

            vm.prank(creator);
            factory.createCoverPool(params);
        }

        assertEq(factory.coverTotalPools(), 3, "Unexpected total pools");
    }

    function test_poolAt_WhenOutOfBounds_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidLimit.selector);
        factory.coverPoolAt(0);
    }

    function test_getPools_WhenLimitZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidLimit.selector);
        factory.getCoverPools(0, 0);
    }

    function test_getPools_WhenOffsetPastEnd_ReturnsEmpty() public view {
        assertEq(factory.getCoverPools(5, 1).length, 0, "Expected empty array");
    }

    function test_getPools_WhenMultiplePools_Paginates() public {
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

    function test_poolExists_WhenUnknown_ReturnsFalse() public view {
        assertFalse(factory.coverPoolExists(address(0x1234)));
    }

    function test_poolAt_WhenPoolsDeployed_ReturnsExpectedAddress() public {
        address pool = _createPool("primary");
        assertEq(factory.coverPoolAt(0), pool, "Pool address mismatch");
    }

    function test_totalPools_WhenNone_ReturnsZero() public view {
        assertEq(factory.coverTotalPools(), 0, "Expected zero pools");
    }

    function test_getPools_WhenOffsetNonZero_ReturnsSlice() public {
        address first = _createPool("first");
        address second = _createPool("second");
        assertNotEq(first, second, "Pools should differ");

        address[] memory slice = factory.getCoverPools(1, 1);
        assertEq(slice.length, 1, "Unexpected slice length");
        assertEq(slice[0], second, "Unexpected pool returned");
    }

    function test_getPools_WhenLimitExceedsRemaining_Truncates() public {
        _createPool("a");
        _createPool("b");
        _createPool("c");

        uint256 total = factory.coverTotalPools();
        address[] memory slice = factory.getCoverPools(1, 10);
        assertEq(slice.length, total - 1, "Slice should truncate to remaining pools");

        for (uint256 i = 0; i < slice.length; ++i) {
            assertEq(slice[i], factory.coverPoolAt(i + 1), "Unexpected pool order");
        }
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
            uint256(uint160(params.quoteSigner)),
            uint256(params.poolFeeBps),
            uint256(uint160(policyManagerAddress))
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

        pool = factory.coverPoolAt(factory.coverTotalPools() - 1);
    }

    /*//////////////////////////////////////////////////////////////
                        STAKE MANAGER CONFIGURATION
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
        address newStakeManager = makeAddr("newStakeManager");

        vm.expectEmit(true, true, false, false);
        emit ICoverPoolFactory.StakeManagerSet(stakeManager, newStakeManager);
        vm.prank(creator);
        factory.setStakeManager(newStakeManager);

        assertEq(factory.stakeManager(), newStakeManager, "StakeManager not updated");
    }

    /*//////////////////////////////////////////////////////////////
                        COMMITTEE REGISTRATION
    //////////////////////////////////////////////////////////////*/
    function test_registerPoolCommittee_WhenCallerNotCreator_Reverts() public {
        address pool = _createPool("test");
        uint96 committeeId = 1;
        address testOperator = makeAddr("testOperator");
        address caller = makeAddr("notCreator");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, creatorRole)
        );
        vm.prank(caller);
        factory.registerPoolCommittee(pool, committeeId, testOperator);
    }

    function test_registerPoolCommittee_WhenPoolNotRegistered_Reverts() public {
        address fakePool = makeAddr("fakePool");
        uint96 committeeId = 1;
        address testOperator = makeAddr("testOperator");

        vm.expectRevert(ICoverPoolFactory.PoolNotRegistered.selector);
        vm.prank(creator);
        factory.registerPoolCommittee(fakePool, committeeId, testOperator);
    }

    function test_registerPoolCommittee_WhenOperatorZero_Reverts() public {
        address pool = _createPool("test");
        uint96 committeeId = 1;

        vm.expectRevert(ICoverPoolFactory.ZeroAddress.selector);
        vm.prank(creator);
        factory.registerPoolCommittee(pool, committeeId, address(0));
    }

    function test_registerPoolCommittee_Success() public {
        address pool = _createPool("test");
        uint96 committeeId = 1;
        address testOperator = makeAddr("testOperator");

        // Mock the StakeManager call
        vm.mockCall(
            stakeManager,
            abi.encodeWithSelector(IStakeManager.addOperatorToCommittee.selector, testOperator, committeeId),
            ""
        );

        vm.expectEmit(true, true, true, false);
        emit ICoverPoolFactory.PoolCommitteeRegistered(pool, committeeId, testOperator);
        vm.prank(creator);
        factory.registerPoolCommittee(pool, committeeId, testOperator);
    }

    function test_unregisterPoolCommittee_WhenCallerNotCreator_Reverts() public {
        address pool = _createPool("test");
        uint96 committeeId = 1;
        address testOperator = makeAddr("testOperator");
        address caller = makeAddr("notCreator");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, caller, creatorRole)
        );
        vm.prank(caller);
        factory.unregisterPoolCommittee(pool, committeeId, testOperator);
    }

    function test_unregisterPoolCommittee_WhenPoolNotRegistered_Reverts() public {
        address fakePool = makeAddr("fakePool");
        uint96 committeeId = 1;
        address testOperator = makeAddr("testOperator");

        vm.expectRevert(ICoverPoolFactory.PoolNotRegistered.selector);
        vm.prank(creator);
        factory.unregisterPoolCommittee(fakePool, committeeId, testOperator);
    }

    function test_unregisterPoolCommittee_Success() public {
        address pool = _createPool("test");
        uint96 committeeId = 1;
        address testOperator = makeAddr("testOperator");

        // Mock the StakeManager call
        vm.mockCall(
            stakeManager,
            abi.encodeWithSelector(IStakeManager.removeOperatorFromCommittee.selector, testOperator, committeeId),
            ""
        );

        vm.expectEmit(true, true, true, false);
        emit ICoverPoolFactory.PoolCommitteeUnregistered(pool, committeeId, testOperator);
        vm.prank(creator);
        factory.unregisterPoolCommittee(pool, committeeId, testOperator);
    }
}
