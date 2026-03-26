// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISpecRegistry} from "../../src/interfaces/ISpecRegistry.sol";
import {MockSpec} from "../../src/mocks/MockSpec.sol";
import {SpecRegistry} from "../../src/SpecRegistry.sol";

contract SpecRegistryFuzzTest is Test {
    bytes32 internal constant ADMIN_ROLE = 0x00;

    SpecRegistry internal registry;
    address internal admin;
    address internal factory;
    address internal pool;
    address internal spec1;
    address internal spec2;
    Options internal opts;

    function setUp() public {
        admin = makeAddr("admin");
        factory = makeAddr("factory");
        pool = makeAddr("pool");
        spec1 = address(new MockSpec());
        spec2 = address(new MockSpec());

        vm.mockCall(factory, abi.encodeWithSelector(ICoverPoolFactory.coverPoolExists.selector, pool), abi.encode(true));

        opts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "SpecRegistry.sol:SpecRegistry", abi.encodeCall(SpecRegistry.initialize, (admin, factory)), opts
        );
        registry = SpecRegistry(proxy);
    }

    function testFuzz_approveSpec_OnlyAdmin(address caller) public {
        vm.assume(caller != admin);

        vm.expectRevert();
        vm.prank(caller);
        registry.approveSpec(spec1);
    }

    function testFuzz_revokeSpec_OnlyAdmin(address caller) public {
        vm.assume(caller != admin);

        vm.expectRevert();
        vm.prank(caller);
        registry.revokeSpec(spec1);
    }

    function testFuzz_approveRevoke_TogglesApproval(uint8 rounds) public {
        rounds = uint8(bound(rounds, 1, 10));

        bool expectedApproval = false;
        for (uint256 i = 0; i < rounds; ++i) {
            vm.startPrank(admin);
            if (i % 2 == 0) {
                registry.approveSpec(spec1);
                expectedApproval = true;
            } else {
                registry.revokeSpec(spec1);
                expectedApproval = false;
            }
            vm.stopPrank();
        }

        assertEq(registry.isSpecApproved(spec1), expectedApproval, "Approval state mismatch after toggle sequence");
    }

    function testFuzz_registerSpec_WhenNotApproved_Reverts(bytes32 specId) public {
        vm.assume(specId != bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(ISpecRegistry.SpecNotApproved.selector, spec1));
        vm.prank(pool);
        registry.registerSpec(specId, ISpec(spec1));
    }

    function testFuzz_registerSpec_WhenApproved_Succeeds(bytes32 specId) public {
        vm.assume(specId != bytes32(0));

        vm.prank(admin);
        registry.approveSpec(spec1);

        vm.prank(pool);
        registry.registerSpec(specId, ISpec(spec1));

        assertEq(address(registry.resolveSpec(pool, specId)), spec1, "Registered spec mismatch");
    }

    function testFuzz_registerSpec_AfterRevoke_Reverts(bytes32 specId1, bytes32 specId2) public {
        vm.assume(specId1 != bytes32(0));
        vm.assume(specId2 != bytes32(0));
        vm.assume(specId1 != specId2);

        vm.startPrank(admin);
        registry.approveSpec(spec1);
        vm.stopPrank();

        vm.prank(pool);
        registry.registerSpec(specId1, ISpec(spec1));

        vm.prank(admin);
        registry.revokeSpec(spec1);

        vm.expectRevert(abi.encodeWithSelector(ISpecRegistry.SpecNotApproved.selector, spec1));
        vm.prank(pool);
        registry.registerSpec(specId2, ISpec(spec1));
    }

    function testFuzz_resolveSpec_UnaffectedByRevoke(bytes32 specId) public {
        vm.assume(specId != bytes32(0));

        vm.prank(admin);
        registry.approveSpec(spec1);

        vm.prank(pool);
        registry.registerSpec(specId, ISpec(spec1));

        vm.prank(admin);
        registry.revokeSpec(spec1);

        assertEq(address(registry.resolveSpec(pool, specId)), spec1, "resolveSpec must work after revoke");
    }
}
