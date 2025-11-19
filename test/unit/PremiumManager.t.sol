// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {PremiumManager} from "../../src/PremiumManager.sol";
import {IPremiumManager} from "../../src/interfaces/IPremiumManager.sol";
import {IPremiumReserve} from "../../src/interfaces/IPremiumReserve.sol";

contract PremiumManagerTest is Test {
    uint16 internal constant PLATFORM_FEE_BPS = 50;
    uint16 internal constant POOL_FEE_BPS = 150;
    uint16 internal constant MAX_FEE_BPS = 10_000;
    uint256 internal constant GROSS_PREMIUM = 1000 ether;
    uint256 internal constant POLICY_ID = 1;
    uint64 internal constant COVERAGE_DURATION = 30 days;

    address internal admin;
    address internal policyManager;
    address internal buyer;
    address internal platformTreasury;
    address internal poolFeeRecipient;
    address internal coverPool;
    address internal operator;

    PremiumManager internal premiumManager;
    MockPremiumReserve internal premiumReserve;
    MockToken internal premiumToken;
    bytes32 internal policyCommit;

    event PremiumCollected(uint256 indexed policyId, uint256 basePremium);
    event PremiumReserveSet(address indexed reserve);
    event PlatformTreasurySet(address indexed treasury);

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        policyManager = makeAddr("policyManager");
        buyer = makeAddr("buyer");
        platformTreasury = makeAddr("platformTreasury");
        poolFeeRecipient = makeAddr("poolFeeRecipient");
        coverPool = makeAddr("coverPool");
        operator = makeAddr("operator");

        vm.label(admin, "Admin");
        vm.label(policyManager, "PolicyManager");
        vm.label(buyer, "Buyer");
        vm.label(platformTreasury, "PlatformTreasury");
        vm.label(poolFeeRecipient, "PoolFeeRecipient");
        vm.label(coverPool, "CoverPool");
        vm.label(operator, "Operator");

        premiumReserve = new MockPremiumReserve();
        premiumToken = new MockToken();
        policyCommit = keccak256("policy-commit");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "PremiumManager.sol",
            abi.encodeCall(
                PremiumManager.initialize, (admin, policyManager, address(premiumReserve), platformTreasury)
            ),
            deployOpts
        );
        premiumManager = PremiumManager(proxy);

        vm.label(address(premiumManager), "PremiumManager");
        vm.label(address(premiumReserve), "PremiumReserve");
        vm.label(address(premiumToken), "PremiumToken");
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        PremiumManager implementation = new PremiumManager();
        PremiumManager freshManager = PremiumManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        freshManager.initialize(address(0), policyManager, address(premiumReserve), platformTreasury);
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        PremiumManager implementation = new PremiumManager();
        PremiumManager freshManager = PremiumManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(0), address(premiumReserve), platformTreasury);
    }

    function test_initialize_WhenPremiumReserveZero_Reverts() public {
        PremiumManager implementation = new PremiumManager();
        PremiumManager freshManager = PremiumManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        freshManager.initialize(admin, policyManager, address(0), platformTreasury);
    }

    function test_initialize_WhenPlatformTreasuryZero_Reverts() public {
        PremiumManager implementation = new PremiumManager();
        PremiumManager freshManager = PremiumManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        freshManager.initialize(admin, policyManager, address(premiumReserve), address(0));
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(premiumManager.hasRole(premiumManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertTrue(
            premiumManager.hasRole(premiumManager.POLICY_MANAGER_ROLE(), policyManager), "Policy manager role missing"
        );
        assertEq(premiumManager.premiumReserve(), address(premiumReserve), "Premium reserve mismatch");
        assertEq(premiumManager.platformTreasury(), platformTreasury, "Platform treasury mismatch");
        assertFalse(premiumManager.paused(), "Manager unexpectedly paused");
    }

    /*//////////////////////////////////////////////////////////////
                            PAUSE/UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        premiumManager.pause();
    }

    function test_pause_WhenCalledByAdmin_PausesManager() public {
        vm.prank(admin);
        premiumManager.pause();

        assertTrue(premiumManager.paused(), "Manager not paused");
    }

    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        premiumManager.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        premiumManager.unpause();
    }

    function test_unpause_WhenCalledByAdmin_UnpausesManager() public {
        vm.startPrank(admin);
        premiumManager.pause();
        premiumManager.unpause();
        vm.stopPrank();

        assertFalse(premiumManager.paused(), "Manager still paused");
    }

    /*//////////////////////////////////////////////////////////////
                        SET PREMIUM RESERVE
    //////////////////////////////////////////////////////////////*/

    function test_setPremiumReserve_WhenCallerNotAdmin_Reverts() public {
        MockPremiumReserve newReserve = new MockPremiumReserve();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        premiumManager.setPremiumReserve(address(newReserve));
    }

    function test_setPremiumReserve_WhenAddressZero_Reverts() public {
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(admin);
        premiumManager.setPremiumReserve(address(0));
    }

    function test_setPremiumReserve_WhenValid_UpdatesStateAndEmits() public {
        MockPremiumReserve newReserve = new MockPremiumReserve();

        vm.expectEmit(true, true, true, true, address(premiumManager));
        emit PremiumReserveSet(address(newReserve));

        vm.prank(admin);
        premiumManager.setPremiumReserve(address(newReserve));

        assertEq(premiumManager.premiumReserve(), address(newReserve), "Reserve not updated");
    }

    /*//////////////////////////////////////////////////////////////
                    SET PLATFORM TREASURY
    //////////////////////////////////////////////////////////////*/

    function test_setPlatformTreasury_WhenCallerNotAdmin_Reverts() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        premiumManager.setPlatformTreasury(newTreasury);
    }

    function test_setPlatformTreasury_WhenAddressZero_Reverts() public {
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(admin);
        premiumManager.setPlatformTreasury(address(0));
    }

    function test_setPlatformTreasury_WhenValid_UpdatesStateAndEmits() public {
        address newTreasury = makeAddr("newTreasury");

        vm.expectEmit(true, true, true, true, address(premiumManager));
        emit PlatformTreasurySet(newTreasury);

        vm.prank(admin);
        premiumManager.setPlatformTreasury(newTreasury);

        assertEq(premiumManager.platformTreasury(), newTreasury, "Platform treasury not updated");
    }

    /*//////////////////////////////////////////////////////////////
                          COLLECT PREMIUM
    //////////////////////////////////////////////////////////////*/

    function test_collectPremium_WhenCallerNotPolicyManager_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, premiumManager.POLICY_MANAGER_ROLE()
            )
        );
        vm.prank(buyer);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenPaused_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();

        vm.prank(admin);
        premiumManager.pause();

        vm.expectRevert();
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenBuyerZero_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.buyer = address(0);

        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenPremiumTokenZero_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.premiumToken = address(0);

        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenBasePremiumZero_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.basePremium = 0;

        vm.expectRevert(IPremiumManager.ZeroAmount.selector);
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenPolicyCommitZero_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.policyCommit = bytes32(0);

        vm.expectRevert(IPremiumManager.InvalidPolicyCommit.selector);
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenInvalidCoverageWindow_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.startTime = uint64(block.timestamp + 1 days);
        allocation.maturityTime = uint64(block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPremiumManager.InvalidCoverageWindow.selector, allocation.startTime, allocation.maturityTime
            )
        );
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenPremiumTotalsMismatch_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.basePremium = GROSS_PREMIUM + 1 ether;

        vm.expectRevert(
            abi.encodeWithSelector(
                IPremiumManager.PremiumTotalsMismatch.selector, GROSS_PREMIUM + 1 ether, GROSS_PREMIUM
            )
        );
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenCoverPoolZero_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.poolShare.coverPool = address(0);

        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenPoolFeeRecipientZero_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.poolShare.poolFeeRecipient = address(0);

        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenOperatorZero_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.poolShare.operator = address(0);

        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenGrossPremiumZero_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.poolShare.grossPremium = 0;
        allocation.basePremium = 0;

        vm.expectRevert(IPremiumManager.ZeroAmount.selector);
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenPlatformFeeTooHigh_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.platformFeeBps = MAX_FEE_BPS + 1;

        uint16 totalFeeBps = (MAX_FEE_BPS + 1) + POOL_FEE_BPS;
        vm.expectRevert(
            abi.encodeWithSelector(
                IPremiumManager.ExcessiveCombinedFees.selector, MAX_FEE_BPS + 1, POOL_FEE_BPS, totalFeeBps
            )
        );
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenPoolFeeTooHigh_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.poolShare.poolFeeBps = MAX_FEE_BPS + 1;

        uint16 totalFeeBps = PLATFORM_FEE_BPS + (MAX_FEE_BPS + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPremiumManager.ExcessiveCombinedFees.selector, PLATFORM_FEE_BPS, MAX_FEE_BPS + 1, totalFeeBps
            )
        );
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenCombinedFeesExceed100Percent_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.platformFeeBps = 6000;
        allocation.poolShare.poolFeeBps = 5000;

        uint16 totalFeeBps = 11_000;
        vm.expectRevert(abi.encodeWithSelector(IPremiumManager.ExcessiveCombinedFees.selector, 6000, 5000, totalFeeBps));
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenCombinedFeesEqual100Percent_Succeeds() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.platformFeeBps = 7000;
        allocation.poolShare.poolFeeBps = 3000;

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(GROSS_PREMIUM, 7000, 3000);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(restakerSplit, 0, "Escrowed amount should be zero");
    }

    function test_collectPremium_WhenBothFeesMaxIndividually_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.platformFeeBps = MAX_FEE_BPS;
        allocation.poolShare.poolFeeBps = MAX_FEE_BPS;

        uint16 totalFeeBps = MAX_FEE_BPS + MAX_FEE_BPS;
        vm.expectRevert(
            abi.encodeWithSelector(
                IPremiumManager.ExcessiveCombinedFees.selector, MAX_FEE_BPS, MAX_FEE_BPS, totalFeeBps
            )
        );
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenOneFeeZeroOtherExceedsMax_Reverts() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.platformFeeBps = 0;
        allocation.poolShare.poolFeeBps = MAX_FEE_BPS + 1;

        uint16 totalFeeBps = MAX_FEE_BPS + 1;
        vm.expectRevert(
            abi.encodeWithSelector(IPremiumManager.ExcessiveCombinedFees.selector, 0, MAX_FEE_BPS + 1, totalFeeBps)
        );
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);
    }

    function test_collectPremium_WhenFeesJustBelowMax_Succeeds() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.platformFeeBps = 9998;
        allocation.poolShare.poolFeeBps = 1;

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(GROSS_PREMIUM, 9998, 1);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertGt(restakerSplit, 0, "Should have some escrowed amount");
    }

    function test_collectPremium_WhenValidSinglePool_TransfersFundsAndOpensEscrow() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(GROSS_PREMIUM, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        vm.expectEmit(true, true, true, true, address(premiumManager));
        emit PremiumCollected(POLICY_ID, GROSS_PREMIUM);

        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumReserve)), restakerSplit, "Escrow amount mismatch");
        assertEq(premiumReserve.openEscrowCallCount(), 1, "OpenEscrow not called");
    }

    function test_collectPremium_WhenZeroPlatformFee_OnlyTransfersPoolFeeAndEscrow() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.platformFeeBps = 0;

        (, uint256 poolSplit, uint256 restakerSplit) = premiumManager.getFeeSplits(GROSS_PREMIUM, 0, POOL_FEE_BPS);

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        assertEq(premiumToken.balanceOf(platformTreasury), 0, "Platform fee should be zero");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumReserve)), restakerSplit, "Escrow amount mismatch");
    }

    function test_collectPremium_WhenZeroPoolFee_OnlyTransfersPlatformFeeAndEscrow() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.poolShare.poolFeeBps = 0;

        (uint256 platformSplit,/* poolSplit */, uint256 restakerSplit) =
            premiumManager.getFeeSplits(GROSS_PREMIUM, PLATFORM_FEE_BPS, 0);

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), 0, "Pool fee should be zero");
        assertEq(premiumToken.balanceOf(address(premiumReserve)), restakerSplit, "Escrow amount mismatch");
    }

    function test_collectPremium_WhenZeroRestaker_OnlyTransfersFees() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();
        allocation.platformFeeBps = 5000;
        allocation.poolShare.poolFeeBps = 5000;

        (
            uint256 platformSplit,
            uint256 poolSplit, /* restakerSplit */
        ) = premiumManager.getFeeSplits(GROSS_PREMIUM, allocation.platformFeeBps, allocation.poolShare.poolFeeBps);

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumReserve)), 0, "Escrow should be zero");
        assertEq(premiumReserve.openEscrowCallCount(), 0, "OpenEscrow should not be called");
    }

    function test_collectPremium_OpensEscrowWithCorrectParameters() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();

        (,/* poolSplit */, uint256 restakerSplit) =
            premiumManager.getFeeSplits(GROSS_PREMIUM, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        IPremiumReserve.EscrowPosition memory escrow = premiumReserve.lastEscrow();
        assertEq(escrow.policyId, POLICY_ID, "Policy ID mismatch");
        assertEq(escrow.policyCommit, policyCommit, "Policy commit mismatch");
        assertEq(escrow.restakerPremiumTotal, restakerSplit, "Restaker premium total mismatch");
        assertEq(escrow.premiumToken, address(premiumToken), "Premium token mismatch");
        assertEq(escrow.buyer, buyer, "Buyer mismatch");
        assertEq(escrow.startTime, allocation.startTime, "Start time mismatch");
        assertEq(escrow.maturityTime, allocation.maturityTime, "Maturity time mismatch");
        assertFalse(escrow.claimLocked, "Claim should not be locked");
        assertEq(escrow.pool, coverPool, "Pool address mismatch");
        assertEq(escrow.operator, operator, "Operator address mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                            GET FEE SPLITS
    //////////////////////////////////////////////////////////////*/

    function test_getFeeSplits_CalculatesCorrectly() public view {
        uint256 grossPremium = 1000 ether;
        uint16 platformFeeBps = 100;
        uint16 poolFeeBps = 200;

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(grossPremium, platformFeeBps, poolFeeBps);

        assertEq(platformSplit, 10 ether, "Platform split mismatch");
        assertEq(poolSplit, 20 ether, "Pool split mismatch");
        assertEq(restakerSplit, 970 ether, "Restaker split mismatch");
        assertEq(platformSplit + poolSplit + restakerSplit, grossPremium, "Total mismatch");
    }

    function test_getFeeSplits_WithZeroFees_ReturnsFullEscrow() public view {
        uint256 grossPremium = 1000 ether;

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(grossPremium, 0, 0);

        assertEq(platformSplit, 0, "Platform split should be zero");
        assertEq(poolSplit, 0, "Pool split should be zero");
        assertEq(restakerSplit, grossPremium, "Restaker split should equal gross");
    }

    function test_getFeeSplits_WithMaxFees_ReturnsZeroEscrow() public view {
        uint256 grossPremium = 1000 ether;

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(grossPremium, 5000, 5000);

        assertEq(platformSplit, 500 ether, "Platform split mismatch");
        assertEq(poolSplit, 500 ether, "Pool split mismatch");
        assertEq(restakerSplit, 0, "Restaker split should be zero");
    }

    function test_getFeeSplits_RoundingBehavior() public view {
        uint256 grossPremium = 100_000;
        uint16 platformFeeBps = 33;
        uint16 poolFeeBps = 67;

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(grossPremium, platformFeeBps, poolFeeBps);

        assertEq(platformSplit, 330, "Platform split rounding");
        assertEq(poolSplit, 670, "Pool split rounding");
        assertEq(restakerSplit, 99_000, "Restaker split rounding");
        assertEq(platformSplit + poolSplit + restakerSplit, grossPremium, "Total should match");
    }

    /*//////////////////////////////////////////////////////////////
                          REENTRANCY GUARD
    //////////////////////////////////////////////////////////////*/

    function test_collectPremium_IsProtectedByReentrancyGuard() public {
        IPremiumManager.PremiumAllocation memory allocation = _defaultAllocation();

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        premiumToken.mint(buyer, GROSS_PREMIUM);
        vm.prank(buyer);
        premiumToken.approve(address(premiumManager), GROSS_PREMIUM);

        allocation.policyId = 2;
        vm.prank(policyManager);
        premiumManager.collectPremium(allocation);

        assertEq(premiumReserve.openEscrowCallCount(), 2, "Should allow sequential calls");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultAllocation() internal view returns (IPremiumManager.PremiumAllocation memory) {
        IPremiumManager.PoolShare memory poolShare = IPremiumManager.PoolShare({
            coverPool: coverPool,
            poolFeeRecipient: poolFeeRecipient,
            operator: operator,
            grossPremium: GROSS_PREMIUM,
            poolFeeBps: POOL_FEE_BPS
        });

        return IPremiumManager.PremiumAllocation({
            policyId: POLICY_ID,
            policyCommit: policyCommit,
            buyer: buyer,
            premiumToken: address(premiumToken),
            basePremium: GROSS_PREMIUM,
            platformFeeBps: PLATFORM_FEE_BPS,
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + COVERAGE_DURATION),
            poolShare: poolShare
        });
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Premium Token", "PRM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockPremiumReserve {
    uint256 public openEscrowCallCount;
    IPremiumReserve.EscrowPosition private _lastEscrow;

    function openEscrow(IPremiumReserve.EscrowPosition calldata position) external {
        openEscrowCallCount++;
        _lastEscrow = position;
    }

    function lastEscrow() external view returns (IPremiumReserve.EscrowPosition memory) {
        return _lastEscrow;
    }
}

