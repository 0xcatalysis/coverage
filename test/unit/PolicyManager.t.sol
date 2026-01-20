// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {PolicyManager} from "../../src/PolicyManager.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IPremiumManager} from "../../src/interfaces/IPremiumManager.sol";
import {IPolicy} from "../../src/interfaces/IPolicy.sol";

contract PolicyManagerTest is Test {
    uint256 internal constant POLICY_ID = 1;
    uint256 internal constant COVERAGE_LIMIT = 1_000_000e18;
    uint256 internal constant BASE_PREMIUM = 10_000e18;
    uint256 internal constant COVERAGE_AMOUNT = 500_000e8; // USD with 8 decimals
    uint16 internal constant PLATFORM_FEE_BPS = 50;
    uint16 internal constant POOL_FEE_BPS = 150;
    uint64 internal constant COVERAGE_DURATION = 30 days;

    address internal admin;
    address internal buyer;
    address internal beneficiary;
    address internal premiumToken;
    address internal payoutToken;
    address internal operator;

    PolicyManager internal policyManager;
    MockCoverPool internal coverPool;
    MockPremiumManager internal mockPremiumManager;
    MockPolicy internal mockPolicy;
    MockStakeManager internal mockStakeManager;
    MockClaimManager internal mockClaimManager;

    bytes32 internal policyCommit;
    bytes32 internal specId;
    bytes32 internal termsHash;

    event PolicyBound(
        uint256 indexed policyId,
        address indexed buyer,
        address indexed beneficiary,
        address pool,
        uint256 coverageLimit,
        uint256 basePremium,
        bytes32 policyCommit
    );

    event PremiumManagerSet(address indexed premiumManager_);
    event PolicyContractSet(address indexed policy_);
    event PlatformFeeSet(uint16 indexed platformFeeBps_);

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        buyer = makeAddr("buyer");
        beneficiary = makeAddr("beneficiary");
        premiumToken = makeAddr("premiumToken");
        payoutToken = makeAddr("payoutToken");
        operator = makeAddr("operator");

        vm.label(admin, "Admin");
        vm.label(buyer, "Buyer");
        vm.label(beneficiary, "Beneficiary");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");
        vm.label(operator, "Operator");

        coverPool = new MockCoverPool();
        mockPremiumManager = new MockPremiumManager();
        mockPolicy = new MockPolicy();
        mockStakeManager = new MockStakeManager();
        mockClaimManager = new MockClaimManager();

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
                    address(mockPolicy),
                    address(mockStakeManager),
                    address(mockClaimManager),
                    PLATFORM_FEE_BPS
                )
            ),
            deployOpts
        );
        policyManager = PolicyManager(proxy);

        vm.label(address(policyManager), "PolicyManager");
        vm.label(address(coverPool), "CoverPool");
        vm.label(address(mockPremiumManager), "MockPremiumManager");
        vm.label(address(mockPolicy), "MockPolicy");
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
            address(mockPolicy),
            address(mockStakeManager),
            address(mockClaimManager),
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
            address(mockPolicy),
            address(mockStakeManager),
            address(mockClaimManager),
            PLATFORM_FEE_BPS
        );
    }

    function test_initialize_WhenPolicyZero_Reverts() public {
        PolicyManager implementation = new PolicyManager();
        PolicyManager freshManager = PolicyManager(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        freshManager.initialize(
            admin,
            address(mockPremiumManager),
            address(0),
            address(mockStakeManager),
            address(mockClaimManager),
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
            address(mockPolicy),
            address(mockStakeManager),
            address(mockClaimManager),
            2501
        );
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertTrue(policyManager.hasRole(policyManager.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertEq(policyManager.premiumManager(), address(mockPremiumManager), "Premium manager mismatch");
        assertEq(policyManager.policy(), address(mockPolicy), "Policy mismatch");
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

    function test_setPolicy_WhenCallerNotAdmin_Reverts() public {
        MockPolicy newPolicy = new MockPolicy();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policyManager.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(buyer);
        policyManager.setPolicy(address(newPolicy));
    }

    function test_setPolicy_WhenAddressZero_Reverts() public {
        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(admin);
        policyManager.setPolicy(address(0));
    }

    function test_setPolicy_WhenValid_UpdatesStateAndEmits() public {
        MockPolicy newPolicy = new MockPolicy();

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit PolicyContractSet(address(newPolicy));

        vm.prank(admin);
        policyManager.setPolicy(address(newPolicy));

        assertEq(policyManager.policy(), address(newPolicy), "Policy not updated");
    }

    /*//////////////////////////////////////////////////////////////
                            BIND POLICY
    //////////////////////////////////////////////////////////////*/

    function test_bindPolicy_WhenPaused_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.prank(admin);
        policyManager.pause();

        vm.expectRevert();
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenBuyerZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.buyer = address(0);

        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenBeneficiaryZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.beneficiary = address(0);

        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenPremiumTokenZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.premiumToken = address(0);

        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenPayoutTokenZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.payoutToken = address(0);

        vm.expectRevert(IPolicyManager.ZeroAddress.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenQuotePoolZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.pool = address(0);

        vm.expectRevert(IPolicyManager.InvalidQuotePool.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenCoverageLimitZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.coverageLimit = 0;

        vm.expectRevert(IPolicyManager.InvalidCoverageLimit.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenBasePremiumZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.basePremium = 0;

        vm.expectRevert(IPolicyManager.InvalidBasePremium.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenCoverageAmountZero_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.coverageAmount = 0;

        vm.expectRevert(IPolicyManager.InvalidCoverageAmount.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenInvalidCoverageWindow_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.startTime = uint64(block.timestamp + 1 days);
        request.quote.maturityTime = uint64(block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyManager.InvalidCoverageWindow.selector, request.quote.startTime, request.quote.maturityTime
            )
        );
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenMaturityInPast_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.startTime = uint64(block.timestamp - 2 days);
        request.quote.maturityTime = uint64(block.timestamp - 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyManager.InvalidCoverageWindow.selector, request.quote.startTime, request.quote.maturityTime
            )
        );
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenPolicyCommitEmpty_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        coverPool.setReturnPolicyCommit(bytes32(0));

        vm.expectRevert(IPolicyManager.InvalidPolicyCommit.selector);
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenValid_CallsValidateQuote() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.prank(buyer);
        policyManager.bindPolicy(request);

        assertEq(coverPool.bindPolicyCallCount(), 1, "BindPolicy should be called after verifyQuote");
    }

    function test_bindPolicy_WhenValid_BindsPolicyOnCoverPool() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.prank(buyer);
        policyManager.bindPolicy(request);

        assertEq(coverPool.bindPolicyCallCount(), 1, "BindPolicy not called");
        assertEq(coverPool.lastPolicyCommit(), policyCommit, "Policy commit mismatch");
    }

    function test_bindPolicy_WhenValid_CollectsPremium() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.prank(buyer);
        policyManager.bindPolicy(request);

        assertEq(mockPremiumManager.collectPremiumCallCount(), 1, "CollectPremium not called");

        IPremiumManager.PremiumAllocation memory allocation = mockPremiumManager.lastAllocation();
        assertEq(allocation.policyId, POLICY_ID, "Policy ID mismatch");
        assertEq(allocation.policyCommit, policyCommit, "Policy commit mismatch");
        assertEq(allocation.buyer, buyer, "Buyer mismatch");
        assertEq(allocation.committeeId, uint96(POLICY_ID), "Committee ID mismatch");
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

    function test_bindPolicy_WhenValid_MintsPolicy() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.prank(buyer);
        policyManager.bindPolicy(request);

        assertEq(mockPolicy.mintPolicyCallCount(), 1, "MintPolicy not called");

        (address mintedTo, uint256 mintedPolicyId, IPolicy.PolicyMetadata memory metadata) = mockPolicy.lastMint();
        assertEq(mintedTo, buyer, "Minted to wrong address");
        assertEq(mintedPolicyId, POLICY_ID, "Policy ID mismatch");
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
        assertEq(metadata.policyCommit, policyCommit, "Metadata policy commit mismatch");
        assertEq(metadata.committeeId, uint96(POLICY_ID), "Metadata committee ID mismatch");
        assertEq(metadata.startTime, uint64(block.timestamp), "Metadata start time mismatch");
        assertEq(metadata.maturityTime, uint64(block.timestamp + COVERAGE_DURATION), "Metadata maturity time mismatch");
        assertEq(metadata.operator, operator, "Metadata operator mismatch");
    }

    function test_bindPolicy_WhenValid_EmitsPolicyBound() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.expectEmit(true, true, true, true, address(policyManager));
        emit PolicyBound(POLICY_ID, buyer, beneficiary, address(coverPool), COVERAGE_LIMIT, BASE_PREMIUM, policyCommit);

        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenValid_ExecutesInCorrectOrder() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.prank(buyer);
        policyManager.bindPolicy(request);

        assertEq(coverPool.bindPolicyCallCount(), 1, "BindPolicy should be called");
        assertEq(mockPremiumManager.collectPremiumCallCount(), 1, "CollectPremium should be called");
        assertEq(mockPolicy.mintPolicyCallCount(), 1, "MintPolicy should be called");
    }

    function test_bindPolicy_MultiplePoliciesToSameBuyer_Succeeds() public {
        IPolicyManager.BindPolicyRequest memory request1 = _defaultRequest();
        IPolicyManager.BindPolicyRequest memory request2 = _defaultRequest();

        coverPool.setReturnPolicyCommit(keccak256("policy-commit-1"));
        vm.prank(buyer);
        policyManager.bindPolicy(request1);

        coverPool.setReturnPolicyCommit(keccak256("policy-commit-2"));
        vm.prank(buyer);
        policyManager.bindPolicy(request2);

        assertEq(mockPolicy.mintPolicyCallCount(), 2, "Should mint two policies");
    }

    function test_bindPolicy_IsProtectedByReentrancyGuard() public {
        IPolicyManager.BindPolicyRequest memory request1 = _defaultRequest();
        IPolicyManager.BindPolicyRequest memory request2 = _defaultRequest();

        coverPool.setReturnPolicyCommit(keccak256("policy-commit-1"));
        vm.prank(buyer);
        policyManager.bindPolicy(request1);

        coverPool.setReturnPolicyCommit(keccak256("policy-commit-2"));
        vm.prank(buyer);
        policyManager.bindPolicy(request2);

        assertEq(mockPremiumManager.collectPremiumCallCount(), 2, "Should allow sequential calls");
    }

    function test_bindPolicy_WhenMaturityEqualsBlockTimestamp_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        request.quote.startTime = uint64(block.timestamp - 1 days);
        request.quote.maturityTime = uint64(block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPolicyManager.InvalidCoverageWindow.selector, request.quote.startTime, request.quote.maturityTime
            )
        );
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_WhenStartEqualsMaturity_Reverts() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint64 sameTime = uint64(block.timestamp + 1 days);
        request.quote.startTime = sameTime;
        request.quote.maturityTime = sameTime;

        vm.expectRevert(abi.encodeWithSelector(IPolicyManager.InvalidCoverageWindow.selector, sameTime, sameTime));
        vm.prank(buyer);
        policyManager.bindPolicy(request);
    }

    function test_bindPolicy_UsesPlatformFeeFromState() public {
        uint16 newPlatformFee = 200;
        vm.prank(admin);
        policyManager.setPlatformFee(newPlatformFee);

        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        vm.prank(buyer);
        policyManager.bindPolicy(request);

        IPremiumManager.PremiumAllocation memory allocation = mockPremiumManager.lastAllocation();
        assertEq(allocation.platformFeeBps, newPlatformFee, "Should use updated platform fee");
    }

    function test_bindPolicy_PolicyIdIncrementsCorrectly() public {
        IPolicyManager.BindPolicyRequest memory request1 = _defaultRequest();
        IPolicyManager.BindPolicyRequest memory request2 = _defaultRequest();

        coverPool.setReturnPolicyCommit(keccak256("policy-commit-1"));
        vm.prank(buyer);
        policyManager.bindPolicy(request1);

        IPremiumManager.PremiumAllocation memory allocation1 = mockPremiumManager.lastAllocation();
        assertEq(allocation1.policyId, 1, "First policy ID should be 1");

        coverPool.setReturnPolicyCommit(keccak256("policy-commit-2"));
        vm.prank(buyer);
        policyManager.bindPolicy(request2);

        IPremiumManager.PremiumAllocation memory allocation2 = mockPremiumManager.lastAllocation();
        assertEq(allocation2.policyId, 2, "Second policy ID should be 2");
    }

    function test_bindPolicy_WhenValid_CreatesCommitteeWithCoverageAmount() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();

        vm.prank(buyer);
        policyManager.bindPolicy(request);

        assertEq(mockStakeManager.createCommitteeCallCount(), 1, "CreateCommittee not called");
        assertEq(mockStakeManager.lastCommitteeId(), uint96(POLICY_ID), "Committee ID mismatch");
        assertEq(mockStakeManager.lastMaxStake(), COVERAGE_AMOUNT, "Coverage amount mismatch");
    }

    function test_bindPolicy_PassesCustomCoverageAmount() public {
        IPolicyManager.BindPolicyRequest memory request = _defaultRequest();
        uint256 customAmount = 999_999e8;
        request.coverageAmount = customAmount;

        vm.prank(buyer);
        policyManager.bindPolicy(request);

        assertEq(mockStakeManager.lastMaxStake(), customAmount, "Should pass custom coverage amount");
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
        assertEq(policyManager.policy(), address(mockPolicy), "Policy should persist");
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

    function test_policy_ReturnsCorrectAddress() public view {
        assertEq(policyManager.policy(), address(mockPolicy), "Should return policy address");
    }

    function test_platformFeeBps_ReturnsCorrectValue() public {
        assertEq(policyManager.platformFeeBps(), PLATFORM_FEE_BPS, "Should return initial platform fee");

        uint16 newFee = 300;
        vm.prank(admin);
        policyManager.setPlatformFee(newFee);

        assertEq(policyManager.platformFeeBps(), newFee, "Should return updated platform fee");
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultRequest() internal view returns (IPolicyManager.BindPolicyRequest memory) {
        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: address(coverPool),
            coverageLimit: COVERAGE_LIMIT,
            basePremium: BASE_PREMIUM,
            specId: specId,
            termsHash: termsHash,
            payoutReceiver: beneficiary,
            committeeId: uint96(123),
            operator: operator,
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + COVERAGE_DURATION),
            expirationTime: uint64(block.timestamp + 1 hours)
        });

        return IPolicyManager.BindPolicyRequest({
            buyer: buyer,
            beneficiary: beneficiary,
            premiumToken: premiumToken,
            payoutToken: payoutToken,
            coverageAmount: COVERAGE_AMOUNT,
            quote: quote,
            signature: abi.encodePacked("mock-signature")
        });
    }
}

contract MockCoverPool {
    uint256 public bindPolicyCallCount;
    bytes32 private _returnPolicyCommit;
    bytes32 public lastPolicyCommit;
    ICoverPool.BoundPolicy private _boundPolicy;

    constructor() {
        _returnPolicyCommit = keccak256("policy-commit");
        _boundPolicy = ICoverPool.BoundPolicy({
            policyId: keccak256("pool-policy-id"),
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

    function verifyQuote(ICoverPool.Quote calldata, bytes calldata) external view returns (bytes32) {
        return _returnPolicyCommit;
    }

    function bindPolicy(
        bytes32 policyCommit,
        ICoverPool.Quote calldata quote,
        bytes calldata
    )
        external
        returns (ICoverPool.BoundPolicy memory)
    {
        bindPolicyCallCount++;
        lastPolicyCommit = policyCommit;
        _boundPolicy.coverageLimit = quote.coverageLimit;
        _boundPolicy.payoutReceiver = quote.payoutReceiver;
        _boundPolicy.committeeId = quote.committeeId;
        _boundPolicy.operator = quote.operator;
        _boundPolicy.startTime = quote.startTime;
        _boundPolicy.maturityTime = quote.maturityTime;
        _boundPolicy.termsHash = quote.termsHash;
        return _boundPolicy;
    }

    function owner() external pure returns (address) {
        return address(0xC0000001);
    }

    function poolFeeBps() external pure returns (uint16) {
        return 150;
    }

    function setReturnPolicyCommit(bytes32 commit) external {
        _returnPolicyCommit = commit;
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

contract MockPolicy {
    uint256 public mintPolicyCallCount;
    address private _lastTo;
    uint256 private _lastPolicyId;
    IPolicy.PolicyMetadata private _lastMetadata;

    function mintPolicy(address to, uint256 policyId, IPolicy.PolicyMetadata calldata metadata) external {
        mintPolicyCallCount++;
        _lastTo = to;
        _lastPolicyId = policyId;
        _lastMetadata = metadata;
    }

    function lastMint() external view returns (address, uint256, IPolicy.PolicyMetadata memory) {
        return (_lastTo, _lastPolicyId, _lastMetadata);
    }
}

contract MockStakeManager {
    uint256 public createCommitteeCallCount;
    uint96 public lastCommitteeId;
    uint256 public lastMaxStake;

    function createCommittee(uint96 committeeId, uint256 maxStakeForCommittee) external {
        createCommitteeCallCount++;
        lastCommitteeId = committeeId;
        lastMaxStake = maxStakeForCommittee;
    }
}

contract MockClaimManager {}
