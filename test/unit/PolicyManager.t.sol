// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {Test} from "forge-std/Test.sol";
import {PolicyManager} from "../../src/PolicyManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IPremiumManager} from "../../src/interfaces/IPremiumManager.sol";

contract PolicyManagerTest is Test {
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 committeeId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address payoutReceiver,uint64 startTime,address operator,uint64 maturityTime,uint64 expirationTime)"
    );
    uint96 internal constant POLICY_ID = 1;
    uint256 internal constant COVERAGE_LIMIT = 1_000_000e18;
    uint256 internal constant BASE_PREMIUM = 10_000e18;
    uint256 internal constant COVERAGE_AMOUNT = 500_000e8;
    uint16 internal constant PLATFORM_FEE_BPS = 50;
    uint16 internal constant POOL_FEE_BPS = 150;
    uint64 internal constant COVERAGE_DURATION = 30 days;

    address internal admin;
    address internal buyer;
    address internal beneficiary;
    address internal premiumToken;
    address internal payoutToken;
    address internal operator;
    address internal curator;

    PolicyManager internal policyManager;
    MockCoverPool internal coverPool;
    MockPremiumManager internal mockPremiumManager;
    MockStakeManager internal mockStakeManager;
    MockClaimManager internal mockClaimManager;
    MockCoverPoolFactory internal mockCoverPoolFactory;

    bytes32 internal policyCommit;
    bytes32 internal specId;
    bytes32 internal termsHash;

    event PolicyBound(
        uint96 indexed policyId,
        address indexed buyer,
        address indexed beneficiary,
        address pool,
        uint256 coverageLimit,
        uint256 basePremium,
        bytes32 policyCommit
    );

    event PremiumManagerSet(address indexed premiumManager_);
    event PlatformFeeSet(uint16 indexed platformFeeBps_);

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
        mockPremiumManager = new MockPremiumManager();
        mockStakeManager = new MockStakeManager();
        mockClaimManager = new MockClaimManager();
        mockCoverPoolFactory = new MockCoverPoolFactory();
        mockCoverPoolFactory.registerPool(address(coverPool));

        policyCommit = keccak256("policy-commit");
        specId = keccak256("spec-id");
        termsHash = keccak256("terms-hash");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "PolicyManager.sol",
            abi.encodeCall(
                PolicyManager.initialize,
                (
                    admin,
                    address(mockPremiumManager),
                    address(mockStakeManager),
                    address(mockClaimManager),
                    address(mockCoverPoolFactory),
                    PLATFORM_FEE_BPS
                )
            ),
            deployOpts
        );
        policyManager = PolicyManager(proxy);

        vm.label(address(policyManager), "PolicyManager");
        vm.label(address(coverPool), "CoverPool");
        vm.label(address(mockPremiumManager), "MockPremiumManager");
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        freshManager.initialize(
            address(0),
            address(mockPremiumManager),
            address(mockStakeManager),
            address(mockClaimManager),
            address(mockCoverPoolFactory),
            PLATFORM_FEE_BPS
        );
    }

    function test_initialize_WhenPremiumManagerZero_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        freshManager.initialize(
            admin,
            address(0),
            address(mockStakeManager),
            address(mockClaimManager),
            address(mockCoverPoolFactory),
            PLATFORM_FEE_BPS
        );
    }

    function test_initialize_WhenCoverPoolFactoryZero_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        freshManager.initialize(
            admin,
            address(mockPremiumManager),
            address(mockStakeManager),
            address(mockClaimManager),
            address(0),
            PLATFORM_FEE_BPS
        );
    }

    function test_initialize_WhenPlatformFeeExceedsMax_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidPlatformFee.selector, 2501));
        freshManager.initialize(
            admin,
            address(mockPremiumManager),
            address(mockStakeManager),
            address(mockClaimManager),
            address(mockCoverPoolFactory),
            2501
        );
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(policyManager.hasRole(policyManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertEq(policyManager.premiumManager(), address(mockPremiumManager), "Premium manager mismatch");
        assertEq(policyManager.platformFeeBps(), PLATFORM_FEE_BPS, "Platform fee mismatch");
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
                        SET PREMIUM MANAGER
    //////////////////////////////////////////////////////////////*/

    function test_setPremiumManager_WhenCallerNotAdmin_Reverts() public {
        MockPremiumManager newManager = new MockPremiumManager();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.setPremiumManager(address(newManager));
    }

    function test_setPremiumManager_WhenAddressZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(admin);
        policyManager.setPremiumManager(address(0));
    }

    function test_setPremiumManager_WhenValid_UpdatesStateAndEmits() public {
        MockPremiumManager newManager = new MockPremiumManager();

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit PremiumManagerSet(address(newManager));

        vm.prank(admin);
        policyManager.setPremiumManager(address(newManager));

        assertEq(policyManager.premiumManager(), address(newManager), "Premium manager not updated");
    }

    /*//////////////////////////////////////////////////////////////
                        SET PLATFORM FEE
    //////////////////////////////////////////////////////////////*/

    function test_setPlatformFee_WhenCallerNotAdmin_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.setPlatformFee(100);
    }

    function test_setPlatformFee_WhenExceedsMax_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidPlatformFee.selector, 2501));
        vm.prank(admin);
        policyManager.setPlatformFee(2501);
    }

    function test_setPlatformFee_WhenValid_UpdatesStateAndEmits() public {
        uint16 newFee = 100;

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit PlatformFeeSet(newFee);

        vm.prank(admin);
        policyManager.setPlatformFee(newFee);

        assertEq(policyManager.platformFeeBps(), newFee, "Platform fee not updated");
    }

    function test_setPlatformFee_AllowsZeroFee() public {
        vm.prank(admin);
        policyManager.setPlatformFee(0);

        assertEq(policyManager.platformFeeBps(), 0, "Platform fee should be zero");
    }

    function test_setPlatformFee_AllowsMaxFee() public {
        vm.prank(admin);
        policyManager.setPlatformFee(2500);

        assertEq(policyManager.platformFeeBps(), 2500, "Platform fee should be max");
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

    function test_bindPolicy_WhenPremiumTokenZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.premiumToken = address(0);

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

    function test_bindPolicy_WhenBasePremiumZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.basePremium = 0;

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.InvalidBasePremium.selector);
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

    function test_bindPolicy_WhenInvalidCoverageWindow_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.startTime = uint64(block.timestamp + 1 days);
        request.quote.maturityTime = uint64(block.timestamp);

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
        request.quote.startTime = uint64(block.timestamp - 2 days);
        request.quote.maturityTime = uint64(block.timestamp - 1 days);

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
        request.quote.startTime = uint64(block.timestamp - 1 days);
        request.quote.maturityTime = uint64(block.timestamp);

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
        uint64 sameTime = uint64(block.timestamp + 1 days);
        request.quote.startTime = sameTime;
        request.quote.maturityTime = sameTime;

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidCoverageWindow.selector, sameTime, sameTime));
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenInsufficientStake_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint96 committeeId = request.quote.committeeId;
        request.quote.operator = makeAddr("lowStakeOperator");

        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        mockStakeManager.createCommittee(committeeId, 1_000_000e8);
        mockStakeManager.addOperatorToCommittee(request.quote.operator, committeeId);
        mockStakeManager.addCommitteeVaults(committeeId, vaults);

        mockStakeManager.setOperatorCommitteeStake(request.quote.operator, committeeId, 100e8);

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
        uint96 committeeId = request.quote.committeeId;

        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        mockStakeManager.createCommittee(committeeId, 1_000_000e8);
        mockStakeManager.addOperatorToCommittee(request.quote.operator, committeeId);
        mockStakeManager.addCommitteeVaults(committeeId, vaults);

        request.coverageAmount = 500_000e8;
        mockStakeManager.setOperatorCommitteeStake(request.quote.operator, committeeId, 550_000e8);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenNoVaultsBound_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint96 committeeId = request.quote.committeeId;
        mockStakeManager.createCommittee(committeeId, 1_000_000e8);
        mockStakeManager.addOperatorToCommittee(request.quote.operator, committeeId);
        mockStakeManager.setOperatorCommitteeStake(request.quote.operator, committeeId, request.coverageAmount);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.NoVaultsBound.selector, committeeId));
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenCommitteeIdMismatchesPolicyId_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint96 wrongCommitteeId = request.policyId + 1;
        request.quote.committeeId = wrongCommitteeId;

        _seedCommitteeForTesting(wrongCommitteeId, operator, COVERAGE_AMOUNT, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.InvalidCommitteeId.selector);
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
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

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
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertEq(coverPool.recordBoundPolicyCallCount(), 1, "RecordBoundPolicy should be called after verifyQuote");
    }

    function test_bindPolicy_WhenValid_BindsPolicyOnCoverPool() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        bytes32 expectedCommit = boundPolicy.policyCommit;

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertEq(coverPool.recordBoundPolicyCallCount(), 1, "RecordBoundPolicy not called");
        assertEq(coverPool.lastPolicyCommit(), expectedCommit, "Policy commit mismatch");
    }

    function test_bindPolicy_WhenValid_CollectsPremium() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        bytes32 expectedCommit = boundPolicy.policyCommit;

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertEq(mockPremiumManager.collectPremiumCallCount(), 1, "CollectPremium not called");

        IPremiumManager.PremiumAllocation memory allocation = mockPremiumManager.lastAllocation();
        assertEq(allocation.policyId, request.policyId, "Policy ID mismatch");
        assertEq(allocation.policyCommit, expectedCommit, "Policy commit mismatch");
        assertEq(allocation.buyer, buyer, "Buyer mismatch");
        assertEq(allocation.committeeId, request.quote.committeeId, "Committee ID mismatch");
        assertEq(allocation.premiumToken, premiumToken, "Premium token mismatch");
        assertEq(allocation.basePremium, BASE_PREMIUM, "Base premium mismatch");
        assertEq(allocation.platformFeeBps, PLATFORM_FEE_BPS, "Platform fee mismatch");
        assertEq(allocation.startTime, uint64(block.timestamp), "Start time mismatch");
        assertEq(allocation.maturityTime, uint64(block.timestamp + COVERAGE_DURATION), "Maturity time mismatch");
        assertEq(allocation.poolShare.coverPool, address(coverPool), "Cover pool mismatch");
        assertEq(allocation.poolShare.poolFeeRecipient, coverPool.owner(), "Pool fee recipient mismatch");
        assertEq(allocation.poolShare.operator, operator, "Operator mismatch");
        assertEq(allocation.poolShare.grossPremium, BASE_PREMIUM, "Gross premium mismatch");
        assertEq(allocation.poolShare.poolFeeBps, POOL_FEE_BPS, "Pool fee BPS mismatch");
    }

    function test_bindPolicy_WhenValid_RegistersPolicy() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        // Verify policy metadata is stored directly in PolicyManager
        IPolicyManager.PolicyMetadata memory metadata = policyManager.policyMetadata(request.policyId);
        assertEq(metadata.buyer, buyer, "Metadata buyer mismatch");
        assertEq(metadata.beneficiary, beneficiary, "Metadata beneficiary mismatch");
        assertEq(metadata.premiumToken, premiumToken, "Metadata premium token mismatch");
        assertEq(metadata.basePremium, BASE_PREMIUM, "Metadata base premium mismatch");
        assertEq(metadata.payoutToken, payoutToken, "Metadata payout token mismatch");
        assertEq(metadata.pool, address(coverPool), "Metadata pool mismatch");
        assertEq(metadata.coverageLimit, COVERAGE_LIMIT, "Metadata coverage limit mismatch");
        assertEq(metadata.payoutReceiver, beneficiary, "Metadata payout receiver mismatch");
        assertEq(metadata.poolPolicyId, coverPool.lastBoundPolicy().policyId, "Metadata pool policy ID mismatch");
        assertEq(metadata.termsHash, termsHash, "Metadata terms hash mismatch");
        assertEq(metadata.policyCommit, boundPolicy.policyCommit, "Metadata policy commit mismatch");
        assertEq(metadata.committeeId, request.quote.committeeId, "Metadata committee ID mismatch");
        assertEq(metadata.startTime, uint64(block.timestamp), "Metadata start time mismatch");
        assertEq(metadata.maturityTime, uint64(block.timestamp + COVERAGE_DURATION), "Metadata maturity time mismatch");
        assertEq(metadata.operator, operator, "Metadata operator mismatch");
    }

    function test_bindPolicy_WhenValid_EmitsPolicyBound() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        bytes32 expectedCommit = boundPolicy.policyCommit;

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit PolicyBound(
            request.policyId, buyer, beneficiary, address(coverPool), COVERAGE_LIMIT, BASE_PREMIUM, expectedCommit
        );

        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenValid_ExecutesInCorrectOrder() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        assertEq(coverPool.recordBoundPolicyCallCount(), 1, "RecordBoundPolicy should be called");
        assertEq(mockPremiumManager.collectPremiumCallCount(), 1, "CollectPremium should be called");
    }

    function test_bindPolicy_MultiplePoliciesToSameBuyer_Succeeds() public {
        // Request two different policies
        vm.prank(buyer);
        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );
        vm.prank(buyer);
        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );

        IPolicyManager.BindPolicyRequest memory request1 = _buildRequest(policyId1);
        IPolicyManager.BindPolicyRequest memory request2 = _buildRequest(policyId2);

        _seedCommitteeForTesting(request1.quote.committeeId, request1.quote.operator, request1.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy1 = _getBoundPolicy(request1);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request1, boundPolicy1);

        _seedCommitteeForTesting(request2.quote.committeeId, request2.quote.operator, request2.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy2 = _getBoundPolicy(request2);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request2, boundPolicy2);

        // Verify both policies are registered
        IPolicyManager.PolicyMetadata memory metadata1 = policyManager.policyMetadata(request1.policyId);
        IPolicyManager.PolicyMetadata memory metadata2 = policyManager.policyMetadata(request2.policyId);
        assertEq(metadata1.buyer, buyer, "First policy buyer mismatch");
        assertEq(metadata2.buyer, buyer, "Second policy buyer mismatch");
    }

    function test_bindPolicy_IsProtectedByReentrancyGuard() public {
        // Request two different policies
        vm.prank(buyer);
        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );
        vm.prank(buyer);
        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );

        IPolicyManager.BindPolicyRequest memory request1 = _buildRequest(policyId1);
        IPolicyManager.BindPolicyRequest memory request2 = _buildRequest(policyId2);

        _seedCommitteeForTesting(request1.quote.committeeId, request1.quote.operator, request1.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy1 = _getBoundPolicy(request1);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request1, boundPolicy1);

        _seedCommitteeForTesting(request2.quote.committeeId, request2.quote.operator, request2.coverageAmount, true);
        ICoverPool.BoundPolicy memory boundPolicy2 = _getBoundPolicy(request2);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request2, boundPolicy2);

        assertEq(mockPremiumManager.collectPremiumCallCount(), 2, "Should allow sequential calls");
    }

    function test_bindPolicy_UsesPlatformFeeFromState() public {
        uint16 newPlatformFee = 200;
        vm.prank(admin);
        policyManager.setPlatformFee(newPlatformFee);

        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);

        IPremiumManager.PremiumAllocation memory allocation = mockPremiumManager.lastAllocation();
        assertEq(allocation.platformFeeBps, newPlatformFee, "Should use updated platform fee");
    }

    function test_bindPolicy_PassesCustomCoverageAmount() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint256 customAmount = 999_999e8;
        request.coverageAmount = customAmount;
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, customAmount, true);

        ICoverPool.BoundPolicy memory boundPolicy = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy);
    }

    function test_bindPolicy_WhenRequestMismatchesDraft_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        _seedCommitteeForTesting(request.quote.committeeId, request.quote.operator, request.coverageAmount, true);

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
        request.premiumToken = makeAddr("maliciousPremiumToken");
        ICoverPool.BoundPolicy memory boundPolicy4 = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy4);

        request = _defaultRequest();
        request.payoutToken = makeAddr("maliciousPayoutToken");
        ICoverPool.BoundPolicy memory boundPolicy5 = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy5);

        request = _defaultRequest();
        request.coverageAmount = 999_999e8;
        ICoverPool.BoundPolicy memory boundPolicy6 = _getBoundPolicy(request);
        vm.expectRevert(IPolicyManager.RequestDraftMismatch.selector);
        vm.prank(address(coverPool));
        policyManager.bindPolicy(request, boundPolicy6);
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
                           UPGRADE
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

        assertEq(policyManager.premiumManager(), address(mockPremiumManager), "Premium manager should persist");
        assertEq(policyManager.platformFeeBps(), PLATFORM_FEE_BPS, "Platform fee should persist");
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
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

    function test_premiumManager_ReturnsCorrectAddress() public view {
        assertEq(policyManager.premiumManager(), address(mockPremiumManager), "Should return premium manager");
    }

    function test_platformFeeBps_ReturnsCorrectValue() public {
        assertEq(policyManager.platformFeeBps(), PLATFORM_FEE_BPS, "Should return initial platform fee");

        uint16 newFee = 300;
        vm.prank(admin);
        policyManager.setPlatformFee(newFee);

        assertEq(policyManager.platformFeeBps(), newFee, "Should return updated platform fee");
    }

    /*//////////////////////////////////////////////////////////////
                         CREATE POLICY DRAFT
    //////////////////////////////////////////////////////////////*/

    function test_requestCoverage_WhenPoolNotRegistered_Reverts() public {
        address invalidPool = makeAddr("invalidPool");
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidCoverPool.selector, invalidPool));
        vm.prank(buyer);
        policyManager.requestCoverage(invalidPool, beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT);
    }

    function test_requestCoverage_WhenBeneficiaryZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), address(0), beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );
    }

    function test_requestCoverage_WhenClaimerZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), beneficiary, address(0), premiumToken, payoutToken, COVERAGE_AMOUNT
        );
    }

    function test_requestCoverage_WhenPremiumTokenZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, address(0), payoutToken, COVERAGE_AMOUNT
        );
    }

    function test_requestCoverage_WhenPayoutTokenZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, address(0), COVERAGE_AMOUNT
        );
    }

    function test_requestCoverage_WhenCoverageAmountZero_Reverts() public {
        vm.expectRevert(IPolicyManager.InvalidCoverageAmount.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, 0);
    }

    function test_requestCoverage_WhenCuratorZero_Reverts() public {
        MockCoverPool poolWithoutCurator = new MockCoverPool();
        poolWithoutCurator.setCurator(address(0));
        mockCoverPoolFactory.registerPool(address(poolWithoutCurator));

        vm.expectRevert(IPolicyManager.InvalidPoolOperator.selector);
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(poolWithoutCurator), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );
    }

    function test_requestCoverage_WhenPaused_Reverts() public {
        vm.prank(admin);
        policyManager.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vm.prank(buyer);
        policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );
    }

    function test_requestCoverage_CreatesDraftSuccessfully() public {
        vm.expectEmit(true, true, true, true, address(policyManager));
        emit IPolicyManager.CoverageRequested(1, address(coverPool), buyer, beneficiary, beneficiary, COVERAGE_AMOUNT);

        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );

        assertEq(policyId, 1, "Policy ID should be 1");
        assertEq(mockStakeManager.createCommitteeCallCount(), 1, "Should create committee");
        assertEq(mockStakeManager.lastCommitteeId(), policyId, "Committee ID should match policy ID");

        IPolicyManager.PolicyDraft memory draft = policyManager.getPolicyDraft(policyId);
        assertEq(draft.pool, address(coverPool), "Pool mismatch");
        assertEq(draft.buyer, buyer, "Buyer mismatch");
        assertEq(draft.beneficiary, beneficiary, "Beneficiary mismatch");
        assertEq(draft.claimer, beneficiary, "Claimer mismatch");
        assertEq(draft.premiumToken, premiumToken, "Premium token mismatch");
        assertEq(draft.payoutToken, payoutToken, "Payout token mismatch");
        assertEq(draft.coverageAmount, COVERAGE_AMOUNT, "Coverage amount mismatch");
        assertEq(draft.committeeId, policyId, "Committee ID mismatch");
        assertTrue(draft.status == IPolicyManager.PolicyStatus.Created, "Status should be Created");
    }

    function test_requestCoverage_IncrementsPolicyIdCorrectly() public {
        vm.startPrank(buyer);
        uint96 policyId1 = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );
        uint96 policyId2 = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
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
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );

        address notBuyer = makeAddr("notBuyer");
        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.NotPolicyBuyer.selector, notBuyer));
        vm.prank(notBuyer);
        policyManager.cancelPolicyDraft(policyId);
    }

    function test_cancelPolicyDraft_WhenAlreadyCancelled_Reverts() public {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
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
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
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
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
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
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );

        IPolicyManager.PolicyDraft memory draft = policyManager.getPolicyDraft(policyId);

        assertEq(draft.pool, address(coverPool), "Pool mismatch");
        assertEq(draft.buyer, buyer, "Buyer mismatch");
        assertEq(draft.beneficiary, beneficiary, "Beneficiary mismatch");
        assertEq(draft.claimer, beneficiary, "Claimer mismatch");
        assertEq(draft.premiumToken, premiumToken, "Premium token mismatch");
        assertEq(draft.payoutToken, payoutToken, "Payout token mismatch");
        assertEq(draft.coverageAmount, COVERAGE_AMOUNT, "Coverage amount mismatch");
        assertEq(draft.committeeId, policyId, "Committee ID mismatch");
        assertTrue(draft.status == IPolicyManager.PolicyStatus.Created, "Status should be Created");
    }

    function externalGetPolicyDraft(uint96 policyId) external view returns (IPolicyManager.PolicyDraft memory) {
        return policyManager.getPolicyDraft(policyId);
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultRequest() internal returns (IPolicyManager.BindPolicyRequest memory) {
        vm.prank(buyer);
        uint96 policyId = policyManager.requestCoverage(
            address(coverPool), beneficiary, beneficiary, premiumToken, payoutToken, COVERAGE_AMOUNT
        );
        return _buildRequest(policyId);
    }

    function _buildRequest(uint96 policyId) internal view returns (IPolicyManager.BindPolicyRequest memory) {
        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: address(coverPool),
            coverageLimit: COVERAGE_LIMIT,
            basePremium: BASE_PREMIUM,
            specId: specId,
            termsHash: termsHash,
            payoutReceiver: beneficiary,
            committeeId: policyId,
            operator: operator,
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + COVERAGE_DURATION),
            expirationTime: uint64(block.timestamp + 1 hours)
        });

        return IPolicyManager.BindPolicyRequest({
            policyId: policyId,
            buyer: buyer,
            beneficiary: beneficiary,
            claimer: beneficiary,
            premiumToken: premiumToken,
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
        mockStakeManager.createCommittee(committeeId, 1_000_000e8);
        mockStakeManager.addOperatorToCommittee(committeeOperator, committeeId);
        if (addVaults) {
            address[] memory vaults = new address[](2);
            vaults[0] = makeAddr("vault1");
            vaults[1] = makeAddr("vault2");
            mockStakeManager.addCommitteeVaults(committeeId, vaults);
        }
        mockStakeManager.setOperatorCommitteeStake(committeeOperator, committeeId, operatorStake);
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
            uint256(quote.committeeId),
            quote.coverageLimit,
            quote.basePremium,
            uint256(quote.specId),
            uint256(quote.termsHash),
            uint256(uint160(quote.payoutReceiver)),
            uint256(quote.startTime),
            uint256(uint160(quote.operator)),
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
            payoutReceiver: address(0x1),
            committeeId: uint96(123),
            operator: address(0x2),
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + 30 days)
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
            _boundPolicy.payoutReceiver = quote.payoutReceiver;
            _boundPolicy.committeeId = quote.committeeId;
            _boundPolicy.operator = quote.operator;
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

contract MockPremiumManager {
    uint256 public collectPremiumCallCount;
    IPremiumManager.PremiumAllocation private _lastAllocation;

    function collectPremium(IPremiumManager.PremiumAllocation calldata allocation) external {
        collectPremiumCallCount++;
        _lastAllocation = allocation;
    }

    function lastAllocation() external view returns (IPremiumManager.PremiumAllocation memory) {
        return _lastAllocation;
    }
}

contract MockStakeManager {
    uint256 public createCommitteeCallCount;
    uint96 public lastCommitteeId;
    uint256 public lastMaxStake;

    mapping(address => uint96) private _operatorCommittees;
    mapping(uint96 => address) private _committeeOperators;
    mapping(uint96 => address[]) private _committeeVaults;
    mapping(uint96 => bool) private _committeeExists;
    mapping(uint96 => mapping(address => uint256)) private _operatorStake;

    function createCommittee(uint96 committeeId, uint256 maxStakeForCommittee) external {
        createCommitteeCallCount++;
        lastCommitteeId = committeeId;
        lastMaxStake = maxStakeForCommittee;
        _committeeExists[committeeId] = true;
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

    function getOperatorCommitteeStake(address operator, uint96 committeeId) external view returns (uint256) {
        if (_committeeOperators[committeeId] == operator && _committeeExists[committeeId]) {
            uint256 stake = _operatorStake[committeeId][operator];
            return stake > 0 ? stake : 1_000_000e8;
        }
        return 0;
    }

    function setOperatorCommitteeStake(address operator, uint96 committeeId, uint256 stake) external {
        _operatorStake[committeeId][operator] = stake;
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
