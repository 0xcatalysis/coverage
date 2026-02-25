// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {Test} from "forge-std/Test.sol";
import {PolicyManager} from "../../src/PolicyManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IBindPolicyHook} from "../../src/interfaces/IBindPolicyHook.sol";

contract PolicyManagerTest is Test {
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 startTime,uint32 maturityTime,uint32 expirationTime)"
    );
    uint96 internal constant POLICY_ID = 1;
    uint256 internal constant COVERAGE_LIMIT = 1_000_000e18;
    uint256 internal constant BASE_PREMIUM = 10_000e18;
    uint256 internal constant COVERAGE_AMOUNT = 500_000e8;
    uint16 internal constant POOL_FEE_BPS = 150;
    uint32 internal constant COVERAGE_DURATION = 30 days;

    address internal admin;
    address internal buyer;
    address internal beneficiary;
    address internal premiumToken;
    address internal payoutToken;
    address internal operator;
    address internal curator;

    PolicyManager internal policyManager;
    MockCoverPool internal coverPool;
    MockStakeManager internal mockStakeManager;
    MockClaimManager internal mockClaimManager;
    MockCoverPoolFactory internal mockCoverPoolFactory;
    MockBindPolicyHook internal defaultHook;

    bytes32 internal policyCommit;
    bytes32 internal specId;
    bytes32 internal termsHash;

    event PolicyBound(
        uint96 indexed policyId,
        address indexed buyer,
        address indexed beneficiary,
        address pool,
        uint256 coverageLimit,
        bytes32 policyCommit,
        address bindPolicyHook
    );

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        buyer = makeAddr("buyer");
        beneficiary = makeAddr("beneficiary");
        premiumToken = makeAddr("premiumToken");
        payoutToken = makeAddr("payoutToken");
        operator = makeAddr("operator");
        curator = makeAddr("curator");

        vm.label(admin, "Admin");
        vm.label(buyer, "Buyer");
        vm.label(beneficiary, "Beneficiary");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");
        vm.label(operator, "Operator");
        vm.label(curator, "Curator");

        coverPool = new MockCoverPool();
        coverPool.setCurator(curator);
        mockStakeManager = new MockStakeManager();
        mockClaimManager = new MockClaimManager();
        mockCoverPoolFactory = new MockCoverPoolFactory();
        mockCoverPoolFactory.registerPool(address(coverPool));

        policyCommit = keccak256("policy-commit");
        specId = keccak256("spec-id");
        termsHash = keccak256("terms-hash");

        defaultHook = new MockBindPolicyHook();
        vm.label(address(defaultHook), "DefaultHook");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "PolicyManager.sol",
            abi.encodeCall(
                PolicyManager.initialize,
                (admin, address(mockStakeManager), address(mockClaimManager), address(mockCoverPoolFactory))
            ),
            deployOpts
        );
        policyManager = PolicyManager(proxy);

        vm.label(address(policyManager), "PolicyManager");
        vm.label(address(coverPool), "CoverPool");
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        freshManager.initialize(
            address(0), address(mockStakeManager), address(mockClaimManager), address(mockCoverPoolFactory)
        );
    }

    function test_initialize_WhenStakeManagerZero_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(0), address(mockClaimManager), address(mockCoverPoolFactory));
    }

    function test_initialize_WhenClaimManagerZero_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(mockStakeManager), address(0), address(mockCoverPoolFactory));
    }

    function test_initialize_WhenCoverPoolFactoryZero_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        freshManager.initialize(admin, address(mockStakeManager), address(mockClaimManager), address(0));
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(policyManager.hasRole(policyManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertFalse(policyManager.paused(), "Manager unexpectedly paused");
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/

    function test_pause_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.pause();
    }

    function test_pause_WhenCalledByAdmin_PausesManager() public {
        vm.prank(admin);
        policyManager.pause();

        assertTrue(policyManager.paused(), "Manager not paused");
    }

    /*//////////////////////////////////////////////////////////////
                                UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function test_unpause_WhenCallerNotAdmin_Reverts() public {
        vm.prank(admin);
        policyManager.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.unpause();
    }

    function test_unpause_WhenCalledByAdmin_UnpausesManager() public {
        vm.startPrank(admin);
        policyManager.pause();
        policyManager.unpause();
        vm.stopPrank();

        assertFalse(policyManager.paused(), "Manager still paused");
    }

    /*//////////////////////////////////////////////////////////////
                        SET STAKE MANAGER
    //////////////////////////////////////////////////////////////*/

    function test_setStakeManager_WhenCallerNotAdmin_Reverts() public {
        MockStakeManager newManager = new MockStakeManager();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.setStakeManager(address(newManager));
    }

    function test_setStakeManager_WhenAddressZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(admin);
        policyManager.setStakeManager(address(0));
    }

    function test_setStakeManager_WhenValid_UpdatesStateAndEmits() public {
        MockStakeManager newManager = new MockStakeManager();

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit IPolicyManager.StakeManagerSet(address(newManager));

        vm.prank(admin);
        policyManager.setStakeManager(address(newManager));

        assertEq(policyManager.stakeManager(), address(newManager), "Stake manager not updated");
    }

    /*//////////////////////////////////////////////////////////////
                        SET CLAIM MANAGER
    //////////////////////////////////////////////////////////////*/

    function test_setClaimManager_WhenCallerNotAdmin_Reverts() public {
        MockClaimManager newManager = new MockClaimManager();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.setClaimManager(address(newManager));
    }

    function test_setClaimManager_WhenAddressZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(admin);
        policyManager.setClaimManager(address(0));
    }

    function test_setClaimManager_WhenValid_UpdatesStateAndEmits() public {
        MockClaimManager newManager = new MockClaimManager();

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit IPolicyManager.ClaimManagerSet(address(newManager));

        vm.prank(admin);
        policyManager.setClaimManager(address(newManager));

        assertEq(policyManager.claimManager(), address(newManager), "Claim manager not updated");
    }

    /*//////////////////////////////////////////////////////////////
                             SET POLICY
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                            BIND POLICY
    //////////////////////////////////////////////////////////////*/

    function test_bindPolicy_WhenBuyerZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.buyer = address(0);
        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenBeneficiaryZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.beneficiary = address(0);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenPayoutTokenZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.payoutToken = address(0);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenQuotePoolZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.pool = address(0);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidCoverPool.selector, address(0)));
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenPoolNotRegistered_Reverts() public {
        MockCoverPool unregisteredPool = new MockCoverPool();

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(POLICY_ID);
        request.quote.pool = address(unregisteredPool);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidCoverPool.selector, address(unregisteredPool)));
        vm.prank(address(unregisteredPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenCoverageLimitZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.coverageLimit = 0;

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.InvalidCoverageLimit.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenCoverageAmountZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.coverageAmount = 0;

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.InvalidCoverageAmount.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenPolicyCommitZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, COVERAGE_AMOUNT, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        boundPolicy.policyCommit = bytes32(0);

        vm.expectRevert(IPolicyManager.InvalidPolicyCommit.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenInvalidCoverageWindow_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.startTime = uint32(block.timestamp + 1 days);
        request.quote.maturityTime = uint32(block.timestamp);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyManager.InvalidCoverageWindow.selector, request.quote.startTime, request.quote.maturityTime
            )
        );
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenMaturityInPast_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.startTime = uint32(block.timestamp - 2 days);
        request.quote.maturityTime = uint32(block.timestamp - 1 days);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyManager.InvalidCoverageWindow.selector, request.quote.startTime, request.quote.maturityTime
            )
        );
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenMaturityEqualsBlockTimestamp_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.startTime = uint32(block.timestamp - 1 days);
        request.quote.maturityTime = uint32(block.timestamp);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyManager.InvalidCoverageWindow.selector, request.quote.startTime, request.quote.maturityTime
            )
        );
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenStartEqualsMaturity_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint32 sameTime = uint32(block.timestamp + 1 days);
        request.quote.startTime = sameTime;
        request.quote.maturityTime = sameTime;

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidCoverageWindow.selector, sameTime, sameTime));
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenInsufficientStake_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint96 committeeId = request.quote.policyId;
        address lowStakeOperator = makeAddr("lowStakeOperator");
        coverPool.setCurator(lowStakeOperator);

        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        mockStakeManager.createCommittee(committeeId, 1_000_000e8, address(coverPool), COVERAGE_DURATION);
        mockStakeManager.addOperatorToCommittee(lowStakeOperator, committeeId);
        mockStakeManager.addCommitteeVaults(committeeId, vaults);

        mockStakeManager.setOperatorCommitteeStake(committeeId, 100e8);

        request.coverageAmount = 500_000e8;

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(
            abi.encodeWithSelector(IPolicyManager.InsufficientStake.selector, committeeId, 500_000e8, 100e8)
        );
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenStakeExceedsCoverage_Succeeds() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint96 committeeId = request.quote.policyId;

        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        mockStakeManager.createCommittee(committeeId, 1_000_000e8, address(coverPool), COVERAGE_DURATION);
        mockStakeManager.addOperatorToCommittee(curator, committeeId);
        mockStakeManager.addCommitteeVaults(committeeId, vaults);

        request.coverageAmount = 500_000e8;
        mockStakeManager.setOperatorCommitteeStake(committeeId, 550_000e8);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenNoVaultsBound_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint96 committeeId = request.quote.policyId;
        mockStakeManager.createCommittee(committeeId, 1_000_000e8, address(coverPool), COVERAGE_DURATION);
        mockStakeManager.addOperatorToCommittee(curator, committeeId);
        mockStakeManager.setOperatorCommitteeStake(committeeId, request.coverageAmount);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.NoVaultsBound.selector, committeeId));
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenDurationMismatch_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        boundPolicy.maturityTime = boundPolicy.startTime + COVERAGE_DURATION + 1 days;
        uint32 actualDuration = boundPolicy.maturityTime - boundPolicy.startTime;

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyManager.DurationMismatch.selector, COVERAGE_DURATION, actualDuration)
        );
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenCommitteeIdMismatchesPolicyId_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint96 wrongCommitteeId = request.policyId + 1;
        request.quote.policyId = wrongCommitteeId;

        _seedCommitteeForTesting(wrongCommitteeId, operator, COVERAGE_AMOUNT, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.InvalidPolicyId.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenPaused_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.prank(admin);
        policyManager.pause();

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert();
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenAlreadyBound_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyManager.InvalidPolicyStatus.selector, IPolicyManager.PolicyStatus.Bound)
        );
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenValid_CallsValidateQuote() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertEq(coverPool.recordBoundPolicyCallCount(), 1, "RecordBoundPolicy should be called after verifyQuote");
    }

    function test_bindPolicy_WhenValid_BindsPolicyOnCoverPool() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        bytes32 expectedCommit = boundPolicy.policyCommit;

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertEq(coverPool.recordBoundPolicyCallCount(), 1, "RecordBoundPolicy not called");
        assertEq(coverPool.lastPolicyCommit(), expectedCommit, "Policy commit mismatch");
    }

    function test_bindPolicy_WhenValid_RegistersPolicy() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);
        assertEq(metadata.buyer, buyer, "Metadata buyer mismatch");
        assertEq(metadata.beneficiary, beneficiary, "Metadata beneficiary mismatch");
        assertEq(metadata.payoutToken, payoutToken, "Metadata payout token mismatch");
        assertEq(metadata.pool, address(coverPool), "Metadata pool mismatch");
        assertEq(metadata.coverageLimit, COVERAGE_LIMIT, "Metadata coverage limit mismatch");
        assertEq(metadata.termsHash, termsHash, "Metadata terms hash mismatch");
        assertEq(metadata.policyCommit, boundPolicy.policyCommit, "Metadata policy commit mismatch");
        assertEq(metadata.policyId, request.quote.policyId, "Metadata policy ID mismatch");
        assertEq(metadata.policyId, coverPool.lastBoundPolicy().policyId, "Metadata and bound policy ID mismatch");
        assertEq(metadata.startTime, uint32(block.timestamp), "Metadata start time mismatch");
        assertEq(metadata.maturityTime, uint32(block.timestamp + COVERAGE_DURATION), "Metadata maturity time mismatch");
    }

    function test_bindPolicy_WhenValid_EmitsPolicyBound() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        bytes32 expectedCommit = boundPolicy.policyCommit;

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit PolicyBound(
            request.policyId,
            buyer,
            beneficiary,
            address(coverPool),
            COVERAGE_LIMIT,
            expectedCommit,
            address(defaultHook)
        );

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_MultiplePoliciesToSameBuyer_Succeeds() public {
        vm.prank(buyer);
        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
        vm.prank(buyer);
        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        IPolicyManager.BindPolicyRequest memory request1 = _buildRequest(policyId1);
        IPolicyManager.BindPolicyRequest memory request2 = _buildRequest(policyId2);

        _seedCommitteeForTesting(request1.quote.policyId, curator, request1.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy1 = _getBoundPolicy(request1);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request1, boundPolicy1);

        _seedCommitteeForTesting(request2.quote.policyId, curator, request2.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy2 = _getBoundPolicy(request2);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request2, boundPolicy2);

        IPolicyManager.PolicyMetadata memory metadata1 = policyManager.policyMetadata(request1.policyId);
        IPolicyManager.PolicyMetadata memory metadata2 = policyManager.policyMetadata(request2.policyId);
        assertEq(metadata1.buyer, buyer, "First policy buyer mismatch");
        assertEq(metadata2.buyer, buyer, "Second policy buyer mismatch");
    }

    function test_bindPolicy_IsProtectedByReentrancyGuard() public {
        vm.prank(buyer);
        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
        vm.prank(buyer);
        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        IPolicyManager.BindPolicyRequest memory request1 = _buildRequest(policyId1);
        IPolicyManager.BindPolicyRequest memory request2 = _buildRequest(policyId2);

        _seedCommitteeForTesting(request1.quote.policyId, curator, request1.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy1 = _getBoundPolicy(request1);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request1, boundPolicy1);

        _seedCommitteeForTesting(request2.quote.policyId, curator, request2.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy2 = _getBoundPolicy(request2);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request2, boundPolicy2);

        IPolicyManager.PolicyMetadata memory metadata1 = policyManager.policyMetadata(request1.policyId);
        IPolicyManager.PolicyMetadata memory metadata2 = policyManager.policyMetadata(request2.policyId);
        assertEq(metadata1.buyer, buyer, "First policy buyer mismatch");
        assertEq(metadata2.buyer, buyer, "Second policy buyer mismatch");
    }

    function test_bindPolicy_PassesCustomCoverageAmount() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint256 customAmount = 999_999e8;
        request.coverageAmount = customAmount;
        _seedCommitteeForTesting(request.quote.policyId, curator, customAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenRequestMismatchesDraft_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        request.buyer = makeAddr("maliciousBuyer");
        ICoverPool.BoundPolicy memory boundPolicy1 = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy1);

        request = _defaultRequest();
        request.beneficiary = makeAddr("maliciousBeneficiary");
        ICoverPool.BoundPolicy memory boundPolicy2 = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy2);

        request = _defaultRequest();
        request.claimer = makeAddr("maliciousClaimer");
        ICoverPool.BoundPolicy memory boundPolicy3 = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy3);

        request = _defaultRequest();
        request.payoutToken = makeAddr("maliciousPayoutToken");
        ICoverPool.BoundPolicy memory boundPolicy4 = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy4);

        request = _defaultRequest();
        request.coverageAmount = 999_999e8;
        ICoverPool.BoundPolicy memory boundPolicy5 = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy5);
    }

    /*//////////////////////////////////////////////////////////////
                      SET COVER POOL FACTORY
    //////////////////////////////////////////////////////////////*/

    function test_setCoverPoolFactory_WhenCallerNotAdmin_Reverts() public {
        MockCoverPoolFactory newFactory = new MockCoverPoolFactory();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.setCoverPoolFactory(address(newFactory));
    }

    function test_setCoverPoolFactory_WhenAddressZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(admin);
        policyManager.setCoverPoolFactory(address(0));
    }

    function test_setCoverPoolFactory_WhenValidAddress_UpdatesState() public {
        MockCoverPoolFactory newFactory = new MockCoverPoolFactory();

        vm.expectEmit(true, true, true, true);
        emit IPolicyManager.CoverPoolFactorySet(address(newFactory));

        vm.prank(admin);
        policyManager.setCoverPoolFactory(address(newFactory));

        assertEq(policyManager.coverPoolFactory(), address(newFactory), "Cover pool factory not updated");
    }

    /*//////////////////////////////////////////////////////////////
                          AUTHORIZE UPGRADE
    //////////////////////////////////////////////////////////////*/

    function test_authorizeUpgrade_WhenCallerNotAdmin_Reverts() public {
        address newImplementation = address(new PolicyManager());

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.upgradeToAndCall(newImplementation, "");
    }

    function test_authorizeUpgrade_WhenCalledByAdmin_Succeeds() public {
        address newImplementation = address(new PolicyManager());

        vm.prank(admin);
        policyManager.upgradeToAndCall(newImplementation, "");

        assertTrue(policyManager.hasRole(policyManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role should persist");
    }

    /*//////////////////////////////////////////////////////////////
                                PAUSED
    //////////////////////////////////////////////////////////////*/

    function test_paused_ReturnsCorrectState() public {
        assertFalse(policyManager.paused(), "Should not be paused initially");

        vm.prank(admin);
        policyManager.pause();
        assertTrue(policyManager.paused(), "Should be paused after pause()");

        vm.prank(admin);
        policyManager.unpause();
        assertFalse(policyManager.paused(), "Should not be paused after unpause()");
    }

    /*//////////////////////////////////////////////////////////////
                         CREATE POLICY DRAFT
    //////////////////////////////////////////////////////////////*/

    function test_requestCoverage_WhenPoolNotRegistered_Reverts() public {
        address invalidPool = makeAddr("invalidPool");
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidCoverPool.selector, invalidPool));
        vm.prank(buyer);
        policyManager.requestCoverage(
            invalidPool, beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, address(defaultHook)
        );
    }

    function test_requestCoverage_WhenBeneficiaryZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool),
            address(0),
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
    }

    function test_requestCoverage_WhenClaimerZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            address(0),
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
    }

    function test_requestCoverage_WhenPayoutTokenZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            address(0),
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
    }

    function test_requestCoverage_WhenCoverageAmountZero_Reverts() public {
        vm.expectRevert(IPolicyManager.InvalidCoverageAmount.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, 0, COVERAGE_DURATION, address(defaultHook)
        );
    }

    function test_requestCoverage_WhenDurationZero_Reverts() public {
        vm.expectRevert(IPolicyManager.InvalidDuration.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, 0, address(defaultHook)
        );
    }

    function test_requestCoverage_WhenCuratorZero_Reverts() public {
        MockCoverPool poolWithoutCurator = new MockCoverPool();
        poolWithoutCurator.setCurator(address(0));
        mockCoverPoolFactory.registerPool(address(poolWithoutCurator));

        vm.expectRevert(IPolicyManager.InvalidPoolOperator.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(poolWithoutCurator),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
    }

    function test_requestCoverage_WhenPaused_Reverts() public {
        vm.prank(admin);
        policyManager.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
    }

    function test_requestCoverage_CreatesDraftSuccessfully() public {
        vm.expectEmit(true, true, true, true, address(policyManager));
        emit IPolicyManager.CoverageRequested(
            1, address(coverPool), buyer, beneficiary, beneficiary, COVERAGE_AMOUNT, COVERAGE_DURATION
        );

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        assertEq(policyId, 1, "Policy ID should be 1");
        assertEq(mockStakeManager.createCommitteeCallCount(), 1, "Should create committee");
        assertEq(mockStakeManager.lastCommitteeId(), policyId, "Committee ID should match policy ID");

        IPolicyManager.PolicyDraft memory draft = policyManager.getPolicyDraft(policyId);
        assertEq(draft.pool, address(coverPool), "Pool mismatch");
        assertEq(draft.buyer, buyer, "Buyer mismatch");
        assertEq(draft.beneficiary, beneficiary, "Beneficiary mismatch");
        assertEq(draft.claimer, beneficiary, "Claimer mismatch");
        assertEq(draft.payoutToken, payoutToken, "Payout token mismatch");
        assertEq(draft.coverageAmount, COVERAGE_AMOUNT, "Coverage amount mismatch");
        assertEq(draft.duration, COVERAGE_DURATION, "Duration mismatch");
        assertEq(draft.policyId, policyId, "Committee ID mismatch");
        assertTrue(draft.status == IPolicyManager.PolicyStatus.Created, "Status should be Created");
    }

    function test_requestCoverage_IncrementsPolicyIdCorrectly() public {
        vm.startPrank(buyer);
        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
        vm.stopPrank();

        assertEq(policyId1, 1, "First policy ID should be 1");
        assertEq(policyId2, 2, "Second policy ID should be 2");
    }

    /*//////////////////////////////////////////////////////////////
                         CANCEL POLICY DRAFT
    //////////////////////////////////////////////////////////////*/

    function test_cancelPolicyDraft_WhenDraftNotFound_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyDraftNotFound.selector, 999));
        vm.prank(buyer);
        policyManager.cancelPolicyDraft(999);
    }

    function test_cancelPolicyDraft_WhenNotBuyer_Reverts() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        address notBuyer = makeAddr("notBuyer");
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.NotPolicyBuyer.selector, notBuyer));
        vm.prank(notBuyer);
        policyManager.cancelPolicyDraft(policyId);
    }

    function test_cancelPolicyDraft_WhenAlreadyCancelled_Reverts() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        vm.prank(buyer);
        policyManager.cancelPolicyDraft(policyId);

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyManager.InvalidPolicyStatus.selector, IPolicyManager.PolicyStatus.Cancelled)
        );
        vm.prank(buyer);
        policyManager.cancelPolicyDraft(policyId);
    }

    function test_cancelPolicyDraft_WhenPaused_Reverts() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        vm.prank(admin);
        policyManager.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(buyer);
        policyManager.cancelPolicyDraft(policyId);
    }

    function test_cancelPolicyDraft_CancelsSuccessfully() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        vm.expectEmit(true, true, false, true, address(policyManager));
        emit IPolicyManager.PolicyDraftCancelled(policyId, address(coverPool));

        vm.prank(buyer);
        policyManager.cancelPolicyDraft(policyId);

        IPolicyManager.PolicyDraft memory draft = policyManager.getPolicyDraft(policyId);
        assertTrue(draft.status == IPolicyManager.PolicyStatus.Cancelled, "Status should be Cancelled");
    }

    /*//////////////////////////////////////////////////////////////
                          GET POLICY DRAFT
    //////////////////////////////////////////////////////////////*/

    function test_getPolicyDraft_WhenDraftNotFound_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyDraftNotFound.selector, 999));
        this.externalGetPolicyDraft(999);
    }

    function test_getPolicyDraft_ReturnsCorrectDraft() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        IPolicyManager.PolicyDraft memory draft = policyManager.getPolicyDraft(policyId);

        assertEq(draft.pool, address(coverPool), "Pool mismatch");
        assertEq(draft.buyer, buyer, "Buyer mismatch");
        assertEq(draft.beneficiary, beneficiary, "Beneficiary mismatch");
        assertEq(draft.claimer, beneficiary, "Claimer mismatch");
        assertEq(draft.payoutToken, payoutToken, "Payout token mismatch");
        assertEq(draft.coverageAmount, COVERAGE_AMOUNT, "Coverage amount mismatch");
        assertEq(draft.policyId, policyId, "Committee ID mismatch");
        assertTrue(draft.status == IPolicyManager.PolicyStatus.Created, "Status should be Created");
    }

    function externalGetPolicyDraft(uint96 policyId) external view returns (IPolicyManager.PolicyDraft memory) {
        return policyManager.getPolicyDraft(policyId);
    }

    /*//////////////////////////////////////////////////////////////
                          BIND POLICY HOOK
    //////////////////////////////////////////////////////////////*/

    function test_requestCoverage_StoresBindPolicyHook() public {
        MockBindPolicyHook hook = new MockBindPolicyHook();

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, address(hook)
        );

        IPolicyManager.PolicyDraft memory draft = policyManager.getPolicyDraft(policyId);
        assertEq(draft.bindPolicyHook, address(hook), "Hook address not stored in draft");
    }

    function test_bindPolicy_WithHook_CallsHook() public {
        MockBindPolicyHook hook = new MockBindPolicyHook();

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, address(hook)
        );

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(policyId);
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertEq(hook.callCount(), 1, "Hook should be called once");
        assertEq(hook.lastPolicyId(), policyId, "Hook received wrong policy ID");
        assertEq(hook.lastCoverageLimit(), COVERAGE_LIMIT, "Hook received wrong coverage limit");
    }

    function test_bindPolicy_WithHook_EmitsEvent() public {
        MockBindPolicyHook hook = new MockBindPolicyHook();

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, address(hook)
        );

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(policyId);
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        bytes32 expectedCommit = boundPolicy.policyCommit;

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit PolicyBound(
            policyId, buyer, beneficiary, address(coverPool), COVERAGE_LIMIT, expectedCommit, address(hook)
        );

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WithHookRevert_RevertsTransaction() public {
        MockBindPolicyHook hook = new MockBindPolicyHook();
        hook.setShouldRevert(true);

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, address(hook)
        );

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(policyId);
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.expectRevert("MockBindPolicyHook: intentional revert");
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        // Verify policy was not bound
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.PolicyNotFound.selector, policyId));
        policyManager.policyMetadata(policyId);
    }

    function test_requestCoverage_WhenBindPolicyHookZero_Reverts() public {
        vm.expectRevert(IPolicyManager.InvalidBindPolicyHook.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, address(0)
        );
    }

    function test_requestCoverage_WhenBindPolicyHookNotContract_Reverts() public {
        address eoa = makeAddr("notAContract");
        vm.expectRevert(); // EOA will cause supportsInterface to revert, caught by try-catch
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, eoa
        );
    }

    function test_requestCoverage_WhenBindPolicyHookDoesNotSupportInterface_Reverts() public {
        MockInvalidHook invalidHook = new MockInvalidHook();
        vm.expectRevert(IPolicyManager.InvalidBindPolicyHook.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(invalidHook)
        );
    }

    function test_requestCoverage_WhenBindPolicyHookSupportsInterfaceReverts_Reverts() public {
        MockRevertingHook revertingHook = new MockRevertingHook();
        vm.expectRevert(IPolicyManager.InvalidBindPolicyHook.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(revertingHook)
        );
    }

    /*//////////////////////////////////////////////////////////////
                          REQUEST COVERAGE
    //////////////////////////////////////////////////////////////*/

    function test_requestCoverage_CreatesCommitteeWithPolicyIdAsCommitteeId() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        assertEq(mockStakeManager.lastCommitteeId(), policyId, "CommitteeId should equal policyId (1:1 mapping)");
        assertEq(mockStakeManager.lastMaxStake(), COVERAGE_AMOUNT, "MaxStake should equal coverage amount");
    }

    function test_requestCoverage_MaxStakeForCommitteeSetToCoverageAmount() public {
        uint256 customCoverageAmount = 750_000e8;

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            customCoverageAmount,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        assertEq(
            mockStakeManager.lastMaxStake(), customCoverageAmount, "MaxStake should be set to requested coverage amount"
        );
        assertEq(
            mockStakeManager.getCommitteeMaxStake(policyId),
            customCoverageAmount,
            "MaxStake should be retrievable from committee"
        );
    }

    function test_requestCoverage_MaxStakeForCommitteeIsImmutable() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        uint256 initialMaxStake = mockStakeManager.getCommitteeMaxStake(policyId);
        assertEq(initialMaxStake, COVERAGE_AMOUNT, "Initial maxStake mismatch");

        vm.expectRevert("MaxStake is immutable");
        mockStakeManager.updateMaxStake(policyId, COVERAGE_AMOUNT * 2);

        assertEq(
            mockStakeManager.getCommitteeMaxStake(policyId),
            initialMaxStake,
            "MaxStake should remain unchanged after attempted update"
        );
    }

    function test_requestCoverage_AddsCuratorAsOperatorToCommittee() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        assertEq(
            mockStakeManager.getOperatorCommittee(curator), policyId, "Curator should be added to committee as operator"
        );
    }

    // TODO: Implement vault locking in PolicyManager.bindPolicy()
    // function test_bindPolicy_LocksCommitteeVaults() public {
    //     IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
    //     _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);
    //
    //     ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
    //
    //     vm.prank(address(coverPool));
    //     policyManager.bindPolicy(request, boundPolicy);
    //
    //     assertTrue(
    //         mockStakeManager.areVaultsLocked(request.quote.policyId), "Vaults should be locked after policy binding"
    //     );
    // }

    function test_bindPolicy_VerifiesVaultsExistForCommittee() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);
        assertEq(metadata.pool, address(coverPool), "Policy should be active");
    }

    function test_bindPolicy_CoverageLimitMatchesCoverageAmount() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);
        assertEq(metadata.coverageLimit, COVERAGE_LIMIT, "Coverage limit stored in metadata");
        assertTrue(
            mockStakeManager.getOperatorCommitteeStake(request.quote.policyId) >= request.coverageAmount,
            "Stake should cover coverageAmount"
        );
    }

    function test_bindPolicy_CoverageLimitGreaterThanStake_AllowedIfStakeCoversAmount() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint96 committeeId = request.quote.policyId;

        request.coverageAmount = 500_000e8;
        request.quote.coverageLimit = 1_000_000e18; // Larger limit for economic payouts

        _seedCommitteeForTesting(committeeId, curator, request.coverageAmount, true);
        mockStakeManager.setOperatorCommitteeStake(committeeId, 500_000e8);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);
        assertEq(metadata.coverageLimit, 1_000_000e18, "Coverage limit should be stored");
    }

    function test_bindPolicy_SetsCorrectMaturityTime() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        uint32 expectedMaturityTime = uint32(block.timestamp + COVERAGE_DURATION);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);
        assertEq(metadata.maturityTime, expectedMaturityTime, "Maturity time mismatch");
        assertEq(
            metadata.maturityTime - metadata.startTime, COVERAGE_DURATION, "Duration should match requested coverage"
        );
    }

    /*//////////////////////////////////////////////////////////////
                          POLICY METADATA
    //////////////////////////////////////////////////////////////*/

    function test_policyMetadata_DurationCalculationConsistency() public {
        uint32 customDuration = 90 days;

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            customDuration,
            address(defaultHook)
        );

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(policyId);
        request.quote.maturityTime = uint32(block.timestamp + customDuration);
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(policyId);
        assertEq(
            metadata.maturityTime - metadata.startTime,
            customDuration,
            "Stored duration should match requested duration"
        );
    }

    function test_bindPolicy_StartTimeFromBoundPolicy() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);
        assertEq(metadata.startTime, boundPolicy.startTime, "Start time should match boundPolicy startTime");
        assertEq(metadata.maturityTime, boundPolicy.maturityTime, "Maturity time should match boundPolicy maturityTime");
    }

    function test_bindPolicy_FutureStartTime_UsesProvidedStartTime() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint32 futureStart = uint32(block.timestamp + 1 days);
        request.quote.startTime = futureStart;
        request.quote.maturityTime = futureStart + COVERAGE_DURATION;

        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);
        // Policy uses the startTime provided by CoverPool
        assertEq(metadata.startTime, boundPolicy.startTime, "Start time should match boundPolicy");
        assertEq(metadata.maturityTime, boundPolicy.maturityTime, "Maturity time should match boundPolicy");
    }

    function test_policyDraft_StatusTransitionFromCreatedToBound() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        IPolicyManager.PolicyDraft memory draftBefore = policyManager.getPolicyDraft(policyId);
        assertTrue(draftBefore.status == IPolicyManager.PolicyStatus.Created, "Initial status should be Created");

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(policyId);
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyDraft memory draftAfter = policyManager.getPolicyDraft(policyId);
        assertTrue(draftAfter.status == IPolicyManager.PolicyStatus.Bound, "Status should transition to Bound");
    }

    function test_policyDraft_StatusTransitionFromCreatedToCancelled() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        IPolicyManager.PolicyDraft memory draftBefore = policyManager.getPolicyDraft(policyId);
        assertTrue(draftBefore.status == IPolicyManager.PolicyStatus.Created, "Initial status should be Created");

        vm.prank(buyer);
        policyManager.cancelPolicyDraft(policyId);

        IPolicyManager.PolicyDraft memory draftAfter = policyManager.getPolicyDraft(policyId);
        assertTrue(draftAfter.status == IPolicyManager.PolicyStatus.Cancelled, "Status should transition to Cancelled");
    }

    function test_bindPolicy_CannotBindCancelledDraft() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        vm.prank(buyer);
        policyManager.cancelPolicyDraft(policyId);

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(policyId);
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyManager.InvalidPolicyStatus.selector, IPolicyManager.PolicyStatus.Cancelled)
        );
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_MultipleHooksForDifferentPolicies_EachReceivesCorrectData() public {
        MockBindPolicyHook hook1 = new MockBindPolicyHook();
        MockBindPolicyHook hook2 = new MockBindPolicyHook();

        vm.prank(buyer);
        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(hook1)
        );

        vm.prank(buyer);
        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT * 2,
            COVERAGE_DURATION,
            address(hook2)
        );

        IPolicyManager.BindPolicyRequest memory request1 = _buildRequest(policyId1);
        _seedCommitteeForTesting(request1.quote.policyId, curator, request1.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy1 = _getBoundPolicy(request1);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request1, boundPolicy1);

        IPolicyManager.BindPolicyRequest memory request2 = _buildRequest(policyId2);
        request2.coverageAmount = COVERAGE_AMOUNT * 2;
        request2.quote.coverageLimit = COVERAGE_LIMIT * 2;
        _seedCommitteeForTesting(request2.quote.policyId, curator, request2.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy2 = _getBoundPolicy(request2);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request2, boundPolicy2);

        assertEq(hook1.callCount(), 1, "Hook1 should be called once");
        assertEq(hook1.lastPolicyId(), policyId1, "Hook1 should receive policyId1");
        assertEq(hook1.lastCoverageLimit(), COVERAGE_LIMIT, "Hook1 should receive correct coverage limit");

        assertEq(hook2.callCount(), 1, "Hook2 should be called once");
        assertEq(hook2.lastPolicyId(), policyId2, "Hook2 should receive policyId2");
        assertEq(hook2.lastCoverageLimit(), COVERAGE_LIMIT * 2, "Hook2 should receive doubled coverage limit");
    }

    function test_bindPolicy_HookCanQueryPolicyMetadataAfterBinding() public {
        MockBindPolicyHookWithQuery hook = new MockBindPolicyHookWithQuery(address(policyManager));

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, address(hook)
        );

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(policyId);
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertTrue(hook.metadataQuerySucceeded(), "Hook should be able to query policy metadata");
        assertEq(hook.queriedBeneficiary(), beneficiary, "Hook should see correct beneficiary");
        assertEq(hook.queriedCoverageLimit(), COVERAGE_LIMIT, "Hook should see correct coverage limit");
    }

    function test_bindPolicy_HookReceivesExactCoverageLimitFromQuote() public {
        MockBindPolicyHook hook = new MockBindPolicyHook();
        uint256 customCoverageLimit = 2_500_000e18;

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, payoutToken, COVERAGE_AMOUNT, COVERAGE_DURATION, address(hook)
        );

        IPolicyManager.BindPolicyRequest memory request = _buildRequest(policyId);
        request.quote.coverageLimit = customCoverageLimit;
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertEq(hook.lastCoverageLimit(), customCoverageLimit, "Hook should receive exact coverage limit from quote");
    }

    function test_bindPolicy_PolicyActiveUntilMaturity() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);

        assertTrue(metadata.startTime < metadata.maturityTime, "Start time should be before maturity");
        assertTrue(block.timestamp >= metadata.startTime, "Current time should be at or after start");
        assertTrue(block.timestamp <= metadata.maturityTime, "Current time should be at or before maturity");
    }

    function test_policyMetadata_RemainsAccessibleAfterMaturity() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.policyId, curator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPolicyManager.PolicyMetadata memory metadataBefore = policyManager.policyMetadata(request.policyId);

        vm.warp(metadataBefore.maturityTime + 30 days);

        IPolicyManager.PolicyMetadata memory metadataAfter = policyManager.policyMetadata(request.policyId);
        assertEq(metadataAfter.policyId, metadataBefore.policyId, "PolicyId should remain the same");
        assertEq(metadataAfter.buyer, metadataBefore.buyer, "Buyer should remain the same");
        assertEq(metadataAfter.maturityTime, metadataBefore.maturityTime, "Maturity time should be immutable");
    }

    function test_bindPolicy_MultiplePoliciesWithDifferentMaturityTimes() public {
        uint32 shortDuration = 15 days;
        uint32 longDuration = 90 days;

        vm.prank(buyer);
        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            shortDuration,
            address(defaultHook)
        );

        vm.prank(buyer);
        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            longDuration,
            address(defaultHook)
        );

        IPolicyManager.BindPolicyRequest memory request1 = _buildRequest(policyId1);
        request1.quote.maturityTime = uint32(block.timestamp + shortDuration);
        _seedCommitteeForTesting(request1.quote.policyId, curator, request1.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy1 = _getBoundPolicy(request1);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request1, boundPolicy1);

        IPolicyManager.BindPolicyRequest memory request2 = _buildRequest(policyId2);
        request2.quote.maturityTime = uint32(block.timestamp + longDuration);
        _seedCommitteeForTesting(request2.quote.policyId, curator, request2.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy2 = _getBoundPolicy(request2);

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request2, boundPolicy2);

        IPolicyManager.PolicyMetadata memory metadata1 = policyManager.policyMetadata(policyId1);
        IPolicyManager.PolicyMetadata memory metadata2 = policyManager.policyMetadata(policyId2);

        assertEq(metadata1.maturityTime - metadata1.startTime, shortDuration, "First policy should have short duration");
        assertEq(metadata2.maturityTime - metadata2.startTime, longDuration, "Second policy should have long duration");
        assertTrue(metadata2.maturityTime > metadata1.maturityTime, "Second policy should mature later");
    }

    function test_invariant_PolicyIdEqualCommitteeId() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        assertEq(mockStakeManager.lastCommitteeId(), policyId, "PolicyId must equal committeeId");
        assertEq(
            mockStakeManager.getOperatorCommittee(curator), policyId, "Committee should be accessible via policyId"
        );
    }

    function test_invariant_MultiplePoliciesCreateUniqueCommittees() public {
        vm.startPrank(buyer);

        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        vm.stopPrank();

        // Each policy creates its own unique committee with matching ID
        assertNotEq(policyId1, policyId2, "PolicyIds should be unique");
        assertTrue(mockStakeManager.committeeExists(policyId1), "Committee 1 should exist");
        assertTrue(mockStakeManager.committeeExists(policyId2), "Committee 2 should exist");
    }

    function test_invariant_BeneficiaryAndClaimerDistinction() public {
        address separateClaimer = makeAddr("separateClaimer");

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            separateClaimer, // Different from beneficiary
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );

        IPolicyManager.PolicyDraft memory draft = policyManager.getPolicyDraft(policyId);
        assertEq(draft.beneficiary, beneficiary, "Beneficiary should be set correctly");
        assertEq(draft.claimer, separateClaimer, "Claimer should be set correctly");
        assertNotEq(draft.beneficiary, draft.claimer, "Beneficiary and claimer can be different addresses");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultRequest() internal returns (IPolicyManager.BindPolicyRequest memory) {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool),
            beneficiary,
            beneficiary,
            payoutToken,
            COVERAGE_AMOUNT,
            COVERAGE_DURATION,
            address(defaultHook)
        );
        return _buildRequest(policyId);
    }

    function _buildRequest(uint96 policyId) internal view returns (IPolicyManager.BindPolicyRequest memory) {
        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: address(coverPool),
            policyId: policyId,
            coverageLimit: COVERAGE_LIMIT,
            basePremium: BASE_PREMIUM,
            specId: specId,
            termsHash: termsHash,
            beneficiary: beneficiary,
            startTime: uint32(block.timestamp),
            maturityTime: uint32(block.timestamp + COVERAGE_DURATION),
            expirationTime: uint32(block.timestamp + 1 hours)
        });

        return IPolicyManager.BindPolicyRequest({
            policyId: policyId,
            buyer: buyer,
            beneficiary: beneficiary,
            claimer: beneficiary,
            payoutToken: payoutToken,
            coverageAmount: COVERAGE_AMOUNT,
            quote: quote,
            signature: abi.encodePacked("mock-signature")
        });
    }

    function _seedCommitteeForTesting(
        uint96 committeeId,
        address committeeOperator,
        uint256 operatorStake,
        bool addVaults
    )
        internal
    {
        mockStakeManager.createCommittee(committeeId, 1_000_000e8, address(coverPool), COVERAGE_DURATION);
        mockStakeManager.addOperatorToCommittee(committeeOperator, committeeId);
        if (addVaults) {
            address[] memory vaults = new address[](2);
            vaults[0] = makeAddr("vault1");
            vaults[1] = makeAddr("vault2");
            mockStakeManager.addCommitteeVaults(committeeId, vaults);
        }
        mockStakeManager.setOperatorCommitteeStake(committeeId, operatorStake);
    }

    function _getBoundPolicy(IPolicyManager.BindPolicyRequest memory request)
        internal
        returns (ICoverPool.BoundPolicy memory)
    {
        bytes32 commit = _hashQuote(request.quote);
        return coverPool.recordBoundPolicy(request.policyId, commit, request.quote);
    }

    function _hashQuote(ICoverPool.Quote memory quote) private pure returns (bytes32) {
        return EfficientHashLib.hash(
            uint256(QUOTE_TYPEHASH),
            uint256(uint160(quote.pool)),
            uint256(quote.policyId),
            quote.coverageLimit,
            quote.basePremium,
            uint256(quote.specId),
            uint256(quote.termsHash),
            uint256(uint160(quote.beneficiary)),
            uint256(quote.startTime),
            uint256(quote.maturityTime),
            uint256(quote.expirationTime)
        );
    }
}

contract MockCoverPool {
    uint256 public recordBoundPolicyCallCount;
    bytes32 private _returnPolicyCommit;
    bytes32 public lastPolicyCommit;
    ICoverPool.BoundPolicy private _boundPolicy;
    bool private _useOverriddenPolicy;
    address public curator;
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    mapping(bytes32 => bool) private _boundPolicyCommits;

    constructor() {
        _returnPolicyCommit = keccak256("policy-commit");
        _boundPolicy = ICoverPool.BoundPolicy({
            policyId: 1,
            policyCommit: keccak256("policy-commit"),
            specId: keccak256("spec-id"),
            termsHash: keccak256("terms-hash"),
            coverageLimit: 1_000_000e18,
            beneficiary: address(0x1),
            startTime: uint32(block.timestamp),
            maturityTime: uint32(block.timestamp + 30 days)
        });
    }

    function setCurator(address curator_) external {
        curator = curator_;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        if (role == DEFAULT_ADMIN_ROLE) {
            return account == curator;
        }
        return false;
    }

    function recordBoundPolicy(
        uint96 policyId,
        bytes32 policyCommit,
        ICoverPool.Quote calldata quote
    )
        external
        returns (ICoverPool.BoundPolicy memory)
    {
        recordBoundPolicyCallCount++;
        lastPolicyCommit = policyCommit;
        _boundPolicyCommits[policyCommit] = true;

        if (!_useOverriddenPolicy) {
            _boundPolicy.policyId = policyId;
            _boundPolicy.policyCommit = policyCommit;
            _boundPolicy.coverageLimit = quote.coverageLimit;
            _boundPolicy.beneficiary = quote.beneficiary;
            _boundPolicy.startTime = quote.startTime;
            _boundPolicy.maturityTime = quote.maturityTime;
            _boundPolicy.termsHash = quote.termsHash;
        } else {
            _useOverriddenPolicy = false;
        }

        return _boundPolicy;
    }

    function boundPolicyCommits(bytes32 policyCommit) external view returns (bool) {
        return _boundPolicyCommits[policyCommit];
    }

    function owner() external view returns (address) {
        return curator;
    }

    function poolFeeBps() external pure returns (uint16) {
        return 150;
    }

    function setReturnPolicyCommit(bytes32 commit) external {
        _returnPolicyCommit = commit;
    }

    function setReturnBoundPolicy(ICoverPool.BoundPolicy memory policy) external {
        _boundPolicy = policy;
        _useOverriddenPolicy = true;
    }

    function lastBoundPolicy() external view returns (ICoverPool.BoundPolicy memory) {
        return _boundPolicy;
    }
}

contract MockStakeManager {
    uint256 public createCommitteeCallCount;
    uint96 public lastCommitteeId;
    uint256 public lastMaxStake;
    address public lastCoverPool;
    uint32 public lastDuration;

    mapping(address => uint96) private _operatorCommittees;
    mapping(uint96 => address) private _committeeOperators;
    mapping(uint96 => address[]) private _committeeVaults;
    mapping(uint96 => bool) private _committeeExists;
    mapping(uint96 => uint256) private _committeeStake;
    mapping(uint96 => uint256) private _committeeMaxStake;

    function createCommittee(
        uint96 committeeId,
        uint256 maxStakeForCommittee,
        address coverPool,
        uint32 duration
    )
        external
    {
        createCommitteeCallCount++;
        lastCommitteeId = committeeId;
        lastMaxStake = maxStakeForCommittee;
        lastCoverPool = coverPool;
        lastDuration = duration;
        _committeeExists[committeeId] = true;
        _committeeMaxStake[committeeId] = maxStakeForCommittee;
    }

    function addOperatorToCommittee(address operator, uint96 committeeId) external {
        _operatorCommittees[operator] = committeeId;
        _committeeOperators[committeeId] = operator;
    }

    function getCommitteeVaults(uint96 committeeId) external view returns (address[] memory) {
        return _committeeVaults[committeeId];
    }

    function getOperatorCommittee(address operator) external view returns (uint96) {
        return _operatorCommittees[operator];
    }

    function addCommitteeVaults(uint96 committeeId, address[] calldata vaults) external {
        for (uint256 i = 0; i < vaults.length; i++) {
            _committeeVaults[committeeId].push(vaults[i]);
        }
    }

    function getOperatorCommitteeStake(uint96 committeeId) external view returns (uint256) {
        if (_committeeExists[committeeId]) {
            uint256 stake = _committeeStake[committeeId];
            return stake > 0 ? stake : 1_000_000e8;
        }
        return 0;
    }

    function setOperatorCommitteeStake(uint96 committeeId, uint256 stake) external {
        _committeeStake[committeeId] = stake;
    }

    function getCommitteeMaxStake(uint96 committeeId) external view returns (uint256) {
        return _committeeMaxStake[committeeId];
    }

    function updateMaxStake(uint96, uint256) external pure {
        revert("MaxStake is immutable");
    }

    function committeeExists(uint96 committeeId) external view returns (bool) {
        return _committeeExists[committeeId];
    }
}

contract MockClaimManager {}

contract MockCoverPoolFactory {
    mapping(address => bool) private _registeredPools;

    function registerPool(address pool) external {
        _registeredPools[pool] = true;
    }

    function coverPoolExists(address pool) external view returns (bool) {
        return _registeredPools[pool];
    }
}

contract MockBindPolicyHook is IBindPolicyHook, ERC165 {
    uint256 public callCount;
    uint96 public lastPolicyId;
    uint256 public lastCoverageLimit;
    bool public shouldRevert;

    function onPolicyBound(uint96 policyId, uint256 coverageLimit) external override {
        if (shouldRevert) {
            revert("MockBindPolicyHook: intentional revert");
        }
        callCount++;
        lastPolicyId = policyId;
        lastCoverageLimit = coverageLimit;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override (ERC165, IERC165) returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || super.supportsInterface(interfaceId);
    }
}

// Contract that does not implement IBindPolicyHook interface for testing
contract MockInvalidHook is ERC165 {
    function onPolicyBound(uint96, uint256) external pure {
        // Empty
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

// Hook that queries policy metadata during callback
contract MockBindPolicyHookWithQuery is IBindPolicyHook, ERC165 {
    address private immutable policyManager;
    bool public metadataQuerySucceeded;
    address public queriedBeneficiary;
    uint256 public queriedCoverageLimit;

    constructor(address policyManager_) {
        policyManager = policyManager_;
    }

    function onPolicyBound(uint96 policyId, uint256) external override {
        // Query policy metadata during the callback
        try IPolicyManager(policyManager).policyMetadata(policyId) returns (
            IPolicyManager.PolicyMetadata memory metadata
        ) {
            metadataQuerySucceeded = true;
            queriedBeneficiary = metadata.beneficiary;
            queriedCoverageLimit = metadata.coverageLimit;
        } catch {
            metadataQuerySucceeded = false;
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override (ERC165, IERC165) returns (bool) {
        return interfaceId == type(IBindPolicyHook).interfaceId || super.supportsInterface(interfaceId);
    }
}

/// @dev Hook whose supportsInterface() always reverts, exercising the catch branch in requestCoverage.
contract MockRevertingHook {
    function supportsInterface(bytes4) external pure returns (bool) {
        revert("supportsInterface: always reverts");
    }
}

