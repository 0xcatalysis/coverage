// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {MockSpecRegistry} from "../../src/mocks/MockSpecRegistry.sol";
import {MockSpec} from "../../src/mocks/MockSpec.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISpecRegistry} from "../../src/interfaces/ISpecRegistry.sol";

contract MockSpecRegistryTest is Test {
    MockSpecRegistry internal registry;
    MockSpec internal spec;
    address internal owner;
    address internal pool;

    function setUp() public {
        owner = address(this);
        pool = makeAddr("pool");
        spec = new MockSpec();
        registry = new MockSpecRegistry(address(spec));
    }

    /*//////////////////////////////////////////////////////////////
                           PAUSE FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    function test_pause_WhenCalledByOwner_PausesRegistry() public {
        assertFalse(registry.paused(), "Should not be paused initially");

        registry.pause();

        assertTrue(registry.paused(), "Should be paused after pause()");
    }

    function test_pause_WhenCalledByNonOwner_Reverts() public {
        vm.expectRevert(MockSpecRegistry.NotOwner.selector);
        vm.prank(pool);
        registry.pause();
    }

    function test_unpause_WhenCalledByOwner_UnpausesRegistry() public {
        registry.pause();
        assertTrue(registry.paused(), "Should be paused");

        registry.unpause();

        assertFalse(registry.paused(), "Should not be paused after unpause()");
    }

    function test_unpause_WhenCalledByNonOwner_Reverts() public {
        registry.pause();

        vm.expectRevert(MockSpecRegistry.NotOwner.selector);
        vm.prank(pool);
        registry.unpause();
    }

    function test_registerSpec_WhenPaused_Reverts() public {
        bytes32 specId = keccak256("TEST_SPEC");
        MockSpec newSpec = new MockSpec();

        registry.pause();

        vm.expectRevert(MockSpecRegistry.EnforcedPause.selector);
        vm.prank(pool);
        registry.registerSpec(specId, ISpec(address(newSpec)));
    }

    function test_registerSpec_WhenNotPaused_Succeeds() public {
        bytes32 specId = keccak256("TEST_SPEC");
        MockSpec newSpec = new MockSpec();

        assertFalse(registry.paused(), "Should not be paused");

        vm.expectEmit(true, true, true, true, address(registry));
        emit ISpecRegistry.SpecRegistered(pool, specId, address(newSpec));

        vm.prank(pool);
        registry.registerSpec(specId, ISpec(address(newSpec)));

        assertEq(address(registry.resolveSpec(pool, specId)), address(newSpec), "Spec should be registered");
    }

    function test_registerSpec_WhenUnpausedAfterPause_Succeeds() public {
        bytes32 specId = keccak256("TEST_SPEC");
        MockSpec newSpec = new MockSpec();

        registry.pause();
        registry.unpause();

        assertFalse(registry.paused(), "Should not be paused after unpause");

        vm.expectEmit(true, true, true, true, address(registry));
        emit ISpecRegistry.SpecRegistered(pool, specId, address(newSpec));

        vm.prank(pool);
        registry.registerSpec(specId, ISpec(address(newSpec)));

        assertEq(address(registry.resolveSpec(pool, specId)), address(newSpec), "Spec should be registered");
    }

    function test_registerSpecForPool_WhenPaused_Reverts() public {
        bytes32 specId = keccak256("TEST_SPEC");
        MockSpec newSpec = new MockSpec();

        registry.pause();

        vm.expectRevert(MockSpecRegistry.EnforcedPause.selector);
        registry.registerSpecForPool(pool, specId, address(newSpec));
    }

    function test_registerSpecForPool_WhenNotPaused_Succeeds() public {
        bytes32 specId = keccak256("TEST_SPEC");
        MockSpec newSpec = new MockSpec();

        assertFalse(registry.paused(), "Should not be paused");

        vm.expectEmit(true, true, true, true, address(registry));
        emit ISpecRegistry.SpecRegistered(pool, specId, address(newSpec));

        registry.registerSpecForPool(pool, specId, address(newSpec));

        assertEq(address(registry.resolveSpec(pool, specId)), address(newSpec), "Spec should be registered");
    }

    function test_resolveSpec_WhenPaused_Succeeds() public {
        bytes32 specId = keccak256("TEST_SPEC");
        MockSpec newSpec = new MockSpec();

        registry.registerSpecForPool(pool, specId, address(newSpec));

        registry.pause();

        // resolveSpec is a view function and should work even when paused
        assertEq(address(registry.resolveSpec(pool, specId)), address(newSpec), "Should resolve spec when paused");
    }
}
