// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISpecRegistry} from "../../src/interfaces/ISpecRegistry.sol";
import {SpecRegistry} from "../../src/SpecRegistry.sol";

contract SpecRegistryTest is Test {
    SpecRegistry internal registry;

    address internal pool1;
    address internal pool2;
    address internal spec1;
    address internal spec2;
    bytes32 internal specId1;
    bytes32 internal specId2;

    event SpecRegistered(address indexed pool, bytes32 indexed specId, address indexed spec);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        registry = new SpecRegistry();

        pool1 = makeAddr("pool1");
        pool2 = makeAddr("pool2");
        spec1 = makeAddr("spec1");
        spec2 = makeAddr("spec2");

        specId1 = keccak256("MorphoSpec");
        specId2 = keccak256("MapleSpec");
    }

    /*//////////////////////////////////////////////////////////////
                           REGISTER SPEC
    //////////////////////////////////////////////////////////////*/

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
}
