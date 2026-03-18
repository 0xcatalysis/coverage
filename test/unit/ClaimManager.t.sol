// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
    uint256 internal constant BASE_PREMIUM = 100 ether;
    uint32 internal constant COVERAGE_DURATION = 30 days;
    uint256 internal constant SLASH_AMOUNT = 500 ether;

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

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(ClaimManager.initialize, (admin, specRegistry, slashingManager, swapper, policy)),
            deployOpts
        );
        claimManager = ClaimManager(proxy);

        vm.label(address(claimManager), "ClaimManager");

        _setupDefaultPolicy();
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(address(0), specRegistry, slashingManager, swapper, policy);
    }

    function test_initialize_WhenSpecRegistryZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(0), slashingManager, swapper, policy);
    }

    function test_initialize_WhenSlashingManagerZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, specRegistry, address(0), swapper, policy);
    }

    function test_initialize_WhenSwapperZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, specRegistry, slashingManager, address(0), policy);
    }

    function test_initialize_WhenPolicyZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, specRegistry, slashingManager, swapper, address(0));
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(claimManager.hasRole(claimManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertEq(claimManager.specRegistry(), specRegistry, "SpecRegistry mismatch");
        assertEq(claimManager.slashingManager(), slashingManager, "SlashingManager mismatch");
        assertEq(claimManager.swapper(), swapper, "Swapper mismatch");
        assertEq(claimManager.policyManager(), policy, "PolicyManager mismatch");
        assertFalse(claimManager.paused(), "Contract unexpectedly paused");
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
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
        assertTrue(claimManager.paused(), "Contract not paused");
    }

    /*//////////////////////////////////////////////////////////////
                                UNPAUSE
    //////////////////////////////////////////////////////////////*/

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
        assertTrue(claimManager.paused(), "Contract not paused");

        claimManager.unpause();
        assertFalse(claimManager.paused(), "Contract still paused");
        vm.stopPrank();
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

        assertEq(claimManager.specRegistry(), newSpecRegistry, "SpecRegistry not updated");
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

        assertEq(claimManager.slashingManager(), newSlashingManager, "SlashingManager not updated");
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

        assertEq(claimManager.swapper(), newSwapper, "Swapper not updated");
    }

    /*//////////////////////////////////////////////////////////////
                              SET POLICY
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

        assertEq(claimManager.policyManager(), newPolicyManager, "PolicyManager not updated");
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

    function test_setMaxSwapSlippageBps_WhenValid_UpdatesStateAndEmitsEvent() public {
        uint16 newSlippage = 500;

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit MaxSwapSlippageBpsSet(newSlippage);

        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(newSlippage);

        assertEq(claimManager.maxSwapSlippageBps(), newSlippage, "Slippage BPS not updated");
    }

    function test_setMaxSwapSlippageBps_WhenZero_UpdatesState() public {
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(0);
        assertEq(claimManager.maxSwapSlippageBps(), 0, "Slippage BPS should be 0");
    }

    function test_setMaxSwapSlippageBps_WhenMaxMinusOne_Succeeds() public {
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(9999);
        assertEq(claimManager.maxSwapSlippageBps(), 9999, "Slippage BPS should be 9999");
    }

    function test_setMaxSwapSlippageBps_AffectsAmountOutMin() public {
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
        uint256 swapOutput = 460 ether; // above amountOutMin of 450 ether
        trackingSwapper.setSwapOutput(swapOutput);
        trackingSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(trackingSwapper), swapOutput);

        vm.prank(admin);
        claimManager.setSwapper(address(trackingSwapper));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        uint256 expectedAmountOutMin = slashAmount * (10_000 - 1000) / 10_000; // 450 ether
        assertEq(
            trackingSwapper.lastAmountOutMin(), expectedAmountOutMin, "amountOutMin does not reflect custom slippage"
        );
    }

    function test_fileClaim_WhenQuoteSwapReturnsZero_AmountOutMinFlooredToOne() public {
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
        // _computeVaultSlashes makes 2 quoteSwap calls (payout-equivalent + slippage-inflation).
        // Return amountIn (1:1) for those, then return 0 for the 3rd call in _processCollateral
        // so that amountOutMin is floored to 1 rather than computed as 0.
        trackingSwapper.setQuoteSwapOutputAfterNCalls(0, 2);
        uint256 swapOutput = 1;
        trackingSwapper.setSwapOutput(swapOutput);
        trackingSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(trackingSwapper), swapOutput);

        vm.prank(admin);
        claimManager.setSwapper(address(trackingSwapper));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 1, evidenceHash, "");

        assertEq(trackingSwapper.lastAmountOutMin(), 1, "amountOutMin should be floored to 1 when quoteSwap returns 0");
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM RECORD
    //////////////////////////////////////////////////////////////*/

    function test_claimRecord_WhenClaimNotFiled_ReturnsDefault() public view {
        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, 0);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.None), "Status should be None");
        assertEq(record.reporter, address(0), "Reporter should be zero");
        assertEq(record.filedAt, 0, "FiledAt should be zero");
        assertEq(record.resolvedAt, 0, "ResolvedAt should be zero");
        assertEq(record.evidenceHash, bytes32(0), "EvidenceHash should be zero");
        assertEq(record.payoutAmount, 0, "PayoutAmount should be zero");
    }

    /*//////////////////////////////////////////////////////////////
                          POLICY CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_policyClaim_WhenNoClaims_ReturnsDefaults() public view {
        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 0, "ClaimCount should be 0");
        assertEq(state.totalPaidOut, 0, "TotalPaidOut should be 0");
    }

    /*//////////////////////////////////////////////////////////////
                        REMAINING COVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_remainingCoverage_WhenNoClaims_ReturnsFullCoverage() public view {
        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remaining, COVERAGE_LIMIT, "Should return full coverage limit");
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

    function test_fileClaim_WhenRequestedAmountZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAmount.selector);
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 0, evidenceHash, "");
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

        bytes32 evidenceHash2 = keccak256("evidence-2");
        collateralTokenMock.mint(address(slashingManager), halfCoverage);

        vm.prank(claimer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, halfCoverage, evidenceHash2, "");

        assertEq(claimId1, 0, "First claim should have ID 0");
        assertEq(claimId2, 1, "Second claim should have ID 1");

        IClaimManager.ClaimRecord memory record1 = claimManager.claimRecord(POLICY_ID, claimId1);
        IClaimManager.ClaimRecord memory record2 = claimManager.claimRecord(POLICY_ID, claimId2);

        assertEq(uint8(record1.status), uint8(IClaimManager.ClaimStatus.Approved), "First claim should be approved");
        assertEq(uint8(record2.status), uint8(IClaimManager.ClaimStatus.Approved), "Second claim should be approved");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.totalPaidOut, COVERAGE_LIMIT, "Total payout should equal coverage limit");
        assertEq(state.claimCount, 2, "Should have 2 claims");

        assertEq(claimManager.remainingCoverage(POLICY_ID), 0, "No coverage should remain");
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
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected), "Status should be Rejected");
        assertEq(record.reporter, claimer, "Reporter should be claimer");
        assertEq(record.filedAt, block.timestamp, "FiledAt mismatch");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
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
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Status should be Approved");
        assertEq(record.reporter, claimer, "Reporter should be claimer");
        assertEq(record.filedAt, block.timestamp, "FiledAt mismatch");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertEq(record.payoutAmount, swapOutput, "PayoutAmount mismatch");
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

        assertEq(record.filedAt, record.resolvedAt, "Filing and resolution should happen in same block");
        assertEq(record.filedAt, block.timestamp, "Timestamps should match current block");
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
                coverageLimit: 0,
                specId: bytes32(0),
                termsHash: bytes32(0),
                policyCommit: bytes32(0)
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
        assertEq(balanceAfter - balanceBefore, requestedAmount, "Should transfer collateral directly");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Payout should equal requested amount");
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim should be approved");
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
        assertEq(record.payoutAmount, firstSwapOutput + secondSwapOutput, "Payout should be sum of both swap outputs");
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim should be approved");
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

    function test_fileClaim_WhenSlashingReturnsEmptyCollateral_Reverts() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        slashingManagerMock.setSlashResult(tokens, amounts);

        // With all tokenStakes = 0, _computeVaultSlashes sees totalPayoutEquivalent = 0
        // and reverts with NoCollateralSlashed (before ever reaching executeSlashing).
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.NoCollateralSlashed.selector, POLICY_ID));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenSwapOutputExceedsRemainingPayout_CapsTransfer() public {
        uint256 requestedAmount = 500 ether;
        uint256 excessiveSwapOutput = 600 ether;

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

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        uint256 balanceAfter = payoutTokenMock.balanceOf(beneficiary);
        assertEq(balanceAfter - balanceBefore, requestedAmount, "Should cap transfer at requested amount");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Payout should be capped at requested amount");
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
        assertEq(balanceAfter - balanceBefore, requestedAmount, "Should cap direct transfer at requested amount");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Payout should be capped at requested amount");
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
        assertEq(remaining, COVERAGE_LIMIT - firstClaim, "Should return remaining coverage after partial claim");
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
        assertEq(remaining, 0, "Should return zero after full coverage exhausted");
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
        assertEq(state.claimCount, 1, "Claim count should be 1");
        assertEq(state.totalPaidOut, requestedAmount, "Total paid out should match requested amount");
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
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Status should be Approved");
        assertEq(record.reporter, claimer, "Reporter should be claimer");
        assertEq(record.evidenceHash, evidenceHash, "Evidence hash should match");
        assertEq(record.requestedAmount, requestedAmount, "Requested amount should match");
        assertEq(record.payoutAmount, payoutAmount, "Payout amount should match");
        assertEq(record.filedAt, block.timestamp, "Filed timestamp should match");
        assertEq(record.resolvedAt, block.timestamp, "Resolved timestamp should match");
        assertTrue(record.evaluationResult.isPayable, "Evaluation should show payable");
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

        assertEq(slashingManagerMock.lastSlashedCommitteeId(), POLICY_ID, "Should slash correct committeeId");
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

        assertEq(
            slashingManagerMock.lastBeneficiary(), operator, "Should pass pool curator/operator to SlashingManager"
        );
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

    function test_fileClaim_AtMaturityTime_Succeeds() public {
        IPolicyManager.PolicyMetadata memory metadata = policyMock.policyMetadata(POLICY_ID);

        vm.warp(metadata.maturityTime);

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
        assertTrue(claim.status == IClaimManager.ClaimStatus.Approved, "Claim should be filed at maturity time");
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

        collateralTokenMock.mint(address(slashingManagerMock), secondClaimAmount);
        payoutTokenMock.mint(address(swapperMock), secondClaimAmount);
        swapperMock.setSwapOutput(secondClaimAmount);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, secondClaimAmount, keccak256("evidence2"), "");

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
        assertEq(remainingBefore, COVERAGE_LIMIT, "Initial remaining should equal coverage limit");

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, firstClaimAmount, keccak256("evidence1"), "");

        uint256 remainingAfterFirst = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remainingAfterFirst, COVERAGE_LIMIT - firstClaimAmount, "Remaining should decrement after first claim");

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
        assertEq(remaining2, coverageLimit2, "Second policy coverage should be unaffected");

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
        assertTrue(claim.status == IClaimManager.ClaimStatus.Approved, "Claim should succeed at start time");
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
        assertTrue(claim.status == IClaimManager.ClaimStatus.Approved, "Claim should succeed before maturity");
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

        assertEq(claimManager.specRegistry(), specRegistry, "SpecRegistry should be preserved");
        assertEq(claimManager.slashingManager(), slashingManager, "SlashingManager should be preserved");
        assertEq(claimManager.swapper(), swapper, "Swapper should be preserved");
        assertEq(claimManager.policyManager(), policy, "PolicyManager should be preserved");
    }

    /*//////////////////////////////////////////////////////////////
                          ATTACK SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_attack_SlippageGuardCalculatedFromQuoteSwap() public {
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
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim must succeed within tolerance");
    }

    function test_attack_MultiCollateralSlashingPaysoutCorrectly() public {
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

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(
            uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Multi-collateral claim should succeed"
        );

        uint256 actualPayout = payoutTokenMock.balanceOf(beneficiary) - beneficiaryBefore;
        assertLe(actualPayout, 500 ether, "Total payout must not exceed requested amount");
        assertGt(actualPayout, 0, "Must pay out something");
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
            coverageLimit: COVERAGE_LIMIT,
            specId: keccak256("MorphoSpec"),
            termsHash: keccak256("terms-hash"),
            policyCommit: policyCommit
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

    /*//////////////////////////////////////////////////////////////
                     REAL-TIME SLIPPAGE INFLATION TESTS
    //////////////////////////////////////////////////////////////*/

    // Scenario: single collateral vault, 1% DEX slippage (below 2% maxSwapSlippageBps cap).
    // Expected: slash amount inflated to baseSlash * expectedOut / quotedOut (not capped).
    function test_inflateForSlippage_BelowCap_InflatesSlashAmount() public {
        uint256 stake = 1000 ether;
        uint256 requestedAmount = 500 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](1);
        vaults[0] = collateralToken;
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = stake;
        slashFull.setPreviewResult(vaults, vaults, stakes);
        slashFull.setExecuteResult(vaults, stakes);
        collateralTokenMock.mint(address(slashFull), stake);
        slashFull.setTokenToTransfer(collateralToken);

        // Call 0: toPayoutEquivalent(col, 1000 ether) → 1000 ether (1:1)
        // Call 1: inflateForSlippage(col, 500 ether)  → 495 ether (1% slippage)
        // Call 2: processCollateral amountOutMin       → 1000 ether (fallback 1:1)
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        uint256[] memory quoteVals = new uint256[](2);
        quoteVals[0] = stake; // 1000 ether
        quoteVals[1] = requestedAmount * (10_000 - 100) / 10_000; // 495 ether (1% slippage)
        seqSwapper.setQuoteValues(quoteVals);
        uint256 swapOut = 990 ether;
        seqSwapper.setSwapOutput(swapOut);
        seqSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(seqSwapper), swapOut);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));

        policyMock.setPolicyMetadata(
            POLICY_ID,
            IPolicyManager.PolicyMetadata({
                buyer: buyer,
                policyId: POLICY_ID,
                beneficiary: beneficiary,
                claimer: claimer,
                startTime: uint32(block.timestamp),
                maturityTime: uint32(block.timestamp + COVERAGE_DURATION),
                payoutToken: payoutToken,
                pool: pool,
                coverageLimit: COVERAGE_LIMIT,
                specId: keccak256("MorphoSpec"),
                termsHash: keccak256("terms-hash"),
                policyCommit: policyCommit
            })
        );

        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        // inflated = (500e18 * 500e18) / 495e18 = 505050505050505050505
        // maxInflated = 500e18 * 10000 / 9800 = 510204081632653061224
        // inflated < maxInflated → result = inflated
        uint256 base = 500 ether;
        uint256 expected = 500 ether;
        uint256 quoted = 495 ether;
        uint256 expectedInflated = (base * expected) / quoted;
        uint256 maxInflated = base * 10_000 / (10_000 - 200);
        assertTrue(expectedInflated < maxInflated, "Test setup: should be below cap");
        assertEq(slashFull.lastSlashTotal(), expectedInflated, "Slash should be inflated below cap");
    }

    // Scenario: extreme DEX slippage (50%), which exceeds the 2% maxSwapSlippageBps cap.
    // Expected: slash amount capped at baseSlash * 10_000 / (10_000 - maxSwapSlippageBps).
    function test_inflateForSlippage_AboveCap_CapsAtMaxSlippageBps() public {
        uint256 stake = 1000 ether;
        uint256 requestedAmount = 500 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](1);
        vaults[0] = collateralToken;
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = stake;
        slashFull.setPreviewResult(vaults, vaults, stakes);
        slashFull.setExecuteResult(vaults, stakes);
        collateralTokenMock.mint(address(slashFull), stake);
        slashFull.setTokenToTransfer(collateralToken);

        // Call 0: toPayoutEquivalent(col, 1000 ether) → 1000 ether (1:1)
        // Call 1: inflateForSlippage(col, 500 ether)  → 250 ether (50% slippage, above 2% cap)
        // Call 2: processCollateral amountOutMin       → 1000 ether (fallback 1:1)
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        uint256[] memory quoteVals = new uint256[](2);
        quoteVals[0] = stake; // 1000 ether
        quoteVals[1] = 250 ether; // 50% slippage — way above the 2% cap
        seqSwapper.setQuoteValues(quoteVals);
        uint256 swapOut = 990 ether;
        seqSwapper.setSwapOutput(swapOut);
        seqSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(seqSwapper), swapOut);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        // inflated = 500e18 * 500e18 / 250e18 = 1000e18 (200% — way over cap)
        // maxInflated = 500e18 * 10000 / 9800 = 510204081632653061224
        uint256 baseAmt = 500 ether;
        uint256 expectedCapped = baseAmt * 10_000 / (10_000 - 200);
        assertEq(slashFull.lastSlashTotal(), expectedCapped, "Slash should be capped at maxSwapSlippageBps");
    }

    // Scenario: quoteSwap returns exactly expectedOut (0% DEX slippage).
    // Expected: no inflation — slash amount equals the proportional base.
    function test_inflateForSlippage_NoInflation_WhenQuoteEqualsExpected() public {
        uint256 stake = 1000 ether;
        uint256 requestedAmount = 500 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](1);
        vaults[0] = collateralToken;
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = stake;
        slashFull.setPreviewResult(vaults, vaults, stakes);
        slashFull.setExecuteResult(vaults, stakes);
        collateralTokenMock.mint(address(slashFull), stake);
        slashFull.setTokenToTransfer(collateralToken);

        // All calls return 1:1 → quotedOut == expectedOut → no inflation
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        seqSwapper.setSwapOutput(990 ether);
        seqSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(seqSwapper), 990 ether);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        // With 1:1 quotes: baseSlash = 1000 * 500 / 1000 = 500 ether, quotedOut = 500 = expectedOut
        assertEq(slashFull.lastSlashTotal(), requestedAmount, "No inflation when quote equals expected");
    }

    // Scenario: quoteSwap reverts during inflateForSlippage.
    // Expected: try/catch falls back to baseSlash unchanged.
    function test_inflateForSlippage_NoInflation_WhenQuoteReverts() public {
        uint256 stake = 1000 ether;
        uint256 requestedAmount = 500 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](1);
        vaults[0] = collateralToken;
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = stake;
        slashFull.setPreviewResult(vaults, vaults, stakes);
        slashFull.setExecuteResult(vaults, stakes);
        collateralTokenMock.mint(address(slashFull), stake);
        slashFull.setTokenToTransfer(collateralToken);

        // Call 0: toPayoutEquivalent → 1000 ether (1:1, no inflation needed here)
        // Call 1: inflateForSlippage → REVERT → fallback to baseSlash = 500 ether
        // Call 2: processCollateral amountOutMin → 1000 ether (fallback 1:1)
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        uint256[] memory quoteVals = new uint256[](1);
        quoteVals[0] = stake; // call 0 = 1:1
        seqSwapper.setQuoteValues(quoteVals);
        seqSwapper.setRevertAtCall(1); // call 1 (inflateForSlippage) reverts
        seqSwapper.setSwapOutput(990 ether);
        seqSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(seqSwapper), 990 ether);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(slashFull.lastSlashTotal(), requestedAmount, "Should fall back to baseSlash when quote reverts");
    }

    // Scenario: quoteSwap reverts during processCollateral amountOutMin computation.
    // Expected: amountOutMin falls back to 1 (try/catch) allowing swap to proceed.
    function test_processCollateral_AmountOutMin_FallsBackToOne_WhenQuoteReverts() public {
        uint256 stake = 1000 ether;
        uint256 requestedAmount = 500 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](1);
        vaults[0] = collateralToken;
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = stake;
        slashFull.setPreviewResult(vaults, vaults, stakes);
        slashFull.setExecuteResult(vaults, stakes);
        collateralTokenMock.mint(address(slashFull), stake);
        slashFull.setTokenToTransfer(collateralToken);

        // Call 0: toPayoutEquivalent → 1000 ether (1:1)
        // Call 1: inflateForSlippage → 1000 ether (1:1, no inflation)
        // Call 2: processCollateral amountOutMin → REVERT → amountOutMin falls back to 1
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        uint256[] memory quoteVals = new uint256[](2);
        quoteVals[0] = stake;
        quoteVals[1] = requestedAmount; // inflateForSlippage: 1:1
        seqSwapper.setQuoteValues(quoteVals);
        seqSwapper.setRevertAtCall(2); // call 2 (processCollateral) reverts
        uint256 swapOut = 600 ether; // above amountOutMin=1
        seqSwapper.setSwapOutput(swapOut);
        seqSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(seqSwapper), swapOut);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(seqSwapper.lastAmountOutMin(), 1, "amountOutMin should fall back to 1 when quoteSwap reverts");
    }

    // Scenario: one of two vaults returns quoteSwap = 0 in _toPayoutEquivalent.
    // Expected: that vault is excluded (payoutEquivalent = 0, VaultSlash.amount = 0);
    //           only the other vault contributes to lastSlashTotal.
    function test_toPayoutEquivalent_ExcludesVault_WhenQuoteReturnsZero() public {
        uint256 requestedAmount = 200 ether;
        MockToken collateralToken2Mock = new MockToken("Col2", "COL2");

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](2);
        vaults[0] = address(collateralTokenMock); // will be excluded (quote = 0)
        vaults[1] = address(collateralToken2Mock);
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = 500 ether;
        stakes[1] = 500 ether;
        slashFull.setPreviewResult(vaults, vaults, stakes);

        address[] memory execTokens = new address[](1);
        execTokens[0] = address(collateralToken2Mock);
        uint256[] memory execAmounts = new uint256[](1);
        execAmounts[0] = requestedAmount;
        slashFull.setExecuteResult(execTokens, execAmounts);
        collateralToken2Mock.mint(address(slashFull), requestedAmount);
        slashFull.setTokenToTransfer(address(collateralToken2Mock));

        // Call 0: toPayoutEquivalent(col1, 500 ether) → 0 (col1 excluded)
        // Call 1: toPayoutEquivalent(col2, 500 ether) → 500 ether (1:1, fallback)
        // Call 2: inflateForSlippage(col2, proportional) → fallback 1:1
        // Call 3: processCollateral amountOutMin → fallback 1:1
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        uint256[] memory quoteVals = new uint256[](1);
        quoteVals[0] = 0; // call 0: col1 returns 0 → excluded
        seqSwapper.setQuoteValues(quoteVals);
        seqSwapper.setSwapOutput(requestedAmount);
        seqSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(seqSwapper), requestedAmount);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(slashFull.getLastVaultSlashAmount(0), 0, "Excluded vault should have zero slash amount");
        assertGt(slashFull.getLastVaultSlashAmount(1), 0, "Included vault should have non-zero slash amount");
        assertEq(slashFull.lastSlashTotal(), slashFull.getLastVaultSlashAmount(1), "Total = only included vault");
    }

    // Scenario: all vault quotes return 0 → totalPayoutEquivalent = 0.
    // Expected: _computeVaultSlashes reverts with NoCollateralSlashed.
    function test_computeVaultSlashes_RevertsNoCollateralSlashed_WhenAllQuotesReturnZero() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](1);
        vaults[0] = collateralToken;
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = 1000 ether;
        slashFull.setPreviewResult(vaults, vaults, stakes);

        // quoteSwap always returns 0 → totalPayoutEquivalent = 0
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        uint256[] memory quoteVals = new uint256[](1);
        quoteVals[0] = 0;
        seqSwapper.setQuoteValues(quoteVals);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.NoCollateralSlashed.selector, POLICY_ID));
        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, 500 ether, evidenceHash, "");
    }

    // Scenario: inflation would exceed tokenStake → capped at tokenStake.
    // Uses requestedAmount near COVERAGE_LIMIT so proportional base slash is large,
    // then extreme slippage inflates beyond tokenStake via maxSwapSlippageBps.
    function test_calculateVaultSlash_CapsInflatedAmountAtTokenStake() public {
        uint256 stake = 1000 ether;
        uint256 requestedAmount = 990 ether; // > 0.98 * stake → maxInflated > stake

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](1);
        vaults[0] = collateralToken;
        uint256[] memory stakes = new uint256[](1);
        stakes[0] = stake;
        slashFull.setPreviewResult(vaults, vaults, stakes);
        slashFull.setExecuteResult(vaults, stakes);
        collateralTokenMock.mint(address(slashFull), stake);
        slashFull.setTokenToTransfer(collateralToken);

        // Call 0: toPayoutEquivalent → 1000 ether (1:1)
        // Call 1: inflateForSlippage(990 ether) → 50 ether (extreme slippage)
        //   inflated = 990 * 990 / 50 >> tokenStake
        //   maxInflated = 990 * 10000/9800 ≈ 1010 ether > tokenStake (1000)
        //   → capped at tokenStake = 1000 ether
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        uint256[] memory quoteVals = new uint256[](2);
        quoteVals[0] = stake; // toPayoutEquivalent
        quoteVals[1] = 50 ether; // inflateForSlippage: extreme slippage
        seqSwapper.setQuoteValues(quoteVals);
        seqSwapper.setSwapOutput(990 ether);
        seqSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(seqSwapper), 990 ether);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        // maxInflated = 990e18 * 10000 / 9800 ≈ 1010e18 > tokenStake → capped at 1000e18
        assertEq(slashFull.lastSlashTotal(), stake, "Inflated slash should be capped at tokenStake");
    }

    // Scenario: two vaults — one payoutToken (direct, no quoting), one collateral (1:1 quote).
    // Expected: proportional slash: payoutToken vault gets 30%, collateral vault gets 70%
    //           of requestedAmount proportional to their stake values.
    function test_computeVaultSlashes_ProportionalDistribution_TwoVaults() public {
        uint256 stakeA = 300 ether; // payoutToken vault — direct transfer
        uint256 stakeB = 700 ether; // collateral vault — swap needed
        uint256 requestedAmount = 500 ether;
        // totalStake = 1000 ether → A gets 30%, B gets 70%
        uint256 expectedSlashA = 150 ether; // 300/1000 * 500
        uint256 expectedSlashB = 350 ether; // 700/1000 * 500

        specMock.setEvaluationResult(true, keccak256("approved"));

        MockSlashingManagerFull slashFull = new MockSlashingManagerFull();
        address[] memory vaults = new address[](2);
        vaults[0] = payoutToken; // vault A token = payoutToken (no swap needed)
        vaults[1] = collateralToken; // vault B token = collateral
        uint256[] memory stakes = new uint256[](2);
        stakes[0] = stakeA;
        stakes[1] = stakeB;
        slashFull.setPreviewResult(vaults, vaults, stakes);

        address[] memory execTokens = new address[](2);
        execTokens[0] = payoutToken;
        execTokens[1] = collateralToken;
        uint256[] memory execAmounts = new uint256[](2);
        execAmounts[0] = stakeA; // payout vault — transfered directly
        execAmounts[1] = stakeB; // collateral vault — to be swapped
        slashFull.setExecuteResult(execTokens, execAmounts);
        payoutTokenMock.mint(address(slashFull), stakeA);
        collateralTokenMock.mint(address(slashFull), stakeB);
        slashFull.setTokenToTransfer(payoutToken);
        slashFull.setToken2ToTransfer(collateralToken);

        // Call 0: toPayoutEquivalent(col, stakeB=700e) → 700 ether (1:1 fallback, no configured values)
        // (vault A is payoutToken → returns stakeA directly, no quoteSwap call)
        // Call 1: inflateForSlippage(col, 350 ether) → 350 ether (fallback 1:1, no inflation)
        // Call 2: processCollateral amountOutMin(col, stakeB) → fallback 1:1
        MockSwapperSequential seqSwapper = new MockSwapperSequential();
        seqSwapper.setSwapOutput(stakeB); // swapper returns stakeB payout tokens for the col swap
        seqSwapper.setPayoutToken(payoutToken);
        payoutTokenMock.mint(address(seqSwapper), stakeB);

        vm.prank(admin);
        claimManager.setSwapper(address(seqSwapper));
        vm.prank(admin);
        claimManager.setSlashingManager(address(slashFull));

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            slashFull.getLastVaultSlashAmount(0), expectedSlashA, "Vault A (payoutToken) slash should be 150 ether"
        );
        assertEq(slashFull.getLastVaultSlashAmount(1), expectedSlashB, "Vault B (collateral) slash should be 350 ether");
        assertEq(
            slashFull.lastSlashTotal(), expectedSlashA + expectedSlashB, "Total slash should equal requestedAmount"
        );
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
    address[] private _assets;
    uint256[] private _amounts;
    address private _tokenToTransfer;
    address private _token2ToTransfer;
    uint96 public lastSlashedCommitteeId;
    uint256 public lastSlashAmount;
    address public lastBeneficiary;

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

    function previewSlashing(
        uint96, /*committeeId*/
        address /*operator*/
    )
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        // Use token addresses as vault addresses for simplicity
        vaults = _assets;
        tokens = _assets;
        tokenStakes = _amounts;
    }

    function executeSlashing(
        uint96 committeeId,
        address operator,
        ISlashingManager.VaultSlash[] calldata vaultSlashes,
        bytes32 /*taskId*/
    )
        external
        returns (address[] memory, uint256[] memory)
    {
        lastSlashedCommitteeId = committeeId;
        lastBeneficiary = operator;
        uint256 total = 0;
        for (uint256 i = 0; i < vaultSlashes.length; ++i) {
            total += vaultSlashes[i].amount;
        }
        lastSlashAmount = total;

        if (_tokenToTransfer != address(0)) {
            require(
                MockToken(_tokenToTransfer).transfer(msg.sender, MockToken(_tokenToTransfer).balanceOf(address(this))),
                "Transfer failed"
            );
        }
        if (_token2ToTransfer != address(0)) {
            require(
                MockToken(_token2ToTransfer)
                    .transfer(msg.sender, MockToken(_token2ToTransfer).balanceOf(address(this))),
                "Transfer failed"
            );
        }
        return (_assets, _amounts);
    }
}

contract MockSwapper {
    uint256 private _swapOutput;
    address private _payoutToken;

    function setSwapOutput(uint256 output) external {
        _swapOutput = output;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    function quoteSwap(address, address, uint256 amountIn) external pure returns (uint256) {
        return amountIn; // 1:1 by default
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

contract MockPolicy {
    mapping(uint256 => IPolicyManager.PolicyMetadata) private _metadata;

    function setPolicyMetadata(uint96 policyId, IPolicyManager.PolicyMetadata memory metadata) external {
        _metadata[policyId] = metadata;
    }

    function policyMetadata(uint96 policyId) external view returns (IPolicyManager.PolicyMetadata memory) {
        return _metadata[policyId];
    }
}

contract MockMultiSwapper {
    mapping(address => uint256) private _swapOutputs;
    address private _payoutToken;

    function setSwapOutput(address tokenIn, uint256 output) external {
        _swapOutputs[tokenIn] = output;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    function quoteSwap(address tokenIn, address, uint256 amountIn) external view returns (uint256) {
        uint256 output = _swapOutputs[tokenIn];
        return output > 0 ? output : amountIn; // fallback to 1:1
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

/**
 * @notice Slashing manager mock with separate state for preview and execute, and per-vault
 *         VaultSlash tracking. Used by slippage inflation tests.
 */
contract MockSlashingManagerFull {
    address[] private _prevVaults;
    address[] private _prevTokens;
    uint256[] private _prevStakes;

    address[] private _execTokens;
    uint256[] private _execAmounts;
    address private _tokenToTransfer;
    address private _token2ToTransfer;

    ISlashingManager.VaultSlash[] private _lastVaultSlashes;
    uint256 public lastSlashTotal;

    function setPreviewResult(address[] calldata v, address[] calldata t, uint256[] calldata s) external {
        _prevVaults = v;
        _prevTokens = t;
        _prevStakes = s;
    }

    function setExecuteResult(address[] calldata t, uint256[] calldata a) external {
        _execTokens = t;
        _execAmounts = a;
    }

    function setTokenToTransfer(address token) external {
        _tokenToTransfer = token;
    }

    function setToken2ToTransfer(address token) external {
        _token2ToTransfer = token;
    }

    function getLastVaultSlashAmount(uint256 idx) external view returns (uint256) {
        require(idx < _lastVaultSlashes.length, "out of bounds");
        return _lastVaultSlashes[idx].amount;
    }

    function previewSlashing(
        uint96,
        address
    )
        external
        view
        returns (address[] memory vaults, address[] memory tokens, uint256[] memory tokenStakes)
    {
        return (_prevVaults, _prevTokens, _prevStakes);
    }

    function executeSlashing(
        uint96,
        address,
        ISlashingManager.VaultSlash[] calldata slashes,
        bytes32
    )
        external
        returns (address[] memory, uint256[] memory)
    {
        delete _lastVaultSlashes;
        lastSlashTotal = 0;
        for (uint256 i = 0; i < slashes.length; ++i) {
            _lastVaultSlashes.push(slashes[i]);
            lastSlashTotal += slashes[i].amount;
        }
        if (_tokenToTransfer != address(0)) {
            require(
                MockToken(_tokenToTransfer).transfer(msg.sender, MockToken(_tokenToTransfer).balanceOf(address(this))),
                "Transfer failed"
            );
        }
        if (_token2ToTransfer != address(0)) {
            require(
                MockToken(_token2ToTransfer)
                    .transfer(msg.sender, MockToken(_token2ToTransfer).balanceOf(address(this))),
                "Transfer2 failed"
            );
        }
        return (_execTokens, _execAmounts);
    }
}

/**
 * @notice Swapper mock that returns a pre-configured sequence of values for quoteSwap calls.
 * Calls beyond the configured list fall back to amountIn (1:1). Supports simulating reverts
 * at a specific call index. Used by slippage inflation tests.
 */
contract MockSwapperSequential {
    uint256[] private _quoteValues;
    uint256 private _quoteCallIdx;
    uint256 private _revertAtCall;
    address private _payoutToken;
    uint256 private _swapOutput;
    uint256 public lastAmountOutMin;

    constructor() {
        _revertAtCall = type(uint256).max; // never revert by default
    }

    function setQuoteValues(uint256[] calldata values) external {
        delete _quoteValues;
        for (uint256 i = 0; i < values.length; ++i) {
            _quoteValues.push(values[i]);
        }
        _quoteCallIdx = 0;
    }

    function setRevertAtCall(uint256 callIdx) external {
        _revertAtCall = callIdx;
    }

    function setSwapOutput(uint256 output) external {
        _swapOutput = output;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    function quoteSwap(address, address, uint256 amountIn) external returns (uint256) {
        uint256 idx = _quoteCallIdx++;
        require(idx != _revertAtCall, "MockSwapperSequential: quoteSwap reverts");
        if (idx < _quoteValues.length) {
            return _quoteValues[idx];
        }
        return amountIn; // fallback: 1:1
    }

    function executeSwap(ISwapper.SwapParams calldata params) external returns (uint256) {
        lastAmountOutMin = params.amountOutMin;
        require(
            MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "transferFrom failed"
        );
        if (_payoutToken != address(0)) {
            MockToken(_payoutToken).mint(params.recipient, _swapOutput);
        }
        return _swapOutput;
    }
}

contract MockSwapperWithTracking {
    uint256 private _swapOutput;
    uint256 private _quoteSwapOutput;
    bool private _quoteSwapOutputSet;
    uint256 private _quoteSwapCallCount;
    uint256 private _quoteSwapCountBeforeOverride;
    address private _payoutToken;
    uint256 public lastAmountOutMin;

    function setSwapOutput(uint256 output) external {
        _swapOutput = output;
    }

    function setQuoteSwapOutput(uint256 output) external {
        _quoteSwapOutput = output;
        _quoteSwapOutputSet = true;
        _quoteSwapCountBeforeOverride = 0;
    }

    /// @dev Returns `amountIn` for the first `afterNCalls` calls, then returns `output`.
    function setQuoteSwapOutputAfterNCalls(uint256 output, uint256 afterNCalls) external {
        _quoteSwapOutput = output;
        _quoteSwapOutputSet = true;
        _quoteSwapCountBeforeOverride = afterNCalls;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    function quoteSwap(address, address, uint256 amountIn) external returns (uint256) {
        if (_quoteSwapOutputSet && _quoteSwapCallCount >= _quoteSwapCountBeforeOverride) {
            _quoteSwapCallCount++;
            return _quoteSwapOutput;
        }
        _quoteSwapCallCount++;
        return amountIn; // 1:1 by default
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
