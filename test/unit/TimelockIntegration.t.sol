// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";

import {ClaimManager} from "../../src/ClaimManager.sol";
import {PolicyManager} from "../../src/PolicyManager.sol";
import {PremiumManager} from "../../src/PremiumManager.sol";
import {SpecRegistry} from "../../src/SpecRegistry.sol";

contract TimelockIntegrationTest is Test {
    uint256 internal constant MIN_DELAY = 2 days;

    address internal multisig;
    address internal deployer;

    TimelockController internal timelock;
    ClaimManager internal claimManager;
    PolicyManager internal policyManager;
    PremiumManager internal premiumManager;
    SpecRegistry internal specRegistry;

    bytes32 internal constant DEFAULT_ADMIN_ROLE = bytes32(0);

    function setUp() public {
        vm.warp(1_000_000);

        multisig = makeAddr("multisig");
        deployer = makeAddr("deployer");

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        Options memory opts;
        opts.unsafeSkipAllChecks = true;

        vm.startPrank(deployer);

        address pmProxy = Upgrades.deployUUPSProxy(
            "PolicyManager.sol",
            abi.encodeCall(
                PolicyManager.initialize, (deployer, address(1), deployer, deployer, address(1), new address[](0))
            ),
            opts
        );
        policyManager = PolicyManager(pmProxy);

        address prProxy = Upgrades.deployUUPSProxy(
            "PremiumManager.sol", abi.encodeCall(PremiumManager.initialize, (deployer, address(1), deployer, 500)), opts
        );
        premiumManager = PremiumManager(prProxy);

        address srProxy = Upgrades.deployUUPSProxy(
            "SpecRegistry.sol", abi.encodeCall(SpecRegistry.initialize, (deployer, address(0))), opts
        );
        specRegistry = SpecRegistry(srProxy);

        address cmProxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(
                ClaimManager.initialize,
                (deployer, address(specRegistry), address(1), address(1), address(policyManager))
            ),
            opts
        );
        claimManager = ClaimManager(payable(cmProxy));

        IAccessControl(address(policyManager)).grantRole(DEFAULT_ADMIN_ROLE, address(timelock));
        IAccessControl(address(premiumManager)).grantRole(DEFAULT_ADMIN_ROLE, address(timelock));
        IAccessControl(address(specRegistry)).grantRole(DEFAULT_ADMIN_ROLE, address(timelock));
        IAccessControl(address(claimManager)).grantRole(DEFAULT_ADMIN_ROLE, address(timelock));

        bytes32 pauserRole = policyManager.PAUSER_ROLE();
        IAccessControl(address(policyManager)).grantRole(pauserRole, address(timelock));
        IAccessControl(address(premiumManager)).grantRole(pauserRole, address(timelock));
        IAccessControl(address(specRegistry)).grantRole(pauserRole, address(timelock));
        IAccessControl(address(claimManager)).grantRole(pauserRole, address(timelock));

        IAccessControl(address(policyManager)).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        IAccessControl(address(premiumManager)).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        IAccessControl(address(specRegistry)).revokeRole(DEFAULT_ADMIN_ROLE, deployer);
        IAccessControl(address(claimManager)).revokeRole(DEFAULT_ADMIN_ROLE, deployer);

        vm.stopPrank();
    }

    function test_timelockHasAdminRoleOnAllContracts() public view {
        assertTrue(IAccessControl(address(policyManager)).hasRole(DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(IAccessControl(address(premiumManager)).hasRole(DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(IAccessControl(address(specRegistry)).hasRole(DEFAULT_ADMIN_ROLE, address(timelock)));
        assertTrue(IAccessControl(address(claimManager)).hasRole(DEFAULT_ADMIN_ROLE, address(timelock)));
    }

    function test_deployerHasNoRoles() public view {
        assertFalse(IAccessControl(address(policyManager)).hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(IAccessControl(address(premiumManager)).hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(IAccessControl(address(specRegistry)).hasRole(DEFAULT_ADMIN_ROLE, deployer));
        assertFalse(IAccessControl(address(claimManager)).hasRole(DEFAULT_ADMIN_ROLE, deployer));
    }

    function test_multisigHasTimelockRoles() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), multisig));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), multisig));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), multisig));
    }

    function test_multisigHasNoDirectAdminRole() public view {
        assertFalse(IAccessControl(address(policyManager)).hasRole(DEFAULT_ADMIN_ROLE, multisig));
        assertFalse(IAccessControl(address(premiumManager)).hasRole(DEFAULT_ADMIN_ROLE, multisig));
    }

    function test_directPauseReverts() public {
        vm.prank(multisig);
        vm.expectRevert();
        policyManager.pause();
    }

    function test_directSetterReverts() public {
        vm.prank(multisig);
        vm.expectRevert();
        premiumManager.setPlatformTreasury(address(0xBEEF));
    }

    function test_timelockPause() public {
        bytes memory data = abi.encodeCall(PolicyManager.pause, ());

        vm.prank(multisig);
        timelock.schedule(address(policyManager), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(policyManager), 0, data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(multisig);
        timelock.execute(address(policyManager), 0, data, bytes32(0), bytes32(0));

        assertTrue(policyManager.paused());
    }

    function test_timelockSetPlatformTreasury() public {
        address newTreasury = makeAddr("newTreasury");
        bytes memory data = abi.encodeCall(PremiumManager.setPlatformTreasury, (newTreasury));

        vm.prank(multisig);
        timelock.schedule(address(premiumManager), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(multisig);
        timelock.execute(address(premiumManager), 0, data, bytes32(0), bytes32(0));

        assertEq(premiumManager.platformTreasury(), newTreasury);
    }

    function test_cancelledOperationCannotExecute() public {
        bytes memory data = abi.encodeCall(PolicyManager.pause, ());
        bytes32 id = timelock.hashOperation(address(policyManager), 0, data, bytes32(0), bytes32(0));

        vm.prank(multisig);
        timelock.schedule(address(policyManager), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        vm.prank(multisig);
        timelock.cancel(id);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(policyManager), 0, data, bytes32(0), bytes32(0));

        assertFalse(policyManager.paused());
    }

    function test_prematureExecutionReverts() public {
        bytes memory data = abi.encodeCall(PolicyManager.pause, ());

        vm.prank(multisig);
        timelock.schedule(address(policyManager), 0, data, bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY - 1);

        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(policyManager), 0, data, bytes32(0), bytes32(0));
    }

    function test_upgradeViaTimelock() public {
        address oldImpl = Upgrades.getImplementationAddress(address(policyManager));

        PolicyManager newImpl = new PolicyManager();

        bytes memory upgradeData = abi.encodeCall(policyManager.upgradeToAndCall, (address(newImpl), ""));

        vm.prank(multisig);
        timelock.schedule(address(policyManager), 0, upgradeData, bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(multisig);
        timelock.execute(address(policyManager), 0, upgradeData, bytes32(0), bytes32(0));

        address currentImpl = Upgrades.getImplementationAddress(address(policyManager));
        assertEq(currentImpl, address(newImpl));
        assertTrue(currentImpl != oldImpl);
    }

    function test_nonProposerCannotSchedule() public {
        address attacker = makeAddr("attacker");
        bytes memory data = abi.encodeCall(PolicyManager.pause, ());

        vm.prank(attacker);
        vm.expectRevert();
        timelock.schedule(address(policyManager), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
    }

    function test_timelockBatchOperation() public {
        address[] memory targets = new address[](2);
        targets[0] = address(policyManager);
        targets[1] = address(premiumManager);

        uint256[] memory values = new uint256[](2);

        bytes[] memory payloads = new bytes[](2);
        payloads[0] = abi.encodeCall(PolicyManager.pause, ());
        payloads[1] = abi.encodeCall(PremiumManager.pause, ());

        vm.prank(multisig);
        timelock.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        vm.prank(multisig);
        timelock.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertTrue(policyManager.paused());
        assertTrue(premiumManager.paused());
    }
}
