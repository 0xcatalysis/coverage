// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {PremiumManager} from "../../src/PremiumManager.sol";
import {IPremiumManager} from "../../src/interfaces/IPremiumManager.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

contract PremiumManagerTest is Test {
    uint16 internal constant PLATFORM_FEE_BPS = 50;
    uint16 internal constant POOL_FEE_BPS = 150;
    uint16 internal constant MAX_FEE_BPS = 10_000;
    uint256 internal constant PREMIUM_AMOUNT = 1000 ether;
    uint96 internal constant POLICY_ID = 123;

    address internal admin;
    address internal premiumCollector;
    address internal platformTreasury;
    address internal poolFeeRecipient;
    address internal pool;
    address internal curator;

    PremiumManager internal premiumManager;
    MockRewardsManager internal rewardsManager;
    MockToken internal premiumToken;
    MockCoverPool internal mockPool;

    event PremiumDistributed(address indexed pool, uint96 indexed policyId, uint256 amount);
    event RewardsManagerSet(address indexed rewardsManager_);
    event PlatformTreasurySet(address indexed treasury);
    event PlatformFeeBpsSet(uint16 indexed platformFeeBps_);
    event SpenderApproved(address indexed token, address indexed spender, uint256 amount);

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        premiumCollector = makeAddr("premiumCollector");
        platformTreasury = makeAddr("platformTreasury");
        poolFeeRecipient = makeAddr("poolFeeRecipient");
        curator = makeAddr("curator");

        vm.label(admin, "Admin");
        vm.label(premiumCollector, "PremiumCollector");
        vm.label(platformTreasury, "PlatformTreasury");
        vm.label(poolFeeRecipient, "PoolFeeRecipient");
        vm.label(curator, "Operator");

        rewardsManager = new MockRewardsManager();
        premiumToken = new MockToken();
        mockPool = new MockCoverPool(curator, poolFeeRecipient, POOL_FEE_BPS);
        pool = address(mockPool);

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "PremiumManager.sol",
            abi.encodeCall(
                PremiumManager.initialize, (admin, address(rewardsManager), platformTreasury, PLATFORM_FEE_BPS)
            ),
            deployOpts
        );
        premiumManager = PremiumManager(proxy);

        vm.label(address(premiumManager), "PremiumManager");
        vm.label(address(rewardsManager), "RewardsManager");
        vm.label(address(premiumToken), "PremiumToken");
        vm.label(address(mockPool), "MockPool");

        bytes32 collectorRole = premiumManager.PREMIUM_COLLECTOR_ROLE();
        vm.startPrank(admin);
        premiumManager.grantRole(collectorRole, premiumCollector);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        PremiumManager implementation = new PremiumManager();
        PremiumManager freshManager = PremiumManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        freshManager.initialize(address(0), address(rewardsManager), platformTreasury, PLATFORM_FEE_BPS);
    }

    function test_initialize_WhenRewardsManagerZero_Reverts() public {
        PremiumManager implementation = new PremiumManager();
        PremiumManager freshManager = PremiumManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(0), platformTreasury, PLATFORM_FEE_BPS);
    }

    function test_initialize_WhenPlatformTreasuryZero_Reverts() public {
        PremiumManager implementation = new PremiumManager();
        PremiumManager freshManager = PremiumManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(rewardsManager), address(0), PLATFORM_FEE_BPS);
    }

    function test_initialize_WhenPlatformFeeExceedsMax_Reverts() public {
        PremiumManager implementation = new PremiumManager();
        PremiumManager freshManager = PremiumManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(abi.encodeWithSelector(IPremiumManager.InvalidPlatformFeeBps.selector, 2501));
        freshManager.initialize(admin, address(rewardsManager), platformTreasury, 2501);
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(premiumManager.hasRole(premiumManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertEq(premiumManager.rewardsManager(), address(rewardsManager), "Rewards manager mismatch");
        assertEq(premiumManager.platformTreasury(), platformTreasury, "Platform treasury mismatch");
        assertEq(premiumManager.platformFeeBps(), PLATFORM_FEE_BPS, "Platform fee mismatch");
        assertFalse(premiumManager.paused(), "Manager unexpectedly paused");
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                premiumCollector,
                premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(premiumCollector);
        premiumManager.pause();
    }

    function test_pause_WhenCalledByAdmin_PausesManager() public {
        vm.prank(admin);
        premiumManager.pause();

        assertTrue(premiumManager.paused(), "Manager not paused");
    }

    /*//////////////////////////////////////////////////////////////
                                UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        premiumManager.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                premiumCollector,
                premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(premiumCollector);
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
                        SET REWARDS MANAGER
    //////////////////////////////////////////////////////////////*/

    function test_setRewardsManager_WhenCallerNotAdmin_Reverts() public {
        MockRewardsManager newRewardsManager = new MockRewardsManager();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                premiumCollector,
                premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(premiumCollector);
        premiumManager.setRewardsManager(address(newRewardsManager));
    }

    function test_setRewardsManager_WhenAddressZero_Reverts() public {
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(admin);
        premiumManager.setRewardsManager(address(0));
    }

    function test_setRewardsManager_WhenValid_UpdatesStateAndEmits() public {
        MockRewardsManager newRewardsManager = new MockRewardsManager();

        vm.expectEmit(true, true, true, true, address(premiumManager));
        emit RewardsManagerSet(address(newRewardsManager));

        vm.prank(admin);
        premiumManager.setRewardsManager(address(newRewardsManager));

        assertEq(premiumManager.rewardsManager(), address(newRewardsManager), "Rewards manager not updated");
    }

    /*//////////////////////////////////////////////////////////////
                       SET PLATFORM TREASURY
    //////////////////////////////////////////////////////////////*/

    function test_setPlatformTreasury_WhenCallerNotAdmin_Reverts() public {
        address newTreasury = makeAddr("newTreasury");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                premiumCollector,
                premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(premiumCollector);
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
                       SET PLATFORM FEE BPS
    //////////////////////////////////////////////////////////////*/

    function test_setPlatformFeeBps_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                premiumCollector,
                premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(premiumCollector);
        premiumManager.setPlatformFeeBps(100);
    }

    function test_setPlatformFeeBps_WhenExceedsMax_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPremiumManager.InvalidPlatformFeeBps.selector, 2501));
        vm.prank(admin);
        premiumManager.setPlatformFeeBps(2501);
    }

    function test_setPlatformFeeBps_WhenValid_UpdatesStateAndEmits() public {
        uint16 newFee = 100;

        vm.expectEmit(true, false, false, true, address(premiumManager));
        emit PlatformFeeBpsSet(newFee);

        vm.prank(admin);
        premiumManager.setPlatformFeeBps(newFee);

        assertEq(premiumManager.platformFeeBps(), newFee, "Platform fee not updated");
    }

    function test_setPlatformFeeBps_AllowsZeroFee() public {
        vm.prank(admin);
        premiumManager.setPlatformFeeBps(0);

        assertEq(premiumManager.platformFeeBps(), 0, "Platform fee should be zero");
    }

    function test_setPlatformFeeBps_AllowsMaxFee() public {
        vm.prank(admin);
        premiumManager.setPlatformFeeBps(2500);

        assertEq(premiumManager.platformFeeBps(), 2500, "Platform fee should be max");
    }

    /*//////////////////////////////////////////////////////////////
                         DISTRIBUTE PREMIUM
    //////////////////////////////////////////////////////////////*/

    function test_distributePremium_WhenCallerNotPremiumCollector_Reverts() public {
        address unauthorized = makeAddr("unauthorized");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                premiumManager.PREMIUM_COLLECTOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenPaused_Reverts() public {
        vm.prank(admin);
        premiumManager.pause();

        vm.expectRevert();
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenPoolZero_Reverts() public {
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(0), POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenPremiumTokenZero_Reverts() public {
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(0), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenAmountZero_Reverts() public {
        vm.expectRevert(IPremiumManager.ZeroAmount.selector);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), 0);
    }

    function test_distributePremium_WhenCommitteeIdZero_Reverts() public {
        vm.expectRevert(IPremiumManager.InvalidPolicyId.selector);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, 0, address(premiumToken), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenPolicyNotBound_Reverts() public {
        mockPool.setPermissive(false);
        vm.expectRevert(abi.encodeWithSelector(IPremiumManager.PolicyNotBound.selector, POLICY_ID, pool));
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenPoolFeeRecipientZero_Reverts() public {
        MockCoverPool zeroRecipientPool = new MockCoverPool(curator, address(0), POOL_FEE_BPS);

        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(zeroRecipientPool), POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenPoolOwnerZero_Reverts() public {
        MockCoverPool zeroOwnerPool = new MockCoverPool(address(0), poolFeeRecipient, POOL_FEE_BPS);

        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(zeroOwnerPool), POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenCombinedFeesExceed100Percent_Reverts() public {
        MockCoverPool highFeePool = new MockCoverPool(curator, poolFeeRecipient, 9990);

        vm.expectRevert(
            abi.encodeWithSelector(IPremiumManager.ExcessiveCombinedFees.selector, PLATFORM_FEE_BPS, 9990, 10_040)
        );
        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(highFeePool), POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);
    }

    function test_distributePremium_WhenValid_DistributesFundsCorrectly() public {
        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(PREMIUM_AMOUNT, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.expectEmit(true, true, true, true, address(premiumManager));
        emit PremiumDistributed(pool, POLICY_ID, PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), restakerSplit, "Restaker split mismatch");
        assertEq(rewardsManager.distributeRewardsCallCount(), 1, "DistributeRewards not called");
    }

    function test_distributePremium_WhenZeroPlatformFee_OnlyTransfersPoolFeeAndRewards() public {
        vm.prank(admin);
        premiumManager.setPlatformFeeBps(0);

        (, uint256 poolSplit, uint256 restakerSplit) = premiumManager.getFeeSplits(PREMIUM_AMOUNT, 0, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(premiumToken.balanceOf(platformTreasury), 0, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), restakerSplit, "Restaker split mismatch");
    }

    function test_distributePremium_WhenZeroPoolFee_OnlyTransfersPlatformFeeAndRewards() public {
        MockCoverPool zeroFeePool = new MockCoverPool(curator, poolFeeRecipient, 0);

        (uint256 platformSplit,, uint256 restakerSplit) =
            premiumManager.getFeeSplits(PREMIUM_AMOUNT, PLATFORM_FEE_BPS, 0);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(zeroFeePool), POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), 0, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), restakerSplit, "Restaker split mismatch");
    }

    function test_distributePremium_DistributesRewardsWithCorrectParameters() public {
        (,, uint256 restakerSplit) = premiumManager.getFeeSplits(PREMIUM_AMOUNT, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        MockRewardsManager.DistributeRewardsCall memory call = rewardsManager.lastCall();
        assertEq(call.policyId, POLICY_ID, "Policy ID mismatch");
        assertEq(call.curator, curator, "Operator mismatch");
        assertEq(call.rewardAmount, restakerSplit, "Reward amount mismatch");
        assertEq(address(call.rewardToken), address(premiumToken), "Reward token mismatch");
    }

    function test_distributePremium_WhenFeeRecipientDiffersFromOwner_SendsFeesToRecipientAndOperatorToOwner() public {
        address differentFeeRecipient = makeAddr("differentFeeRecipient");
        address separatePoolOwner = makeAddr("separatePoolOwner");
        MockCoverPool separateAddressPool = new MockCoverPool(separatePoolOwner, differentFeeRecipient, POOL_FEE_BPS);

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(PREMIUM_AMOUNT, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(separateAddressPool), POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(differentFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(separatePoolOwner), 0, "Pool owner should not receive pool fee");
        assertEq(premiumToken.balanceOf(address(premiumManager)), restakerSplit, "Restaker split mismatch");

        MockRewardsManager.DistributeRewardsCall memory call = rewardsManager.lastCall();
        assertEq(call.curator, separatePoolOwner, "Curator should be the pool owner, not feeRecipient");
    }

    function test_distributePremium_FlowFromPolicyBindingToPremiumDistribution() public {
        uint96 policyId = 123;
        uint256 premiumAmount = 1000 ether;

        premiumToken.mint(address(premiumManager), premiumAmount);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, policyId, address(premiumToken), premiumAmount);

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(premiumAmount, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), restakerSplit, "Restaker split mismatch");
    }

    function test_distributePremium_MultipleDistributionsToSamePolicy() public {
        uint96 policyId = 456;
        uint256 firstPremium = 500 ether;
        uint256 secondPremium = 750 ether;

        premiumToken.mint(address(premiumManager), firstPremium);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, policyId, address(premiumToken), firstPremium);

        uint256 platformAfterFirst = premiumToken.balanceOf(platformTreasury);
        uint256 poolAfterFirst = premiumToken.balanceOf(poolFeeRecipient);
        uint256 pmBalanceAfterFirst = premiumToken.balanceOf(address(premiumManager));

        premiumToken.mint(address(premiumManager), secondPremium);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, policyId, address(premiumToken), secondPremium);

        (uint256 platformSplit2, uint256 poolSplit2, uint256 restakerSplit2) =
            premiumManager.getFeeSplits(secondPremium, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        assertEq(premiumToken.balanceOf(platformTreasury), platformAfterFirst + platformSplit2, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient) - poolAfterFirst, poolSplit2, "Pool fee mismatch");
        assertEq(
            premiumToken.balanceOf(address(premiumManager)),
            pmBalanceAfterFirst + restakerSplit2,
            "Restaker split mismatch"
        );
    }

    function test_distributePremium_RewardsManagerReceivesCorrectCommitteeId() public {
        uint96 policyId = 789;
        uint256 premiumAmount = 1000 ether;

        premiumToken.mint(address(premiumManager), premiumAmount);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, policyId, address(premiumToken), premiumAmount);

        MockRewardsManager.DistributeRewardsCall memory call = rewardsManager.lastCall();
        assertEq(call.policyId, policyId, "CommitteeId should equal policyId for rewards distribution");
        assertEq(call.curator, curator, "Curator should be pool owner");
    }

    function test_distributePremium_DifferentPoliciesSameCurator_BothDistributeCorrectly() public {
        uint96 policyId1 = 100;
        uint96 policyId2 = 200;
        uint256 premium1 = 500 ether;
        uint256 premium2 = 1000 ether;

        premiumToken.mint(address(premiumManager), premium1);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, policyId1, address(premiumToken), premium1);

        uint256 pmBalanceAfterFirst = premiumToken.balanceOf(address(premiumManager));

        premiumToken.mint(address(premiumManager), premium2);
        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, policyId2, address(premiumToken), premium2);

        (,, uint256 restakerSplit2) = premiumManager.getFeeSplits(premium2, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        assertEq(
            premiumToken.balanceOf(address(premiumManager)),
            pmBalanceAfterFirst + restakerSplit2,
            "Restaker split mismatch"
        );
    }

    function test_distributePremium_WhenMaxCombinedFees_RestakerSplitIsZero_SkipsRewardsCall() public {
        uint16 maxPlatformFeeBps = 2500;
        uint16 remainingPoolFeeBps = 7500;
        MockCoverPool maxFeePool = new MockCoverPool(curator, poolFeeRecipient, remainingPoolFeeBps);

        vm.prank(admin);
        premiumManager.setPlatformFeeBps(maxPlatformFeeBps);

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(PREMIUM_AMOUNT, maxPlatformFeeBps, remainingPoolFeeBps);

        assertEq(restakerSplit, 0, "Restaker split should be zero at 100% combined fees");

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(maxFeePool), POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), 0, "Restaker split mismatch");
        assertEq(rewardsManager.distributeRewardsCallCount(), 0, "RewardsManager should not be called");
    }

    function test_distributePremium_WhenBothFeesZero_EntirePremiumRetainedInPM() public {
        MockCoverPool zeroFeePool = new MockCoverPool(curator, poolFeeRecipient, 0);

        vm.prank(admin);
        premiumManager.setPlatformFeeBps(0);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(zeroFeePool), POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(premiumToken.balanceOf(platformTreasury), 0, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), 0, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), PREMIUM_AMOUNT, "Restaker split mismatch");
        assertEq(rewardsManager.distributeRewardsCallCount(), 1, "DistributeRewards not called");
    }

    function test_distributePremium_WhenSSPRouterApproved_CanPullRestakerSplitFromPM() public {
        address sspRouter = makeAddr("sspRouter");
        (,, uint256 restakerSplit) = premiumManager.getFeeSplits(PREMIUM_AMOUNT, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        vm.prank(admin);
        premiumManager.approveSpender(address(premiumToken), sspRouter, type(uint256).max);

        vm.prank(sspRouter);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        premiumToken.transferFrom(address(premiumManager), sspRouter, restakerSplit);

        assertEq(premiumToken.balanceOf(sspRouter), restakerSplit, "SSPRouter balance mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), 0, "PM should be empty after pull");
    }

    function test_distributePremium_WhenDifferentPools_EachCuratorGetsOwnRewardsCall() public {
        address curator2 = makeAddr("curator2");
        address feeRecipient2 = makeAddr("feeRecipient2");
        MockCoverPool pool2 = new MockCoverPool(curator2, feeRecipient2, POOL_FEE_BPS);
        uint96 policyId2 = POLICY_ID + 1;

        (uint256 platformSplit,, uint256 restakerSplit) =
            premiumManager.getFeeSplits(PREMIUM_AMOUNT, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(rewardsManager.lastCall().curator, curator, "First curator mismatch");

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(address(pool2), policyId2, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(rewardsManager.lastCall().curator, curator2, "Second curator mismatch");
        assertEq(rewardsManager.distributeRewardsCallCount(), 2, "DistributeRewards call count mismatch");
        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit * 2, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), restakerSplit * 2, "Restaker split mismatch");
    }

    function test_distributePremium_WhenSmallPremium_SplitsSumToTotalPremium() public {
        uint256 smallPremium = 100;

        (uint256 platformSplit, uint256 poolSplit, uint256 restakerSplit) =
            premiumManager.getFeeSplits(smallPremium, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), smallPremium);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), smallPremium);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit, "Platform fee mismatch");
        assertEq(premiumToken.balanceOf(poolFeeRecipient), poolSplit, "Pool fee mismatch");
        assertEq(premiumToken.balanceOf(address(premiumManager)), restakerSplit, "Restaker split mismatch");
        assertEq(platformSplit + poolSplit + restakerSplit, smallPremium, "Splits must sum to premium");
    }

    function test_distributePremium_EmitsEventForEachDistributionInSequence() public {
        uint96 policyId2 = POLICY_ID + 1;
        uint256 premium2 = 500 ether;

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT + premium2);

        vm.expectEmit(true, true, true, true, address(premiumManager));
        emit PremiumDistributed(pool, POLICY_ID, PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        vm.expectEmit(true, true, true, true, address(premiumManager));
        emit PremiumDistributed(pool, policyId2, premium2);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, policyId2, address(premiumToken), premium2);
    }

    function test_distributePremium_WhenPlatformFeeChanges_SubsequentCallUsesNewFee() public {
        uint16 newPlatformFeeBps = 200;

        (uint256 platformSplit1,, uint256 restakerSplit1) =
            premiumManager.getFeeSplits(PREMIUM_AMOUNT, PLATFORM_FEE_BPS, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, POLICY_ID, address(premiumToken), PREMIUM_AMOUNT);

        vm.prank(admin);
        premiumManager.setPlatformFeeBps(newPlatformFeeBps);

        (uint256 platformSplit2,, uint256 restakerSplit2) =
            premiumManager.getFeeSplits(PREMIUM_AMOUNT, newPlatformFeeBps, POOL_FEE_BPS);

        premiumToken.mint(address(premiumManager), PREMIUM_AMOUNT);

        uint96 policyId2 = POLICY_ID + 1;

        vm.prank(premiumCollector);
        premiumManager.distributePremium(pool, policyId2, address(premiumToken), PREMIUM_AMOUNT);

        assertEq(premiumToken.balanceOf(platformTreasury), platformSplit1 + platformSplit2, "Platform fee mismatch");
        assertEq(
            premiumToken.balanceOf(address(premiumManager)), restakerSplit1 + restakerSplit2, "Restaker split mismatch"
        );
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
                            APPROVE SPENDER
    //////////////////////////////////////////////////////////////*/

    function test_approveSpender_WhenCalledByAdmin_SetsAllowance() public {
        address spender = makeAddr("spender");
        uint256 amount = type(uint256).max;

        vm.prank(admin);
        premiumManager.approveSpender(address(premiumToken), spender, amount);

        assertEq(premiumToken.allowance(address(premiumManager), spender), amount, "Allowance should be set");
    }

    function test_approveSpender_EmitsEvent() public {
        address spender = makeAddr("spender");
        uint256 amount = type(uint256).max;

        vm.expectEmit(true, true, false, true, address(premiumManager));
        emit SpenderApproved(address(premiumToken), spender, amount);

        vm.prank(admin);
        premiumManager.approveSpender(address(premiumToken), spender, amount);
    }

    function test_approveSpender_WhenCalledByNonAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                premiumCollector,
                premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(premiumCollector);
        premiumManager.approveSpender(address(premiumToken), makeAddr("spender"), type(uint256).max);
    }

    function test_approveSpender_WhenTokenZero_Reverts() public {
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(admin);
        premiumManager.approveSpender(address(0), makeAddr("spender"), type(uint256).max);
    }

    function test_approveSpender_WhenSpenderZero_Reverts() public {
        vm.expectRevert(IPremiumManager.ZeroAddress.selector);
        vm.prank(admin);
        premiumManager.approveSpender(address(premiumToken), address(0), type(uint256).max);
    }

    function test_approveSpender_CanResetApproval() public {
        address spender = makeAddr("spender");

        vm.prank(admin);
        premiumManager.approveSpender(address(premiumToken), spender, type(uint256).max);
        assertEq(premiumToken.allowance(address(premiumManager), spender), type(uint256).max, "Should be max");

        vm.prank(admin);
        premiumManager.approveSpender(address(premiumToken), spender, 0);
        assertEq(premiumToken.allowance(address(premiumManager), spender), 0, "Should be revoked");
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_authorizeUpgrade_WhenCallerNotAdmin_Reverts() public {
        PremiumManager newImpl = new PremiumManager();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                premiumCollector,
                premiumManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(premiumCollector);
        premiumManager.upgradeToAndCall(address(newImpl), "");
    }

    function test_authorizeUpgrade_WhenCalledByAdmin_Succeeds() public {
        PremiumManager newImpl = new PremiumManager();
        vm.prank(admin);
        premiumManager.upgradeToAndCall(address(newImpl), "");

        assertEq(premiumManager.rewardsManager(), address(rewardsManager), "RewardsManager should be preserved");
        assertEq(premiumManager.platformTreasury(), platformTreasury, "PlatformTreasury should be preserved");
        assertEq(premiumManager.platformFeeBps(), PLATFORM_FEE_BPS, "PlatformFeeBps should be preserved");
        assertTrue(premiumManager.hasRole(premiumManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role should be preserved");
    }
}

contract MockToken is ERC20 {
    constructor() ERC20("Premium Token", "PRM") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockRewardsManager {
    uint256 public distributeRewardsCallCount;

    struct DistributeRewardsCall {
        uint96 policyId;
        address curator;
        uint256 rewardAmount;
        IERC20 rewardToken;
    }

    DistributeRewardsCall private _lastCall;

    function distributeRewards(
        uint96 policyId,
        address curator,
        uint256 rewardAmount,
        IERC20 rewardToken,
        bytes32 /*taskId*/
    )
        external
    {
        distributeRewardsCallCount++;
        _lastCall = DistributeRewardsCall({
            policyId: policyId, curator: curator, rewardAmount: rewardAmount, rewardToken: rewardToken
        });
    }

    function lastCall() external view returns (DistributeRewardsCall memory) {
        return _lastCall;
    }
}

contract MockCoverPool {
    address public owner;
    address public feeRecipient;
    uint16 public poolFeeBps;

    bool private _permissive = true;

    constructor(address owner_, address feeRecipient_, uint16 poolFeeBps_) {
        owner = owner_;
        feeRecipient = feeRecipient_;
        poolFeeBps = poolFeeBps_;
    }

    function setPermissive(bool permissive) external {
        _permissive = permissive;
    }

    function hasBoundPolicy(uint96 policyId) external view returns (bool) {
        return _permissive && policyId != 0;
    }

    function getBoundPolicy(uint96 policyId) external view returns (ICoverPool.BoundPolicy memory policy) {
        if (!_permissive) {
            revert ICoverPool.PolicyNotFound(policyId);
        }
        policy.policyId = policyId;
    }
}
