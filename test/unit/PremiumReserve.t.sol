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
    event PremiumReleased(uint256 indexed policyId, address indexed to, uint256 restakerShare);
    event ClaimPaid(uint256 indexed policyId, uint256 settledAmount);
    event EscrowReleased(uint256 indexed policyId, uint256 timestamp);

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

    function test_openEscrow_WhenInvalidPoolData_Reverts() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        position.pool = address(0);
        vm.prank(premiumManager);
        vm.expectRevert(IPremiumReserve.InvalidPoolData.selector);
        reserve.openEscrow(position);
    }

    function test_openEscrow_WhenZeroRestakerPremium_Reverts() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        position.restakerPremiumTotal = 0;
        vm.prank(premiumManager);
        vm.expectRevert(IPremiumReserve.ZeroRestakerPremium.selector);
        reserve.openEscrow(position);
    }

    function test_openEscrow_Succeeds() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();

        premiumToken.mint(premiumManager, RESTAKER_PREMIUM);
        vm.prank(premiumManager);
        premiumToken.transfer(address(reserve), RESTAKER_PREMIUM);

        vm.prank(premiumManager);
        reserve.openEscrow(position);

        assertEq(reserve.getPool(POLICY_ID), pool0, "should store pool address");
        IPremiumReserve.EscrowPosition memory stored = reserve.escrowPosition(POLICY_ID);
        assertEq(stored.operator, operator0, "should store operator address");
    }

    function test_openEscrow_StoresStateAndEmits() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();

        premiumToken.mint(premiumManager, RESTAKER_PREMIUM);
        vm.prank(premiumManager);
        premiumToken.transfer(address(reserve), RESTAKER_PREMIUM);

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
        assertEq(stored.pool, pool0, "pool mismatch");
        assertEq(stored.operator, operator0, "operator mismatch");
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

        vm.expectRevert(abi.encodeWithSelector(IPremiumReserve.EscrowNotLocked.selector, POLICY_ID));
        vm.prank(claimManager);
        reserve.payClaim(POLICY_ID, payoutRecipient, 100 ether);
    }

    function test_payClaim_WhenExceedsFunds_Reverts() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        vm.expectRevert(
            abi.encodeWithSelector(IPremiumReserve.InsufficientEscrow.selector, POLICY_ID, 1100 ether, RESTAKER_PREMIUM)
        );
        reserve.payClaim(POLICY_ID, payoutRecipient, 1100 ether);
        vm.stopPrank();
    }

    function test_payClaim_ReducesRestakerPremiums() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);
        reserve.payClaim(POLICY_ID, payoutRecipient, 600 ether);
        vm.stopPrank();

        IPremiumReserve.EscrowPosition memory stored = reserve.escrowPosition(POLICY_ID);
        assertEq(stored.policyCommit, policyCommit, "policy commit should persist after claim");
        assertEq(stored.restakerPremiumTotal, RESTAKER_PREMIUM - 600 ether, "restaker remainder");
    }

    function test_payClaim_MultipleSequentialClaims() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        reserve.payClaim(POLICY_ID, payoutRecipient, 300 ether);

        IPremiumReserve.EscrowPosition memory stored1 = reserve.escrowPosition(POLICY_ID);
        assertEq(stored1.restakerPremiumTotal, 700 ether, "after first claim total");
        assertEq(premiumToken.balanceOf(payoutRecipient), 300 ether, "first payout");

        reserve.payClaim(POLICY_ID, payoutRecipient, 200 ether);

        IPremiumReserve.EscrowPosition memory stored2 = reserve.escrowPosition(POLICY_ID);
        assertEq(stored2.restakerPremiumTotal, 500 ether, "after second claim total");
        assertEq(premiumToken.balanceOf(payoutRecipient), 500 ether, "cumulative payout");

        reserve.payClaim(POLICY_ID, payoutRecipient, 500 ether);
        vm.stopPrank();

        IPremiumReserve.EscrowPosition memory stored3 = reserve.escrowPosition(POLICY_ID);
        assertEq(stored3.restakerPremiumTotal, 0, "after third claim total depleted");
        assertEq(premiumToken.balanceOf(payoutRecipient), 1000 ether, "full payout");
    }

    function test_payClaim_ExactEscrowAmount_DepletesCompletely() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        vm.expectEmit();
        emit ClaimPaid(POLICY_ID, RESTAKER_PREMIUM);
        reserve.payClaim(POLICY_ID, payoutRecipient, RESTAKER_PREMIUM);
        vm.stopPrank();

        IPremiumReserve.EscrowPosition memory stored = reserve.escrowPosition(POLICY_ID);
        assertEq(stored.restakerPremiumTotal, 0, "total should be zero");
        assertEq(premiumToken.balanceOf(payoutRecipient), RESTAKER_PREMIUM, "recipient gets full amount");
        assertEq(premiumToken.balanceOf(address(reserve)), 0, "reserve fully depleted");
    }

    function test_payClaim_AfterPartialClaim_RemainingCanBeReleased() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);
        reserve.payClaim(POLICY_ID, payoutRecipient, 400 ether);
        reserve.setClaimLockStatus(POLICY_ID, false);
        vm.stopPrank();

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.warp(maturityTime);

        vm.prank(policyManager);
        reserve.releaseEscrow(POLICY_ID, rewardsManager);

        assertEq(premiumToken.balanceOf(rewardsManager), 600 ether, "rewards manager gets remainder");
        assertEq(premiumToken.balanceOf(payoutRecipient), 400 ether, "payout recipient keeps claim amount");
    }

    /*//////////////////////////////////////////////////////////////
                                 RELEASE
    //////////////////////////////////////////////////////////////*/

    function test_releaseEscrow_WhenLocked_Reverts() public {
        _openEscrow();

        vm.prank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        vm.expectRevert(abi.encodeWithSelector(IPremiumReserve.EscrowLocked.selector, POLICY_ID));
        vm.prank(policyManager);
        reserve.releaseEscrow(POLICY_ID, rewardsManager);
    }

    function test_releaseEscrow_WhenNotMatured_Reverts() public {
        _openEscrow();

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.expectRevert(abi.encodeWithSelector(IPremiumReserve.MaturityNotReached.selector, POLICY_ID, maturityTime));
        vm.prank(policyManager);
        reserve.releaseEscrow(POLICY_ID, rewardsManager);
    }

    function test_releaseEscrow_TransfersPremiums() public {
        _openEscrow();

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.warp(maturityTime);

        vm.expectEmit(true, true, true, true, address(rewardsManagerMock));
        emit RewardsManagerMock.RewardsDistributed(COVERAGE_POLICY_TASK, operator0, policyCommit, RESTAKER_PREMIUM);
        vm.expectEmit();
        emit PremiumReleased(POLICY_ID, rewardsManager, RESTAKER_PREMIUM);
        vm.expectEmit();
        emit EscrowReleased(POLICY_ID, maturityTime);
        vm.prank(policyManager);
        reserve.releaseEscrow(POLICY_ID, rewardsManager);

        assertEq(premiumToken.balanceOf(rewardsManager), RESTAKER_PREMIUM, "restaker transfer");
        assertEq(premiumToken.balanceOf(buyer), 0, "buyer should not receive funds");

        IPremiumReserve.EscrowPosition memory stored = reserve.escrowPosition(POLICY_ID);
        assertEq(stored.policyCommit, policyCommit, "policy commit should persist after release");
        assertEq(stored.restakerPremiumTotal, 0, "restaker not cleared");
    }

    function test_releaseEscrow_EmitsEscrowReleasedEvent() public {
        _openEscrow();

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.warp(maturityTime);

        vm.expectEmit();
        emit EscrowReleased(POLICY_ID, maturityTime);
        vm.prank(policyManager);
        reserve.releaseEscrow(POLICY_ID, rewardsManager);
    }

    function test_releaseEscrow_AfterClaimTransfersRemainingPremiums() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);
        reserve.payClaim(POLICY_ID, payoutRecipient, 300 ether);
        reserve.setClaimLockStatus(POLICY_ID, false);
        vm.stopPrank();

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.warp(maturityTime);

        vm.prank(policyManager);
        reserve.releaseEscrow(POLICY_ID, rewardsManager);

        assertEq(
            premiumToken.balanceOf(rewardsManager), RESTAKER_PREMIUM - 300 ether, "restaker payout matches remainder"
        );
        assertEq(premiumToken.balanceOf(buyer), 0, "buyer should remain unpaid");
    }

    /*//////////////////////////////////////////////////////////////
                            QUERY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_isEscrowReleased_WhenNotReleased_ReturnsFalse() public {
        _openEscrow();
        assertFalse(reserve.isEscrowReleased(POLICY_ID), "should not be released initially");
    }

    function test_isEscrowReleased_WhenReleased_ReturnsTrue() public {
        _openEscrow();

        uint64 maturityTime = reserve.escrowPosition(POLICY_ID).maturityTime;
        vm.warp(maturityTime);

        vm.prank(policyManager);
        reserve.releaseEscrow(POLICY_ID, rewardsManager);

        assertTrue(reserve.isEscrowReleased(POLICY_ID), "should be released after release");
    }

    function test_isEscrowLocked_WhenNotLocked_ReturnsFalse() public {
        _openEscrow();
        assertFalse(reserve.isEscrowLocked(POLICY_ID), "should not be locked initially");
    }

    function test_isEscrowLocked_WhenLocked_ReturnsTrue() public {
        _openEscrow();

        vm.prank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);

        assertTrue(reserve.isEscrowLocked(POLICY_ID), "should be locked after setting lock");
    }

    function test_isEscrowLocked_AfterUnlock_ReturnsFalse() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);
        reserve.setClaimLockStatus(POLICY_ID, false);
        vm.stopPrank();

        assertFalse(reserve.isEscrowLocked(POLICY_ID), "should not be locked after unlock");
    }

    function test_getRemainingPremium_InitiallyReturnsTotal() public {
        _openEscrow();
        assertEq(reserve.getRemainingPremium(POLICY_ID), RESTAKER_PREMIUM, "should return full premium initially");
    }

    function test_getRemainingPremium_AfterPartialClaim_ReturnsRemainder() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);
        reserve.payClaim(POLICY_ID, payoutRecipient, 300 ether);
        vm.stopPrank();

        assertEq(reserve.getRemainingPremium(POLICY_ID), 700 ether, "should return remainder after claim");
    }

    function test_getRemainingPremium_AfterFullClaim_ReturnsZero() public {
        _openEscrow();

        vm.startPrank(claimManager);
        reserve.setClaimLockStatus(POLICY_ID, true);
        reserve.payClaim(POLICY_ID, payoutRecipient, RESTAKER_PREMIUM);
        vm.stopPrank();

        assertEq(reserve.getRemainingPremium(POLICY_ID), 0, "should return zero after full claim");
    }

    function test_getPool_ReturnsCorrectPool() public {
        _openEscrow();
        assertEq(reserve.getPool(POLICY_ID), pool0, "should return correct pool");
    }

    function test_getPool_WithDifferentPolicyIds() public {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        position.policyId = 999;

        premiumToken.mint(premiumManager, RESTAKER_PREMIUM);
        vm.prank(premiumManager);
        premiumToken.transfer(address(reserve), RESTAKER_PREMIUM);

        vm.prank(premiumManager);
        reserve.openEscrow(position);

        assertEq(reserve.getPool(999), pool0, "should return pool for policy 999");
        assertEq(reserve.getPool(POLICY_ID), address(0), "should return zero for non-opened policy");
    }

    function test_getPool_ForNonexistentEscrow_ReturnsZero() public view {
        assertEq(reserve.getPool(999), address(0), "should return zero for nonexistent escrow");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _openEscrow() internal {
        IPremiumReserve.EscrowPosition memory position = _defaultPosition();
        premiumToken.mint(premiumManager, RESTAKER_PREMIUM);
        vm.prank(premiumManager);
        premiumToken.transfer(address(reserve), RESTAKER_PREMIUM);
        vm.prank(premiumManager);
        reserve.openEscrow(position);
    }

    function _fundReserve() internal {
        premiumToken.mint(buyer, RESTAKER_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(reserve), RESTAKER_PREMIUM);
    }

    function _defaultPosition() internal view returns (IPremiumReserve.EscrowPosition memory position) {
        position.policyId = POLICY_ID;
        position.policyCommit = policyCommit;
        position.restakerPremiumTotal = RESTAKER_PREMIUM;
        position.premiumToken = address(premiumToken);
        position.buyer = buyer;
        position.pool = pool0;
        position.operator = operator0;
        position.startTime = uint64(block.timestamp);
        position.maturityTime = uint64(block.timestamp + MATURITY_OFFSET);
        position.claimLocked = false;
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
