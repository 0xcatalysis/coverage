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
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";

contract ClaimManagerTest is Test {
    uint96 internal constant POLICY_ID = 1;
    uint256 internal constant COVERAGE_LIMIT = 1000 ether;
    uint256 internal constant BASE_PREMIUM = 100 ether;
    uint64 internal constant COVERAGE_DURATION = 30 days;
    uint256 internal constant SLASH_AMOUNT = 500 ether;

    address internal admin;
    address internal claimer;
    address internal unauthorized;
    address internal specRegistry;
    address internal slashingManager;
    address internal swapper;
    address internal policy;
    address internal chainlinkPriceFeed;
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
    MockChainlinkPriceFeed internal chainlinkPriceFeedMock;
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
    event ChainlinkPriceFeedSet(address indexed chainlinkPriceFeed);

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
        chainlinkPriceFeedMock = new MockChainlinkPriceFeed();
        collateralTokenMock = new MockToken("Collateral", "COL");
        payoutTokenMock = new MockToken("Payout", "PAY");

        specRegistry = address(specRegistryMock);
        slashingManager = address(slashingManagerMock);
        swapper = address(swapperMock);
        policy = address(policyMock);
        chainlinkPriceFeed = address(chainlinkPriceFeedMock);
        collateralToken = address(collateralTokenMock);
        payoutToken = address(payoutTokenMock);

        vm.label(specRegistry, "SpecRegistry");
        vm.label(slashingManager, "SlashingManager");
        vm.label(swapper, "Swapper");
        vm.label(policy, "Policy");
        vm.label(chainlinkPriceFeed, "ChainlinkPriceFeed");
        vm.label(collateralToken, "CollateralToken");
        vm.label(payoutToken, "PayoutToken");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(
                ClaimManager.initialize, (admin, specRegistry, slashingManager, swapper, policy, chainlinkPriceFeed)
            ),
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
        freshManager.initialize(address(0), specRegistry, slashingManager, swapper, policy, chainlinkPriceFeed);
    }

    function test_initialize_WhenSpecRegistryZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(0), slashingManager, swapper, policy, chainlinkPriceFeed);
    }

    function test_initialize_WhenSlashingManagerZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, specRegistry, address(0), swapper, policy, chainlinkPriceFeed);
    }

    function test_initialize_WhenSwapperZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, specRegistry, slashingManager, address(0), policy, chainlinkPriceFeed);
    }

    function test_initialize_WhenPolicyZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, specRegistry, slashingManager, swapper, address(0), chainlinkPriceFeed);
    }

    function test_initialize_WhenPriceFeedZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, specRegistry, slashingManager, swapper, policy, address(0));
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(claimManager.hasRole(claimManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertEq(claimManager.specRegistry(), specRegistry, "SpecRegistry mismatch");
        assertEq(claimManager.slashingManager(), slashingManager, "SlashingManager mismatch");
        assertEq(claimManager.swapper(), swapper, "Swapper mismatch");
        assertEq(claimManager.policyManager(), policy, "PolicyManager mismatch");
        assertEq(claimManager.chainlinkPriceFeed(), chainlinkPriceFeed, "ChainlinkPriceFeed mismatch");
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
                            SET PRICE FEED
    //////////////////////////////////////////////////////////////*/

    function test_setChainlinkPriceFeed_WhenCallerNotAdmin_Reverts() public {
        address newChainlinkPriceFeed = makeAddr("newChainlinkPriceFeed");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setChainlinkPriceFeed(newChainlinkPriceFeed);
    }

    function test_setChainlinkPriceFeed_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setChainlinkPriceFeed(address(0));
    }

    function test_setChainlinkPriceFeed_WhenValid_UpdatesState() public {
        address newChainlinkPriceFeed = makeAddr("newChainlinkPriceFeed");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit ChainlinkPriceFeedSet(newChainlinkPriceFeed);

        vm.prank(admin);
        claimManager.setChainlinkPriceFeed(newChainlinkPriceFeed);

        assertEq(claimManager.chainlinkPriceFeed(), newChainlinkPriceFeed, "ChainlinkPriceFeed not updated");
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
        metadata.startTime = uint64(block.timestamp + 1 days);
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

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ZeroPayoutAmount.selector, POLICY_ID));
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
        // Warp to middle of coverage period
        vm.warp(block.timestamp + (COVERAGE_DURATION / 2));

        specMock.setEvaluationResult(true, keccak256("approved"));

        // Setup slashing to return collateral
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

        // Warp to exact maturity time
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

        // Should succeed as implementation allows claims AT maturity
        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory claim = claimManager.claimRecord(POLICY_ID, claimId);
        assertTrue(claim.status == IClaimManager.ClaimStatus.Approved, "Claim should be filed at maturity time");
    }

    function test_fileClaim_AfterMaturity_Reverts() public {
        IPolicyManager.PolicyMetadata memory metadata = policyMock.policyMetadata(POLICY_ID);

        // Warp past maturity
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

    /*//////////////////////////////////////////////////////////////
                            FILE CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_fileClaim_MultipleClaimsExhaustCoverage_FinalClaimCapped() public {
        uint256 firstClaimAmount = COVERAGE_LIMIT / 2;
        uint256 secondClaimAmount = COVERAGE_LIMIT / 2;
        uint256 thirdClaimAmount = COVERAGE_LIMIT / 4; // This should be capped

        specMock.setEvaluationResult(true, keccak256("approved"));

        // First claim
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

        // Second claim
        collateralTokenMock.mint(address(slashingManagerMock), secondClaimAmount);
        payoutTokenMock.mint(address(swapperMock), secondClaimAmount);
        swapperMock.setSwapOutput(secondClaimAmount);

        vm.prank(claimer);
        claimManager.fileClaim(POLICY_ID, secondClaimAmount, keccak256("evidence2"), "");

        // Third claim should be capped to remaining coverage (0)
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
        // Premium reserve removed from ClaimManager
        assertEq(claimManager.chainlinkPriceFeed(), chainlinkPriceFeed, "ChainlinkPriceFeed should be preserved");
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
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + COVERAGE_DURATION),
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

        // Setup slashing for atomic claim flow
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
    address[] private _assets;
    uint256[] private _amounts;
    address private _tokenToTransfer;
    address private _token2ToTransfer;
    uint96 public lastSlashedCommitteeId;
    address public lastBeneficiary;
    uint256 public lastSlashAmount;

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

    function executeSlashing(
        uint96 committeeId,
        address beneficiary,
        uint256 slashAmount
    )
        external
        returns (address[] memory, uint256[] memory)
    {
        lastSlashedCommitteeId = committeeId;
        lastBeneficiary = beneficiary;
        lastSlashAmount = slashAmount;

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

contract MockChainlinkPriceFeed {
    mapping(address => uint256) private _pricePerToken;

    function setPrice(address token, uint256 price) external {
        _pricePerToken[token] = price;
    }

    function getUSDValue(address token, uint256 amount) external view returns (uint256) {
        uint256 price = _pricePerToken[token];
        if (price == 0) {
            return amount;
        }
        return (amount * price) / 1e18;
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
    address private immutable _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function owner() external view returns (address) {
        return _owner;
    }
}
