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
    uint256 internal constant POLICY_ID = 1;
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
    address internal priceFeed;
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
    MockChainlinkPriceFeed internal priceFeedMock;
    MockToken internal collateralTokenMock;
    MockToken internal payoutTokenMock;

    bytes32 internal evidenceHash;
    bytes32 internal policyCommit;

    event ClaimFiled(
        uint256 indexed policyId,
        uint256 indexed claimId,
        address indexed reporter,
        bytes32 evidenceHash,
        uint256 requestedAmount,
        uint256 timestamp
    );
    event ClaimApproved(
        uint256 indexed policyId,
        uint256 indexed claimId,
        address indexed beneficiary,
        uint256 payoutAmount,
        uint256 timestamp
    );
    event ClaimRejected(uint256 indexed policyId, uint256 indexed claimId, string reason, uint256 timestamp);
    event CollateralSwapped(
        uint256 indexed policyId,
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
    event PriceFeedSet(address indexed priceFeed);

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
        priceFeedMock = new MockChainlinkPriceFeed();
        collateralTokenMock = new MockToken("Collateral", "COL");
        payoutTokenMock = new MockToken("Payout", "PAY");

        specRegistry = address(specRegistryMock);
        slashingManager = address(slashingManagerMock);
        swapper = address(swapperMock);
        policy = address(policyMock);
        premiumReserve = address(premiumReserveMock);
        priceFeed = address(priceFeedMock);
        collateralToken = address(collateralTokenMock);
        payoutToken = address(payoutTokenMock);

        vm.label(specRegistry, "SpecRegistry");
        vm.label(slashingManager, "SlashingManager");
        vm.label(swapper, "Swapper");
        vm.label(policy, "Policy");
        vm.label(premiumReserve, "PremiumReserve");
        vm.label(priceFeed, "PriceFeed");
        vm.label(collateralToken, "CollateralToken");
        vm.label(payoutToken, "PayoutToken");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(
                ClaimManager.initialize,
                (admin, claimOperator, specRegistry, slashingManager, swapper, policy, premiumReserve, priceFeed)
            ),
            deployOpts
        );
        claimManager = ClaimManager(proxy);

        vm.label(address(claimManager), "ClaimManager");

        _setupDefaultPolicy();
    }

    /*//////////////////////////////////////////////////////////////
                           INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            address(0), claimOperator, specRegistry, slashingManager, swapper, policy, premiumReserve, priceFeed
        );
    }

    function test_initialize_WhenClaimOperatorZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, address(0), specRegistry, slashingManager, swapper, policy, premiumReserve, priceFeed
        );
    }

    function test_initialize_WhenSpecRegistryZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, address(0), slashingManager, swapper, policy, premiumReserve, priceFeed
        );
    }

    function test_initialize_WhenSlashingManagerZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, address(0), swapper, policy, premiumReserve, priceFeed
        );
    }

    function test_initialize_WhenSwapperZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, slashingManager, address(0), policy, premiumReserve, priceFeed
        );
    }

    function test_initialize_WhenPolicyZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, slashingManager, swapper, address(0), premiumReserve, priceFeed
        );
    }

    function test_initialize_WhenPremiumReserveZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, slashingManager, swapper, policy, address(0), priceFeed
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
        assertEq(claimManager.priceFeed(), priceFeed, "PriceFeed mismatch");
        assertFalse(claimManager.paused(), "Contract unexpectedly paused");
    }

    /*//////////////////////////////////////////////////////////////
                              PAUSING
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
                           CONFIGURATION
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

    function test_setPriceFeed_WhenCallerNotAdmin_Reverts() public {
        address newPriceFeed = makeAddr("newPriceFeed");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.setPriceFeed(newPriceFeed);
    }

    function test_setPriceFeed_WhenAddressZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        vm.prank(admin);
        claimManager.setPriceFeed(address(0));
    }

    function test_setPriceFeed_WhenValid_UpdatesState() public {
        address newPriceFeed = makeAddr("newPriceFeed");

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit PriceFeedSet(newPriceFeed);

        vm.prank(admin);
        claimManager.setPriceFeed(newPriceFeed);

        assertEq(claimManager.priceFeed(), newPriceFeed, "PriceFeed not updated");
    }

    /*//////////////////////////////////////////////////////////////
                             FILE CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_fileClaim_WhenPaused_Reverts() public {
        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash);
    }

    function test_fileClaim_WhenEvidenceHashZero_Reverts() public {
        vm.expectRevert(IClaimManager.InvalidEvidenceHash.selector);
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, bytes32(0));
    }

    function test_fileClaim_WhenRequestedAmountZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAmount.selector);
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, 0, evidenceHash);
    }

    function test_fileClaim_WhenRequestedAmountExceedsCoverage_Reverts() public {
        uint256 excessAmount = COVERAGE_LIMIT + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.RequestedAmountExceedsRemainingCoverage.selector, POLICY_ID, excessAmount, COVERAGE_LIMIT
            )
        );
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, excessAmount, evidenceHash);
    }

    function test_fileClaim_WhenPolicyNotFound_Reverts() public {
        uint256 invalidPolicyId = 999;
        policyMock.setPolicyMetadata(
            invalidPolicyId,
            IPolicy.PolicyMetadata({
                buyer: address(0),
                beneficiary: address(0),
                premiumToken: address(0),
                basePremium: 0,
                payoutToken: address(0),
                pool: address(0),
                coverageLimit: 0,
                payoutReceiver: address(0),
                poolPolicyId: bytes32(0),
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
        vm.prank(buyer);
        claimManager.fileClaim(invalidPolicyId, COVERAGE_LIMIT, evidenceHash);
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
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash);
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
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash);
    }

    function test_fileClaim_WhenEscrowAlreadyReleased_Reverts() public {
        premiumReserveMock.setEscrowReleased(POLICY_ID, true);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.EscrowAlreadyReleased.selector, POLICY_ID));
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash);
    }

    function test_fileClaim_WhenAllCoverageExhausted_Reverts() public {
        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COVERAGE_LIMIT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), COVERAGE_LIMIT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(COVERAGE_LIMIT);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        bytes32 evidenceHash2 = keccak256("evidence-hash-2");
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.RequestedAmountExceedsRemainingCoverage.selector, POLICY_ID, 1 ether, 0
            )
        );
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, 1 ether, evidenceHash2);
    }

    function test_fileClaim_WhenValid_StoresClaimAndEmits() public {
        uint256 requestedAmount = 500 ether;

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit ClaimFiled(POLICY_ID, 0, buyer, evidenceHash, requestedAmount, block.timestamp);

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        assertEq(claimId, 0, "First claim should have ID 0");
        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Filed), "Status mismatch");
        assertEq(record.reporter, buyer, "Reporter mismatch");
        assertEq(record.filedAt, block.timestamp, "FiledAt mismatch");
        assertEq(record.evidenceHash, evidenceHash, "EvidenceHash mismatch");
        assertEq(record.requestedAmount, requestedAmount, "RequestedAmount mismatch");
        assertTrue(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock not set");
    }

    function test_fileClaim_WhenValidByNonBuyer_Succeeds() public {
        address reporter = makeAddr("reporter");
        uint256 requestedAmount = 500 ether;

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit ClaimFiled(POLICY_ID, 0, reporter, evidenceHash, requestedAmount, block.timestamp);

        vm.prank(reporter);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.reporter, reporter, "Reporter should be msg.sender");
        assertEq(record.requestedAmount, requestedAmount, "RequestedAmount mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                           APPROVE CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_approveClaim_WhenPaused_Reverts() public {
        uint256 claimId = _fileClaim();

        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");
    }

    function test_approveClaim_WhenClaimNotFiled_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ClaimNotFiled.selector, POLICY_ID, 0));
        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, 0, "");
    }

    function test_approveClaim_WhenCallerNotOperator_Reverts() public {
        uint256 claimId = _fileClaim();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.CLAIM_OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.approveClaim(POLICY_ID, claimId, "");
    }

    function test_approveClaim_WhenSpecRejectsPayable_RejectsClaim() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(false, 0, keccak256("rejected"));

        vm.expectEmit(true, true, false, false, address(claimManager));
        emit ClaimRejected(POLICY_ID, claimId, "Spec evaluation failed", block.timestamp);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected), "Status should be Rejected");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertFalse(record.evaluationResult.isPayable, "Should not be payable");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
    }

    function test_approveClaim_WhenNoCollateralSlashed_Reverts() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));
        slashingManagerMock.setSlashResult(new address[](0), new uint256[](0));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.NoCollateralSlashed.selector, POLICY_ID));
        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");
    }

    function test_approveClaim_WhenAllCollateralAmountsZero_Reverts() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        address[] memory assets = new address[](2);
        assets[0] = collateralToken;
        assets[1] = payoutToken;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 0;
        amounts[1] = 0;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ZeroPayoutAmount.selector, POLICY_ID));
        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");
    }

    function test_approveClaim_WhenSpecApproves_ExecutesPayoutAndEmits() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        uint256 swapOutput = 450 ether;
        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(payoutToken);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit CollateralSwapped(POLICY_ID, claimId, collateralToken, SLASH_AMOUNT, payoutToken, swapOutput);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit ClaimApproved(POLICY_ID, claimId, payoutReceiver, swapOutput, block.timestamp);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Status should be Approved");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertEq(record.payoutAmount, swapOutput, "Payout amount mismatch");
        assertTrue(record.evaluationResult.isPayable, "Should be payable");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
        assertEq(payoutTokenMock.balanceOf(payoutReceiver), swapOutput, "Receiver should get payout tokens");
    }

    function test_approveClaim_WhenCollateralMatchesPayoutToken_TransfersDirect() public {
        uint256 claimId = _fileClaim();

        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutToken = collateralToken;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit CollateralSwapped(POLICY_ID, claimId, collateralToken, SLASH_AMOUNT, collateralToken, SLASH_AMOUNT);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, SLASH_AMOUNT, "Payout should equal slashed amount");
        assertEq(collateralTokenMock.balanceOf(payoutReceiver), SLASH_AMOUNT, "Receiver should get tokens");
    }

    function test_approveClaim_WhenMultipleCollateralTypes_ProcessesAll() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        MockToken collateral2 = new MockToken("Collateral2", "COL2");
        address[] memory assets = new address[](2);
        assets[0] = collateralToken;
        assets[1] = address(collateral2);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 300 ether;
        amounts[1] = 200 ether;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), 300 ether);
        collateral2.mint(address(slashingManager), 200 ether);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        slashingManagerMock.setToken2ToTransfer(address(collateral2));

        swapperMock.setSwapOutput(250 ether);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, 500 ether, "Total payout should be sum of both swaps");
        assertEq(payoutTokenMock.balanceOf(payoutReceiver), 500 ether, "Receiver should get payout tokens");
    }

    function test_approveClaim_WhenZeroAmountCollateral_SkipsProcessing() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        address[] memory assets = new address[](2);
        assets[0] = collateralToken;
        assets[1] = payoutToken;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = SLASH_AMOUNT;
        amounts[1] = 0;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        uint256 swapOutput = 450 ether;
        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, swapOutput, "Should only count non-zero amounts");
        assertEq(payoutTokenMock.balanceOf(payoutReceiver), swapOutput, "Receiver should get payout tokens");
    }

    function test_approveClaim_WhenSwapOutputExceedsRequestedAmount_CapsTransfer() public {
        uint256 requestedAmount = 300 ether;
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        uint256 swapOutput = 500 ether;
        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(payoutToken);

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit CollateralSwapped(POLICY_ID, claimId, collateralToken, SLASH_AMOUNT, payoutToken, requestedAmount);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Payout should be capped at requestedAmount");
        assertEq(payoutTokenMock.balanceOf(payoutReceiver), requestedAmount, "Receiver should only get requestedAmount");
        uint256 excess = swapOutput - requestedAmount;
        assertEq(payoutTokenMock.balanceOf(address(claimManager)), excess, "Excess should remain in ClaimManager");
    }

    function test_approveClaim_WhenDirectTransferExceedsRequestedAmount_CapsTransfer() public {
        uint256 requestedAmount = 300 ether;
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutToken = collateralToken;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit CollateralSwapped(POLICY_ID, claimId, collateralToken, SLASH_AMOUNT, collateralToken, requestedAmount);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Payout should be capped at requestedAmount");
        assertEq(
            collateralTokenMock.balanceOf(payoutReceiver), requestedAmount, "Receiver should only get requestedAmount"
        );
        uint256 excess = SLASH_AMOUNT - requestedAmount;
        assertEq(collateralTokenMock.balanceOf(address(claimManager)), excess, "Excess should remain in ClaimManager");
    }

    /*//////////////////////////////////////////////////////////////
                    PREMIUM RESERVE WATERFALL
    //////////////////////////////////////////////////////////////*/

    function test_approveClaim_WhenPremiumReserveSufficient_NeverSlashes() public {
        uint256 requestedAmount = 500 ether;
        uint256 premiumAvailable = 600 ether;

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(address(payoutTokenMock));

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should pay full requested amount from premium reserve");
        assertEq(payoutTokenMock.balanceOf(payoutReceiver), requestedAmount, "Receiver should get full payout");
    }

    function test_approveClaim_WhenPremiumReservePartial_SlashesShortfall() public {
        uint256 requestedAmount = 1000 ether;
        uint256 premiumAvailable = 400 ether;
        uint256 shortfall = requestedAmount - premiumAvailable;

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

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

        vm.expectEmit(true, true, true, false, address(claimManager));
        emit CollateralSwapped(POLICY_ID, claimId, collateralToken, shortfall, payoutToken, shortfall);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should pay full requested amount from premium + slashing");
        assertEq(
            payoutTokenMock.balanceOf(payoutReceiver),
            premiumAvailable + shortfall,
            "Receiver should get premium + slashed amount"
        );
    }

    function test_approveClaim_WhenPremiumReserveEmpty_SlashesFull() public {
        uint256 requestedAmount = 800 ether;

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        premiumReserveMock.setPremiumAvailable(POLICY_ID, 0);
        premiumReserveMock.setPremiumToken(address(payoutTokenMock));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), requestedAmount);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        swapperMock.setSwapOutput(requestedAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.expectEmit(true, true, true, false, address(claimManager));
        emit CollateralSwapped(POLICY_ID, claimId, collateralToken, requestedAmount, payoutToken, requestedAmount);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should pay full requested amount from slashing");
        assertEq(payoutTokenMock.balanceOf(payoutReceiver), requestedAmount, "Receiver should get full slashed amount");
    }

    function test_approveClaim_WhenPremiumReserve100k_Claim70k_NoSlashing() public {
        uint256 premiumAvailable = 100_000 ether;
        uint256 requestedAmount = 70_000 ether;
        uint256 highCoverageLimit = 2_000_000 ether;

        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.coverageLimit = highCoverageLimit;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, highCoverageLimit, keccak256("approved"));

        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(address(payoutTokenMock));

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should pay 70k from premium reserve");
        assertEq(payoutTokenMock.balanceOf(payoutReceiver), requestedAmount, "Receiver should get 70k");
    }

    function test_approveClaim_WhenPremiumReserve100k_Claim250k_Slash150k() public {
        uint256 premiumAvailable = 100_000 ether;
        uint256 requestedAmount = 250_000 ether;
        uint256 shortfall = 150_000 ether;
        uint256 highCoverageLimit = 2_000_000 ether;

        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.coverageLimit = highCoverageLimit;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, highCoverageLimit, keccak256("approved"));

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

        vm.expectEmit(true, true, true, false, address(claimManager));
        emit CollateralSwapped(POLICY_ID, claimId, collateralToken, shortfall, payoutToken, shortfall);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should pay 250k total");
        assertEq(
            payoutTokenMock.balanceOf(payoutReceiver),
            premiumAvailable + shortfall,
            "Receiver should get 100k from reserve + 150k from slashing"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    PREMIUM/PAYOUT TOKEN CONVERSION
    //////////////////////////////////////////////////////////////*/

    function test_approveClaim_WhenPremiumTokenDifferentFromPayoutToken_ConvertsAndPays() public {
        uint256 requestedAmount = 500 ether;
        uint256 premiumAvailable = 600 ether;
        uint256 swappedAmount = 550 ether;

        MockToken differentPremiumToken = new MockToken("Premium", "PREM");

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(address(differentPremiumToken));

        swapperMock.setSwapOutput(swappedAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.expectEmit(true, true, true, false, address(claimManager));
        emit CollateralSwapped(
            POLICY_ID, claimId, address(differentPremiumToken), requestedAmount, payoutToken, requestedAmount
        );

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should be capped at requested amount");
        assertEq(
            payoutTokenMock.balanceOf(payoutReceiver),
            requestedAmount,
            "Receiver should get requested amount (capped to prevent over-payment)"
        );
    }

    function test_approveClaim_WhenPremiumTokenDifferent_PartialReserve_ConvertsAndSlashes() public {
        uint256 requestedAmount = 1000 ether;
        uint256 premiumAvailable = 400 ether;
        uint256 swappedPremiumAmount = 400 ether;
        uint256 shortfall = requestedAmount - swappedPremiumAmount;

        MockToken differentPremiumToken = new MockToken("Premium", "PREM");

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(address(differentPremiumToken));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = shortfall;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), shortfall);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        swapperMock.setSwapOutput(swappedPremiumAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.expectEmit(true, true, true, false, address(claimManager));
        emit CollateralSwapped(
            POLICY_ID, claimId, address(differentPremiumToken), premiumAvailable, payoutToken, swappedPremiumAmount
        );

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertGe(record.payoutAmount, swappedPremiumAmount, "Should pay at least the premium conversion amount");
        assertGt(payoutTokenMock.balanceOf(payoutReceiver), 0, "Receiver should receive payout tokens");
    }

    function test_approveClaim_WhenPremiumTokenDifferent_ConversionYieldsMore_StillSlashesCorrectShortfall() public {
        uint256 requestedAmount = 1000 ether;
        uint256 premiumAvailable = 600 ether;
        uint256 swappedPremiumAmount = 720 ether;
        uint256 shortfall = requestedAmount - swappedPremiumAmount;

        MockToken differentPremiumToken = new MockToken("Premium", "PREM");

        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(address(differentPremiumToken));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = shortfall;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), shortfall);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        swapperMock.setSwapOutput(swappedPremiumAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(
            record.payoutAmount,
            swappedPremiumAmount + shortfall,
            "Should pay 720 from premium + 280 from slashing = 1000"
        );
        assertEq(
            payoutTokenMock.balanceOf(payoutReceiver),
            swappedPremiumAmount + shortfall,
            "Receiver should get full requested amount"
        );
    }

    /*//////////////////////////////////////////////////////////////
                           REJECT CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_rejectClaim_WhenPaused_Reverts() public {
        uint256 claimId = _fileClaim();

        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(claimOperator);
        claimManager.rejectClaim(POLICY_ID, claimId, "fraud detected");
    }

    function test_rejectClaim_WhenClaimNotFiled_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ClaimNotFiled.selector, POLICY_ID, 0));
        vm.prank(claimOperator);
        claimManager.rejectClaim(POLICY_ID, 0, "invalid");
    }

    function test_rejectClaim_WhenCallerNotOperator_Reverts() public {
        uint256 claimId = _fileClaim();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.CLAIM_OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.rejectClaim(POLICY_ID, claimId, "unauthorized rejection");
    }

    function test_rejectClaim_WhenValid_RejectsClaimAndEmits() public {
        uint256 claimId = _fileClaim();

        string memory reason = "insufficient evidence";

        vm.expectEmit(true, false, false, true, address(claimManager));
        emit ClaimRejected(POLICY_ID, claimId, reason, block.timestamp);

        vm.prank(claimOperator);
        claimManager.rejectClaim(POLICY_ID, claimId, reason);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected), "Status should be Rejected");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
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

    function test_claimRecord_WhenClaimFiled_ReturnsClaimData() public {
        uint256 claimId = _fileClaim();

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Filed), "Status mismatch");
        assertEq(record.reporter, buyer, "Reporter mismatch");
        assertEq(record.evidenceHash, evidenceHash, "EvidenceHash mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                            POLICY CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_policyClaim_WhenNoClaims_ReturnsDefaults() public view {
        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 0, "ClaimCount should be 0");
        assertEq(state.totalPaidOut, 0, "TotalPaidOut should be 0");
    }

    function test_policyClaim_AfterFilingClaim_UpdatesClaimCount() public {
        _fileClaim();

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 1, "ClaimCount should be 1 after filing");
        assertEq(state.totalPaidOut, 0, "TotalPaidOut should still be 0 before approval");
    }

    function test_policyClaim_AfterApprovingClaim_UpdatesTotalPaidOut() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);

        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));

        uint256 swapOutput = 450 ether;
        swapperMock.setSwapOutput(swapOutput);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 1, "ClaimCount should be 1");
        assertEq(state.totalPaidOut, swapOutput, "TotalPaidOut should match payout amount");
    }

    function test_policyClaim_AfterMultipleClaims_AccumulatesTotalPaidOut() public {
        uint256 halfCoverage = COVERAGE_LIMIT / 2;
        bytes32 evidenceHash1 = keccak256("evidence-1");
        bytes32 evidenceHash2 = keccak256("evidence-2");

        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, halfCoverage, evidenceHash1);

        vm.prank(buyer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, halfCoverage, evidenceHash2);

        specMock.setEvaluationResult(true, halfCoverage, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = halfCoverage;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), halfCoverage * 2);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(halfCoverage);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId2, "");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 2, "ClaimCount should be 2");
        assertEq(state.totalPaidOut, COVERAGE_LIMIT, "TotalPaidOut should equal coverage limit");
    }

    /*//////////////////////////////////////////////////////////////
                          REMAINING COVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_remainingCoverage_WhenNoClaims_ReturnsFullCoverage() public view {
        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remaining, COVERAGE_LIMIT, "Should return full coverage limit");
    }

    function test_remainingCoverage_AfterPartialClaim_ReturnsReduced() public {
        uint256 claimAmount = 400 ether;
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, claimAmount, evidenceHash);

        specMock.setEvaluationResult(true, claimAmount, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claimAmount;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), claimAmount);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(claimAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remaining, COVERAGE_LIMIT - claimAmount, "Remaining should be reduced by claim amount");
    }

    function test_remainingCoverage_AfterFullCoverage_ReturnsZero() public {
        vm.prank(buyer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COVERAGE_LIMIT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), COVERAGE_LIMIT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(COVERAGE_LIMIT);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        uint256 remaining = claimManager.remainingCoverage(POLICY_ID);
        assertEq(remaining, 0, "Remaining should be zero after full coverage exhausted");
    }

    /*//////////////////////////////////////////////////////////////
                       PENDING CLAIM COUNT
    //////////////////////////////////////////////////////////////*/

    function test_pendingClaimCount_WhenNoClaims_ReturnsZero() public view {
        uint256 pending = claimManager.pendingClaimCount(POLICY_ID);
        assertEq(pending, 0, "Should have no pending claims");
    }

    function test_pendingClaimCount_AfterFilingClaim_IncrementsCount() public {
        _fileClaim();

        uint256 pending = claimManager.pendingClaimCount(POLICY_ID);
        assertEq(pending, 1, "Should have 1 pending claim");
    }

    function test_pendingClaimCount_AfterApprovingClaim_DecrementsCount() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), SLASH_AMOUNT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(SLASH_AMOUNT);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");

        uint256 pending = claimManager.pendingClaimCount(POLICY_ID);
        assertEq(pending, 0, "Should have no pending claims after approval");
    }

    function test_pendingClaimCount_AfterRejectingClaim_DecrementsCount() public {
        uint256 claimId = _fileClaim();

        vm.prank(claimOperator);
        claimManager.rejectClaim(POLICY_ID, claimId, "rejected");

        uint256 pending = claimManager.pendingClaimCount(POLICY_ID);
        assertEq(pending, 0, "Should have no pending claims after rejection");
    }

    function test_pendingClaimCount_WithMultiplePendingClaims_TracksCorrectly() public {
        bytes32 evidenceHash1 = keccak256("evidence-1");
        bytes32 evidenceHash2 = keccak256("evidence-2");
        bytes32 evidenceHash3 = keccak256("evidence-3");

        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, 100 ether, evidenceHash1);

        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, 200 ether, evidenceHash2);

        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, 300 ether, evidenceHash3);

        uint256 pending = claimManager.pendingClaimCount(POLICY_ID);
        assertEq(pending, 3, "Should have 3 pending claims");
    }

    function test_approveClaim_WhenCoverageExhaustedAtExecution_PaysZero() public {
        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash);

        bytes32 evidenceHash2 = keccak256("evidence-2");
        vm.prank(buyer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, 100 ether, evidenceHash2);

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = COVERAGE_LIMIT;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), COVERAGE_LIMIT);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(COVERAGE_LIMIT);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        assertEq(claimManager.remainingCoverage(POLICY_ID), 0, "No coverage should remain after first claim");

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ZeroPayoutAmount.selector, POLICY_ID));
        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId2, "");
    }

    function test_approveClaim_WhenSlashingReturnsZeroButArraysNonEmpty_Reverts() public {
        uint256 claimId = _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ZeroPayoutAmount.selector, POLICY_ID));
        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId, "");
    }

    /*//////////////////////////////////////////////////////////////
                        FILE AND RESOLVE CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_fileAndResolveClaim_WhenPaused_Reverts() public {
        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileAndResolveClaim_WhenCallerNotOperator_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.CLAIM_OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileAndResolveClaim_WhenEvidenceHashZero_Reverts() public {
        vm.expectRevert(IClaimManager.InvalidEvidenceHash.selector);
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, COVERAGE_LIMIT, bytes32(0), "");
    }

    function test_fileAndResolveClaim_WhenRequestedAmountZero_Reverts() public {
        vm.expectRevert(IClaimManager.ZeroAmount.selector);
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, 0, evidenceHash, "");
    }

    function test_fileAndResolveClaim_WhenMultiplePartialClaims_AllowsMultipleClaims() public {
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
        uint256 claimId1 = claimManager.fileAndResolveClaim(POLICY_ID, halfCoverage, evidenceHash1, "");

        bytes32 evidenceHash2 = keccak256("evidence-2");
        collateralTokenMock.mint(address(slashingManager), halfCoverage);

        vm.prank(claimOperator);
        uint256 claimId2 = claimManager.fileAndResolveClaim(POLICY_ID, halfCoverage, evidenceHash2, "");

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

    function test_fileClaim_WhenMultiplePendingClaims_EscrowRemainsLockedUntilAllResolved() public {
        uint256 halfCoverage = COVERAGE_LIMIT / 2;
        bytes32 evidenceHash1 = keccak256("evidence-1");
        bytes32 evidenceHash2 = keccak256("evidence-2");

        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, halfCoverage, evidenceHash1);

        assertTrue(premiumReserveMock.isClaimLockSet(POLICY_ID), "Escrow should be locked after first claim");
        assertEq(claimManager.pendingClaimCount(POLICY_ID), 1, "Pending count should be 1");

        vm.prank(buyer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, halfCoverage, evidenceHash2);

        assertTrue(premiumReserveMock.isClaimLockSet(POLICY_ID), "Escrow should remain locked");
        assertEq(claimManager.pendingClaimCount(POLICY_ID), 2, "Pending count should be 2");

        specMock.setEvaluationResult(true, halfCoverage, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = halfCoverage;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), halfCoverage * 2);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(halfCoverage);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        assertTrue(premiumReserveMock.isClaimLockSet(POLICY_ID), "Escrow should remain locked with pending claim");
        assertEq(claimManager.pendingClaimCount(POLICY_ID), 1, "Pending count should be 1 after first approval");

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId2, "");

        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Escrow should be unlocked when all claims resolved");
        assertEq(claimManager.pendingClaimCount(POLICY_ID), 0, "Pending count should be 0");
    }

    function test_approveClaim_WhenConcurrentClaimsExceedCoverage_CapsPayoutToRemaining() public {
        uint256 claimAmount = 600 ether;
        uint256 expectedSecondPayout = COVERAGE_LIMIT - claimAmount;
        bytes32 evidenceHash1 = keccak256("evidence-1");
        bytes32 evidenceHash2 = keccak256("evidence-2");

        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, claimAmount, evidenceHash1);

        vm.prank(buyer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, claimAmount, evidenceHash2);

        specMock.setEvaluationResult(true, claimAmount, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = claimAmount;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), claimAmount);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(claimAmount);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        IClaimManager.ClaimRecord memory record1 = claimManager.claimRecord(POLICY_ID, claimId1);
        assertEq(record1.payoutAmount, claimAmount, "First claim should get full amount");
        assertEq(claimManager.remainingCoverage(POLICY_ID), expectedSecondPayout, "Remaining should be 400");

        amounts[0] = expectedSecondPayout;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), expectedSecondPayout);
        swapperMock.setSwapOutput(expectedSecondPayout);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId2, "");

        IClaimManager.ClaimRecord memory record2 = claimManager.claimRecord(POLICY_ID, claimId2);
        assertEq(record2.payoutAmount, expectedSecondPayout, "Second claim should be capped to remaining coverage");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.totalPaidOut, COVERAGE_LIMIT, "Total paid should equal coverage limit");
        assertEq(claimManager.remainingCoverage(POLICY_ID), 0, "No coverage should remain");
    }

    function test_fileAndResolveClaim_WhenSpecRejects_RejectsAtomically() public {
        specMock.setEvaluationResult(false, 0, keccak256("rejected"));

        vm.expectEmit(true, true, false, true, address(claimManager));
        emit ClaimFiled(POLICY_ID, 0, claimOperator, evidenceHash, COVERAGE_LIMIT, block.timestamp);

        vm.expectEmit(true, true, false, false, address(claimManager));
        emit ClaimRejected(POLICY_ID, 0, "Spec evaluation failed", block.timestamp);

        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected), "Status should be Rejected");
        assertEq(record.reporter, claimOperator, "Reporter should be claimOperator");
        assertEq(record.filedAt, block.timestamp, "FiledAt mismatch");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
    }

    function test_fileAndResolveClaim_WhenSpecApproves_ExecutesPayoutAtomically() public {
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
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Status should be Approved");
        assertEq(record.reporter, claimOperator, "Reporter should be claimOperator");
        assertEq(record.filedAt, block.timestamp, "FiledAt mismatch");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertEq(record.payoutAmount, swapOutput, "PayoutAmount mismatch");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
    }

    function test_fileAndResolveClaim_WhenPremiumReserveSufficient_NoSlashing() public {
        uint256 requestedAmount = 70 ether;
        uint256 premiumAvailable = 100 ether;

        specMock.setEvaluationResult(true, requestedAmount, keccak256("approved"));
        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(payoutToken);

        payoutTokenMock.mint(address(premiumReserveMock), premiumAvailable);

        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Status should be Approved");
        assertEq(record.payoutAmount, requestedAmount, "Payout should equal requested amount");
    }

    function test_fileAndResolveClaim_FilesAndResolvesInSameBlock() public {
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
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);

        assertEq(record.filedAt, record.resolvedAt, "Filing and resolution should happen in same block");
        assertEq(record.filedAt, block.timestamp, "Timestamps should match current block");
    }

    function test_fileAndResolveClaim_WhenPolicyNotFound_Reverts() public {
        uint256 invalidPolicyId = 999;
        policyMock.setPolicyMetadata(
            invalidPolicyId,
            IPolicy.PolicyMetadata({
                buyer: address(0),
                beneficiary: address(0),
                premiumToken: address(0),
                basePremium: 0,
                payoutToken: address(0),
                pool: address(0),
                coverageLimit: 0,
                payoutReceiver: address(0),
                poolPolicyId: bytes32(0),
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
        claimManager.fileAndResolveClaim(invalidPolicyId, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileAndResolveClaim_WhenRequestedAmountExceedsCoverage_Reverts() public {
        uint256 excessAmount = COVERAGE_LIMIT + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.RequestedAmountExceedsRemainingCoverage.selector, POLICY_ID, excessAmount, COVERAGE_LIMIT
            )
        );
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, excessAmount, evidenceHash, "");
    }

    function test_fileAndResolveClaim_WhenBeforeCoverageWindow_Reverts() public {
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
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileAndResolveClaim_WhenAfterCoverageWindow_Reverts() public {
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
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileAndResolveClaim_WhenEscrowAlreadyReleased_Reverts() public {
        premiumReserveMock.setEscrowReleased(POLICY_ID, true);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.EscrowAlreadyReleased.selector, POLICY_ID));
        vm.prank(claimOperator);
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash, "");
    }

    function test_fileAndResolveClaim_WhenPremiumReservePartial_SlashesShortfall() public {
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
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should pay full requested amount from premium + slashing");
        assertEq(
            payoutTokenMock.balanceOf(payoutReceiver),
            premiumAvailable + shortfall,
            "Receiver should get premium + slashed amount"
        );
    }

    function test_fileAndResolveClaim_WhenPremiumTokenDifferent_ConvertsAndPays() public {
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
        uint256 claimId = claimManager.fileAndResolveClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount, "Should be capped at requested amount");
        assertEq(
            payoutTokenMock.balanceOf(payoutReceiver),
            requestedAmount,
            "Receiver should get requested amount (capped to prevent over-payment)"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        MULTIPLE CLAIMS SCENARIOS
    //////////////////////////////////////////////////////////////*/

    function test_multipleClaims_WhenSomeApprovedSomeRejected_TracksCorrectly() public {
        bytes32 evidenceHash1 = keccak256("evidence-1");
        bytes32 evidenceHash2 = keccak256("evidence-2");
        bytes32 evidenceHash3 = keccak256("evidence-3");

        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, 300 ether, evidenceHash1);

        vm.prank(buyer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, 400 ether, evidenceHash2);

        vm.prank(buyer);
        uint256 claimId3 = claimManager.fileClaim(POLICY_ID, 300 ether, evidenceHash3);

        assertEq(claimManager.pendingClaimCount(POLICY_ID), 3, "Should have 3 pending claims");

        specMock.setEvaluationResult(true, 300 ether, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 300 ether;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), 300 ether);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(300 ether);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        assertEq(claimManager.pendingClaimCount(POLICY_ID), 2, "Should have 2 pending claims after first approval");
        assertEq(claimManager.remainingCoverage(POLICY_ID), 700 ether, "700 ether should remain");

        vm.prank(claimOperator);
        claimManager.rejectClaim(POLICY_ID, claimId2, "insufficient evidence");

        assertEq(claimManager.pendingClaimCount(POLICY_ID), 1, "Should have 1 pending claim after rejection");
        assertEq(claimManager.remainingCoverage(POLICY_ID), 700 ether, "Coverage should remain unchanged by rejection");

        amounts[0] = 300 ether;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), 300 ether);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId3, "");

        assertEq(claimManager.pendingClaimCount(POLICY_ID), 0, "Should have no pending claims");
        assertEq(claimManager.remainingCoverage(POLICY_ID), 400 ether, "400 ether should remain");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.claimCount, 3, "Should have 3 total claims");
        assertEq(state.totalPaidOut, 600 ether, "Should have paid 600 ether (300 + 0 + 300)");

        IClaimManager.ClaimRecord memory record1 = claimManager.claimRecord(POLICY_ID, claimId1);
        IClaimManager.ClaimRecord memory record2 = claimManager.claimRecord(POLICY_ID, claimId2);
        IClaimManager.ClaimRecord memory record3 = claimManager.claimRecord(POLICY_ID, claimId3);

        assertEq(uint8(record1.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim 1 should be approved");
        assertEq(uint8(record2.status), uint8(IClaimManager.ClaimStatus.Rejected), "Claim 2 should be rejected");
        assertEq(uint8(record3.status), uint8(IClaimManager.ClaimStatus.Approved), "Claim 3 should be approved");

        assertEq(record1.payoutAmount, 300 ether, "Claim 1 payout mismatch");
        assertEq(record2.payoutAmount, 0, "Claim 2 should have zero payout");
        assertEq(record3.payoutAmount, 300 ether, "Claim 3 payout mismatch");
    }

    function test_fileClaim_AfterPartialPayout_RespectReducedCoverage() public {
        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, 600 ether, evidenceHash);

        specMock.setEvaluationResult(true, 600 ether, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 600 ether;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), 600 ether);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(600 ether);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        assertEq(claimManager.remainingCoverage(POLICY_ID), 400 ether, "400 ether should remain");

        bytes32 evidenceHash2 = keccak256("evidence-2");
        vm.expectRevert(
            abi.encodeWithSelector(
                IClaimManager.RequestedAmountExceedsRemainingCoverage.selector, POLICY_ID, 500 ether, 400 ether
            )
        );
        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, 500 ether, evidenceHash2);

        vm.prank(buyer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, 400 ether, evidenceHash2);

        assertEq(claimId2, 1, "Second claim should have ID 1");

        amounts[0] = 400 ether;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), 400 ether);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId2, "");

        assertEq(claimManager.remainingCoverage(POLICY_ID), 0, "No coverage should remain");
        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.totalPaidOut, COVERAGE_LIMIT, "Total payout should equal coverage limit");
    }

    function test_multipleClaims_SequentialWaterfallDepletion() public {
        uint256 premiumAvailable = 200_000 ether;
        uint256 claim1Amount = 300_000 ether;
        uint256 claim2Amount = 200_000 ether;

        premiumReserveMock.setPremiumAvailable(POLICY_ID, premiumAvailable);
        premiumReserveMock.setPremiumToken(address(payoutTokenMock));

        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.coverageLimit = 1_000_000 ether;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        bytes32 evidenceHash1 = keccak256("evidence-1");
        bytes32 evidenceHash2 = keccak256("evidence-2");

        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, claim1Amount, evidenceHash1);

        specMock.setEvaluationResult(true, claim1Amount, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 100_000 ether;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), 100_000 ether);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(100_000 ether);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        IClaimManager.ClaimRecord memory record1 = claimManager.claimRecord(POLICY_ID, claimId1);
        assertEq(record1.payoutAmount, claim1Amount, "Claim 1 should get full 300K (200K reserve + 100K slash)");

        vm.prank(buyer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, claim2Amount, evidenceHash2);

        amounts[0] = claim2Amount;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), claim2Amount);
        swapperMock.setSwapOutput(claim2Amount);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId2, "");

        IClaimManager.ClaimRecord memory record2 = claimManager.claimRecord(POLICY_ID, claimId2);
        assertEq(record2.payoutAmount, claim2Amount, "Claim 2 should get full 200K from slashing only");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.totalPaidOut, 500_000 ether, "Total paid should be 500K");
        assertEq(claimManager.remainingCoverage(POLICY_ID), 500_000 ether, "500K coverage should remain");
    }

    function test_multipleClaims_ConcurrentFilingWithRaceCondition() public {
        bytes32 evidenceHash1 = keccak256("evidence-1");
        bytes32 evidenceHash2 = keccak256("evidence-2");

        vm.prank(buyer);
        uint256 claimId1 = claimManager.fileClaim(POLICY_ID, 700 ether, evidenceHash1);

        vm.prank(buyer);
        uint256 claimId2 = claimManager.fileClaim(POLICY_ID, 500 ether, evidenceHash2);

        assertEq(claimManager.pendingClaimCount(POLICY_ID), 2, "Should have 2 pending claims");
        assertTrue(premiumReserveMock.isClaimLockSet(POLICY_ID), "Escrow should be locked");

        specMock.setEvaluationResult(true, 700 ether, keccak256("approved"));
        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 700 ether;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), 700 ether);
        slashingManagerMock.setTokenToTransfer(address(collateralTokenMock));
        swapperMock.setSwapOutput(700 ether);
        swapperMock.setPayoutToken(payoutToken);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId1, "");

        assertEq(claimManager.remainingCoverage(POLICY_ID), 300 ether, "300 ether should remain");
        assertEq(claimManager.pendingClaimCount(POLICY_ID), 1, "Should have 1 pending claim");
        assertTrue(premiumReserveMock.isClaimLockSet(POLICY_ID), "Escrow should still be locked");

        amounts[0] = 300 ether;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManager), 300 ether);
        swapperMock.setSwapOutput(300 ether);

        vm.prank(claimOperator);
        claimManager.approveClaim(POLICY_ID, claimId2, "");

        IClaimManager.ClaimRecord memory record2 = claimManager.claimRecord(POLICY_ID, claimId2);
        assertEq(record2.requestedAmount, 500 ether, "Requested amount should be preserved");
        assertEq(record2.payoutAmount, 300 ether, "Payout should be capped to remaining coverage");

        assertEq(claimManager.remainingCoverage(POLICY_ID), 0, "No coverage should remain");
        assertEq(claimManager.pendingClaimCount(POLICY_ID), 0, "Should have no pending claims");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Escrow should be unlocked");

        IClaimManager.PolicyClaim memory state = claimManager.policyClaim(POLICY_ID);
        assertEq(state.totalPaidOut, COVERAGE_LIMIT, "Total payout should equal coverage limit");
        assertEq(state.claimCount, 2, "Should have 2 claims");
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
        assertEq(claimManager.priceFeed(), priceFeed, "PriceFeed should be preserved");
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
            premiumToken: premiumToken,
            basePremium: BASE_PREMIUM,
            payoutToken: payoutToken,
            pool: pool,
            coverageLimit: COVERAGE_LIMIT,
            payoutReceiver: payoutReceiver,
            poolPolicyId: keccak256("pool-policy-id"),
            specId: keccak256("MorphoSpec"),
            termsHash: keccak256("terms-hash"),
            policyCommit: policyCommit,
            committeeId: uint96(123),
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + COVERAGE_DURATION),
            operator: operator
        });
    }

    function _fileClaim() private returns (uint256 claimId) {
        vm.prank(buyer);
        claimId = claimManager.fileClaim(POLICY_ID, COVERAGE_LIMIT, evidenceHash);
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

    function setPolicyMetadata(uint256 policyId, IPolicy.PolicyMetadata memory metadata) external {
        _metadata[policyId] = metadata;
    }

    function policyMetadata(uint256 policyId) external view returns (IPolicy.PolicyMetadata memory) {
        return _metadata[policyId];
    }
}

contract MockPremiumReserve {
    mapping(uint256 => bool) private _escrowReleased;
    mapping(uint256 => bool) private _claimLocked;
    mapping(uint256 => uint256) private _premiumAvailable;
    address private _premiumToken;

    error EscrowNotLocked(uint256 policyId);

    function setEscrowReleased(uint256 policyId, bool released) external {
        _escrowReleased[policyId] = released;
    }

    function isEscrowReleased(uint256 policyId) external view returns (bool) {
        return _escrowReleased[policyId];
    }

    function setClaimLockStatus(uint256 policyId, bool locked) external {
        _claimLocked[policyId] = locked;
    }

    function isClaimLockSet(uint256 policyId) external view returns (bool) {
        return _claimLocked[policyId];
    }

    function setPremiumAvailable(uint256 policyId, uint256 amount) external {
        _premiumAvailable[policyId] = amount;
    }

    function setPremiumToken(address token) external {
        _premiumToken = token;
    }

    function payClaim(
        uint256 policyId,
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
