// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {CoverPoolFactory} from "../../src/CoverPoolFactory.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";

contract CoverPoolFactoryTest is Test {
    CoverPoolFactory internal factory;
    CoverPool internal implementation;

    address internal admin;
    address internal creator;
    address internal policyManager;
    address internal curator;
    address internal quoteSigner;

    bytes32 internal constant ADMIN_ROLE = 0x00;
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant DEFAULT_SPEC_ID = bytes32("spec");
    uint16 internal constant DEFAULT_POOL_FEE = 100;

    bytes32 internal creatorRole;

    Options internal opts;

    function setUp() public {
        admin = makeAddr("admin");
        creator = makeAddr("creator");
        policyManager = makeAddr("policyManager");
        curator = makeAddr("curator");
        quoteSigner = makeAddr("quoteSigner");

        vm.label(admin, "Admin");
        vm.label(creator, "Creator");
        vm.label(policyManager, "PolicyManager");
        vm.label(curator, "Curator");
        vm.label(quoteSigner, "QuoteSigner");

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

        assertEq(factory.policyManager(), newPolicyManager, "Policy manager not updated");
    }

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

        vm.expectEmit(false, true, true, true, address(factory));
        emit ICoverPoolFactory.CoverPoolCreated(
            address(0), params.curator, params.quoteSigner, policyManager, params.defaultSpecId, params.poolFeeBps
        );

        vm.prank(creator);
        factory.createCoverPool(params);

        assertEq(factory.totalPools(), 1, "Unexpected total pools");
        assertTrue(factory.poolExists(factory.poolAt(0)), "Pool not exists");

        address[] memory pools = factory.getPools(0, 1);
        assertEq(pools.length, 1, "Unexpected pool count");

        CoverPool deployed = CoverPool(pools[0]);
        assertEq(deployed.owner(), params.curator, "Curator not set");
        assertTrue(deployed.hasRole(deployed.POLICY_MANAGER_ROLE(), policyManager), "Policy manager role missing");
        assertTrue(deployed.hasRole(deployed.QUOTE_SIGNER_ROLE(), params.quoteSigner), "Quote signer role missing");
        assertEq(deployed.defaultSpecId(), params.defaultSpecId, "Default spec mismatch");
        assertEq(deployed.poolFeeBps(), params.poolFeeBps, "Pool fee mismatch");
    }

    function test_totalPools_WhenMultiplePools_Increments() public {
        for (uint256 i = 0; i < 3; ++i) {
            ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
            params.curator = makeAddr(string.concat("curator", vm.toString(i)));
            params.quoteSigner = makeAddr(string.concat("quoteSigner", vm.toString(i)));

            vm.prank(creator);
            factory.createCoverPool(params);
        }

        assertEq(factory.totalPools(), 3, "Unexpected total pools");
    }

    function test_poolAt_WhenOutOfBounds_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidLimit.selector);
        factory.poolAt(0);
    }

    function test_getPools_WhenLimitZero_Reverts() public {
        vm.expectRevert(ICoverPoolFactory.InvalidLimit.selector);
        factory.getPools(0, 0);
    }

    function test_getPools_WhenOffsetPastEnd_ReturnsEmpty() public view {
        assertEq(factory.getPools(5, 1).length, 0, "Expected empty array");
    }

    function test_getPools_WhenMultiplePools_Paginates() public {
        for (uint256 i = 0; i < 3; ++i) {
            ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
            params.curator = makeAddr(string.concat("curator", vm.toString(i)));
            params.quoteSigner = makeAddr(string.concat("quoteSigner", vm.toString(i)));

            vm.prank(creator);
            factory.createCoverPool(params);
        }

        address[] memory firstPage = factory.getPools(0, 2);
        address[] memory secondPage = factory.getPools(2, 2);

        assertEq(firstPage.length, 2, "Unexpected first page size");
        assertEq(secondPage.length, 1, "Unexpected second page size");
        assertNotEq(firstPage[0], firstPage[1], "Duplicate pool on first page");
        assertNotEq(firstPage[0], secondPage[0], "Overlap across pages");
    }

    function test_poolExists_WhenUnknown_ReturnsFalse() public view {
        assertFalse(factory.poolExists(address(0x1234)));
    }

    function test_poolAt_WhenPoolsDeployed_ReturnsExpectedAddress() public {
        address pool = _createPool("primary");
        assertEq(factory.poolAt(0), pool, "Pool address mismatch");
    }

    function test_totalPools_WhenNone_ReturnsZero() public view {
        assertEq(factory.totalPools(), 0, "Expected zero pools");
    }

    function test_getPools_WhenOffsetNonZero_ReturnsSlice() public {
        address first = _createPool("first");
        address second = _createPool("second");
        assertNotEq(first, second, "Pools should differ");

        address[] memory slice = factory.getPools(1, 1);
        assertEq(slice.length, 1, "Unexpected slice length");
        assertEq(slice[0], second, "Unexpected pool returned");
    }

    function test_getPools_WhenLimitExceedsRemaining_Truncates() public {
        _createPool("a");
        _createPool("b");
        _createPool("c");

        uint256 total = factory.totalPools();
        address[] memory slice = factory.getPools(1, 10);
        assertEq(slice.length, total - 1, "Slice should truncate to remaining pools");

        for (uint256 i = 0; i < slice.length; ++i) {
            assertEq(slice[i], factory.poolAt(i + 1), "Unexpected pool order");
        }
    }

    function _defaultCreateParams() internal view returns (ICoverPoolFactory.CreateCoverPoolParams memory params) {
        params = ICoverPoolFactory.CreateCoverPoolParams({
            curator: curator, quoteSigner: quoteSigner, defaultSpecId: DEFAULT_SPEC_ID, poolFeeBps: DEFAULT_POOL_FEE
        });
    }

    function _createPool(string memory label) internal returns (address pool) {
        ICoverPoolFactory.CreateCoverPoolParams memory params = _defaultCreateParams();
        params.curator = makeAddr(string.concat("curator_", label));
        params.quoteSigner = makeAddr(string.concat("signer_", label));

        vm.prank(creator);
        factory.createCoverPool(params);

        pool = factory.poolAt(factory.totalPools() - 1);
    }
}
