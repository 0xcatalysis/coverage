// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {PremiumReserve} from "../../src/PremiumReserve.sol";
import {IPremiumReserve} from "../../src/interfaces/IPremiumReserve.sol";

contract PremiumReserveTest is Test {
    bytes internal constant COVERAGE_POLICY_TASK = "COVERAGE_POLICY";
    uint256 internal constant POLICY_ID = 1;
    uint256 internal constant RESTAKER_PREMIUM = 1000 ether;
    uint64 internal constant MATURITY_OFFSET = 30 days;

    address internal admin;
    address internal premiumManager;
    address internal claimManager;
    address internal policyManager;
    address internal buyer;
    address internal rewardsManager;
    RewardsManagerMock internal rewardsManagerMock;
    address internal payoutRecipient;
    address internal pool0;
    address internal pool1;
    address internal operator0;
    address internal operator1;
    bytes32 internal policyCommit;

    PremiumReserve internal reserve;
    MockToken internal premiumToken;

    event EscrowOpened(uint256 indexed policyId, address premiumToken, uint256 restakerPremiumTotal);
    event ClaimLockStatusSet(uint256 indexed policyId, bool locked);
    event PoolPremiumReleased(uint256 indexed policyId, address indexed pool, uint256 amount);
    event PremiumReleased(uint256 indexed policyId, address indexed to, uint256 restakerShare);
    event ClaimPaid(uint256 indexed policyId, uint256 settledAmount);

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        premiumManager = makeAddr("premiumManager");
        claimManager = makeAddr("claimManager");
        policyManager = makeAddr("policyManager");
        buyer = makeAddr("buyer");
        payoutRecipient = makeAddr("payoutRecipient");
        pool0 = makeAddr("pool0");
        pool1 = makeAddr("pool1");
        operator0 = makeAddr("operator0");
        operator1 = makeAddr("operator1");

        vm.label(admin, "Admin");
        vm.label(premiumManager, "PremiumManager");
        vm.label(claimManager, "ClaimManager");
        vm.label(policyManager, "PolicyManager");
        vm.label(buyer, "Buyer");
        vm.label(payoutRecipient, "PayoutRecipient");
        vm.label(pool0, "Pool0");
        vm.label(pool1, "Pool1");
        vm.label(operator0, "Operator0");
        vm.label(operator1, "Operator1");

        rewardsManagerMock = new RewardsManagerMock();
        rewardsManager = address(rewardsManagerMock);
        premiumToken = new MockToken();
        policyCommit = keccak256("policy-commit");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "PremiumReserve.sol",
            abi.encodeCall(PremiumReserve.initialize, (admin, premiumManager, claimManager, policyManager)),
            deployOpts
        );
        reserve = PremiumReserve(proxy);

        vm.label(address(reserve), "PremiumReserve");
        vm.label(address(premiumToken), "PremiumToken");
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAddressZero_Reverts() public {
        PremiumReserve implementation = new PremiumReserve();
        PremiumReserve freshReserve = PremiumReserve(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumReserve.ZeroAddress.selector);
        freshReserve.initialize(address(0), premiumManager, claimManager, policyManager);
    }

    /*//////////////////////////////////////////////////////////////
                                 ESCROW
    //////////////////////////////////////////////////////////////*/

    function test_openEscrow_WhenCallerUnauthorized_Reverts() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, reserve.PREMIUM_MANAGER_ROLE()
            )
        );
        vm.prank(buyer);
        reserve.openEscrow(position);
    }

    function test_openEscrow_WhenPoolSumMismatch_Reverts() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        position.poolPremiums[0].restakerPremium += 1;
        vm.prank(premiumManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPremiumReserve.PremiumTotalsMismatch.selector,
                position.restakerPremiumTotal,
                position.restakerPremiumTotal + 1
            )
        );
        reserve.openEscrow(position);
    }

    function test_openEscrow_WhenZeroRestakerPremium_Reverts() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        position.restakerPremiumTotal = 0;
        position.poolPremiums = new IPremiumReserve.PoolPremium[](0);
        vm.prank(premiumManager);
        vm.expectRevert(IPremiumReserve.ZeroRestakerPremium.selector);
        reserve.openEscrow(position);
    }

    function test_openEscrow_WhenZeroPoolsWithNonZeroPremium_Reverts() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        position.poolPremiums = new IPremiumReserve.PoolPremium[](0);
        vm.prank(premiumManager);
        vm.expectRevert(IPremiumReserve.InvalidPoolPremiums.selector);
        reserve.openEscrow(position);
    }

    function test_openEscrow_StoresStateAndEmits() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();

        vm.expectEmit();
        emit EscrowOpened(POLICY_ID, address(premiumToken), RESTAKER_PREMIUM);
        vm.prank(premiumManager);
        reserve.openEscrow(position);

        IPremiumReserve.EscrowPosition memory stored = reserve.escrowPosition(POLICY_ID);
        assertEq(stored.policyId, POLICY_ID, "policy id mismatch");
        assertEq(stored.policyCommit, policyCommit, "policy commit mismatch");
        assertEq(stored.restakerPremiumTotal, RESTAKER_PREMIUM, "restaker premium mismatch");
        assertEq(stored.premiumToken, address(premiumToken), "premium token mismatch");
        assertEq(stored.buyer, buyer, "buyer mismatch");
        assertEq(stored.poolPremiums.length, 2, "pool length");
        assertEq(stored.poolPremiums[0].restakerPremium, 600 ether, "pool0 share");
        assertEq(stored.poolPremiums[1].restakerPremium, 400 ether, "pool1 share");
    }

    /*//////////////////////////////////////////////////////////////
                                CLAIM LOCK
    //////////////////////////////////////////////////////////////*/

    function test_setClaimLockStatus_SetsFlag() public {
        _openEscrow();

        vm.expectEmit();
        emit ClaimLockStatusSet(POLICY_ID, true);
        vm.prank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        IPremiumReserve.EscrowPosition memory stored = reserve.escrowPosition(POLICY_ID);
        assertEq(stored.policyCommit, policyCommit, "policy commit should persist");
        assertTrue(stored.claimLocked, "lock not set");
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM PAYOUT
    //////////////////////////////////////////////////////////////*/

    function test_payClaim_WhenNotLocked_Reverts() public {
        _openEscrow();
        _fundReserve();

        vm.expectRevert(abi.encodeWithSelector(IPremiumReserve.EscrowNotLocked.selector, POLICY_ID));
        vm.prank(claimManager);
        reserve.payClaim(POLICY_ID, payoutRecipient, 100 ether);
    }

    function test_payClaim_WhenExceedsFunds_Reverts() public {
        _openEscrow();
        _fundReserve();

        vm.prank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        vm.expectRevert(
            abi.encodeWithSelector(IPremiumReserve.InsufficientEscrow.selector, POLICY_ID, 1100 ether, RESTAKER_PREMIUM)
        );
        vm.prank(claimManager);
        reserve.payClaim(POLICY_ID, payoutRecipient, 1100 ether);
    }

    function test_payClaim_ReducesRestakerPremiumsProRata() public {
        _openEscrow();
        _fundReserve();

        vm.prank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        vm.prank(claimManager);
        reserve.payClaim(POLICY_ID, payoutRecipient, 600 ether);

        IPremiumReserve.EscrowPosition memory stored = reserve.escrowPosition(POLICY_ID);
        assertEq(stored.policyCommit, policyCommit, "policy commit should persist after claim");
        assertEq(stored.restakerPremiumTotal, RESTAKER_PREMIUM - 600 ether, "restaker remainder");
        assertEq(stored.poolPremiums[0].restakerPremium, 240 ether, "pool0 remainder");
        assertEq(stored.poolPremiums[1].restakerPremium, 160 ether, "pool1 remainder");
    }

    /*//////////////////////////////////////////////////////////////
                                 RELEASE
    //////////////////////////////////////////////////////////////*/

    function test_releasePremium_WhenLocked_Reverts() public {
        _openEscrow();
        _fundReserve();

        vm.prank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        vm.expectRevert(abi.encodeWithSelector(IPremiumReserve.EscrowLocked.selector, POLICY_ID));
        vm.prank(policyManager);
        reserve.releasePremium(POLICY_ID, rewardsManager);
    }

    function test_releasePremium_WhenNotMatured_Reverts() public {
        _openEscrow();
        _fundReserve();

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.expectRevert(abi.encodeWithSelector(IPremiumReserve.MaturityNotReached.selector, POLICY_ID, maturityTime));
        vm.prank(policyManager);
        reserve.releasePremium(POLICY_ID, rewardsManager);
    }

    function test_releasePremium_TransfersPremiums() public {
        _openEscrow();
        _fundReserve();

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.warp(maturityTime);

        vm.expectEmit(true, true, true, true, address(rewardsManagerMock));
        emit RewardsManagerMock.RewardsDistributed(COVERAGE_POLICY_TASK, operator0, policyCommit, 600 ether);
        vm.expectEmit();
        emit PoolPremiumReleased(POLICY_ID, pool0, 600 ether);
        vm.expectEmit(true, true, true, true, address(rewardsManagerMock));
        emit RewardsManagerMock.RewardsDistributed(COVERAGE_POLICY_TASK, operator1, policyCommit, 400 ether);
        vm.expectEmit();
        emit PoolPremiumReleased(POLICY_ID, pool1, 400 ether);
        vm.expectEmit();
        emit PremiumReleased(POLICY_ID, rewardsManager, RESTAKER_PREMIUM);
        vm.prank(policyManager);
        reserve.releasePremium(POLICY_ID, rewardsManager);

        assertEq(premiumToken.balanceOf(rewardsManager), RESTAKER_PREMIUM, "restaker transfer");
        assertEq(premiumToken.balanceOf(buyer), 0, "buyer should not receive funds");

        IPremiumReserve.EscrowPosition memory stored = reserve.escrowPosition(POLICY_ID);
        assertEq(stored.policyCommit, policyCommit, "policy commit should persist after release");
        assertEq(stored.restakerPremiumTotal, 0, "restaker not cleared");
    }

    function test_releasePremium_AfterClaimTransfersRemainingPremiums() public {
        _openEscrow();
        _fundReserve();

        vm.prank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);
        vm.prank(claimManager);
        reserve.payClaim(POLICY_ID, payoutRecipient, 300 ether);
        vm.prank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, false);

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.warp(maturityTime);

        vm.prank(policyManager);
        reserve.releasePremium(POLICY_ID, rewardsManager);

        assertEq(
            premiumToken.balanceOf(rewardsManager), RESTAKER_PREMIUM - 300 ether, "restaker payout matches remainder"
        );
        assertEq(premiumToken.balanceOf(buyer), 0, "buyer should remain unpaid");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _openEscrow() internal {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        vm.prank(premiumManager);
        reserve.openEscrow(position);
    }

    function _fundReserve() internal {
        premiumToken.mint(address(reserve), RESTAKER_PREMIUM);
    }

    function _defaultPosition() internal returns (IPremiumReserve.EscrowPosition memory position) {
        position.policyId = POLICY_ID;
        position.policyCommit = policyCommit;
        position.restakerPremiumTotal = RESTAKER_PREMIUM;
        position.premiumToken = address(premiumToken);
        position.buyer = buyer;
        position.startTime = uint64(block.timestamp);
        position.maturityTime = uint64(block.timestamp + MATURITY_OFFSET);
        position.claimLocked = false;
        position.poolPremiums = new IPremiumReserve.PoolPremium[](2);
        position.poolPremiums[0] =
            IPremiumReserve.PoolPremium({pool: pool0, operator: operator0, restakerPremium: 600 ether});
        position.poolPremiums[1] =
            IPremiumReserve.PoolPremium({pool: pool1, operator: operator1, restakerPremium: 400 ether});
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Premium Token", "PRM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract RewardsManagerMock {
    event RewardsDistributed(bytes taskType, address taskPerformer, bytes32 taskDefinitionId, uint256 rewardAmount);

    function distributeRewards(
        bytes calldata taskType,
        address taskPerformer,
        bytes32 taskDefinitionId,
        uint256 rewardAmount
    )
        external
    {
        emit RewardsDistributed(taskType, taskPerformer, taskDefinitionId, rewardAmount);
    }
}
