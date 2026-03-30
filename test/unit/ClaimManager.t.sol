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
        claimManager = ClaimManager(payable(proxy));

        vm.label(address(claimManager), "ClaimManager");

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
        assertFalse(claimManager.paused());
    }

    function test_initialize_SetsDefaultMaxSwapSlippageBps() public view {
        assertEq(claimManager.maxSwapSlippageBps(), 200);
    }

    function test_initialize_WhenAlreadyInitialized_Reverts() public {
        vm.expectRevert();
        claimManager.initialize(admin, specRegistry, slashingManager, swapper, policy);
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
        assertTrue(claimManager.paused());
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
        assertTrue(claimManager.paused());

        claimManager.unpause();
        assertFalse(claimManager.paused());
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

    function test_setMaxSwapSlippageBps_WhenMaxMinusOne_Succeeds() public {
        vm.prank(admin);
        claimManager.setMaxSwapSlippageBps(9999);
        assertEq(claimManager.maxSwapSlippageBps(), 9999);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM APPROVAL REQUIRED
    //////////////////////////////////////////////////////////////*/

    function test_claimApprovalRequired_WhenFreshPolicy_ReturnsFalse() public view {
        assertFalse(claimManager.claimApprovalRequired(POLICY_ID));
    }

    /*//////////////////////////////////////////////////////////////
                           APPROVE NEXT CLAIM
    //////////////////////////////////////////////////////////////*/

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

    function test_approveNextClaim_WhenNoApprovalRequired_Succeeds() public {
        assertFalse(claimManager.claimApprovalRequired(POLICY_ID));

        vm.expectEmit(true, true, true, true, address(claimManager));
        emit NextClaimApproved(POLICY_ID, operator);

        vm.prank(operator);
        claimManager.approveNextClaim(POLICY_ID);

        assertFalse(claimManager.claimApprovalRequired(POLICY_ID));
    }

    /*//////////////////////////////////////////////////////////////
                                RECEIVE
    //////////////////////////////////////////////////////////////*/

    function test_receive_AcceptsNativeETH() public {
        uint256 amount = 1 ether;
        vm.deal(address(this), amount);

        uint256 balanceBefore = address(claimManager).balance;
        (bool sent,) = address(claimManager).call{value: amount}("");

        assertTrue(sent);
        assertEq(address(claimManager).balance, balanceBefore + amount);
    }

    /*//////////////////////////////////////////////////////////////
                            RECOVER TOKENS
    //////////////////////////////////////////////////////////////*/

    event TokensRecovered(address indexed token, address indexed to, uint256 amount);

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

    function test_fileClaim_WhenSlashingReturnsMismatchedArrayLengths_Reverts() public {
        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory tokens = new address[](2);
        tokens[0] = collateralToken;
        tokens[1] = payoutToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SLASH_AMOUNT;
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
        assertEq(balanceAfter - balanceBefore, requestedAmount);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount);
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
        assertTrue(claim.status == IClaimManager.ClaimStatus.Approved);
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

    function test_fileClaim_WhenNativeETHCollateralSwap_CapsOutputAtRemainingPayout() public {
        uint256 requestedAmount = 400 ether;
        uint256 excessiveSwapOutput = 600 ether;

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = NATIVE_ETH;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(assets, amounts);

        vm.deal(address(slashingManagerMock), requestedAmount);
        slashingManagerMock.setTokenToTransfer(NATIVE_ETH);

        swapperMock.setSwapOutput(excessiveSwapOutput);
        swapperMock.setPayoutToken(payoutToken);

        uint256 balanceBefore = payoutTokenMock.balanceOf(beneficiary);

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(
            payoutTokenMock.balanceOf(beneficiary) - balanceBefore,
            requestedAmount,
            "Beneficiary should receive capped ERC20 amount"
        );

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount);
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

    function test_fileClaim_WhenERC20CollateralSwapToNativeETH_CapsOutputAtRemainingPayout() public {
        uint256 requestedAmount = 400 ether;
        uint256 excessiveSwapOutput = 600 ether;

        IPolicyManager.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutToken = NATIVE_ETH;
        policyMock.setPolicyMetadata(POLICY_ID, metadata);

        specMock.setEvaluationResult(true, keccak256("approved"));

        address[] memory assets = new address[](1);
        assets[0] = collateralToken;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = requestedAmount;
        slashingManagerMock.setSlashResult(assets, amounts);
        collateralTokenMock.mint(address(slashingManagerMock), requestedAmount);
        slashingManagerMock.setTokenToTransfer(collateralToken);

        swapperMock.setSwapOutput(excessiveSwapOutput);
        swapperMock.setPayoutToken(NATIVE_ETH);
        vm.deal(address(swapperMock), excessiveSwapOutput);

        uint256 balanceBefore = beneficiary.balance;

        vm.prank(claimer);
        uint256 claimId = claimManager.fileClaim(POLICY_ID, requestedAmount, evidenceHash, "");

        assertEq(beneficiary.balance - balanceBefore, requestedAmount);

        IClaimManager.ClaimRecord memory record = claimManager.claimRecord(POLICY_ID, claimId);
        assertEq(record.payoutAmount, requestedAmount);
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
                                PAUSED
    //////////////////////////////////////////////////////////////*/

    function test_paused_WhenNotPaused_ReturnsFalse() public view {
        assertFalse(claimManager.paused());
    }

    function test_paused_WhenPaused_ReturnsTrue() public {
        vm.prank(admin);
        claimManager.pause();
        assertTrue(claimManager.paused());
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

    function getTokenAmount(address token, uint256 usdValue) external view returns (uint256) {
        uint256 price = _pricePerToken[token];
        if (price == 0) {
            return usdValue;
        }
        return (usdValue * 1e18) / price;
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
        uint256 out = _swapOutputs[tokenIn];
        return out > 0 ? out : amountIn;
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

contract MockSwapperWithTracking {
    uint256 private _swapOutput;
    address private _payoutToken;
    uint256 public lastAmountOutMin;

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
    address private _payoutToken;

    receive() external payable {}

    function setSwapOutput(address tokenIn, uint256 output) external {
        _swapOutputs[tokenIn] = output;
    }

    function setPayoutToken(address token) external {
        _payoutToken = token;
    }

    function quoteSwap(address tokenIn, address, uint256 amountIn) external view returns (uint256) {
        uint256 out = _swapOutputs[tokenIn];
        return out > 0 ? out : amountIn;
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
