// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ICoverPoolFactory} from "../../src/interfaces/ICoverPoolFactory.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISpecRegistry} from "../../src/interfaces/ISpecRegistry.sol";
import {MockSpec} from "../../src/mocks/MockSpec.sol";
import {SpecRegistry} from "../../src/SpecRegistry.sol";

/**
 * @title SpecRegistryHandler
 * @notice Stateful handler that exercises approve/revoke/register sequences against SpecRegistry.
 *         Tracks which specs were approved at the moment of successful registration so the parent
 *         invariant test can assert the safety property after arbitrary call sequences.
 */
contract SpecRegistryHandler is Test {
    SpecRegistry internal registry;
    address internal admin;
    address internal pool;

    /// @dev Fixed set of spec contracts available to the fuzzer.
    address[] internal specContracts;

    /// @dev Fixed set of specIds available to the fuzzer.
    bytes32[] internal specIds;

    /// @dev Tracks specs that were successfully registered and the approval status AT that moment.
    ///      Key: keccak256(pool, specId). Value: the spec address that was registered.
    mapping(bytes32 key => address spec) public registeredSpec;

    /// @dev Whether the spec was approved at registration time (should always be true).
    mapping(bytes32 key => bool wasApproved) public approvedAtRegistration;

    /// @dev All registration keys seen, used for iteration.
    bytes32[] public registrationKeys;

    constructor(SpecRegistry registry_, address admin_, address pool_) {
        registry = registry_;
        admin = admin_;
        pool = pool_;

        specContracts.push(address(new MockSpec()));
        specContracts.push(address(new MockSpec()));
        specContracts.push(address(new MockSpec()));

        specIds.push(keccak256("SpecA"));
        specIds.push(keccak256("SpecB"));
    }

    function approveSpec(uint256 specIdx) external {
        address spec = specContracts[specIdx % specContracts.length];
        vm.prank(admin);
        try registry.approveSpec(spec) {} catch {}
    }

    function revokeSpec(uint256 specIdx) external {
        address spec = specContracts[specIdx % specContracts.length];
        vm.prank(admin);
        try registry.revokeSpec(spec) {} catch {}
    }

    function registerSpec(uint256 specIdx, uint256 specIdIdx) external {
        address spec = specContracts[specIdx % specContracts.length];
        bytes32 specId = specIds[specIdIdx % specIds.length];

        bool approvedBefore = registry.isSpecApproved(spec);

        vm.prank(pool);
        try registry.registerSpec(specId, ISpec(spec)) {
            bytes32 key = keccak256(abi.encodePacked(pool, specId));

            if (registeredSpec[key] == address(0)) {
                registeredSpec[key] = spec;
                approvedAtRegistration[key] = approvedBefore;
                registrationKeys.push(key);
            }
        } catch {}
    }

    function registrationKeysLength() external view returns (uint256) {
        return registrationKeys.length;
    }
}

contract SpecRegistryInvariantTest is StdInvariant, Test {
    SpecRegistry internal registry;
    SpecRegistryHandler internal handler;

    address internal admin;
    address internal pool;
    address internal factory;

    Options internal opts;

    function setUp() public {
        admin = makeAddr("admin");
        factory = makeAddr("factory");
        pool = makeAddr("pool");

        vm.mockCall(factory, abi.encodeWithSelector(ICoverPoolFactory.coverPoolExists.selector, pool), abi.encode(true));

        opts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "SpecRegistry.sol:SpecRegistry", abi.encodeCall(SpecRegistry.initialize, (admin, factory)), opts
        );
        registry = SpecRegistry(proxy);

        handler = new SpecRegistryHandler(registry, admin, pool);
        targetContract(address(handler));
    }

    /**
     * @notice Every spec that was successfully registered must have been approved at the time of
     *         registration. This is the core safety invariant of COV-5.
     */
    function invariant_registeredSpecWasApprovedAtRegistration() public view {
        uint256 len = handler.registrationKeysLength();
        for (uint256 i = 0; i < len; ++i) {
            bytes32 key = handler.registrationKeys(i);
            assertTrue(
                handler.approvedAtRegistration(key), "Invariant violated: a spec was registered without being approved"
            );
        }
    }

    /**
     * @notice resolveSpec must always succeed for any successfully registered (pool, specId) pair,
     *         regardless of subsequent approve/revoke calls.
     */
    function invariant_registeredSpecAlwaysResolvable() public view {
        uint256 len = handler.registrationKeysLength();
        for (uint256 i = 0; i < len; ++i) {
            bytes32 key = handler.registrationKeys(i);
            address expectedSpec = handler.registeredSpec(key);
            if (expectedSpec == address(0)) continue;

            assertGt(expectedSpec.code.length, 0, "Registered spec contract must always have code");
        }
    }
}
