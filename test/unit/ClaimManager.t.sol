// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {ClaimManager} from "../../src/ClaimManager.sol";
import {IClaimManager} from "../../src/interfaces/IClaimManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ISlashingManager} from "../../src/interfaces/ISlashingManager.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";

contract ClaimManagerTest is Test {
    uint96 internal constant POLICY_ID = 1;
    uint256 internal constant COVERAGE_LIMIT = 1000 ether;
    uint32 internal constant COVERAGE_DURATION = 30 days;
    uint256 internal constant SLASH_AMOUNT = 500 ether;
    address internal constant NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address internal admin;
    address internal claimer;
    address internal unauthorized;
    address internal specRegistry;
    address internal slashingManager;
    address internal swapper;
    address internal policy;
    address internal buyer;
    address internal beneficiary;
    address internal operator;
    address internal pool;
    address internal premiumToken;
    address internal payoutToken;
    address internal collateralToken;

    ClaimManager internal claimManager;
    MockSpecRegistry internal specRegistryMock;
    MockSpec internal specMock;
    MockSlashingManager internal slashingManagerMock;
    MockSwapper internal swapperMock;
    MockPolicy internal policyMock;
    MockToken internal collateralTokenMock;
    MockToken internal payoutTokenMock;
    MockCoverPool internal mockPool;
    MockOraclePriceFeed internal oracleFeedMock;

    bytes32 internal evidenceHash;
    bytes32 internal policyCommit;

    event ClaimFiled(
        uint96 indexed policyId,
        uint256 indexed claimId,
        address indexed reporter,
        bytes32 evidenceHash,
        uint256 requestedAmount,
        uint256 timestamp
    );
    event ClaimApproved(
        uint96 indexed policyId,
        uint256 indexed claimId,
        address indexed beneficiary,
        uint256 payoutAmount,
        uint256 timestamp
    );
    event ClaimRejected(uint96 indexed policyId, uint256 indexed claimId, string reason, uint256 timestamp);
    event CollateralSwapped(
        uint96 indexed policyId,
        uint256 indexed claimId,
        address indexed collateralToken,
        uint256 collateralAmount,
        address payoutToken,
        uint256 payoutAmount
    );
    event SpecRegistrySet(address indexed specRegistry);
    event SlashingManagerSet(address indexed slashingManager);
    event SwapperSet(address indexed swapper);
    event PolicyManagerSet(address indexed policyManager);
    event MaxSwapSlippageBpsSet(uint16 maxSwapSlippageBps);
    event NextClaimApproved(uint96 indexed policyId, address indexed approver);
    event TokensRecovered(address indexed token, address indexed to, uint256 amount);
    event VaultExcludedFromSlashing(address indexed vault, address indexed token);
    event PremiumManagerSet(address indexed premiumManager);
    event OraclePriceFeedSet(address indexed oraclePriceFeed);
    event PriceDeviationToleranceBpsSet(uint16 priceDeviationToleranceBps);
    event SwapSurplusDistributed(
        uint96 indexed policyId, uint256 indexed claimId, address indexed payoutToken, uint256 surplusAmount
    );
    event SwapSurplusDistributionFailed(
        uint96 indexed policyId, uint256 indexed claimId, address indexed token, uint256 surplusAmount
    );

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/
    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        claimer = makeAddr("claimer");
        unauthorized = makeAddr("unauthorized");
        buyer = makeAddr("buyer");
        beneficiary = makeAddr("beneficiary");
        operator = makeAddr("operator");
        premiumToken = makeAddr("premiumToken");

        mockPool = new MockCoverPool(operator);
        pool = address(mockPool);

        vm.label(admin, "Admin");
        vm.label(claimer, "Claimer");
        vm.label(unauthorized, "Unauthorized");
        vm.label(buyer, "Buyer");
        vm.label(beneficiary, "Beneficiary");
        vm.label(operator, "Operator");
        vm.label(pool, "Pool");

        evidenceHash = keccak256("evidence-hash");
        policyCommit = keccak256("policy-commit");

        specMock = new MockSpec();
        specRegistryMock = new MockSpecRegistry(address(specMock));
        slashingManagerMock = new MockSlashingManager();
        swapperMock = new MockSwapper();
        policyMock = new MockPolicy();
        collateralTokenMock = new MockToken("Collateral", "COL");
        payoutTokenMock = new MockToken("Payout", "PAY");

        specRegistry = address(specRegistryMock);
        slashingManager = address(slashingManagerMock);
        swapper = address(swapperMock);
        policy = address(policyMock);
        collateralToken = address(collateralTokenMock);
        payoutToken = address(payoutTokenMock);

        vm.label(specRegistry, "SpecRegistry");
        vm.label(slashingManager, "SlashingManager");
        vm.label(swapper, "Swapper");
        vm.label(policy, "Policy");
        vm.label(collateralToken, "CollateralToken");
        vm.label(payoutToken, "PayoutToken");

        oracleFeedMock = new MockOraclePriceFeed();

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (admin, specRegistry, slashingManager, swapper, policy)),
            deployOpts
        );
        claimManager = ClaimManager(payable(proxy));

        vm.prank(admin);
        claimManager.initializeV2(address(oracleFeedMock), 300);

        vm.label(address(claimManager), "ClaimManager");
        vm.label(address(oracleFeedMock), "OraclePriceFeed");

        _setupDefaultPolicy();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/
    function test_initialize_WhenAdminZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager newClaimManager = ClaimManager(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        newClaimManager.initialize(address(0), specRegistry, slashingManager, swapper, policy);
    }

    function test_initialize_WhenSpecRegistryZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager newClaimManager = ClaimManager(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        newClaimManager.initialize(admin, address(0), slashingManager, swapper, policy);
    }

    function test_initialize_WhenSlashingManagerZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager newClaimManager = ClaimManager(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        newClaimManager.initialize(admin, specRegistry, address(0), swapper, policy);
    }

    function test_initialize_WhenSwapperZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager newClaimManager = ClaimManager(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        newClaimManager.initialize(admin, specRegistry, slashingManager, address(0), policy);
    }

    function test_initialize_WhenPolicyZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager newClaimManager = ClaimManager(payable(address(new ERC1967Proxy(address(implementation), ""))));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        newClaimManager.initialize(admin, specRegistry, slashingManager, swapper, address(0));
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(claimManager.hasRole(claimManager.DEFAULT_ADMIN_ROLE(), admin));
        assertEq(claimManager.specRegistry(), specRegistry);
        assertEq(claimManager.slashingManager(), slashingManager);
        assertEq(claimManager.swapper(), swapper);
        assertEq(claimManager.policyManager(), policy);
    }

    function test_initialize_SetsDefaultMaxSwapSlippageBps() public view {
        assertEq(claimManager.maxSwapSlippageBps(), 200);
    }

    function test_initialize_WhenAlreadyInitialized_Reverts() public {
        vm.expectRevert();
        claimManager.initialize(admin, specRegistry, slashingManager, swapper, policy);
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZE V2
    //////////////////////////////////////////////////////////////*/

    function test_initializeV2_WhenZeroOraclePriceFeed_Reverts() public {
        ClaimManager impl = new ClaimManager();
        ClaimManager cm = ClaimManager(payable(address(new ERC1967Proxy(address(impl), ""))));
        cm.initialize(admin, specRegistry, slashingManager, swapper, policy);
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        cm.initializeV2(address(0), 300);
    }

    function test_initializeV2_WhenAboveDeviationBound_Reverts() public {
        ClaimManager impl = new ClaimManager();
        ClaimManager cm = ClaimManager(payable(address(new ERC1967Proxy(address(impl), ""))));
        cm.initialize(admin, specRegistry, slashingManager, swapper, policy);
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.InvalidDeviationBps.selector, uint16(1001)));
        cm.initializeV2(address(oracleFeedMock), 1001);
    }

    function test_initializeV2_WhenCalledTwice_Reverts() public {
        vm.expectRevert();
        claimManager.initializeV2(address(oracleFeedMock), 300);
    }

    function test_initializeV2_EmitsBothSetterEvents() public {
        ClaimManager impl = new ClaimManager();
        ClaimManager cm = ClaimManager(payable(address(new ERC1967Proxy(address(impl), ""))));
        cm.initialize(admin, specRegistry, slashingManager, swapper, policy);

        vm.expectEmit(true, false, false, false, address(cm));
        emit OraclePriceFeedSet(address(oracleFeedMock));
        vm.expectEmit(false, false, false, true, address(cm));
        emit PriceDeviationToleranceBpsSet(300);

        cm.initializeV2(address(oracleFeedMock), 300);
    }

    function test_initializeV2_PopulatesStateCorrectly() public view {
        assertEq(claimManager.oraclePriceFeed(), address(oracleFeedMock));
        assertEq(claimManager.priceDeviationToleranceBps(), 300);
    }

    /*//////////////////////////////////////////////////////////////
                    SET ORACLE PRICE FEED
    //////////////////////////////////////////////////////////////*/

    function test_setOraclePriceFeed_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setOraclePriceFeed(address(oracleFeedMock));
    }

    function test_setOraclePriceFeed_WhenZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setOraclePriceFeed(address(0));
    }

    function test_setOraclePriceFeed_EmitsEvent() public {
        address newFeed = makeAddr("newFeed");
        vm.expectEmit(true, false, false, false, address(claimManager));
        emit OraclePriceFeedSet(newFeed);
        vm.prank(admin);
        claimManager.setOraclePriceFeed(newFeed);
        assertEq(claimManager.oraclePriceFeed(), newFeed);
    }

    /*//////////////////////////////////////////////////////////////
               SET PRICE DEVIATION TOLERANCE BPS
    //////////////////////////////////////////////////////////////*/

    function test_setPriceDeviationToleranceBps_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setPriceDeviationToleranceBps(300);
    }

    function test_setPriceDeviationToleranceBps_WhenAboveBound_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.InvalidDeviationBps.selector, uint16(1001)));
        vm.prank(admin);
        claimManager.setPriceDeviationToleranceBps(1001);
    }

    function test_setPriceDeviationToleranceBps_WhenAtBound_Succeeds() public {
        vm.prank(admin);
        claimManager.setPriceDeviationToleranceBps(1000);
        assertEq(claimManager.priceDeviationToleranceBps(), 1000);
    }

    function test_setPriceDeviationToleranceBps_EmitsEvent() public {
        vm.expectEmit(false, false, false, true, address(claimManager));
        emit PriceDeviationToleranceBpsSet(500);
        vm.prank(admin);
        claimManager.setPriceDeviationToleranceBps(500);
        assertEq(claimManager.priceDeviationToleranceBps(), 500);
    }

    /*//////////////////////////////////////////////////////////////
                  PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/
    function test_pause_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.pause();
    }

    function test_pause_WhenCalledByAdmin_PausesContract() public {
        vm.prank(admin);
        claimManager.pause();
        assertTrue(claimManager.paused());
    }

    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.unpause();
    }

    function test_unpause_WhenCalledByAdmin_ClearsPause() public {
        vm.startPrank(admin);
        claimManager.pause();
        assertTrue(claimManager.paused());

        claimManager.unpause();
        assertFalse(claimManager.paused());
        vm.stopPrank();
    }

    function test_paused_WhenNotPaused_ReturnsFalse() public view {
        assertFalse(claimManager.paused());
    }

    function test_paused_WhenPaused_ReturnsTrue() public {
        vm.prank(admin);
        claimManager.pause();
        assertTrue(claimManager.paused());
    }

    /*//////////////////////////////////////////////////////////////
                            SET SPEC REGISTRY
    //////////////////////////////////////////////////////////////*/
    function test_setSpecRegistry_WhenCallerNotAdmin_Reverts() public {
        address newSpecRegistry = makeAddr("newSpecRegistry");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setSpecRegistry(newSpecRegistry);
    }

    function test_setSpecRegistry_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setSpecRegistry(address(0));
    }

    function test_setSpecRegistry_WhenValid_UpdatesState() public {
        address newSpecRegistry = makeAddr("newSpecRegistry");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit SpecRegistrySet(newSpecRegistry);

        vm.prank(admin);
        claimManager.setSpecRegistry(newSpecRegistry);

        assertEq(claimManager.specRegistry(), newSpecRegistry);
    }

    /*//////////////////////////////////////////////////////////////
                          SET SLASHING MANAGER
    //////////////////////////////////////////////////////////////*/
    function test_setSlashingManager_WhenCallerNotAdmin_Reverts() public {
        address newSlashingManager = makeAddr("newSlashingManager");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setSlashingManager(newSlashingManager);
    }

    function test_setSlashingManager_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setSlashingManager(address(0));
    }

    function test_setSlashingManager_WhenValid_UpdatesState() public {
        address newSlashingManager = makeAddr("newSlashingManager");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit SlashingManagerSet(newSlashingManager);

        vm.prank(admin);
        claimManager.setSlashingManager(newSlashingManager);

        assertEq(claimManager.slashingManager(), newSlashingManager);
    }

    /*//////////////////////////////////////////////////////////////
                               SET SWAPPER
    //////////////////////////////////////////////////////////////*/
    function test_setSwapper_WhenCallerNotAdmin_Reverts() public {
        address newSwapper = makeAddr("newSwapper");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setSwapper(newSwapper);
    }

    function test_setSwapper_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setSwapper(address(0));
    }

    function test_setSwapper_WhenValid_UpdatesState() public {
        address newSwapper = makeAddr("newSwapper");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit SwapperSet(newSwapper);

        vm.prank(admin);
        claimManager.setSwapper(newSwapper);

        assertEq(claimManager.swapper(), newSwapper);
    }

    /*//////////////////////////////////////////////////////////////
                           SET POLICY MANAGER
    //////////////////////////////////////////////////////////////*/
    function test_setPolicyManager_WhenCallerNotAdmin_Reverts() public {
        address newPolicyManager = makeAddr("newPolicyManager");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setPolicyManager(newPolicyManager);
    }

    function test_setPolicyManager_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setPolicyManager(address(0));
    }

    function test_setPolicyManager_WhenValid_UpdatesState() public {
        address newPolicyManager = makeAddr("newPolicyManager");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit PolicyManagerSet(newPolicyManager);

        vm.prank(admin);
        claimManager.setPolicyManager(newPolicyManager);

        assertEq(claimManager.policyManager(), newPolicyManager);
    }

    /*//////////////////////////////////////////////////////////////
                        SET MAX SWAP SLIPPAGE BPS
    //////////////////////////////////////////////////////////////*/
    function test_setMaxSwapSlippageBps_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setMaxSwapSlippageBps(500);
    }

    function test_setMaxSwapSlippageBps_WhenValueAtMaximum_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.InvalidSlippageBps.selector, uint16(10_000)));
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(10_000);
    }

    function test_setMaxSwapSlippageBps_WhenValueExceedsMaximum_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.InvalidSlippageBps.selector, uint16(10_001)));
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(10_001);
    }

    function test_setMaxSwapSlippageBps_WhenAboveMaxSettable_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.InvalidSlippageBps.selector, uint16(3001)));
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(3001);
    }

    function test_setMaxSwapSlippageBps_WhenMaxMinusOne_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.InvalidSlippageBps.selector, uint16(9999)));
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(9999);
    }

    function test_setMaxSwapSlippageBps_WhenAtMaxBound_Succeeds() public {
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(3000);
        assertEq(claimManager.maxSwapSlippageBps(), 3000);
    }

    function test_setMaxSwapSlippageBps_WhenValid_UpdatesStateAndEmitsEvent() public {
        uint16 newSlippage = 500;

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit MaxSwapSlippageBpsSet(newSlippage);

        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(newSlippage);

        assertEq(claimManager.maxSwapSlippageBps(), newSlippage);
    }

    function test_setMaxSwapSlippageBps_WhenZero_UpdatesState() public {
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(0);
        assertEq(claimManager.maxSwapSlippageBps(), 0);
    }

    function test_premiumManager_InitiallyZeroAddress() public view {
        assertEq(claimManager.premiumManager(), address(0));
    }

    function test_setPremiumManager_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setPremiumManager(makeAddr("premiumManager"));
    }

    function test_setPremiumManager_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setPremiumManager(address(0));
    }

    function test_setPremiumManager_WhenValid_UpdatesStateAndEmitsEvent() public {
        address newPremiumManager = makeAddr("newPremiumManager");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit PremiumManagerSet(newPremiumManager);

        vm.prank(admin);
        claimManager.setPremiumManager(newPremiumManager);

        assertEq(claimManager.premiumManager(), newPremiumManager);
    }

    /*//////////////////////////////////////////////////////////////
                           APPROVE NEXT CLAIM
    //////////////////////////////////////////////////////////////*/
    function test_claimApprovalRequired_WhenFreshPolicy_ReturnsFalse() public view {
        assertFalse(claimManager.claimApprovalRequired(POLICY_ID));
    }

    function test_approveNextClaim_ByCurator_AllowsNextClaim() public {
        _fileAndApproveClaim();

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit NextClaimApproved(POLICY_ID, operator);

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        assertFalse(claimManager.claimApprovalRequired(POLICY_ID));

        uint256 remainingCoverage = claimManager.remainingCoverage(POLICY_ID);

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = remainingCoverage;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), remainingCoverage);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), remainingCoverage);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(remainingCoverage);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, remainingCoverage, keccak256("evidence2"), "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
    }

    function test_approveNextClaim_ByAdmin_Reverts() public {
        _fileAndApproveClaim();

        vm.expectRevert(IClaimManager.UnauthorizedApprover.selector);
        vm.prank(admin);
        claimManager.approveNextClaim(POLICY_ID);
    }

    function test_approveNextClaim_WhenUnauthorized_Reverts() public {
        _fileAndApproveClaim();

        vm.expectRevert(IClaimManager.UnauthorizedApprover.selector);
        vm.prank(unauthorized);
        claimManager.approveNextClaim(POLICY_ID);
    }

    function test_approveNextClaim_WhenPolicyNotFound_Reverts() public {
        uint96 nonExistentPolicyId = 9999;
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.PolicyNotFound.selector, nonExistentPolicyId));
        vm.prank(operator);
        claimManager.approveNextClaim(nonExistentPolicyId);
    }

    function test_approveNextClaim_WhenNoApprovalRequired_Reverts() public {
        assertFalse(claimManager.claimApprovalRequired(POLICY_ID));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.NoApprovalPending.selector, POLICY_ID));
        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);
    }

    function test_approveNextClaim_WhenApprovalPending_ClearsFlag() public {
        _fileAndApproveClaim();
        assertTrue(claimManager.claimApprovalRequired(POLICY_ID));

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        assertFalse(claimManager.claimApprovalRequired(POLICY_ID));
    }

    function test_approveNextClaim_WhenPoolOwnershipTransfers_NewOwnerReverts() public {
        address newPoolOwner = makeAddr("newPoolOwner");
        MutableOwnerCoverPool mutablePool = new MutableOwnerCoverPool(operator);

        IPolicyManager.PolicyMetadata memory meta = _defaultMetadata();
        meta.pool = address(mutablePool);
        meta.curator = operator;
        policyMock.setPolicyMetadata(POLICY_ID, meta);

        _fileAndApproveClaim();
        assertTrue(claimManager.claimApprovalRequired(POLICY_ID));

        mutablePool.transferOwnership(newPoolOwner);
        assertEq(mutablePool.owner(), newPoolOwner);

        vm.expectRevert(IClaimManager.UnauthorizedApprover.selector);
        vm.prank(newPoolOwner);
        claimManager.approveNextClaim(POLICY_ID);
    }

    function test_approveNextClaim_WhenPoolOwnershipTransfers_OriginalCuratorSucceeds() public {
        address newPoolOwner = makeAddr("newPoolOwner");
        MutableOwnerCoverPool mutablePool = new MutableOwnerCoverPool(operator);

        IPolicyManager.PolicyMetadata memory meta = _defaultMetadata();
        meta.pool = address(mutablePool);
        meta.curator = operator;
        policyMock.setPolicyMetadata(POLICY_ID, meta);

        _fileAndApproveClaim();
        assertTrue(claimManager.claimApprovalRequired(POLICY_ID));

        mutablePool.transferOwnership(newPoolOwner);

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        assertFalse(claimManager.claimApprovalRequired(POLICY_ID));
    }

    /*//////////////////////////////////////////////////////////////
                             RECOVER TOKENS
    //////////////////////////////////////////////////////////////*/
    function test_receive_AcceptsNativeETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        uint256 balanceBefore = address(claimManager).balance;
        (bool sent,) = address(claimManager).call{value: amount}("");

        assertTrue(sent);
        assertEq(address(claimManager).balance, balanceBefore + amount);
    }

    function test_recoverTokens_ERC20_ByAdmin_Succeeds() public {
        uint256 amount = 100 ether;
        collateralTokenMock.mint(address(claimManager), amount);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit TokensRecovered(collateralToken, beneficiary, amount);

        vm.prank(admin);
        claimManager.recoverTokens(collateralToken, beneficiary, amount);

        assertEq(collateralTokenMock.balanceOf(beneficiary), amount);
        assertEq(collateralTokenMock.balanceOf(address(claimManager)), 0);
    }

    function test_recoverTokens_NativeETH_ByAdmin_Succeeds() public {
        uint256 amount = 2 ether;
        vm.deal(address(claimManager), amount);

        uint256 recipientBefore = beneficiary.balance;

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit TokensRecovered(NATIVE_ETH, beneficiary, amount);

        vm.prank(admin);
        claimManager.recoverTokens(NATIVE_ETH, beneficiary, amount);

        assertEq(address(claimManager).balance, 0);
        assertEq(beneficiary.balance, recipientBefore + amount);
    }

    function test_recoverTokens_WhenCallerNotAdmin_Reverts() public {
        collateralTokenMock.mint(address(claimManager), 1 ether);

        vm.expectRevert();
        vm.prank(unauthorized);
        claimManager.recoverTokens(collateralToken, beneficiary, 1 ether);
    }

    function test_recoverTokens_WhenTokenZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.recoverTokens(address(0), beneficiary, 1 ether);
    }

    function test_recoverTokens_WhenToZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.recoverTokens(collateralToken, address(0), 1 ether);
    }

    function test_recoverTokens_WhenAmountZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAmount.selector);
        vm.prank(admin);
        claimManager.recoverTokens(collateralToken, beneficiary, 0);
    }

    /*//////////////////////////////////////////////////////////////
           FILE CLAIM — ORACLE PROTECTION (CYS3-03)
    //////////////////////////////////////////////////////////////*/

    function test_fileClaim_WhenOraclePriceFeedUnset_RevertsOracleUnavailable() public {
        // Deploy a fresh ClaimManager that was never given initializeV2 (oraclePriceFeed == address(0))
        Options memory opts;
        opts.unsafeSkipAllChecks = true;
        address freshProxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (admin, specRegistry, slashingManager, swapper, policy)),
            opts
        );
        ClaimManager freshCm = ClaimManager(payable(freshProxy));

        // Wire policy to fresh proxy
        policyMock.setPolicyMetadata(POLICY_ID, _defaultMetadata());

        // collateralToken != payoutToken → cross-token path → OracleUnavailable (feed address is address(0))
        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.OracleUnavailable.selector, collateralToken, payoutToken));
        vm.prank(claimer);
        freshCm.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
    }

    function test_fileClaim_WhenOracleFeedMissingForCollateral_RevertsOracleUnavailable() public {
        oracleFeedMock.setFeedMissing(collateralToken);

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.OracleUnavailable.selector, collateralToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
    }

    function test_fileClaim_WhenOracleFeedMissingForPayoutToken_RevertsOracleUnavailable() public {
        oracleFeedMock.setFeedMissing(payoutToken);

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.OracleUnavailable.selector, collateralToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
    }

    function test_fileClaim_WhenOraclePriceStale_RevertsOracleUnavailable() public {
        oracleFeedMock.setShouldRevert(true);

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.OracleUnavailable.selector, collateralToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
    }

    function test_fileClaim_WhenDexQuoteDeviatesAboveTolerance_RevertsQuoteDeviatesFromOracle() public {
        // Configure a swapper where quoteSwap for collateralToken returns 5000 ether
        // but oracle fair value is 1:1 = SLASH_AMOUNT.
        // Deviation = (5000 ether - 500 ether) / 500 ether * 10000 = 90000 bps >> 300 bps tolerance.
        MockMultiSwapper deviatingSwapper = new MockMultiSwapper();
        deviatingSwapper.setQuoteOutput(collateralToken, 5000 ether); // quoteSwap returns 5000 ether
        deviatingSwapper.setSwapOutput(collateralToken, 5000 ether);
        deviatingSwapper.setPayoutToken(payoutToken);
        vm.prank(admin);
        claimManager.setSwapper(address(deviatingSwapper));

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        // oracleFair = SLASH_AMOUNT (1:1); dex = 5000 ether → huge upward deviation
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.QuoteDeviatesFromOracle.selector,
                collateralToken,
                payoutToken,
                uint256(5000 ether),
                uint256(SLASH_AMOUNT),
                uint256(90_000)
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
    }

    function test_fileClaim_WhenDexQuoteDeviatesBelowTolerance_RevertsQuoteDeviatesFromOracle() public {
        // Configure a swapper where quoteSwap for collateralToken returns 400 ether (20% below 500)
        // but oracle fair value is 1:1 = SLASH_AMOUNT = 500 ether.
        // Deviation = (500 - 400) / 500 * 10000 = 2000 bps >> 300 bps tolerance.
        MockMultiSwapper deviatingSwapper = new MockMultiSwapper();
        deviatingSwapper.setQuoteOutput(collateralToken, 400 ether); // quoteSwap returns 400 ether
        deviatingSwapper.setSwapOutput(collateralToken, 400 ether);
        deviatingSwapper.setPayoutToken(payoutToken);
        vm.prank(admin);
        claimManager.setSwapper(address(deviatingSwapper));

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.QuoteDeviatesFromOracle.selector,
                collateralToken,
                payoutToken,
                uint256(400 ether),
                uint256(SLASH_AMOUNT),
                uint256(2000)
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
    }

    function test_fileClaim_WhenDexQuoteWithinTolerance_SlashSizingUsesOracleFair() public {
        // DEX quote and oracle fair are both 1:1 (deviation = 0 bps → well within 300 bps tolerance).
        // Slash sizing uses payoutEquivalents[i] = _oracleFairValue(token, payout, stake) = stake.
        // The proportional slash is: baseSlash = stake * requested / stake = requested, inflated by slippage.
        uint256 stakeA = 300 ether;
        uint256 requestedAmount = 100 ether;

        // Default quoteSwap is 1:1; executeSwap mints requestedAmount to beneficiary.
        MockMultiSwapper multiSwap = new MockMultiSwapper();
        multiSwap.setSwapOutput(collateralToken, requestedAmount);
        multiSwap.setPayoutToken(payoutToken);
        vm.prank(admin);
        claimManager.setSwapper(address(multiSwap));

        // Single cross-token vault: stakeA of collateralToken
        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](1);
        pvaults[0] = makeAddr("vA");
        address[] memory ptokens = new address[](1);
        ptokens[0] = collateralToken;
        uint256[] memory pstakes = new uint256[](1);
        pstakes[0] = stakeA;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        // ~102 ether of collateral will be slashed (100 requested inflated by 2% slippage buffer)
        collateralTokenMock.mint(address(slashMock), stakeA);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);
        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(uint8(claimManager.claimRecord(POLICY_ID, claimId).status), uint8(IClaimManager.ClaimStatus.Approved));
        // Beneficiary receives up to requestedAmount (excess is surplus-distributed or stranded)
        assertGt(payoutTokenMock.balanceOf(beneficiary) - balanceBefore, 0, "Beneficiary should receive payout");
    }

    function test_fileClaim_WhenDexBelowFairWithinTolerance_AmountOutMinAnchoredToDex() public {
        // DEX 1.5% below fair → anchor = dex; amountOutMin = dex * (1 - slippage)
        // The swap should succeed because amountOutMin is achievable.
        uint256 dexQuote = (SLASH_AMOUNT * 9850) / 10_000; // 1.5% below

        MockMultiSwapper nearFairSwapper = new MockMultiSwapper();
        nearFairSwapper.setQuoteOutput(collateralToken, dexQuote); // quoteSwap returns dexQuote
        nearFairSwapper.setSwapOutput(collateralToken, dexQuote); // executeSwap also returns dexQuote
        nearFairSwapper.setPayoutToken(payoutToken);
        vm.prank(admin);
        claimManager.setSwapper(address(nearFairSwapper));

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
        assertEq(uint8(claimManager.claimRecord(POLICY_ID, claimId).status), uint8(IClaimManager.ClaimStatus.Approved));
    }

    function test_fileClaim_WhenDexAboveFairWithinTolerance_AmountOutMinAnchoredToFair() public {
        // DEX 1.5% above fair → anchor = fair; amountOutMin = fair * (1 - slippage)
        // The swap should succeed because the swap produces at least the fair-anchored minimum.
        uint256 dexQuote = (SLASH_AMOUNT * 10_150) / 10_000; // 1.5% above

        MockMultiSwapper aboveFairSwapper = new MockMultiSwapper();
        aboveFairSwapper.setQuoteOutput(collateralToken, dexQuote); // quoteSwap returns above-fair
        aboveFairSwapper.setSwapOutput(collateralToken, dexQuote); // executeSwap produces dexQuote
        aboveFairSwapper.setPayoutToken(payoutToken);
        vm.prank(admin);
        claimManager.setSwapper(address(aboveFairSwapper));

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
        assertEq(uint8(claimManager.claimRecord(POLICY_ID, claimId).status), uint8(IClaimManager.ClaimStatus.Approved));
    }

    function test_fileClaim_NativeEthCollateral_NormalizesToWrapperForOracle() public {
        // When the collateral is NATIVE_ETH, _oracleFairValue must query nativeWrapper not NATIVE_ETH.
        // Mark NATIVE_ETH as missing but nativeWrapper as present in the mock feed.
        address nativeWrapper = swapperMock.nativeWrapper();
        oracleFeedMock.setFeedMissing(NATIVE_ETH); // ensures we only pass via nativeWrapper path

        // Set up a policy where payoutToken == nativeWrapper so same-token path is taken for NATIVE_ETH
        // (after normalization, NATIVE_ETH → nativeWrapper == payoutToken → same-token path → no oracle needed)
        IPolicyManager.PolicyMetadata memory meta = _defaultMetadata();
        meta.payoutToken = nativeWrapper;
        meta.claimer = claimer;
        policyMock.setPolicyMetadata(POLICY_ID, meta);

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](1);
        pvaults[0] = makeAddr("ethVault");
        address[] memory ptokens = new address[](1);
        ptokens[0] = NATIVE_ETH;
        uint256[] memory pstakes = new uint256[](1);
        pstakes[0] = SLASH_AMOUNT;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        vm.deal(address(slashMock), SLASH_AMOUNT);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        // payoutToken == nativeWrapper; NATIVE_ETH normalizes to nativeWrapper → same-token path → no oracle needed
        // slashMock sends ETH; claimManager receives it and transfers to beneficiary (native ETH payout)
        // This test verifies that NATIVE_ETH → nativeWrapper normalization does NOT trigger OracleUnavailable
        // even when the NATIVE_ETH sentinel's feed is marked missing.
        vm.prank(claimer);
        // Expected: no OracleUnavailable revert (NATIVE_ETH → nativeWrapper → same-token path)
        // May revert for other reasons (native transfer), so just assert no oracle error:
        try claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "") {
        // success is fine
        }
        catch (bytes memory data) {
            bytes4 oracleSelector = IClaimManager.OracleUnavailable.selector;
            if (data.length >= 4) {
                bytes4 gotSelector;
                assembly {
                    gotSelector := mload(add(data, 0x20))
                }
                assertFalse(gotSelector == oracleSelector, "Should not revert OracleUnavailable for NATIVE_ETH");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               FILE CLAIM
    //////////////////////////////////////////////////////////////*/
    function test_fileClaim_WhenPaused_Reverts() public {
        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenCallerNotClaimer_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.UnauthorizedClaimer.selector, unauthorized, claimer));
        vm.prank(unauthorized);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenEvidenceHashZero_Reverts() public {
        vm.expectRevert(IClaimManager.InvalidEvidenceHash.selector);
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, bytes32(0), "");
    }

    function test_fileClaim_WhenDuplicateEvidenceHash_Reverts() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.DuplicateEvidenceHash.selector, POLICY_ID, evidenceHash));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
    }

    function test_fileClaim_WhenDuplicateEvidenceHashDifferentPolicy_Succeeds() public {
        uint96 policyId2 = 999;
        IPolicyManager.PolicyMetadata memory metadata2 = _defaultMetadata();
        metadata2.policyId = policyId2;
        metadata2.claimer = claimer;
        policyMock.setPolicyMetadata(policyId2, metadata2);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");

        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);

        vm.prank(claimer);
        uint256 claimId2 = claimManager.fileClaim(policyId2, SLASH_AMOUNT, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(policyId2, claimId2);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Second policy claim must succeed");
    }

    function test_fileClaim_WhenRejectedClaimEvidenceReused_Reverts() public {
        specMock.setEvaluationResult(false, keccak256("rejected"));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, 0);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected), "Claim should be rejected");

        specMock.setEvaluationResult(true, keccak256("approved"));
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.DuplicateEvidenceHash.selector, POLICY_ID, evidenceHash));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenRequestedAmountZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAmount.selector);
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 0, evidenceHash, "");
    }

    function test_fileClaim_WhenPolicyNotFound_Reverts() public {
        uint96 invalidPolicyId = 999;
        policyMock.setPolicyMetadata(
            invalidPolicyId,
            IPolicyManager.PolicyMetadata({
                buyer: address(0),
                policyId: 0,
                beneficiary: address(0),
                claimer: address(0),
                startTime: 0,
                maturityTime: 0,
                payoutToken: address(0),
                pool: address(0),
                curator: address(0),
                coverageLimit: 0,
                specId: bytes32(0),
                termsHash: bytes32(0),
                policyCommit: bytes32(0),
                premiumDefaulted: false
            })
        );

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.PolicyNotFound.selector, invalidPolicyId));
        vm.prank(claimer);
        claimManager.fileClaim(invalidPolicyId, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenRequestedAmountExceedsCoverage_Reverts() public {
        uint256 excessAmount = COVERAGE_LIMIT + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.RequestedAmountExceedsRemainingCoverage.selector, POLICY_ID, excessAmount, COVERAGE_LIMIT
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, excessAmount, evidenceHash, "");
    }

    function test_fileClaim_WhenBeforeCoverageWindow_Reverts() public {
        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.startTime = uint32(block.timestamp + 1 days);
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.ClaimOutsideCoverageWindow.selector,
                POLICY_ID,
                metadata.startTime,
                metadata.maturityTime,
                block.timestamp
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenAfterCoverageWindow_Reverts() public {
        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        vm.warp(metadata.maturityTime + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.ClaimOutsideCoverageWindow.selector,
                POLICY_ID,
                metadata.startTime,
                metadata.maturityTime,
                metadata.maturityTime + 1
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenSlashingReturnsNoCollateral_Reverts() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        slashingManagerMock.setSlashResult(tokens, amounts);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.NoCollateralSlashed.selector, POLICY_ID));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenPreviewSlashingReturnsMismatchedArrayLengths_Reverts() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory vaults = new address[](2);
        vaults[0] = makeAddr("vault0");
        vaults[1] = makeAddr("vault1");
        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = SLASH_AMOUNT;
        stakes[1] = SLASH_AMOUNT;

        vm.mockCall(
            address(slashingManagerMock),
            abi.encodeWithSelector(ISlashingManager.previewSlashing.selector),
            abi.encode(vaults, tokens, stakes)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.SlashingArrayLengthMismatch.selector, vaults.length, tokens.length, stakes.length
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenSlashingReturnsEmptyCollateral_Reverts() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        slashingManagerMock.setSlashResult(tokens, amounts);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.NoCollateralSlashed.selector, POLICY_ID));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenSpecRejects_RejectsAtomically() public {
        specMock.setEvaluationResult(false, keccak256("rejected"));

        vm.expectEmit(true, true, false, true, address(claimManager));
        emit ClaimFiled(POLICY_ID, 0, claimer, evidenceHash, COVERAGE_LIMIT, block.timestamp);

        vm.expectEmit(true, true, false, false, address(claimManager));
        emit ClaimRejected(POLICY_ID, 0, "Spec evaluation failed", block.timestamp);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected));
        assertEq(record.reporter, claimer);
        assertEq(record.filedAt, block.timestamp);
        assertEq(record.resolvedAt, block.timestamp);
    }

    function test_fileClaim_WhenSpecApproves_ExecutesPayoutAtomically() public {
        uint256 requestedAmount = 500 ether;
        uint256 swapOutput = 450 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(payoutToken);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit ClaimFiled(POLICY_ID, 0, claimer, evidenceHash, requestedAmount, block.timestamp);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit ClaimApproved(POLICY_ID, 0, beneficiary, swapOutput, block.timestamp);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
        assertEq(record.reporter, claimer);
        assertEq(record.filedAt, block.timestamp);
        assertEq(record.resolvedAt, block.timestamp);
        assertEq(record.payoutAmount, swapOutput);
    }

    function test_fileClaim_FilesAndResolvesInSameBlock() public {
        uint256 requestedAmount = 500 ether;
        uint256 swapOutput = 450 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);

        assertEq(record.filedAt, record.resolvedAt);
        assertEq(record.filedAt, block.timestamp);
    }

    function test_fileClaim_WhenCollateralMatchesPayoutToken_DirectlyTransfers() public {
        uint256 requestedAmount = 500 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);

        payoutTokenMock.mint(address(slashingManager), requestedAmount);
        slashingManagerMock.setTokenToTransfer(address(payoutTokenMock));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit CollateralSwapped(POLICY_ID, 0, payoutToken, requestedAmount, payoutToken, requestedAmount);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        uint256 balanceAfter = payoutTokenMock.balanceOf(beneficiary);
        assertEq(balanceAfter - balanceBefore, requestedAmount);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
    }

    function test_fileClaim_WhenSwapOutputExceedsRemainingPayout_BeneficiaryReceivesCappedAmount() public {
        uint256 requestedAmount = 500 ether;
        uint256 excessiveSwapOutput = 600 ether;
        uint256 excess = excessiveSwapOutput - requestedAmount;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(excessiveSwapOutput);
        swapperMock.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(swapperMock), excessiveSwapOutput);

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        uint256 balanceAfter = payoutTokenMock.balanceOf(beneficiary);
        assertEq(balanceAfter - balanceBefore, requestedAmount, "Beneficiary receives capped requestedAmount");
        assertEq(
            payoutTokenMock.balanceOf(address(claimManager)), excess, "Excess swap proceeds retained in ClaimManager"
        );

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "payoutAmount records capped amount");
    }

    function test_fileClaim_WhenDirectTransferExceedsRemainingPayout_CapsTransfer() public {
        uint256 requestedAmount = 300 ether;
        uint256 excessiveCollateral = 500 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = excessiveCollateral;
        slashingManagerMock.setSlashResult(tokens, amounts);

        payoutTokenMock.mint(address(slashingManager), excessiveCollateral);
        slashingManagerMock.setTokenToTransfer(address(payoutTokenMock));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        uint256 balanceAfter = payoutTokenMock.balanceOf(beneficiary);
        assertEq(balanceAfter - balanceBefore, requestedAmount);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount);
    }

    function test_fileClaim_WhenMultipleCollateralTokens_ProcessesAllTokens() public {
        uint256 requestedAmount = 900 ether;
        uint256 firstTokenAmount = 400 ether;
        uint256 secondTokenAmount = 600 ether;
        uint256 firstSwapOutput = 350 ether;
        uint256 secondSwapOutput = 550 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockToken collateralToken2Mock = new MockToken("Collateral2", "COL2");
        address collateralToken2 = address(collateralToken2Mock);
        vm.label(collateralToken2, "CollateralToken2");

        address[] memory tokens = new address[](2);
        tokens[0] = collateralToken;
        tokens[1] = collateralToken2;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = firstTokenAmount;
        amounts[1] = secondTokenAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), firstTokenAmount);
        collateralToken2Mock.mint(address(slashingManager), secondTokenAmount);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        slashingManagerMock.setToken2ToTransfer(address(collateralToken2Mock));

        MockMultiSwapper multiSwapper = new MockMultiSwapper();
        multiSwapper.setSwapOutput(collateralToken, firstSwapOutput);
        multiSwapper.setSwapOutput(collateralToken2, secondSwapOutput);
        // quoteSwap defaults to 1:1 (amountIn) — oracle deviation gate passes automatically.
        multiSwapper.setPayoutToken(payoutToken);
        vm.prank(admin);
        claimManager.setSwapper(address(multiSwapper));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit CollateralSwapped(POLICY_ID, 0, collateralToken, firstTokenAmount, payoutToken, firstSwapOutput);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit CollateralSwapped(POLICY_ID, 0, collateralToken2, secondTokenAmount, payoutToken, secondSwapOutput);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, firstSwapOutput + secondSwapOutput);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
    }

    function test_fileClaim_WhenQuoteSwapReverts_RevertsQuoteUnavailable() public {
        uint256 requestedAmount = 100 ether;
        uint256 quotableStake = 300 ether;
        uint256 unquotableStake = 200 ether;

        MockToken unquotableTokenMock = new MockToken("Unquotable", "UNQ");
        address unquotableToken = address(unquotableTokenMock);

        MockSwapperWithUnquotable unquotableSwapper = new MockSwapperWithUnquotable();
        unquotableSwapper.setQuoteReverts(unquotableToken);
        unquotableSwapper.setPayoutToken(payoutToken);
        unquotableSwapper.setSwapOutput(requestedAmount);
        vm.prank(admin);
        claimManager.setSwapper(address(unquotableSwapper));

        address vault1 = makeAddr("vault1");
        address vault2 = makeAddr("vault2");

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = vault1;
        pvaults[1] = vault2;
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = unquotableToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = quotableStake;
        pstakes[1] = unquotableStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(slashMock), quotableStake);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.QuoteUnavailable.selector, unquotableToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");
    }

    function test_fileClaim_WhenQuoteSwapReturnsZero_RevertsQuoteUnavailable() public {
        uint256 requestedAmount = 100 ether;
        uint256 quotableStake = 300 ether;
        uint256 zeroQuoteStake = 200 ether;

        MockToken zeroQuoteTokenMock = new MockToken("ZeroQuote", "ZQ");
        address zeroQuoteToken = address(zeroQuoteTokenMock);

        MockSwapperWithUnquotable zeroSwapper = new MockSwapperWithUnquotable();
        zeroSwapper.setQuoteReturnsZero(zeroQuoteToken);
        zeroSwapper.setPayoutToken(payoutToken);
        zeroSwapper.setSwapOutput(requestedAmount);
        vm.prank(admin);
        claimManager.setSwapper(address(zeroSwapper));

        address vault1 = makeAddr("vault1");
        address vault2 = makeAddr("vault2");

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = vault1;
        pvaults[1] = vault2;
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = zeroQuoteToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = quotableStake;
        pstakes[1] = zeroQuoteStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(slashMock), quotableStake);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.QuoteUnavailable.selector, zeroQuoteToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");
    }

    function test_fileClaim_WhenOneVaultUnquotable_RevertsQuoteUnavailable() public {
        MockToken unquotableTokenMock = new MockToken("Unquotable2", "UNQ2");
        address unquotableToken = address(unquotableTokenMock);

        MockSwapperWithUnquotable sw = new MockSwapperWithUnquotable();
        sw.setQuoteReverts(unquotableToken);
        sw.setPayoutToken(payoutToken);
        sw.setSwapOutput(100 ether);
        vm.prank(admin);
        claimManager.setSwapper(address(sw));

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("vault1");
        pvaults[1] = makeAddr("vault2");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = unquotableToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = 300 ether;
        pstakes[1] = 200 ether;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(slashMock), 300 ether);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.QuoteUnavailable.selector, unquotableToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 100 ether, evidenceHash, "");
    }

    function _setupTwoVaultScenarioWithUnquotable() private {
        MockToken unquotableTokenMock = new MockToken("Unquotable2", "UNQ2");
        address unquotableToken = address(unquotableTokenMock);

        MockSwapperWithUnquotable unquotableSwapper = new MockSwapperWithUnquotable();
        unquotableSwapper.setQuoteReverts(unquotableToken);
        unquotableSwapper.setPayoutToken(payoutToken);
        unquotableSwapper.setSwapOutput(100 ether);
        vm.prank(admin);
        claimManager.setSwapper(address(unquotableSwapper));

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("vaultA");
        pvaults[1] = makeAddr("vaultB");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = unquotableToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = 300 ether;
        pstakes[1] = 200 ether;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(slashMock), 300 ether);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));
    }

    function test_fileClaim_WhenMultiplePartialClaims_AllowsMultipleClaims() public {
        uint256 halfCoverage = COVERAGE_LIMIT / 2;
        bytes32 evidenceHash1 = keccak256("evidence-1");

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = halfCoverage;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), halfCoverage);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(halfCoverage);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, halfCoverage, evidenceHash1, "");

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        bytes32 evidenceHash2 = keccak256("evidence-2");
        collateralTokenMock.mint(address(slashingManager), halfCoverage);

        vm.prank(claimer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, halfCoverage, evidenceHash2, "");

        assertEq(claimId1, 0);
        assertEq(claimId2, 1);

        IClaimManager.ClaimRecord memory record1 = claimManager.claimRecord(POLICY_ID, claimId1);
        IClaimManager.ClaimRecord memory record2 = claimManager.claimRecord(POLICY_ID, claimId2);

        assertEq(uint8(record1.status), uint8(IClaimManager.ClaimStatus.Approved));
        assertEq(uint8(record2.status), uint8(IClaimManager.ClaimStatus.Approved));

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.totalPaidOut, COVERAGE_LIMIT);
        assertEq(state.claimCount, 2);

        assertEq(claimManager.remainingCoverage(POLICY_ID), 0);
    }

    function test_fileClaim_WhenPremiumDefaulted_Reverts() public {
        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.premiumDefaulted = true;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.PremiumDefaulted.selector, POLICY_ID));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 100 ether, evidenceHash, "");
    }

    function test_fileClaim_WhenPremiumDefaultCleared_Succeeds() public {
        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.premiumDefaulted = true;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.PremiumDefaulted.selector, POLICY_ID));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 100 ether, evidenceHash, "");

        metadata.premiumDefaulted = false;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        specMock.setEvaluationResult(true, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(100 ether);
        swapperMock.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(swapperMock), 100 ether);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, 100 ether, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
    }

    function test_fileClaim_MultipleClaimsExhaustCoverage_FinalClaimCapped() public {
        uint256 firstClaimAmount = COVERAGE_LIMIT / 2;
        uint256 secondClaimAmount = COVERAGE_LIMIT / 2;
        uint256 thirdClaimAmount = COVERAGE_LIMIT / 4;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = firstClaimAmount;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), firstClaimAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), firstClaimAmount);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(firstClaimAmount);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, firstClaimAmount, keccak256("evidence1"), "");

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        collateralTokenMock.mint(address(slashingManagerMock), secondClaimAmount);
        payoutTokenMock.mint(address(swapperMock), secondClaimAmount);
        swapperMock.setSwapOutput(secondClaimAmount);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, secondClaimAmount, keccak256("evidence2"), "");

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.RequestedAmountExceedsRemainingCoverage.selector, POLICY_ID, thirdClaimAmount, 0
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, thirdClaimAmount, keccak256("evidence3"), "");
    }

    function test_fileClaim_RemainingCoverageDecrementsCorrectly() public {
        uint256 firstClaimAmount = 300 ether;
        uint256 secondClaimAmount = 400 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = firstClaimAmount;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), firstClaimAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), firstClaimAmount);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(firstClaimAmount);

        uint256 remainingBefore = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remainingBefore, COVERAGE_LIMIT);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, firstClaimAmount, keccak256("evidence1"), "");

        uint256 remainingAfterFirst = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remainingAfterFirst, COVERAGE_LIMIT - firstClaimAmount);

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        collateralTokenMock.mint(address(slashingManagerMock), secondClaimAmount);
        payoutTokenMock.mint(address(swapperMock), secondClaimAmount);
        swapperMock.setSwapOutput(secondClaimAmount);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, secondClaimAmount, keccak256("evidence2"), "");

        uint256 remainingAfterSecond = claimManager.remainingCoverage(POLICY_ID);
        assertEq(
            remainingAfterSecond,
            COVERAGE_LIMIT - firstClaimAmount - secondClaimAmount,
            "Remaining should decrement after second claim"
        );
    }

    function test_fileClaim_ClaimsAcrossMultiplePolicies_IsolatedCoverage() public {
        uint96 policyId2 = 999;
        uint256 coverageLimit2 = 500 ether;

        IPolicyManager.PolicyMetadata memory metadata2 = _defaultMetadata();
        metadata2.policyId = policyId2;
        metadata2.coverageLimit = coverageLimit2;
        metadata2.claimer = claimer;
        policyMock.setPolicyMetadata(policyId2, metadata2);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COVERAGE_LIMIT / 2;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), COVERAGE_LIMIT / 2);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), COVERAGE_LIMIT / 2);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(COVERAGE_LIMIT / 2);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT / 2, keccak256("evidence1"), "");

        uint256 remaining2 = claimManager.remainingCoverage(policyId2);
        assertEq(remaining2, coverageLimit2);

        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = coverageLimit2 / 2;
        slashingManagerMock.setSlashResult(assets, amounts2);

        collateralTokenMock.mint(address(slashingManagerMock), coverageLimit2 / 2);
        payoutTokenMock.mint(address(swapperMock), coverageLimit2 / 2);
        swapperMock.setSwapOutput(coverageLimit2 / 2);

        vm.prank(claimer);
        claimManager.fileClaim(policyId2, coverageLimit2 / 2, keccak256("evidence2"), "");

        assertEq(
            claimManager.remainingCoverage(POLICY_ID),
            COVERAGE_LIMIT / 2,
            "First policy remaining should only reflect its own claims"
        );
        assertEq(
            claimManager.remainingCoverage(policyId2),
            coverageLimit2 / 2,
            "Second policy remaining should only reflect its own claims"
        );
    }

    function test_fileClaim_AtStartTime_Succeeds() public {
        IPolicyManager.PolicyMetadata memory metadata = policyMock.policyMetadata(POLICY_ID);

        vm.warp(metadata.startTime);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory claim = claimManager.claimRecord(POLICY_ID, claimId);
        assertTrue(claim.status == IClaimManager.ClaimStatus.Approved);
    }

    function test_fileClaim_BeforeMaturity_Succeeds() public {
        vm.warp(block.timestamp + (COVERAGE_DURATION / 2));

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory claim = claimManager.claimRecord(POLICY_ID, claimId);
        assertTrue(
            claim.status == IClaimManager.ClaimStatus.Approved, "Claim should be filed successfully before maturity"
        );
    }

    function test_fileClaim_AtMaturityTime_Reverts() public {
        IPolicyManager.PolicyMetadata memory metadata = policyMock.policyMetadata(POLICY_ID);

        vm.warp(metadata.maturityTime);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.ClaimOutsideCoverageWindow.selector,
                POLICY_ID,
                metadata.startTime,
                metadata.maturityTime,
                uint32(metadata.maturityTime)
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_OneSecondBeforeMaturity_Succeeds() public {
        IPolicyManager.PolicyMetadata memory metadata = policyMock.policyMetadata(POLICY_ID);

        vm.warp(metadata.maturityTime - 1);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory claim = claimManager.claimRecord(POLICY_ID, claimId);
        assertTrue(claim.status == IClaimManager.ClaimStatus.Approved);
    }

    function test_fileClaim_AfterMaturity_Reverts() public {
        IPolicyManager.PolicyMetadata memory metadata = policyMock.policyMetadata(POLICY_ID);

        vm.warp(metadata.maturityTime + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.ClaimOutsideCoverageWindow.selector,
                POLICY_ID,
                metadata.startTime,
                metadata.maturityTime,
                metadata.maturityTime + 1 days
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_OneSecondAfterMaturity_Reverts() public {
        IPolicyManager.PolicyMetadata memory metadata = policyMock.policyMetadata(POLICY_ID);

        vm.warp(metadata.maturityTime + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.ClaimOutsideCoverageWindow.selector,
                POLICY_ID,
                metadata.startTime,
                metadata.maturityTime,
                metadata.maturityTime + 1
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_SlashesCorrectCommitteeId() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        assertEq(slashingManagerMock.lastSlashedCommitteeId(), POLICY_ID);
    }

    function test_fileClaim_SlashingUsesCommitteeIdFromPolicy() public {
        uint96 customPolicyId = 456;
        IPolicyManager.PolicyMetadata memory customMetadata = _defaultMetadata();
        customMetadata.policyId = customPolicyId;
        customMetadata.claimer = claimer;
        policyMock.setPolicyMetadata(customPolicyId, customMetadata);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        claimManager.fileClaim(customPolicyId, COVERAGE_LIMIT, keccak256("evidence"), "");

        assertEq(
            slashingManagerMock.lastSlashedCommitteeId(),
            customPolicyId,
            "CommitteeId should equal policyId for slashing"
        );
    }

    function test_fileClaim_SlashAmountPassedToSlashingManager() public {
        uint256 customRequestedAmount = 300 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = customRequestedAmount;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManagerMock), customRequestedAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        payoutTokenMock.mint(address(swapperMock), customRequestedAmount);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(customRequestedAmount);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, customRequestedAmount, evidenceHash, "");

        assertEq(
            slashingManagerMock.lastSlashAmount(), customRequestedAmount, "Should use requested amount for slashing"
        );
    }

    function test_fileClaim_PassesCuratorAddressToSlashingManager() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        assertEq(slashingManagerMock.lastOperator(), operator, "Should pass pool curator/operator to SlashingManager");
    }

    function test_fileClaim_WhenQuoteVerySmall_AmountOutMinFlooredToOne() public {
        uint256 slashAmount = 1;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = slashAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), slashAmount);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        MockSwapperWithTracking trackingSwapper = new MockSwapperWithTracking();
        uint256 swapOutput = 1;
        trackingSwapper.setSwapOutput(swapOutput);
        trackingSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(trackingSwapper), swapOutput);

        vm.prank(admin);
        claimManager.setSwapper(address(trackingSwapper));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 1, evidenceHash, "");

        assertEq(trackingSwapper.lastAmountOutMin(), 1);
    }

    function test_fileClaim_WhenCustomSlippage_AmountOutMinIsAdjusted() public {
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(1000);

        uint256 requestedAmount = 500 ether;
        uint256 slashAmount = 500 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = slashAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), slashAmount);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        MockSwapperWithTracking trackingSwapper = new MockSwapperWithTracking();
        uint256 swapOutput = 460 ether;
        trackingSwapper.setSwapOutput(swapOutput);
        trackingSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(trackingSwapper), swapOutput);

        vm.prank(admin);
        claimManager.setSwapper(address(trackingSwapper));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        uint256 expectedAmountOutMin = slashAmount * (10_000 - 1000) / 10_000;
        assertEq(
            trackingSwapper.lastAmountOutMin(), expectedAmountOutMin, "amountOutMin does not reflect custom slippage"
        );
    }

    function test_fileClaim_WhenCrossTokenLargeStake_SlashInflatedToCompensateSlippage() public {
        uint256 requestedAmount = 100 ether;
        uint256 stake = 200 ether;

        uint16 slippageBps = claimManager.maxSwapSlippageBps();
        uint16 deviationBps = claimManager.priceDeviationToleranceBps();
        uint256 inflatedSlash = requestedAmount * 10_000 / (10_000 - slippageBps) * 10_000 / (10_000 - deviationBps);

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](1);
        pvaults[0] = makeAddr("vault");
        address[] memory ptokens = new address[](1);
        ptokens[0] = collateralToken;
        uint256[] memory pstakes = new uint256[](1);
        pstakes[0] = stake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(slashMock), inflatedSlash);

        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        uint256 worstCaseSwapOutput = inflatedSlash * (10_000 - slippageBps) / 10_000;
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(worstCaseSwapOutput);

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        uint256 received = payoutTokenMock.balanceOf(beneficiary) - balanceBefore;
        assertApproxEqAbs(received, requestedAmount, 1, "Beneficiary should receive full requestedAmount within 1 wei");
        assertGt(
            inflatedSlash, requestedAmount, "Slash must be inflated beyond requestedAmount when stake is sufficient"
        );
    }

    function test_fileClaim_WhenOracleOverestimatesDex_CompoundInflationCoversDeviationGap() public {
        uint256 requestedAmount = 100 ether;
        uint256 stake = 200 ether;

        oracleFeedMock.setPrice(collateralToken, 1_030_000_000_000_000_000); // oracle: 1.03 payout per collateral

        uint256 fair = stake * 1_030_000_000_000_000_000 / 1e18; // 206 ether (oracle fair for full stake)
        uint256 s = claimManager.maxSwapSlippageBps();
        uint256 d = claimManager.priceDeviationToleranceBps();
        uint256 inflatedSlash = stake * requestedAmount / fair * 10_000 / (10_000 - s) * 10_000 / (10_000 - d);
        assertGt(inflatedSlash, requestedAmount, "Compound inflation must exceed requestedAmount to cover oracle gap");

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](1);
        pvaults[0] = makeAddr("vault");
        address[] memory ptokens = new address[](1);
        ptokens[0] = collateralToken;
        uint256[] memory pstakes = new uint256[](1);
        pstakes[0] = stake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(slashMock), inflatedSlash);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(stake);

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - balanceBefore,
            requestedAmount,
            "Beneficiary must receive full requestedAmount despite oracle overestimation"
        );
        assertEq(
            collateralTokenMock.balanceOf(address(slashMock)),
            0,
            "All compound-inflated collateral must be transferred from slash mock"
        );
    }

    function test_fileClaim_WhenSwapProducesMoreThanRemainingPayout_SurplusDistributedAsRewards() public {
        uint256 requestedAmount = 100 ether;

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        {
            address[] memory pvaults = new address[](1);
            pvaults[0] = makeAddr("vault");
            address[] memory ptokens = new address[](1);
            ptokens[0] = collateralToken;
            uint256[] memory pstakes = new uint256[](1);
            pstakes[0] = 200 ether;
            slashMock.setupPreview(pvaults, ptokens, pstakes);
            collateralTokenMock.mint(
                address(slashMock),
                requestedAmount * 10_000 / (10_000 - claimManager.maxSwapSlippageBps()) * 10_000
                    / (10_000 - claimManager.priceDeviationToleranceBps())
            );
        }

        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        uint256 favorableSwapOutput = requestedAmount + 5 ether;
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(favorableSwapOutput);
        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 beneficiaryBefore = payoutTokenMock.balanceOf(beneficiary);
        uint256 claimManagerBefore = payoutTokenMock.balanceOf(address(claimManager));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - beneficiaryBefore,
            requestedAmount,
            "Beneficiary must receive exactly the claim amount"
        );
        assertEq(
            payoutTokenMock.balanceOf(address(claimManager)) - claimManagerBefore,
            0,
            "No payout tokens should remain stranded in ClaimManager"
        );
        assertEq(premiumMock.totalReceived(), 5 ether, "Surplus must be forwarded via PremiumManager");
        assertEq(premiumMock.lastPolicyId(), POLICY_ID, "PremiumManager must be called with the correct policyId");
        assertEq(premiumMock.lastCurator(), operator, "PremiumManager must be called with the pool curator");
        assertEq(
            claimManager.claimRecord(POLICY_ID, 0).payoutAmount,
            requestedAmount,
            "Claim payout accounting must be capped at requestedAmount"
        );
    }

    function test_fileClaim_WhenSwapProducesMoreThanRemainingPayout_NoPremiumManager_SurplusStranded() public {
        uint256 requestedAmount = 100 ether;
        uint256 stake = 200 ether;

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](1);
        pvaults[0] = makeAddr("vault");
        address[] memory ptokens = new address[](1);
        ptokens[0] = collateralToken;
        uint256[] memory pstakes = new uint256[](1);
        pstakes[0] = stake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        uint16 slippageBps = claimManager.maxSwapSlippageBps();
        uint16 deviationBps = claimManager.priceDeviationToleranceBps();
        uint256 inflatedSlash = requestedAmount * 10_000 / (10_000 - slippageBps) * 10_000 / (10_000 - deviationBps);
        collateralTokenMock.mint(address(slashMock), inflatedSlash);

        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        uint256 favorableSwapOutput = requestedAmount + 5 ether;
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(favorableSwapOutput);

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 claimManagerBefore = payoutTokenMock.balanceOf(address(claimManager));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        uint256 claimManagerGained = payoutTokenMock.balanceOf(address(claimManager)) - claimManagerBefore;
        assertEq(claimManagerGained, 5 ether, "Surplus stays in ClaimManager when premiumManager is not configured");
    }

    function test_fileClaim_WhenSwapProducesSurplus_EmitsSwapSurplusDistributedEvent() public {
        uint256 requestedAmount = 100 ether;
        uint256 stake = 200 ether;

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](1);
        pvaults[0] = makeAddr("vault");
        address[] memory ptokens = new address[](1);
        ptokens[0] = collateralToken;
        uint256[] memory pstakes = new uint256[](1);
        pstakes[0] = stake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        uint16 slippageBps = claimManager.maxSwapSlippageBps();
        uint16 deviationBps = claimManager.priceDeviationToleranceBps();
        uint256 inflatedSlash = requestedAmount * 10_000 / (10_000 - slippageBps) * 10_000 / (10_000 - deviationBps);
        collateralTokenMock.mint(address(slashMock), inflatedSlash);

        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        uint256 favorableSwapOutput = requestedAmount + 5 ether;
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(favorableSwapOutput);
        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit SwapSurplusDistributed(POLICY_ID, 0, payoutToken, 5 ether);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");
    }

    function test_fileClaim_WhenSwapExactlyMatchesRemainingPayout_PremiumManagerNotCalled() public {
        uint256 requestedAmount = 100 ether;

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), requestedAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(requestedAmount); // exactly matches — no surplus

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(premiumMock.totalReceived(), 0, "PremiumManager must not be called when there is no surplus");
        assertEq(payoutTokenMock.balanceOf(address(claimManager)), 0, "No tokens should remain in ClaimManager");
    }

    function test_fileClaim_WhenSwapProducesSurplusAndNativeETHPayoutToken_SurplusStaysInContract() public {
        uint256 requestedAmount = 10 ether;
        uint256 favorableSwapOutput = 12 ether;

        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutToken = NATIVE_ETH;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), requestedAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        swapperMock.setSwapOutput(favorableSwapOutput);
        swapperMock.setPayoutToken(NATIVE_ETH);
        vm.deal(address(swapperMock), favorableSwapOutput);

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        uint256 beneficiaryBefore = beneficiary.balance;
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            beneficiary.balance - beneficiaryBefore, requestedAmount, "Beneficiary receives exactly requestedAmount"
        );
        assertEq(premiumMock.totalReceived(), 0, "PremiumManager must not be called for native ETH surplus");
        assertEq(
            address(claimManager).balance,
            favorableSwapOutput - requestedAmount,
            "Native ETH surplus stays in ClaimManager (recoverable via recoverTokens)"
        );
    }

    function test_fileClaim_SecondClaimRequiresApproval() public {
        _fileAndApproveClaim();

        assertTrue(claimManager.claimApprovalRequired(POLICY_ID));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ClaimApprovalRequired.selector, POLICY_ID));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 1 ether, evidenceHash, "");
    }

    function test_fileClaim_AfterApprovalConsumed_RequiresApprovalAgain() public {
        _fileAndApproveClaim();

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = remaining / 2;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), remaining / 2);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), remaining / 2);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(remaining / 2);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, remaining / 2, keccak256("evidence2"), "");

        assertTrue(claimManager.claimApprovalRequired(POLICY_ID));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ClaimApprovalRequired.selector, POLICY_ID));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 1 ether, evidenceHash, "");
    }

    function test_fileClaim_WhenRejectedByClaim_DoesNotSetApprovalRequired() public {
        specMock.setEvaluationResult(false, keccak256("rejected"));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        assertFalse(
            claimManager.claimApprovalRequired(POLICY_ID), "Rejection should not set the approval-required flag"
        );

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, keccak256("evidence2"), "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected));
    }

    function test_fileClaim_WhenNativeETHCollateralEqualsPayoutToken_DirectTransfersETH() public {
        uint256 claimAmount = 500 ether;

        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutToken = NATIVE_ETH;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = NATIVE_ETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claimAmount;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.deal(address(slashingManagerMock), claimAmount);
        slashingManagerMock.setTokenToTransfer(NATIVE_ETH);

        uint256 balanceBefore = beneficiary.balance;

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, claimAmount, evidenceHash, "");

        assertEq(beneficiary.balance - balanceBefore, claimAmount);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
        assertEq(record.payoutAmount, claimAmount);
    }

    function test_fileClaim_WhenNativeETHDirectTransfer_CapsAtRemainingPayout() public {
        uint256 requestedAmount = 300 ether;
        uint256 excessiveCollateral = 500 ether;

        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutToken = NATIVE_ETH;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = NATIVE_ETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = excessiveCollateral;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.deal(address(slashingManagerMock), excessiveCollateral);
        slashingManagerMock.setTokenToTransfer(NATIVE_ETH);

        uint256 balanceBefore = beneficiary.balance;

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(beneficiary.balance - balanceBefore, requestedAmount);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount);
    }

    function test_fileClaim_WhenNativeETHCollateral_SwapsToERC20Payout() public {
        uint256 claimAmount = 500 ether;
        uint256 swapOutput = 490 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = NATIVE_ETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claimAmount;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.deal(address(slashingManagerMock), claimAmount);
        slashingManagerMock.setTokenToTransfer(NATIVE_ETH);

        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(payoutToken);

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, claimAmount, evidenceHash, "");

        assertEq(payoutTokenMock.balanceOf(beneficiary) - balanceBefore, swapOutput);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
        assertEq(record.payoutAmount, swapOutput);
    }

    function test_fileClaim_WhenERC20Collateral_SwapsToNativeETHPayout() public {
        uint256 claimAmount = 500 ether;
        uint256 swapOutput = 490 ether;

        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutToken = NATIVE_ETH;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claimAmount;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), claimAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(NATIVE_ETH);
        vm.deal(address(swapperMock), swapOutput);

        uint256 balanceBefore = beneficiary.balance;

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, claimAmount, evidenceHash, "");

        assertEq(beneficiary.balance - balanceBefore, swapOutput);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
        assertEq(record.payoutAmount, swapOutput);
    }

    function test_fileClaim_WhenMixedNativeETHAndERC20Collateral_ProcessesBoth() public {
        uint256 ethCollateralAmount = 200 ether;
        uint256 erc20CollateralAmount = 300 ether;
        uint256 ethSwapOutput = 195 ether;
        uint256 erc20SwapOutput = 290 ether;
        uint256 requestedAmount = ethSwapOutput + erc20SwapOutput;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](2);
        assets[0] = NATIVE_ETH;
        assets[1] = collateralToken;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = ethCollateralAmount;
        amounts[1] = erc20CollateralAmount;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.deal(address(slashingManagerMock), ethCollateralAmount);
        slashingManagerMock.setTokenToTransfer(NATIVE_ETH);
        collateralTokenMock.mint(address(slashingManagerMock), erc20CollateralAmount);
        slashingManagerMock.setToken2ToTransfer(collateralToken);

        MockNativeMultiSwapper nativeMultiSwapper = new MockNativeMultiSwapper();
        nativeMultiSwapper.setSwapOutput(NATIVE_ETH, ethSwapOutput);
        nativeMultiSwapper.setSwapOutput(collateralToken, erc20SwapOutput);
        // quoteSwap defaults to 1:1 (amountIn) — oracle deviation gate passes automatically.
        nativeMultiSwapper.setPayoutToken(payoutToken);
        vm.prank(admin);
        claimManager.setSwapper(address(nativeMultiSwapper));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - balanceBefore,
            ethSwapOutput + erc20SwapOutput,
            "Beneficiary should receive combined ERC20 payout"
        );

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
        assertEq(record.payoutAmount, ethSwapOutput + erc20SwapOutput);
    }

    function test_fileClaim_SlippageGuardCalculatedFromOracle() public {
        uint256 requestedAmount = 500 ether;
        uint256 swapOutput = 450 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), requestedAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(swapOutput);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(
            uint8(record.status),
            uint8(IClaimManager.ClaimStatus.Approved),
            "Claim must succeed within slippage tolerance"
        );
    }

    function test_fileClaim_MultiCollateralSlashingPaysoutCorrectly() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](2);
        tokens[0] = collateralToken;
        tokens[1] = payoutToken;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300 ether;
        amounts[1] = 200 ether;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), 300 ether);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(slashingManager), 200 ether);
        slashingManagerMock.setToken2ToTransfer(payoutToken);

        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(300 ether);

        uint256 beneficiaryBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, 500 ether, evidenceHash, "");

        IClaimManager.ClaimRecord memory claimRecord = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(
            uint8(claimRecord.status),
            uint8(IClaimManager.ClaimStatus.Approved),
            "Multi-collateral claim should succeed"
        );

        uint256 actualPayout = payoutTokenMock.balanceOf(beneficiary) - beneficiaryBefore;
        assertLe(actualPayout, 500 ether);
        assertGt(actualPayout, 0);
    }

    function test_fileClaim_WhenOneVaultUnquotable_RevertsWithQuoteUnavailable() public {
        uint256 requestedAmount = 400 ether;
        uint256 quotableStake = 500 ether;
        uint256 unquotableStake = 500 ether;

        MockToken unquotableTokenMock = new MockToken("Unquotable", "UNQ");
        address unquotableToken = address(unquotableTokenMock);

        MockSwapperWithUnquotable unquotableSwapper = new MockSwapperWithUnquotable();
        unquotableSwapper.setQuoteReverts(unquotableToken);
        unquotableSwapper.setPayoutToken(payoutToken);
        unquotableSwapper.setSwapOutput(requestedAmount);
        vm.prank(admin);
        claimManager.setSwapper(address(unquotableSwapper));

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("vault1");
        pvaults[1] = makeAddr("vault2");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = unquotableToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = quotableStake;
        pstakes[1] = unquotableStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(slashMock), quotableStake);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.QuoteUnavailable.selector, unquotableToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");
    }

    function test_fileClaim_WhenVaultQuoteReturnsZero_RevertsQuoteUnavailable() public {
        uint256 requestedAmount = 300 ether;
        uint256 quotableStake = 400 ether;
        uint256 zeroQuoteStake = 400 ether;

        MockToken zeroQuoteTokenMock = new MockToken("ZeroQuote", "ZQT");
        address zeroQuoteToken = address(zeroQuoteTokenMock);

        MockSwapperWithUnquotable partialSwapper = new MockSwapperWithUnquotable();
        partialSwapper.setQuoteReturnsZero(zeroQuoteToken);
        partialSwapper.setPayoutToken(payoutToken);
        partialSwapper.setSwapOutput(requestedAmount);
        vm.prank(admin);
        claimManager.setSwapper(address(partialSwapper));

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("vaultA");
        pvaults[1] = makeAddr("vaultB");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = zeroQuoteToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = quotableStake;
        pstakes[1] = zeroQuoteStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(slashMock), quotableStake);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.QuoteUnavailable.selector, zeroQuoteToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");
    }

    function test_fileClaim_WhenAllVaultsUnquotable_RevertsQuoteUnavailable() public {
        MockToken unquotableTokenMock = new MockToken("Unquotable2", "UNQ2");
        address unquotableToken = address(unquotableTokenMock);

        MockSwapperWithUnquotable revertSwapper = new MockSwapperWithUnquotable();
        revertSwapper.setQuoteReverts(unquotableToken);
        vm.prank(admin);
        claimManager.setSwapper(address(revertSwapper));

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](1);
        pvaults[0] = makeAddr("vaultOnly");
        address[] memory ptokens = new address[](1);
        ptokens[0] = unquotableToken;
        uint256[] memory pstakes = new uint256[](1);
        pstakes[0] = 500 ether;
        slashMock.setupPreview(pvaults, ptokens, pstakes);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.QuoteUnavailable.selector, unquotableToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenOneVaultUnquotableDex_RevertsBeforeExecuteSlashing() public {
        uint256 requestedAmount = 300 ether;
        uint256 quotableStake = 400 ether;

        MockToken unquotableTokenMock = new MockToken("Unquotable3", "UNQ3");
        address unquotableToken = address(unquotableTokenMock);

        MockSwapperWithUnquotable sw = new MockSwapperWithUnquotable();
        sw.setQuoteReverts(unquotableToken);
        sw.setPayoutToken(payoutToken);
        sw.setSwapOutput(requestedAmount);
        vm.prank(admin);
        claimManager.setSwapper(address(sw));

        MockSlashingManagerAssertingNoZeroAmounts assertingMock = new MockSlashingManagerAssertingNoZeroAmounts();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("quotableVault");
        pvaults[1] = makeAddr("unquotableVault");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = unquotableToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = quotableStake;
        pstakes[1] = 500 ether;
        assertingMock.setupPreview(pvaults, ptokens, pstakes);
        collateralTokenMock.mint(address(assertingMock), quotableStake);
        vm.prank(admin);
        claimManager.setSlashingManager(address(assertingMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        // Under the new oracle model, a missing DEX quote reverts the whole claim rather than
        // silently excluding the vault from slashing distribution.
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.QuoteUnavailable.selector, unquotableToken, payoutToken));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");
    }

    function test_fileClaim_WhenTinyVaultBaseSlashRoundsToZero_ExcludesCrossTokenVaultAndSucceeds() public {
        uint256 tinyStake = 1;
        uint256 largeStake = 1000 ether;
        uint256 requestedAmount = 1 ether;

        MockToken tinyTokenMock = new MockToken("TinyToken", "TINY");
        address tinyToken = address(tinyTokenMock);
        address tinyVaultAddr = makeAddr("tinyVault");

        vm.prank(admin);
        claimManager.setSwapper(address(swapperMock));
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(requestedAmount);

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = tinyVaultAddr;
        pvaults[1] = makeAddr("largeVault");
        address[] memory ptokens = new address[](2);
        ptokens[0] = tinyToken;
        ptokens[1] = collateralToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = tinyStake;
        pstakes[1] = largeStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        uint256 baseSlash = (largeStake * requestedAmount) / (tinyStake + largeStake);
        uint256 slippageDenom = 10_000 - claimManager.maxSwapSlippageBps();
        uint256 deviationDenom = 10_000 - claimManager.priceDeviationToleranceBps();
        uint256 expectedLargeSlash = (baseSlash * 10_000 * 10_000) / (slippageDenom * deviationDenom);
        collateralTokenMock.mint(address(slashMock), expectedLargeSlash);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectEmit(true, true, false, false, address(claimManager));
        emit VaultExcludedFromSlashing(tinyVaultAddr, tinyToken);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim should be approved");
    }

    function test_fileClaim_WhenDexQuoteDeviatesFromOracleByPerTokenDivisor_RevertsQuoteDeviatesFromOracle() public {
        (address tinyVaultAddr, address tinyToken) = _setupTinyBaseSlashWithRealisticQuoter();
        // Silence unused variable warning
        tinyVaultAddr;

        specMock.setEvaluationResult(true, keccak256("approved"));

        // The MockSwapperWithPerTokenDivisor divides the quote by 1001, so for tinyStake=1001:
        // dex = 1001 / 1001 = 1; oracleFair = 1001 (1:1 mock).
        // Deviation = (1000 / 1001) * 10000 ≈ 9990 bps > priceDeviationToleranceBps(300) → revert.
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.QuoteDeviatesFromOracle.selector,
                tinyToken,
                payoutToken,
                uint256(1), // dex quote (1001/1001)
                uint256(1001), // oracle fair (1:1)
                uint256(9990) // actual deviationBps
            )
        );
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 1 ether, evidenceHash, "");
    }

    function _setupTinyBaseSlashWithRealisticQuoter() private returns (address tinyVaultAddr, address tinyToken) {
        uint256 DIVISOR = 1001;
        uint256 tinyStake = 1001;
        uint256 largeStake = 2002 ether;
        uint256 requestedAmount = 1 ether;

        MockToken tinyTokenMock = new MockToken("TinyToken2", "TINY2");
        tinyToken = address(tinyTokenMock);
        tinyVaultAddr = makeAddr("tinyVault2");

        MockSwapperWithPerTokenDivisor divSwapper = new MockSwapperWithPerTokenDivisor();
        divSwapper.setDivisor(tinyToken, DIVISOR);
        divSwapper.setPayoutToken(payoutToken);
        divSwapper.setSwapOutput(requestedAmount);
        vm.prank(admin);
        claimManager.setSwapper(address(divSwapper));

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = tinyVaultAddr;
        pvaults[1] = makeAddr("largeVault2");
        address[] memory ptokens = new address[](2);
        ptokens[0] = tinyToken;
        ptokens[1] = collateralToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = tinyStake;
        pstakes[1] = largeStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        uint256 totalEquiv = tinyStake / DIVISOR + largeStake;
        uint256 largeBaseSlash = (largeStake * requestedAmount) / totalEquiv;
        uint256 expectedLargeSlash = largeBaseSlash * 10_000 / (10_000 - claimManager.maxSwapSlippageBps()) * 10_000
            / (10_000 - claimManager.priceDeviationToleranceBps());
        collateralTokenMock.mint(address(slashMock), expectedLargeSlash);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));
    }

    function test_fileClaim_WhenSameTokenVaultUnderwater_CapsSlashAtVaultStake() public {
        uint256 vaultStake = 300 ether;
        uint256 requestedAmount = 500 ether;

        IPolicyManager.PolicyMetadata memory meta = _defaultMetadata();
        meta.payoutToken = payoutToken;
        policyMock.setPolicyMetadata(POLICY_ID, meta);

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](1);
        pvaults[0] = makeAddr("sameTokenVault");
        address[] memory ptokens = new address[](1);
        ptokens[0] = payoutToken;
        uint256[] memory pstakes = new uint256[](1);
        pstakes[0] = vaultStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        payoutTokenMock.mint(address(slashMock), vaultStake);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim should be approved");
        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - balanceBefore,
            vaultStake,
            "Payout must be capped at vault stake, not requested amount"
        );
    }

    function test_fileClaim_WhenMixedVaultsUnderwater_CapsEachVaultAtItsStake() public {
        uint256 sameTokenStake = 200 ether;
        uint256 crossTokenStake = 200 ether;
        uint256 requestedAmount = 600 ether;

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("sameTokenVault");
        pvaults[1] = makeAddr("crossTokenVault");
        address[] memory ptokens = new address[](2);
        ptokens[0] = payoutToken;
        ptokens[1] = collateralToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = sameTokenStake;
        pstakes[1] = crossTokenStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        payoutTokenMock.mint(address(slashMock), sameTokenStake);
        collateralTokenMock.mint(address(slashMock), crossTokenStake);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(crossTokenStake);

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim should be approved");
        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - balanceBefore,
            sameTokenStake + crossTokenStake,
            "Payout must equal total available stake across both vaults, not requested amount"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          SURPLUS DISTRIBUTION
    //////////////////////////////////////////////////////////////*/
    function test_fileClaim_WhenSameTokenVaultProducesSurplus_EmitsSwapSurplusDistributedEvent() public {
        uint256 requestedAmount = 100 ether;
        uint256 slashedAmount = 105 ether;
        uint256 expectedSurplus = slashedAmount - requestedAmount;

        address[] memory tokens = new address[](1);
        tokens[0] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = slashedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);
        payoutTokenMock.mint(address(slashingManagerMock), slashedAmount);
        slashingManagerMock.setTokenToTransfer(payoutToken);

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit SwapSurplusDistributed(POLICY_ID, 0, payoutToken, expectedSurplus);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(premiumMock.totalReceived(), expectedSurplus, "Surplus must be forwarded via PremiumManager");
        assertEq(
            payoutTokenMock.balanceOf(beneficiary), requestedAmount, "Beneficiary receives exactly requestedAmount"
        );
        assertEq(payoutTokenMock.balanceOf(address(claimManager)), 0, "No tokens should remain in ClaimManager");
    }

    function test_fileClaim_WhenSameTokenVaultProducesNoSurplus_PremiumManagerNotCalled() public {
        uint256 requestedAmount = 100 ether;

        address[] memory tokens = new address[](1);
        tokens[0] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);
        payoutTokenMock.mint(address(slashingManagerMock), requestedAmount);
        slashingManagerMock.setTokenToTransfer(payoutToken);

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            premiumMock.totalReceived(), 0, "PremiumManager must not be called when there is no same-token surplus"
        );
        assertEq(
            payoutTokenMock.balanceOf(beneficiary), requestedAmount, "Beneficiary receives exactly requestedAmount"
        );
        assertEq(payoutTokenMock.balanceOf(address(claimManager)), 0, "No tokens should remain in ClaimManager");
    }

    function test_fileClaim_WhenSameTokenVaultProducesSurplusAndNoPremiumManager_SurplusStranded() public {
        uint256 requestedAmount = 100 ether;
        uint256 slashedAmount = 105 ether;

        address[] memory tokens = new address[](1);
        tokens[0] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = slashedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);
        payoutTokenMock.mint(address(slashingManagerMock), slashedAmount);
        slashingManagerMock.setTokenToTransfer(payoutToken);

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 claimManagerBefore = payoutTokenMock.balanceOf(address(claimManager));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary), requestedAmount, "Beneficiary receives exactly requestedAmount"
        );
        assertEq(
            payoutTokenMock.balanceOf(address(claimManager)) - claimManagerBefore,
            slashedAmount - requestedAmount,
            "Surplus stays in ClaimManager when premiumManager is not configured"
        );
    }

    function test_fileClaim_WhenMultiVaultCrossTokenFavorableSwapLeavesSameTokenSurplus_DistributesSurplus() public {
        uint256 requestedAmount = 100 ether;
        uint256 crossTokenStake = 100 ether;
        uint256 sameTokenStake = 100 ether;
        uint256 crossSlash = 50 ether;
        uint256 sameSlash = 50 ether;
        uint256 crossSwapOutput = 70 ether;
        uint256 expectedSameTokenSurplus = sameSlash - (requestedAmount - crossSwapOutput); // 50 - 30 = 20

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("crossVault");
        pvaults[1] = makeAddr("sameVault");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = payoutToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = crossTokenStake;
        pstakes[1] = sameTokenStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(0);
        vm.prank(admin);
        claimManager.setPriceDeviationToleranceBps(0); // no inflation; test focuses on vault-skip behavior

        collateralTokenMock.mint(address(slashMock), crossSlash);
        payoutTokenMock.mint(address(slashMock), sameSlash);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(crossSwapOutput);

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit SwapSurplusDistributed(POLICY_ID, 0, payoutToken, expectedSameTokenSurplus);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            premiumMock.totalReceived(), expectedSameTokenSurplus, "Same-token surplus forwarded via PremiumManager"
        );
        assertEq(
            payoutTokenMock.balanceOf(beneficiary), requestedAmount, "Beneficiary receives exactly requestedAmount"
        );
        assertEq(payoutTokenMock.balanceOf(address(claimManager)), 0, "No tokens should remain in ClaimManager");
    }

    function test_fileClaim_WhenFirstVaultFullySatisfiesPayout_SecondVaultSameTokenRoutedAsSurplus() public {
        uint256 requestedAmount = 100 ether;
        uint256 stake = 100 ether;
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(0);
        vm.prank(admin);
        claimManager.setPriceDeviationToleranceBps(0); // no inflation; test focuses on vault-skip behavior

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("crossVault");
        pvaults[1] = makeAddr("sameVault");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = payoutToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = stake;
        pstakes[1] = stake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        collateralTokenMock.mint(address(slashMock), 50 ether);
        payoutTokenMock.mint(address(slashMock), 50 ether);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(requestedAmount);

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 beneficiaryBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - beneficiaryBefore,
            requestedAmount,
            "Beneficiary must receive exactly requestedAmount"
        );
        assertEq(
            premiumMock.totalReceived(), 50 ether, "Second vault same-token surplus must be routed to PremiumManager"
        );
        assertEq(
            payoutTokenMock.balanceOf(address(claimManager)),
            0,
            "No payout tokens remain in ClaimManager after surplus distribution"
        );
    }

    function test_fileClaim_WhenFirstVaultFullySatisfiesPayout_SecondVaultCrossTokenSkippedToAvoidSwapFailureRisk()
        public
    {
        uint256 requestedAmount = 100 ether;
        uint256 stake = 100 ether;
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(0);
        vm.prank(admin);
        claimManager.setPriceDeviationToleranceBps(0); // no inflation; test focuses on vault-skip behavior

        MockToken collateralToken2Mock = new MockToken("Collateral2", "COL2");
        address collateralToken2 = address(collateralToken2Mock);

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("vault1");
        pvaults[1] = makeAddr("vault2");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = collateralToken2;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = stake;
        pstakes[1] = stake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        collateralTokenMock.mint(address(slashMock), 50 ether);
        collateralToken2Mock.mint(address(slashMock), 50 ether);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        MockMultiSwapper multiSwapper = new MockMultiSwapper();
        multiSwapper.setSwapOutput(collateralToken, requestedAmount);
        multiSwapper.setSwapOutput(collateralToken2, requestedAmount);
        // quoteSwap defaults to 1:1 (amountIn) so oracle deviation gate passes automatically.
        multiSwapper.setPayoutToken(payoutToken);
        vm.prank(admin);
        claimManager.setSwapper(address(multiSwapper));

        MockPremiumManagerForClaims premiumMock = new MockPremiumManagerForClaims();
        vm.prank(admin);
        claimManager.setPremiumManager(address(premiumMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 beneficiaryBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit IClaimManager.CrossTokenSurplusStranded(POLICY_ID, 0, collateralToken2, 50 ether);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - beneficiaryBefore,
            requestedAmount,
            "Beneficiary must receive exactly requestedAmount"
        );
        // Cross-token surplus entries are intentionally skipped when payout is already filled.
        // A surplus-only swap could revert (liquidity shift / price impact from the earlier swap)
        // and block an already-completed beneficiary payout. The stranded collateral remains
        // recoverable via recoverTokens().
        assertEq(premiumMock.totalReceived(), 0, "Cross-token surplus must not be attempted when payout is filled");
        assertEq(payoutTokenMock.balanceOf(address(claimManager)), 0, "No payout tokens remain in ClaimManager");
        assertEq(
            collateralToken2Mock.balanceOf(address(claimManager)),
            50 ether,
            "Cross-token surplus collateral stays in ClaimManager, recoverable via recoverTokens"
        );
    }

    function test_fileClaim_WhenFirstVaultFullySatisfiesPayout_SecondVaultSurplusStrandedWithoutPremiumManager()
        public
    {
        uint256 requestedAmount = 100 ether;
        uint256 stake = 100 ether;
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(0);
        vm.prank(admin);
        claimManager.setPriceDeviationToleranceBps(0); // no inflation; test focuses on vault-skip behavior

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("crossVault");
        pvaults[1] = makeAddr("sameVault");
        address[] memory ptokens = new address[](2);
        ptokens[0] = collateralToken;
        ptokens[1] = payoutToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = stake;
        pstakes[1] = stake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        collateralTokenMock.mint(address(slashMock), 50 ether);
        payoutTokenMock.mint(address(slashMock), 50 ether);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(requestedAmount);

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 beneficiaryBefore = payoutTokenMock.balanceOf(beneficiary);
        uint256 claimManagerBefore = payoutTokenMock.balanceOf(address(claimManager));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit IClaimManager.SameTokenSurplusStranded(POLICY_ID, 0, payoutToken, 50 ether);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - beneficiaryBefore,
            requestedAmount,
            "Beneficiary must receive exactly requestedAmount"
        );
        assertEq(
            payoutTokenMock.balanceOf(address(claimManager)) - claimManagerBefore,
            50 ether,
            "Second vault surplus stays in ClaimManager when no PremiumManager is configured"
        );
    }

    function test_fileClaim_WhenDistributeSurplusAsRewardsRevertsOnCrossTokenPath_ClaimCompletesAndEmitsFailureEvent()
        public
    {
        uint256 requestedAmount = 100 ether;

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        {
            address[] memory pvaults = new address[](1);
            pvaults[0] = makeAddr("vault");
            address[] memory ptokens = new address[](1);
            ptokens[0] = collateralToken;
            uint256[] memory pstakes = new uint256[](1);
            pstakes[0] = 200 ether;
            slashMock.setupPreview(pvaults, ptokens, pstakes);
            collateralTokenMock.mint(
                address(slashMock),
                requestedAmount * 10_000 / (10_000 - claimManager.maxSwapSlippageBps()) * 10_000
                    / (10_000 - claimManager.priceDeviationToleranceBps())
            );
        }
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        MockPremiumManagerReverting revertingMock = new MockPremiumManagerReverting();
        vm.prank(admin);
        claimManager.setPremiumManager(address(revertingMock));

        uint256 surplus = 5 ether;
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(requestedAmount + surplus);
        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit SwapSurplusDistributionFailed(POLICY_ID, 0, payoutToken, surplus);

        uint256 beneficiaryBefore = payoutTokenMock.balanceOf(beneficiary);
        uint256 claimManagerBefore = payoutTokenMock.balanceOf(address(claimManager));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - beneficiaryBefore,
            requestedAmount,
            "Beneficiary must still receive the full payout despite distributeRewards reverting"
        );
        assertEq(
            payoutTokenMock.balanceOf(address(claimManager)) - claimManagerBefore,
            surplus,
            "Surplus must stay in ClaimManager when distributeRewards reverts (recoverable via recoverTokens)"
        );
    }

    function test_fileClaim_WhenDistributeSurplusAsRewardsRevertsOnSameTokenPath_ClaimCompletesAndEmitsFailureEvent()
        public
    {
        uint256 requestedAmount = 100 ether;
        uint256 slashedAmount = 105 ether;
        uint256 surplus = slashedAmount - requestedAmount;

        address[] memory tokens = new address[](1);
        tokens[0] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = slashedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);
        payoutTokenMock.mint(address(slashingManagerMock), slashedAmount);
        slashingManagerMock.setTokenToTransfer(payoutToken);

        MockPremiumManagerReverting revertingMock = new MockPremiumManagerReverting();
        vm.prank(admin);
        claimManager.setPremiumManager(address(revertingMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit SwapSurplusDistributionFailed(POLICY_ID, 0, payoutToken, surplus);

        uint256 beneficiaryBefore = payoutTokenMock.balanceOf(beneficiary);
        uint256 claimManagerBefore = payoutTokenMock.balanceOf(address(claimManager));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - beneficiaryBefore,
            requestedAmount,
            "Beneficiary must still receive the full payout despite distributeRewards reverting"
        );
        assertEq(
            payoutTokenMock.balanceOf(address(claimManager)) - claimManagerBefore,
            surplus,
            "Surplus must stay in ClaimManager when distributeRewards reverts (recoverable via recoverTokens)"
        );
    }

    function test_fileClaim_WhenRequestedAmountTiny_DoesNotRevertWithNoCollateralSlashed() public {
        uint256 smallStake = 1;
        uint256 largeStake = 1_000_000;
        uint256 requestedAmount = 1;

        IPolicyManager.PolicyMetadata memory meta = _defaultMetadata();
        meta.payoutToken = payoutToken;
        policyMock.setPolicyMetadata(POLICY_ID, meta);

        MockSlashingManagerRespectingSlash slashMock = new MockSlashingManagerRespectingSlash();
        address[] memory pvaults = new address[](2);
        pvaults[0] = makeAddr("smallVault");
        pvaults[1] = makeAddr("largeVault");
        address[] memory ptokens = new address[](2);
        ptokens[0] = payoutToken;
        ptokens[1] = payoutToken;
        uint256[] memory pstakes = new uint256[](2);
        pstakes[0] = smallStake;
        pstakes[1] = largeStake;
        slashMock.setupPreview(pvaults, ptokens, pstakes);

        payoutTokenMock.mint(address(slashMock), smallStake + largeStake);
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashMock));

        specMock.setEvaluationResult(true, keccak256("approved"));

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim should be approved");
        assertGt(
            payoutTokenMock.balanceOf(beneficiary) - balanceBefore,
            0,
            "Beneficiary should receive a non-zero payout for a tiny but valid claim"
        );
    }

    function test_fileClaim_UsesMetadataCuratorNotLivePoolOwner() public {
        address snapshotCurator = makeAddr("snapshotCurator");
        address livePoolOwner = operator;
        assertNotEq(snapshotCurator, livePoolOwner, "precondition: curator must differ from live owner");

        IPolicyManager.PolicyMetadata memory meta = _defaultMetadata();
        meta.curator = snapshotCurator;
        policyMock.setPolicyMetadata(POLICY_ID, meta);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COVERAGE_LIMIT;
        slashingManagerMock.setSlashResult(assets, amounts);
        payoutTokenMock.mint(address(slashingManagerMock), COVERAGE_LIMIT);
        slashingManagerMock.setTokenToTransfer(payoutToken);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        assertEq(
            slashingManagerMock.lastOperator(),
            snapshotCurator,
            "executeSlashing must receive the snapshotted curator, not the live pool owner"
        );
        assertNotEq(
            slashingManagerMock.lastOperator(), livePoolOwner, "executeSlashing must not receive the live pool owner"
        );
    }

    function test_fileClaim_WhenPoolOwnershipTransfers_StillUsesOriginalCurator() public {
        address originalCurator = makeAddr("originalCurator");
        address newPoolOwner = makeAddr("newPoolOwner");
        MutableOwnerCoverPool mutablePool = new MutableOwnerCoverPool(originalCurator);

        IPolicyManager.PolicyMetadata memory meta = _defaultMetadata();
        meta.pool = address(mutablePool);
        meta.curator = originalCurator;
        policyMock.setPolicyMetadata(POLICY_ID, meta);

        mutablePool.transferOwnership(newPoolOwner);
        assertEq(mutablePool.owner(), newPoolOwner, "precondition: live owner must now be newPoolOwner");
        assertNotEq(newPoolOwner, originalCurator, "precondition: new owner must differ from original curator");

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COVERAGE_LIMIT;
        slashingManagerMock.setSlashResult(assets, amounts);
        payoutTokenMock.mint(address(slashingManagerMock), COVERAGE_LIMIT);
        slashingManagerMock.setTokenToTransfer(payoutToken);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        assertEq(
            slashingManagerMock.lastOperator(),
            originalCurator,
            "executeSlashing must use the original curator despite pool ownership transfer"
        );
        assertNotEq(slashingManagerMock.lastOperator(), newPoolOwner, "executeSlashing must not use the new pool owner");
    }

    function test_fileClaim_WhenApprovedClaimEvidenceReused_Reverts() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.DuplicateEvidenceHash.selector, POLICY_ID, evidenceHash));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, SLASH_AMOUNT, evidenceHash, "");
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM RECORD
    //////////////////////////////////////////////////////////////*/
    function test_claimRecord_WhenClaimNotFiled_ReturnsDefault() public view {
        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, 0);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.None));
        assertEq(record.reporter, address(0));
        assertEq(record.filedAt, 0);
        assertEq(record.resolvedAt, 0);
        assertEq(record.evidenceHash, bytes32(0));
        assertEq(record.payoutAmount, 0);
    }

    function test_claimRecord_AfterApprovedClaim_StoresCompleteData() public {
        uint256 requestedAmount = 350 ether;
        uint256 payoutAmount = 330 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(payoutAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved));
        assertEq(record.reporter, claimer);
        assertEq(record.evidenceHash, evidenceHash);
        assertEq(record.requestedAmount, requestedAmount);
        assertEq(record.payoutAmount, payoutAmount);
        assertEq(record.filedAt, block.timestamp);
        assertEq(record.resolvedAt, block.timestamp);
        assertTrue(record.evaluationResult.isPayable);
    }

    function test_claimRecord_AfterRejectedClaim_StoresRejectionData() public {
        specMock.setEvaluationResult(false, keccak256("rejected-reason"));

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected));
        assertEq(record.reporter, claimer);
        assertEq(record.evidenceHash, evidenceHash);
        assertEq(record.requestedAmount, COVERAGE_LIMIT);
        assertEq(record.payoutAmount, 0);
        assertEq(record.filedAt, block.timestamp);
        assertEq(record.resolvedAt, block.timestamp);
        assertFalse(record.evaluationResult.isPayable);
    }

    /*//////////////////////////////////////////////////////////////
                              POLICY CLAIM
    //////////////////////////////////////////////////////////////*/
    function test_policyClaim_WhenNoClaims_ReturnsDefaults() public view {
        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 0);
        assertEq(state.totalPaidOut, 0);
    }

    function test_policyClaim_AfterSuccessfulClaim_UpdatesState() public {
        uint256 requestedAmount = 400 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), requestedAmount);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(requestedAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 1);
        assertEq(state.totalPaidOut, requestedAmount);
    }

    function test_policyClaim_AfterRejectedClaim_IncrementsCountWithoutPayout() public {
        specMock.setEvaluationResult(false, keccak256("rejected"));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 1);
        assertEq(state.totalPaidOut, 0);
    }

    /*//////////////////////////////////////////////////////////////
                           REMAINING COVERAGE
    //////////////////////////////////////////////////////////////*/
    function test_remainingCoverage_WhenNoClaims_ReturnsFullCoverage() public view {
        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remaining, COVERAGE_LIMIT);
    }

    function test_remainingCoverage_AfterPartialClaim_ReturnsRemaining() public {
        uint256 firstClaim = 300 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = firstClaim;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), firstClaim);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(firstClaim);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, firstClaim, evidenceHash, "");

        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remaining, COVERAGE_LIMIT - firstClaim);
    }

    function test_remainingCoverage_AfterFullCoverageExhausted_ReturnsZero() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COVERAGE_LIMIT;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), COVERAGE_LIMIT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(COVERAGE_LIMIT);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remaining, 0);
    }

    function test_remainingCoverage_AfterRejectedClaim_Unchanged() public {
        specMock.setEvaluationResult(false, keccak256("rejected"));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remaining, COVERAGE_LIMIT);
    }

    function test_remainingCoverage_DecrementsCorrectlyAcrossClaims() public {
        uint256 firstClaimAmount = 300 ether;
        uint256 secondClaimAmount = 400 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = firstClaimAmount;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), firstClaimAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), firstClaimAmount);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(firstClaimAmount);

        assertEq(claimManager.remainingCoverage(POLICY_ID), COVERAGE_LIMIT);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, firstClaimAmount, keccak256("evidence1"), "");

        assertEq(claimManager.remainingCoverage(POLICY_ID), COVERAGE_LIMIT - firstClaimAmount);

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        collateralTokenMock.mint(address(slashingManagerMock), secondClaimAmount);
        payoutTokenMock.mint(address(swapperMock), secondClaimAmount);
        swapperMock.setSwapOutput(secondClaimAmount);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, secondClaimAmount, keccak256("evidence2"), "");

        assertEq(claimManager.remainingCoverage(POLICY_ID), COVERAGE_LIMIT - firstClaimAmount - secondClaimAmount);
    }

    function test_remainingCoverage_IsIsolatedAcrossPolicies() public {
        uint96 policyId2 = 999;
        uint256 coverageLimit2 = 500 ether;

        IPolicyManager.PolicyMetadata memory metadata2 = _defaultMetadata();
        metadata2.policyId = policyId2;
        metadata2.coverageLimit = coverageLimit2;
        metadata2.claimer = claimer;
        policyMock.setPolicyMetadata(policyId2, metadata2);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COVERAGE_LIMIT / 2;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), COVERAGE_LIMIT / 2);
        slashingManagerMock.setTokenToTransfer(collateralToken);
        payoutTokenMock.mint(address(swapperMock), COVERAGE_LIMIT / 2);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(COVERAGE_LIMIT / 2);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT / 2, keccak256("evidence1"), "");

        assertEq(claimManager.remainingCoverage(policyId2), coverageLimit2);

        uint256[] memory amounts2 = new uint256[](1);
        amounts2[0] = coverageLimit2 / 2;
        slashingManagerMock.setSlashResult(assets, amounts2);

        collateralTokenMock.mint(address(slashingManagerMock), coverageLimit2 / 2);
        payoutTokenMock.mint(address(swapperMock), coverageLimit2 / 2);
        swapperMock.setSwapOutput(coverageLimit2 / 2);

        vm.prank(claimer);
        claimManager.fileClaim(policyId2, coverageLimit2 / 2, keccak256("evidence2"), "");

        assertEq(claimManager.remainingCoverage(POLICY_ID), COVERAGE_LIMIT / 2);
        assertEq(claimManager.remainingCoverage(policyId2), coverageLimit2 / 2);
    }

    /*//////////////////////////////////////////////////////////////
                           AUTHORIZE UPGRADE
    //////////////////////////////////////////////////////////////*/
    function test_authorizeUpgrade_WhenCallerNotAdmin_Reverts() public {
        address newImplementation = address(new ClaimManager());

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.upgradeToAndCall(newImplementation, "");
    }

    function test_authorizeUpgrade_WhenCalledByAdmin_Succeeds() public {
        ClaimManager newImplementation = new ClaimManager();

        vm.prank(admin);
        claimManager.upgradeToAndCall(address(newImplementation), "");

        assertEq(claimManager.specRegistry(), specRegistry);
        assertEq(claimManager.slashingManager(), slashingManager);
        assertEq(claimManager.swapper(), swapper);
        assertEq(claimManager.policyManager(), policy);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/
    function _setupDefaultPolicy() private {
        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        policyMock.setPolicyMetadata(POLICY_ID, metadata);
    }

    function _defaultMetadata() private view returns (IPolicyManager.PolicyMetadata memory metadata) {
        metadata = IPolicyManager.PolicyMetadata({
            buyer: buyer,
            policyId: POLICY_ID,
            beneficiary: beneficiary,
            claimer: claimer,
            startTime: uint32(block.timestamp),
            maturityTime: uint32(block.timestamp + COVERAGE_DURATION),
            payoutToken: payoutToken,
            pool: pool,
            curator: operator,
            coverageLimit: COVERAGE_LIMIT,
            specId: keccak256("MorphoSpec"),
            termsHash: keccak256("terms-hash"),
            policyCommit: policyCommit,
            premiumDefaulted: false
        });
    }

    function _fileAndApproveClaim() private returns (uint256 claimId) {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManagerMock), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        payoutTokenMock.mint(address(swapperMock), SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);
        swapperMock.setSwapOutput(SLASH_AMOUNT);

        vm.prank(claimer);
        claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }
}

/*//////////////////////////////////////////////////////////////
                         MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockSpec is ISpec {
    EvaluationResult private _result;

    function setEvaluationResult(bool isPayable, bytes32 notesHash) external {
        _result = EvaluationResult({isPayable: isPayable, notesHash: notesHash});
    }

    function evaluate(EvaluationContext calldata) external view override returns (EvaluationResult memory) {
        return _result;
    }
}

contract MockSpecRegistry {
    address private immutable SPEC;

    constructor(address spec_) {
        SPEC = spec_;
    }

    function resolveSpec(address, bytes32) external view returns (ISpec) {
        return ISpec(SPEC);
    }
}

contract MockSlashingManager {
    address private constant _NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address[] private _assets;
    uint256[] private _amounts;
    address private _tokenToTransfer;
    address private _token2ToTransfer;
    uint96 public lastSlashedCommitteeId;
    address public lastOperator;
    uint256 public lastSlashAmount;

    receive() external payable {}

    /// @dev Also configures preview data from the same arrays (min-length safe).
    function setSlashResult(address[] memory assets, uint256[] memory amounts) external {
        _assets = assets;
        _amounts = amounts;
    }

    function setTokenToTransfer(address token) external {
        _tokenToTransfer = token;
    }

    function setToken2ToTransfer(address token) external {
        _token2ToTransfer = token;
    }

    /// @dev Returns preview using the same assets/amounts set via setSlashResult.
    ///      Uses min(assets.length, amounts.length) to stay safe with mismatched test data.
    function previewSlashing(
        uint96,
        address
    )
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        uint256 len = _assets.length < _amounts.length ? _assets.length : _amounts.length;
        vaults = new address[](len);
        tokens = new address[](len);
        tokenStakes = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            vaults[i] = address(uint160(i + 1));
            tokens[i] = _assets[i];
            tokenStakes[i] = _amounts[i];
        }
    }

    function executeSlashing(
        uint96 committeeId,
        address operator,
        ISlashingManager.VaultSlash[] memory vaultSlashes,
        bytes32 /*taskId*/
    )
        external
        returns (address[] memory, uint256[] memory)
    {
        lastSlashedCommitteeId = committeeId;
        lastOperator = operator;
        if (vaultSlashes.length > 0) lastSlashAmount = vaultSlashes[0].amount;

        if (_tokenToTransfer != address(0)) {
            if (_tokenToTransfer == _NATIVE_ETH) {
                (bool sent,) = msg.sender.call{value: address(this).balance}("");
                require(sent);
            } else {
                require(
                    MockToken(_tokenToTransfer)
                        .transfer(msg.sender, MockToken(_tokenToTransfer).balanceOf(address(this))),
                    "Transfer failed"
                );
            }
        }
        if (_token2ToTransfer != address(0)) {
            if (_token2ToTransfer == _NATIVE_ETH) {
                (bool sent,) = msg.sender.call{value: address(this).balance}("");
                require(sent);
            } else {
                require(
                    MockToken(_token2ToTransfer)
                        .transfer(msg.sender, MockToken(_token2ToTransfer).balanceOf(address(this))),
                    "Transfer failed"
                );
            }
        }
        return (_assets, _amounts);
    }
}

contract MockSwapper {
    address private constant _NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    uint256 private _swapOutput;
    address private _payoutToken;
    address public nativeWrapper = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH placeholder

    receive() external payable {}

    function setSwapOutput(uint256 output) external {
        _swapOutput = output;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    /// @dev Returns amountIn (1:1 ratio) so _computeVaultSlashes proportional math works in tests.
    function quoteSwap(address, address, uint256 amountIn) external pure returns (uint256) {
        return amountIn;
    }

    function executeSwap(ISwapper.SwapParams calldata params) external payable returns (uint256) {
        if (params.tokenIn != _NATIVE_ETH) {
            require(
                MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn),
                "TransferFrom failed"
            );
        }
        if (_payoutToken == _NATIVE_ETH) {
            (bool sent,) = params.recipient.call{value: _swapOutput}("");
            require(sent);
        } else if (_payoutToken != address(0)) {
            MockToken(_payoutToken).mint(params.recipient, _swapOutput);
        }
        return _swapOutput;
    }
}

contract MockPolicy {
    mapping(uint256 => IPolicyManager.PolicyMetadata) private _metadata;

    function setPolicyMetadata(uint96 policyId, IPolicyManager.PolicyMetadata memory metadata) external {
        _metadata[policyId] = metadata;
    }

    function policyMetadata(uint96 policyId) external view returns (IPolicyManager.PolicyMetadata memory) {
        return _metadata[policyId];
    }
}

/**
 * @dev Configurable oracle price feed mock.
 *      - All tokens default to a 1:1 price (price = 1e18).
 *      - `setFeedMissing(token)` makes hasPriceFeed return false and getUSDValue revert.
 *      - `setShouldRevert(true)` makes every external call revert (staleness simulation).
 *      - `setPrice(token, price)` overrides the per-token price (in 1e18 scale).
 */
contract MockOraclePriceFeed {
    mapping(address => uint256) private _pricePerToken;
    mapping(address => bool) private _feedMissing;
    bool private _shouldRevert;

    function setPrice(address token, uint256 price) external {
        _pricePerToken[token] = price;
    }

    function setFeedMissing(address token) external {
        _feedMissing[token] = true;
    }

    function setShouldRevert(bool shouldRevert_) external {
        _shouldRevert = shouldRevert_;
    }

    function hasPriceFeed(address token) external view returns (bool) {
        return !_feedMissing[token];
    }

    function getUSDValue(address token, uint256 amount) external view returns (uint256) {
        require(!_shouldRevert, "MockOraclePriceFeed: stale");
        require(!_feedMissing[token], "MockOraclePriceFeed: no feed");
        uint256 price = _pricePerToken[token];
        if (price == 0) {
            return amount; // 1:1 default
        }
        return (amount * price) / 1e18;
    }

    function getTokenAmount(address token, uint256 usdValue) external view returns (uint256) {
        require(!_shouldRevert, "MockOraclePriceFeed: stale");
        require(!_feedMissing[token], "MockOraclePriceFeed: no feed");
        uint256 price = _pricePerToken[token];
        if (price == 0) {
            return usdValue; // 1:1 default
        }
        return (usdValue * 1e18) / price;
    }
}

/**
 * @dev Multi-token swapper mock supporting separate quoteSwap and executeSwap outputs per token.
 *      - `setSwapOutput(token, amt)`: sets both quote and execution output (default: amountIn 1:1).
 *      - `setQuoteOutput(token, amt)`: overrides only the quoteSwap output independently of executeSwap.
 *      This allows tests to have quoteSwap return 1:1 (passing oracle deviation checks) while executeSwap
 *      returns a different amount (simulating actual swap price impact).
 */
contract MockMultiSwapper {
    mapping(address => uint256) private _swapOutputs;
    mapping(address => uint256) private _quoteOutputs;
    address private _payoutToken;
    address public nativeWrapper = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setSwapOutput(address tokenIn, uint256 output) external {
        _swapOutputs[tokenIn] = output;
    }

    /// @dev Separate quoteSwap amount — allows passing oracle validation (1:1 with oracle)
    ///      while executeSwap returns a different amount (simulating price impact).
    function setQuoteOutput(address tokenIn, uint256 output) external {
        _quoteOutputs[tokenIn] = output;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    /// @dev Returns _quoteOutputs if set, otherwise amountIn (1:1 default).
    ///      The 1:1 default ensures oracle deviation gate passes in tests that only configure executeSwap output.
    function quoteSwap(address tokenIn, address, uint256 amountIn) external view returns (uint256) {
        uint256 q = _quoteOutputs[tokenIn];
        if (q > 0) return q;
        return amountIn; // 1:1 default: consistent with oracle 1:1 mock
    }

    function executeSwap(ISwapper.SwapParams calldata params) external returns (uint256) {
        require(
            MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "TransferFrom failed"
        );
        uint256 output = _swapOutputs[params.tokenIn];
        if (_payoutToken != address(0) && output > 0) {
            MockToken(_payoutToken).mint(params.recipient, output);
        }
        return output;
    }
}

contract MockCoverPool {
    address private immutable _OWNER;

    constructor(address owner_) {
        _OWNER = owner_;
    }

    function owner() external view returns (address) {
        return _OWNER;
    }
}

/// @dev CoverPool mock whose owner can be changed after deployment, simulating a pool ownership transfer.
contract MutableOwnerCoverPool {
    address private _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function transferOwnership(address newOwner) external {
        _owner = newOwner;
    }
}

/**
 * @dev Swapper mock that makes quoteSwap revert or return 0 for configured tokens, simulating
 *      collateral tokens with no quote route.  executeSwap also reverts for those tokens so that
 *      any attempt to actually swap them (which should never happen after the fix) is caught.
 */
contract MockSwapperWithUnquotable {
    mapping(address => bool) private _revertOnQuote;
    mapping(address => bool) private _zeroOnQuote;
    address private _payoutToken;
    uint256 private _swapOutput;
    address public nativeWrapper = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setQuoteReverts(address token) external {
        _revertOnQuote[token] = true;
    }

    function setQuoteReturnsZero(address token) external {
        _zeroOnQuote[token] = true;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    function setSwapOutput(uint256 output) external {
        _swapOutput = output;
    }

    function quoteSwap(address tokenIn, address, uint256 amountIn) external view returns (uint256) {
        require(!_revertOnQuote[tokenIn], "MockSwapperWithUnquotable: quoteSwap reverts for this token");
        if (_zeroOnQuote[tokenIn]) return 0;
        return amountIn;
    }

    function executeSwap(ISwapper.SwapParams calldata params) external returns (uint256) {
        require(
            !_revertOnQuote[params.tokenIn] && !_zeroOnQuote[params.tokenIn],
            "MockSwapperWithUnquotable: executeSwap reverts for unquotable token"
        );
        require(
            MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "TransferFrom failed"
        );
        if (_payoutToken != address(0)) {
            MockToken(_payoutToken).mint(params.recipient, _swapOutput);
        }
        return _swapOutput;
    }
}

/**
 * @dev SlashingManager mock where executeSlashing honours the VaultSlash.amount values passed
 *      to it (rather than returning a pre-set constant).  This lets tests verify that unquotable
 *      vaults receive amount=0 and are therefore not transferred.
 */
contract MockSlashingManagerRespectingSlash {
    address[] private _previewVaults;
    address[] private _previewTokens;
    uint256[] private _previewStakes;

    function setupPreview(address[] memory vaults, address[] memory tokens, uint256[] memory stakes) external {
        _previewVaults = vaults;
        _previewTokens = tokens;
        _previewStakes = stakes;
    }

    function previewSlashing(
        uint96,
        address
    )
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        return (_previewVaults, _previewTokens, _previewStakes);
    }

    function executeSlashing(
        uint96,
        address,
        ISlashingManager.VaultSlash[] memory vaultSlashes,
        bytes32
    )
        external
        returns (address[] memory collateralTokens, uint256[] memory collateralAmounts)
    {
        uint256 len = vaultSlashes.length;
        collateralTokens = new address[](len);
        collateralAmounts = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            collateralTokens[i] = vaultSlashes[i].token;
            collateralAmounts[i] = vaultSlashes[i].amount;
            if (vaultSlashes[i].amount > 0) {
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                ERC20(vaultSlashes[i].token).transfer(msg.sender, vaultSlashes[i].amount);
            }
        }
    }
}

contract MockSwapperWithTracking {
    uint256 private _swapOutput;
    address private _payoutToken;
    uint256 public lastAmountOutMin;
    address public nativeWrapper = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setSwapOutput(uint256 output) external {
        _swapOutput = output;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    function quoteSwap(address, address, uint256 amountIn) external pure returns (uint256) {
        return amountIn;
    }

    function executeSwap(ISwapper.SwapParams calldata params) external returns (uint256) {
        lastAmountOutMin = params.amountOutMin;
        require(
            MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "TransferFrom failed"
        );
        if (_payoutToken != address(0)) {
            MockToken(_payoutToken).mint(params.recipient, _swapOutput);
        }
        return _swapOutput;
    }
}

contract MockNativeMultiSwapper {
    address private constant _NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    mapping(address => uint256) private _swapOutputs;
    mapping(address => uint256) private _quoteOutputs;
    address private _payoutToken;
    address public nativeWrapper = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    receive() external payable {}

    function setSwapOutput(address tokenIn, uint256 output) external {
        _swapOutputs[tokenIn] = output;
    }

    function setQuoteOutput(address tokenIn, uint256 output) external {
        _quoteOutputs[tokenIn] = output;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    /// @dev Returns _quoteOutputs if set, otherwise amountIn (1:1 default).
    function quoteSwap(address tokenIn, address, uint256 amountIn) external view returns (uint256) {
        uint256 q = _quoteOutputs[tokenIn];
        if (q > 0) return q;
        return amountIn; // 1:1 default
    }

    function executeSwap(ISwapper.SwapParams calldata params) external payable returns (uint256) {
        if (params.tokenIn != _NATIVE_ETH) {
            require(
                MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn),
                "TransferFrom failed"
            );
        }
        uint256 output = _swapOutputs[params.tokenIn];
        if (_payoutToken != address(0) && output > 0) {
            MockToken(_payoutToken).mint(params.recipient, output);
        }
        return output;
    }
}

/**
 * @dev SlashingManager mock that records the VaultSlash array and reverts if any entry has amount == 0.
 *      Used to assert that _computeVaultSlashes compacts zero-amount entries before calling executeSlashing.
 */
contract MockSlashingManagerAssertingNoZeroAmounts {
    address[] private _previewVaults;
    address[] private _previewTokens;
    uint256[] private _previewStakes;

    ISlashingManager.VaultSlash[] private _lastReceivedSlashes;

    function lastReceivedSlash(uint256 i) external view returns (ISlashingManager.VaultSlash memory) {
        return _lastReceivedSlashes[i];
    }

    function lastReceivedSlashCount() external view returns (uint256) {
        return _lastReceivedSlashes.length;
    }

    function setupPreview(address[] memory vaults, address[] memory tokens, uint256[] memory stakes) external {
        _previewVaults = vaults;
        _previewTokens = tokens;
        _previewStakes = stakes;
    }

    function previewSlashing(
        uint96,
        address
    )
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        return (_previewVaults, _previewTokens, _previewStakes);
    }

    function executeSlashing(
        uint96,
        address,
        ISlashingManager.VaultSlash[] memory vaultSlashes,
        bytes32
    )
        external
        returns (address[] memory collateralTokens, uint256[] memory collateralAmounts)
    {
        delete _lastReceivedSlashes;
        for (uint256 i = 0; i < vaultSlashes.length; ++i) {
            require(vaultSlashes[i].amount > 0, "MockSlashingManagerAssertingNoZeroAmounts: zero-amount entry received");
            _lastReceivedSlashes.push(vaultSlashes[i]);
        }

        uint256 len = vaultSlashes.length;
        collateralTokens = new address[](len);
        collateralAmounts = new uint256[](len);
        for (uint256 i = 0; i < len; ++i) {
            collateralTokens[i] = vaultSlashes[i].token;
            collateralAmounts[i] = vaultSlashes[i].amount;
            require(ERC20(vaultSlashes[i].token).transfer(msg.sender, vaultSlashes[i].amount));
        }
    }
}

/**
 * @dev Minimal PremiumManager mock that implements distributeSurplusAsRewards() by pulling tokens from the
 *      caller via safeTransferFrom, mirroring the real PremiumManager behaviour. Tracks the
 *      last call parameters and accumulates received tokens for assertion.
 */
contract MockPremiumManagerForClaims {
    using SafeERC20 for IERC20;

    uint96 public lastPolicyId;
    address public lastCurator;
    uint256 public totalReceived;

    function distributeSurplusAsRewards(
        uint96 policyId,
        address curator,
        uint256 amount,
        IERC20 token,
        bytes32
    )
        external
    {
        lastPolicyId = policyId;
        lastCurator = curator;
        token.safeTransferFrom(msg.sender, address(this), amount);
        totalReceived += amount;
    }
}

/**
 * @dev PremiumManager mock that always reverts on distributeSurplusAsRewards(), simulating a Core-side
 *      failure (e.g. duplicate taskId, paused state, or an upgrade regression).
 *      Used to verify that _distributeSurplus's try/catch allows the claim to complete.
 */
contract MockPremiumManagerReverting {
    function distributeSurplusAsRewards(uint96, address, uint256, IERC20, bytes32) external pure {
        revert("MockPremiumManagerReverting: always reverts");
    }
}

/**
 * @dev Swapper mock where quoteSwap applies a per-token integer divisor, simulating realistic
 *      DEX price ratios.  Tokens without an explicit divisor default to 1:1.
 *
 *      Purpose: reproduce the QuoteUnavailable-blocking-claim bug where a cross-token vault
 *      passes the first-pass inclusion check (quoteSwap(token, payout, fullStake) > 0) but
 *      its computed proportional baseSlash rounds to 0, which under the old code was forced
 *      to 1, causing quoteSwap(token, payout, 1) to return 0 and revert.
 */
contract MockSwapperWithPerTokenDivisor {
    address private constant _NATIVE_ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    mapping(address => uint256) private _divisors;
    address private _payoutToken;
    uint256 private _swapOutput;
    address public nativeWrapper = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    function setDivisor(address token, uint256 divisor) external {
        _divisors[token] = divisor;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    function setSwapOutput(uint256 output) external {
        _swapOutput = output;
    }

    /// @dev Returns amountIn / divisor (flooring), or amountIn when no divisor is set (1:1).
    function quoteSwap(address tokenIn, address, uint256 amountIn) external view returns (uint256) {
        uint256 d = _divisors[tokenIn];
        return d > 0 ? amountIn / d : amountIn;
    }

    function executeSwap(ISwapper.SwapParams calldata params) external returns (uint256) {
        require(
            MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "TransferFrom failed"
        );
        if (_payoutToken != address(0)) {
            MockToken(_payoutToken).mint(params.recipient, _swapOutput);
        }
        return _swapOutput;
    }
}
