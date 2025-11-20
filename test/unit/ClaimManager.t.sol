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
    MockToken internal collateralTokenMock;
    MockToken internal payoutTokenMock;

    bytes32 internal evidenceHash;
    bytes32 internal policyCommit;

    event ClaimFiled(uint256 indexed policyId, address indexed reporter, bytes32 evidenceHash, uint256 timestamp);
    event ClaimApproved(uint256 indexed policyId, address indexed beneficiary, uint256 payoutAmount, uint256 timestamp);
    event ClaimRejected(uint256 indexed policyId, string reason, uint256 timestamp);
    event CollateralSwapped(
        uint256 indexed policyId,
        address indexed collateralToken,
        uint256 collateralAmount,
        address indexed payoutToken,
        uint256 payoutAmount
    );
    event SpecRegistrySet(address indexed specRegistry);
    event SlashingManagerSet(address indexed slashingManager);
    event SwapperSet(address indexed swapper);
    event PolicySet(address indexed policy);
    event PremiumReserveSet(address indexed premiumReserve);

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
        collateralTokenMock = new MockToken("Collateral", "COL");
        payoutTokenMock = new MockToken("Payout", "PAY");

        specRegistry = address(specRegistryMock);
        slashingManager = address(slashingManagerMock);
        swapper = address(swapperMock);
        policy = address(policyMock);
        premiumReserve = address(premiumReserveMock);
        collateralToken = address(collateralTokenMock);
        payoutToken = address(payoutTokenMock);

        vm.label(specRegistry, "SpecRegistry");
        vm.label(slashingManager, "SlashingManager");
        vm.label(swapper, "Swapper");
        vm.label(policy, "Policy");
        vm.label(premiumReserve, "PremiumReserve");
        vm.label(collateralToken, "CollateralToken");
        vm.label(payoutToken, "PayoutToken");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "ClaimManager.sol",
            abi.encodeCall(
                ClaimManager.initialize,
                (admin, claimOperator, specRegistry, slashingManager, swapper, policy, premiumReserve)
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
            address(0), claimOperator, specRegistry, slashingManager, swapper, policy, premiumReserve
        );
    }

    function test_initialize_WhenClaimOperatorZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(0), specRegistry, slashingManager, swapper, policy, premiumReserve);
    }

    function test_initialize_WhenSpecRegistryZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, claimOperator, address(0), slashingManager, swapper, policy, premiumReserve);
    }

    function test_initialize_WhenSlashingManagerZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, claimOperator, specRegistry, address(0), swapper, policy, premiumReserve);
    }

    function test_initialize_WhenSwapperZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, claimOperator, specRegistry, slashingManager, address(0), policy, premiumReserve);
    }

    function test_initialize_WhenPolicyZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(
            admin, claimOperator, specRegistry, slashingManager, swapper, address(0), premiumReserve
        );
    }

    function test_initialize_WhenPremiumReserveZero_Reverts() public {
        ClaimManager implementation = new ClaimManager();
        ClaimManager freshManager = ClaimManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IClaimManager.ZeroAddress.selector);
        freshManager.initialize(admin, claimOperator, specRegistry, slashingManager, swapper, policy, address(0));
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

    /*//////////////////////////////////////////////////////////////
                             FILE CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_fileClaim_WhenPaused_Reverts() public {
        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, evidenceHash);
    }

    function test_fileClaim_WhenEvidenceHashZero_Reverts() public {
        vm.expectRevert(IClaimManager.InvalidEvidenceHash.selector);
        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, bytes32(0));
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
        claimManager.fileClaim(invalidPolicyId, evidenceHash);
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
        claimManager.fileClaim(POLICY_ID, evidenceHash);
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
        claimManager.fileClaim(POLICY_ID, evidenceHash);
    }

    function test_fileClaim_WhenEscrowAlreadyReleased_Reverts() public {
        premiumReserveMock.setEscrowReleased(POLICY_ID, true);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.EscrowAlreadyReleased.selector, POLICY_ID));
        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, evidenceHash);
    }

    function test_fileClaim_WhenClaimAlreadyFiled_Reverts() public {
        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, evidenceHash);

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ClaimAlreadyFiled.selector, POLICY_ID));
        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, evidenceHash);
    }

    function test_fileClaim_WhenValid_StoresClaimAndEmits() public {
        vm.expectEmit(true, true, false, true, address(claimManager));
        emit ClaimFiled(POLICY_ID, buyer, evidenceHash, block.timestamp);

        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, evidenceHash);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Filed), "Status mismatch");
        assertEq(record.reporter, buyer, "Reporter mismatch");
        assertEq(record.filedAt, block.timestamp, "FiledAt mismatch");
        assertEq(record.evidenceHash, evidenceHash, "EvidenceHash mismatch");
        assertTrue(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock not set");
    }

    function test_fileClaim_WhenValidByNonBuyer_Succeeds() public {
        address reporter = makeAddr("reporter");

        vm.expectEmit(true, true, false, true, address(claimManager));
        emit ClaimFiled(POLICY_ID, reporter, evidenceHash, block.timestamp);

        vm.prank(reporter);
        claimManager.fileClaim(POLICY_ID, evidenceHash);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(record.reporter, reporter, "Reporter should be msg.sender");
    }

    /*//////////////////////////////////////////////////////////////
                           RESOLVE CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_resolveClaim_WhenPaused_Reverts() public {
        _fileClaim();

        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(claimOperator);
        claimManager.resolveClaim(POLICY_ID, "");
    }

    function test_resolveClaim_WhenClaimNotFiled_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ClaimNotFiled.selector, POLICY_ID));
        vm.prank(claimOperator);
        claimManager.resolveClaim(POLICY_ID, "");
    }

    function test_resolveClaim_WhenCallerNotOperator_Reverts() public {
        _fileClaim();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.CLAIM_OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.resolveClaim(POLICY_ID, "");
    }

    function test_resolveClaim_WhenSpecRejectsPayable_RejectsClaim() public {
        _fileClaim();

        specMock.setEvaluationResult(false, 0, keccak256("rejected"));

        vm.expectEmit(true, false, false, false, address(claimManager));
        emit ClaimRejected(POLICY_ID, "Spec evaluation failed", block.timestamp);

        vm.prank(claimOperator);
        claimManager.resolveClaim(POLICY_ID, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected), "Status should be Rejected");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertFalse(record.evaluationResult.isPayable, "Should not be payable");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
    }

    function test_resolveClaim_WhenNoCollateralSlashed_Reverts() public {
        _fileClaim();

        specMock.setEvaluationResult(true, COVERAGE_LIMIT, keccak256("approved"));
        slashingManagerMock.setSlashResult(new address[](0), new uint256[](0));

        vm.expectRevert(abi.encodeWithSelector(IClaimManager.NoCollateralSlashed.selector, POLICY_ID));
        vm.prank(claimOperator);
        claimManager.resolveClaim(POLICY_ID, "");
    }

    function test_resolveClaim_WhenSpecApproves_ExecutesPayoutAndEmits() public {
        _fileClaim();

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

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit CollateralSwapped(POLICY_ID, collateralToken, SLASH_AMOUNT, payoutToken, swapOutput);

        vm.expectEmit(true, true, false, true, address(claimManager));
        emit ClaimApproved(POLICY_ID, payoutReceiver, swapOutput, block.timestamp);

        vm.prank(claimOperator);
        claimManager.resolveClaim(POLICY_ID, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Approved), "Status should be Approved");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertEq(record.payoutAmount, swapOutput, "Payout amount mismatch");
        assertTrue(record.evaluationResult.isPayable, "Should be payable");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
    }

    function test_resolveClaim_WhenCollateralMatchesPayoutToken_TransfersDirect() public {
        _fileClaim();

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
        emit CollateralSwapped(POLICY_ID, collateralToken, SLASH_AMOUNT, collateralToken, SLASH_AMOUNT);

        vm.prank(claimOperator);
        claimManager.resolveClaim(POLICY_ID, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(record.payoutAmount, SLASH_AMOUNT, "Payout should equal slashed amount");
        assertEq(collateralTokenMock.balanceOf(payoutReceiver), SLASH_AMOUNT, "Receiver should get tokens");
    }

    function test_resolveClaim_WhenMultipleCollateralTypes_ProcessesAll() public {
        _fileClaim();

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

        vm.prank(claimOperator);
        claimManager.resolveClaim(POLICY_ID, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(record.payoutAmount, 500 ether, "Total payout should be sum of both swaps");
    }

    function test_resolveClaim_WhenZeroAmountCollateral_SkipsProcessing() public {
        _fileClaim();

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

        vm.prank(claimOperator);
        claimManager.resolveClaim(POLICY_ID, "");

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(record.payoutAmount, swapOutput, "Should only count non-zero amounts");
    }

    /*//////////////////////////////////////////////////////////////
                           REJECT CLAIM
    //////////////////////////////////////////////////////////////*/

    function test_rejectClaim_WhenPaused_Reverts() public {
        _fileClaim();

        vm.prank(admin);
        claimManager.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(claimOperator);
        claimManager.rejectClaim(POLICY_ID, "fraud detected");
    }

    function test_rejectClaim_WhenClaimNotFiled_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IClaimManager.ClaimNotFiled.selector, POLICY_ID));
        vm.prank(claimOperator);
        claimManager.rejectClaim(POLICY_ID, "invalid");
    }

    function test_rejectClaim_WhenCallerNotOperator_Reverts() public {
        _fileClaim();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                unauthorized,
                claimManager.CLAIM_OPERATOR_ROLE()
            )
        );
        vm.prank(unauthorized);
        claimManager.rejectClaim(POLICY_ID, "unauthorized rejection");
    }

    function test_rejectClaim_WhenValid_RejectsClaimAndEmits() public {
        _fileClaim();

        string memory reason = "insufficient evidence";

        vm.expectEmit(true, false, false, true, address(claimManager));
        emit ClaimRejected(POLICY_ID, reason, block.timestamp);

        vm.prank(claimOperator);
        claimManager.rejectClaim(POLICY_ID, reason);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Rejected), "Status should be Rejected");
        assertEq(record.resolvedAt, block.timestamp, "ResolvedAt mismatch");
        assertFalse(premiumReserveMock.isClaimLockSet(POLICY_ID), "Claim lock should be cleared");
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    function test_claimRecord_WhenClaimNotFiled_ReturnsDefault() public view {
        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.None), "Status should be None");
        assertEq(record.reporter, address(0), "Reporter should be zero");
        assertEq(record.filedAt, 0, "FiledAt should be zero");
        assertEq(record.resolvedAt, 0, "ResolvedAt should be zero");
        assertEq(record.evidenceHash, bytes32(0), "EvidenceHash should be zero");
        assertEq(record.payoutAmount, 0, "PayoutAmount should be zero");
    }

    function test_claimRecord_WhenClaimFiled_ReturnsClaimData() public {
        _fileClaim();

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID);
        assertEq(uint8(record.status), uint8(IClaimManager.ClaimStatus.Filed), "Status mismatch");
        assertEq(record.reporter, buyer, "Reporter mismatch");
        assertEq(record.evidenceHash, evidenceHash, "EvidenceHash mismatch");
    }

    function test_paused_WhenNotPaused_ReturnsFalse() public view {
        assertFalse(claimManager.paused(), "Should not be paused");
    }

    function test_paused_WhenPaused_ReturnsTrue() public {
        vm.prank(admin);
        claimManager.pause();
        assertTrue(claimManager.paused(), "Should be paused");
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
            termsHash: keccak256("terms-hash"),
            policyCommit: policyCommit,
            committeeId: uint96(123),
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + COVERAGE_DURATION),
            operator: operator
        });
    }

    function _fileClaim() private {
        vm.prank(buyer);
        claimManager.fileClaim(POLICY_ID, evidenceHash);
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

    function executeSlashing(bytes calldata, address, bytes32) external returns (address[] memory, uint256[] memory) {
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

    function setSwapOutput(uint256 output) external {
        _swapOutput = output;
    }

    function executeSwap(ISwapper.SwapParams calldata params) external returns (uint256) {
        require(
            MockToken(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn), "TransferFrom failed"
        );
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
}
