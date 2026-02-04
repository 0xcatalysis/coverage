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
import {IPolicy} from "../../src/interfaces/IPolicy.sol";
import {ISpec} from "../../src/interfaces/ISpec.sol";
import {ISwapper} from "../../src/interfaces/ISwapper.sol";

contract ClaimManagerTest is Test {
    uint96 internal constant POLICY_ID = 1;
    uint256 internal constant COVERAGE_LIMIT = 1000 ether;
    uint256 internal constant BASE_PREMIUM = 100 ether;
    uint64 internal constant COVERAGE_DURATION = 30 days;
    uint256 internal constant SLASH_AMOUNT = 500 ether;

    address internal admin;
    address internal claimOperator;
    address internal unauthorized;
    address internal specRegistry;
    address internal slashingManager;
    address internal swapper;
    address internal policy;
    address internal premiumReserve;
    address internal chainlinkPriceFeed;
    address internal buyer;
    address internal payoutReceiver;
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
    MockPremiumReserve internal premiumReserveMock;
    MockChainlinkPriceFeed internal chainlinkPriceFeedMock;
    MockToken internal collateralTokenMock;
    MockToken internal payoutTokenMock;

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
    event PolicySet(address indexed policy);
    event PremiumReserveSet(address indexed premiumReserve);
    event ChainlinkPriceFeedSet(address indexed chainlinkPriceFeed);

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        claimOperator = makeAddr("claimOperator");
        unauthorized = makeAddr("unauthorized");
        buyer = makeAddr("buyer");
        payoutReceiver = makeAddr("payoutReceiver");
        operator = makeAddr("operator");
        pool = makeAddr("pool");
        premiumToken = makeAddr("premiumToken");

        vm.label(admin, "Admin");
        vm.label(claimOperator, "ClaimOperator");
        vm.label(unauthorized, "Unauthorized");
        vm.label(buyer, "Buyer");
        vm.label(payoutReceiver, "PayoutReceiver");
        vm.label(operator, "Operator");
        vm.label(pool, "Pool");

        evidenceHash = keccak256("evidence-hash");
        policyCommit = keccak256("policy-commit");

        specMock = new MockSpec();
        specRegistryMock = new MockSpecRegistry(address(specMock));
        slashingManagerMock = new MockSlashingManager();
        swapperMock = new MockSwapper();
        policyMock = new MockPolicy();
        premiumReserveMock = new MockPremiumReserve();
        chainlinkPriceFeedMock = new MockChainlinkPriceFeed();
        collateralTokenMock = new MockToken("Collateral", "COL");
        payoutTokenMock = new MockToken("Payout", "PAY");

        specRegistry = address(specRegistryMock);
        slashingManager = address(slashingManagerMock);
        swapper = address(swapperMock);
        policy = address(policyMock);
        premiumReserve = address(premiumReserveMock);
        chainlinkPriceFeed = address(chainlinkPriceFeedMock);
        collateralToken = address(collateralTokenMock);
        payoutToken = address(payoutTokenMock);

        vm.label(specRegistry, "SpecRegistry");
        vm.label(slashingManager, "SlashingManager");
        vm.label(swapper, "Swapper");
        vm.label(policy, "Policy");
        vm.label(premiumReserve, "PremiumReserve");
        vm.label(chainlinkPriceFeed, "ChainlinkPriceFeed");
        vm.label(collateralToken, "CollateralToken");
        vm.label(payoutToken, "PayoutToken");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(
                ClaimManager.initialize,
                (
                    admin,
                    claimOperator,
                    specRegistry,
                    slashingManager,
                    swapper,
                    policy,
                    premiumReserve,
                    chainlinkPriceFeed
                )
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
        freshManager.initialize(
            address(0),
            claimOperator,
            specRegistry,
            slashingManager,
            swapper,
            policy,
            premiumReserve,
            chainlinkPriceFeed
        );
    }

    function test_initialize_WhenClaimOperatorZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, address(0), specRegistry, slashingManager, swapper, policy, premiumReserve, chainlinkPriceFeed
        );
    }

    function test_initialize_WhenSpecRegistryZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, address(0), slashingManager, swapper, policy, premiumReserve, chainlinkPriceFeed
        );
    }

    function test_initialize_WhenSlashingManagerZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, address(0), swapper, policy, premiumReserve, chainlinkPriceFeed
        );
    }

    function test_initialize_WhenSwapperZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, slashingManager, address(0), policy, premiumReserve, chainlinkPriceFeed
        );
    }

    function test_initialize_WhenPolicyZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, slashingManager, swapper, address(0), premiumReserve, chainlinkPriceFeed
        );
    }

    function test_initialize_WhenPremiumReserveZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, slashingManager, swapper, policy, address(0), chainlinkPriceFeed
        );
    }

    function test_initialize_WhenPriceFeedZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, slashingManager, swapper, policy, premiumReserve, address(0)
        );
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(claimManager.hasRole(claimManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertTrue(
            claimManager.hasRole(claimManager.CLAIM_OPERATOR_ROLE(), claimOperator), "Claim operator role missing"
        );
        assertEq(claimManager.specRegistry(), specRegistry, "SpecRegistry mismatch");
        assertEq(claimManager.slashingManager(), slashingManager, "SlashingManager mismatch");
        assertEq(claimManager.swapper(), swapper, "Swapper mismatch");
        assertEq(claimManager.policy(), policy, "Policy mismatch");
        assertEq(claimManager.premiumReserve(), premiumReserve, "PremiumReserve mismatch");
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

    function test_setPolicy_WhenCallerNotAdmin_Reverts() public {
        address newPolicy = makeAddr("newPolicy");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setPolicy(newPolicy);
    }

    function test_setPolicy_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setPolicy(address(0));
    }

    function test_setPolicy_WhenValid_UpdatesState() public {
        address newPolicy = makeAddr("newPolicy");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit PolicySet(newPolicy);

        vm.prank(admin);
        claimManager.setPolicy(newPolicy);

        assertEq(claimManager.policy(), newPolicy, "Policy not updated");
    }

    /*//////////////////////////////////////////////////////////////
                         SET PREMIUM RESERVE
    //////////////////////////////////////////////////////////////*/

    function test_setPremiumReserve_WhenCallerNotAdmin_Reverts() public {
        address newPremiumReserve = makeAddr("newPremiumReserve");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setPremiumReserve(newPremiumReserve);
    }

    function test_setPremiumReserve_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setPremiumReserve(address(0));
    }

    function test_setPremiumReserve_WhenValid_UpdatesState() public {
        address newPremiumReserve = makeAddr("newPremiumReserve");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit PremiumReserveSet(newPremiumReserve);

        vm.prank(admin);
        claimManager.setPremiumReserve(newPremiumReserve);

        assertEq(claimManager.premiumReserve(), newPremiumReserve, "PremiumReserve not updated");
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
                       PENDING CLAIM COUNT
    //////////////////////////////////////////////////////////////*/

    function test_pendingClaimCount_WhenNoClaims_ReturnsZero() public view {
        uint256 pending = claimManager.pendingClaimCount(POLICY_ID);
        assertEq(pending, 0, "Should have no pending claims");
    }

    /*//////////////////////////////////////////////////////////////
                            FILE CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_fileClaim_WhenPaused_Reverts() public {
        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(claimOperator);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenCallerNotOperator_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.CLAIM_OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenEvidenceHashZero_Reverts() public {
        vm.expectRevert(IClaimManager.InvalidEvidenceHash.selector);
        vm.prank(claimOperator);
        claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, bytes32(0), "");
    }

    function test_fileClaim_WhenRequestedAmountZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAmount.selector);
        vm.prank(claimOperator);
        claimManager.fileClaim(POLICY_ID, 0, evidenceHash, "");
    }

    function test_fileClaim_WhenMultiplePartialClaims_AllowsMultipleClaims() public {
        uint256 halfCoverage = COVERAGE_LIMIT / 2;
        bytes32 evidenceHash1 = keccak256("evidence-1");

        specMock.setEvaluationResult(true, halfCoverage, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = halfCoverage;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), halfCoverage);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(halfCoverage);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, halfCoverage, evidenceHash1, "");

        bytes32 evidenceHash2 = keccak256("evidence-2");
        collateralTokenMock.mint(address(slashingManager), halfCoverage);

        vm.prank(claimOperator);
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
        specMock.setEvaluationResult(false, 0, keccak256("rejected"));

        vm.expectEmit(true, true, false, true, address(claimManager));
        emit ClaimFiled(POLICY_ID, 0, claimOperator, evidenceHash, COVERAGE_LIMIT, block.timestamp);

        vm.expectEmit(true, true, false, false, address(claimManager));
        emit ClaimRejected(POLICY_ID, 0, "Spec evaluation failed", block.timestamp);

        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected), "Status should be Rejected");
        assertEq(record.reporter, claimOperator, "Reporter should be claimOperator");
        assertEq(record.filedAt, block.timestamp, "FiledAt mismatch");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
    }

    function test_fileClaim_WhenSpecApproves_ExecutesPayoutAtomically() public {
        uint256 requestedAmount = 500 ether;
        uint256 swapOutput = 450 ether;

        specMock.setEvaluationResult(true, requestedAmount, keccak256("approved"));

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
        emit ClaimFiled(POLICY_ID, 0, claimOperator, evidenceHash, requestedAmount, block.timestamp);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit ClaimApproved(POLICY_ID, 0, payoutReceiver, swapOutput, block.timestamp);

        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Status should be Approved");
        assertEq(record.reporter, claimOperator, "Reporter should be claimOperator");
        assertEq(record.filedAt, block.timestamp, "FiledAt mismatch");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertEq(record.payoutAmount, swapOutput, "PayoutAmount mismatch");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
    }

    function test_fileClaim_WhenPremiumReserveSufficient_NoSlashing() public {
        uint256 requestedAmount = 70 ether;
        uint256 premiumAvailable = 100 ether;

        specMock.setEvaluationResult(true, requestedAmount, keccak256("approved"));
        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(payoutToken);

        payoutTokenMock.mint(address(premiumReserveMock), premiumAvailable);

        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Status should be Approved");
        assertEq(record.payoutAmount, requestedAmount, "Payout should equal requested amount");
    }

    function test_fileClaim_FilesAndResolvesInSameBlock() public {
        uint256 requestedAmount = 500 ether;
        uint256 swapOutput = 450 ether;

        specMock.setEvaluationResult(true, requestedAmount, keccak256("approved"));

        address[] memory tokens = new address[](1);
        tokens[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(tokens, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);

        assertEq(record.filedAt, record.resolvedAt, "Filing and resolution should happen in same block");
        assertEq(record.filedAt, block.timestamp, "Timestamps should match current block");
    }

    function test_fileClaim_WhenPolicyNotFound_Reverts() public {
        uint96 invalidPolicyId = 999;
        policyMock.setPolicyMetadata(
            invalidPolicyId,
            IPolicy.PolicyMetadata({
                buyer: address(0),
                beneficiary: address(0),
                claimer: address(0),
                premiumToken: address(0),
                basePremium: 0,
                payoutToken: address(0),
                pool: address(0),
                coverageLimit: 0,
                payoutReceiver: address(0),
                poolPolicyId: 0,
                specId: bytes32(0),
                termsHash: bytes32(0),
                policyCommit: bytes32(0),
                committeeId: 0,
                startTime: 0,
                maturityTime: 0,
                operator: address(0)
            })
        );

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.PolicyNotFound.selector, invalidPolicyId));
        vm.prank(claimOperator);
        claimManager.fileClaim(invalidPolicyId, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenRequestedAmountExceedsCoverage_Reverts() public {
        uint256 excessAmount = COVERAGE_LIMIT + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.RequestedAmountExceedsRemainingCoverage.selector, POLICY_ID, excessAmount, COVERAGE_LIMIT
            )
        );
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, excessAmount, evidenceHash, "");
    }

    function test_fileClaim_WhenBeforeCoverageWindow_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
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
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenAfterCoverageWindow_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
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
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenEscrowAlreadyReleased_Reverts() public {
        premiumReserveMock.setEscrowReleased(POLICY_ID, true);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.EscrowAlreadyReleased.selector, POLICY_ID));
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileClaim_WhenPremiumReservePartial_SlashesShortfall() public {
        uint256 requestedAmount = 1000 ether;
        uint256 premiumAvailable = 400 ether;
        uint256 shortfall = requestedAmount - premiumAvailable;

        specMock.setEvaluationResult(true, requestedAmount, keccak256("approved"));

        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(address(payoutTokenMock));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = shortfall;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), shortfall);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        swapperMock.setSwapOutput(shortfall);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should pay full requested amount from premium + slashing");
        assertEq(
            payoutTokenMock.balanceOf(payoutReceiver),
            premiumAvailable + shortfall,
            "Receiver should get premium + slashed amount"
        );
    }

    function test_fileClaim_WhenPremiumTokenDifferent_ConvertsAndPays() public {
        uint256 requestedAmount = 500 ether;
        uint256 premiumAvailable = 600 ether;
        uint256 swappedAmount = 550 ether;

        MockToken differentPremiumToken = new MockToken("Premium", "PREM");

        specMock.setEvaluationResult(true, requestedAmount, keccak256("approved"));

        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(address(differentPremiumToken));

        swapperMock.setSwapOutput(swappedAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should be capped at requested amount");
        assertEq(
            payoutTokenMock.balanceOf(payoutReceiver),
            requestedAmount,
            "Receiver should get requested amount (capped to prevent over-payment)"
        );
    }

    /*//////////////////////////////////////////////////////////////
                               UPGRADES
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
        assertEq(claimManager.policy(), policy, "Policy should be preserved");
        assertEq(claimManager.premiumReserve(), premiumReserve, "PremiumReserve should be preserved");
        assertEq(claimManager.chainlinkPriceFeed(), chainlinkPriceFeed, "ChainlinkPriceFeed should be preserved");
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setupDefaultPolicy() private {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        policyMock.setPolicyMetadata(POLICY_ID, metadata);
    }

    function _defaultMetadata() private view returns (IPolicy.PolicyMetadata memory metadata) {
        metadata = IPolicy.PolicyMetadata({
            buyer: buyer,
            beneficiary: buyer,
            claimer: buyer,
            premiumToken: premiumToken,
            basePremium: BASE_PREMIUM,
            payoutToken: payoutToken,
            pool: pool,
            coverageLimit: COVERAGE_LIMIT,
            payoutReceiver: payoutReceiver,
            poolPolicyId: 1,
            specId: keccak256("MorphoSpec"),
            termsHash: keccak256("terms-hash"),
            policyCommit: policyCommit,
            committeeId: uint96(123),
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + COVERAGE_DURATION),
            operator: operator
        });
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

    function setEvaluationResult(bool isPayable, uint256 amountUsd, bytes32 notesHash) external {
        _result = EvaluationResult({isPayable: isPayable, amountUsd: amountUsd, notesHash: notesHash});
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

    function executeSlashing(uint96, address, uint256) external returns (address[] memory, uint256[] memory) {
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
    mapping(uint256 => IPolicy.PolicyMetadata) private _metadata;

    function setPolicyMetadata(uint96 policyId, IPolicy.PolicyMetadata memory metadata) external {
        _metadata[policyId] = metadata;
    }

    function policyMetadata(uint96 policyId) external view returns (IPolicy.PolicyMetadata memory) {
        return _metadata[policyId];
    }
}

contract MockPremiumReserve {
    mapping(uint256 => bool) private _escrowReleased;
    mapping(uint256 => bool) private _claimLocked;
    mapping(uint256 => uint256) private _premiumAvailable;
    address private _premiumToken;

    error EscrowNotLocked(uint96 policyId);

    function setEscrowReleased(uint96 policyId, bool released) external {
        _escrowReleased[policyId] = released;
    }

    function isEscrowReleased(uint96 policyId) external view returns (bool) {
        return _escrowReleased[policyId];
    }

    function setClaimLockStatus(uint96 policyId, bool locked) external {
        _claimLocked[policyId] = locked;
    }

    function isClaimLockSet(uint96 policyId) external view returns (bool) {
        return _claimLocked[policyId];
    }

    function setPremiumAvailable(uint96 policyId, uint256 amount) external {
        _premiumAvailable[policyId] = amount;
    }

    function setPremiumToken(address token) external {
        _premiumToken = token;
    }

    function payClaim(
        uint96 policyId,
        address payoutRecipient,
        uint256 settledAmount
    )
        external
        returns (uint256 paidAmount, address premiumToken)
    {
        require(_claimLocked[policyId], EscrowNotLocked(policyId));

        uint256 available = _premiumAvailable[policyId];
        paidAmount = available >= settledAmount ? settledAmount : available;
        premiumToken = _premiumToken;

        if (paidAmount > 0) {
            _premiumAvailable[policyId] -= paidAmount;
            if (_premiumToken != address(0)) {
                MockToken(_premiumToken).mint(payoutRecipient, paidAmount);
            }
        }
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
