// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {Options, Upgrades} from "@openzeppelin/upgrades/Upgrades.sol";
import {Test} from "forge-std/Test.sol";
import {Policy} from "../../src/Policy.sol";
import {IPolicy} from "../../src/interfaces/IPolicy.sol";

contract PolicyTest is Test {
    uint256 internal constant POLICY_ID = 1;

    address internal admin;
    address internal policyManager;
    address internal buyer;
    address internal beneficiary;
    address internal premiumToken;
    address internal payoutToken;
    address internal pool;
    address internal payoutReceiver;
    address internal operator;

    Policy internal policy;
    bytes32 internal policyCommit;

    event PolicyMinted(
        uint256 indexed policyId,
        address indexed to,
        address indexed pool,
        uint64 startTime,
        uint64 maturityTime,
        uint256 coverageLimit,
        bytes32 policyCommit
    );

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("admin");
        policyManager = makeAddr("policyManager");
        buyer = makeAddr("buyer");
        beneficiary = makeAddr("beneficiary");
        premiumToken = makeAddr("premiumToken");
        payoutToken = makeAddr("payoutToken");
        pool = makeAddr("pool");
        payoutReceiver = makeAddr("payoutReceiver");
        operator = makeAddr("operator");
        policyCommit = keccak256("policy-commit");

        vm.label(admin, "Admin");
        vm.label(policyManager, "PolicyManager");
        vm.label(buyer, "Buyer");
        vm.label(beneficiary, "Beneficiary");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");
        vm.label(pool, "Pool");
        vm.label(payoutReceiver, "PayoutReceiver");
        vm.label(operator, "Operator");

        Options memory deployOpts;
        deployOpts.unsafeSkipAllChecks = true;
        address proxy = Upgrades.deployUUPSProxy(
            "Policy.sol", abi.encodeCall(Policy.initialize, (admin, policyManager)), deployOpts
        );
        policy = Policy(proxy);
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_WhenAdminZero_Reverts() public {
        Policy implementation = new Policy();
        Policy freshPolicy = Policy(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        freshPolicy.initialize(address(0), policyManager);
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        Policy implementation = new Policy();
        Policy freshPolicy = Policy(address(new ERC1967Proxy(address(implementation), "")));
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        freshPolicy.initialize(admin, address(0));
    }

    function test_initialize_SetsRolesAndMetadata() public view {
        assertTrue(policy.hasRole(policy.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertTrue(policy.hasRole(policy.POLICY_MANAGER_ROLE(), policyManager), "Policy manager role missing");
        assertEq(policy.name(), "Catalysis Policy", "Name mismatch");
        assertEq(policy.symbol(), "POLICY", "Symbol mismatch");
        assertTrue(policy.supportsInterface(type(IERC165).interfaceId), "IERC165 unsupported");
        assertTrue(policy.supportsInterface(type(IAccessControl).interfaceId), "IAccessControl unsupported");
        assertTrue(policy.supportsInterface(type(IERC721Metadata).interfaceId), "IERC721Metadata unsupported");
    }

    /*//////////////////////////////////////////////////////////////
                             MINT POLICY
    //////////////////////////////////////////////////////////////*/

    function test_mintPolicy_WhenCallerNotPolicyManager_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, buyer, policy.POLICY_MANAGER_ROLE()
            )
        );
        vm.prank(buyer);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenRecipientZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        vm.prank(policyManager);
        policy.mintPolicy(address(0), POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenBuyerZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.buyer = address(0);
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenBeneficiaryZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.beneficiary = address(0);
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenPremiumTokenZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.premiumToken = address(0);
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenPayoutTokenZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutToken = address(0);
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenPoolZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.pool = address(0);
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenPayoutReceiverZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.payoutReceiver = address(0);
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenOperatorZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.operator = address(0);
        vm.expectRevert(IPolicy.ZeroAddress.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenPolicyCommitEmpty_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.policyCommit = bytes32(0);
        vm.expectRevert(IPolicy.InvalidPolicyCommit.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenCoverageLimitZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.coverageLimit = 0;
        vm.expectRevert(IPolicy.InvalidCoverageLimit.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenBasePremiumZero_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.basePremium = 0;
        vm.expectRevert(IPolicy.InvalidBasePremium.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenCoverageWindowInvalid_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.startTime = metadata.maturityTime;
        vm.expectRevert(
            abi.encodeWithSelector(IPolicy.InvalidCoverageWindow.selector, metadata.startTime, metadata.maturityTime)
        );
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenPolicyAlreadyMinted_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _mintDefaultPolicy();

        metadata.policyCommit = keccak256("new-commit");
        vm.expectRevert(abi.encodeWithSelector(IPolicy.PolicyAlreadyMinted.selector, POLICY_ID));
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenPolicyCommitRegistered_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _mintDefaultPolicy();

        uint256 newPolicyId = 77;
        vm.expectRevert(abi.encodeWithSelector(IPolicy.PolicyCommitAlreadyRegistered.selector, metadata.policyCommit));
        vm.prank(policyManager);
        policy.mintPolicy(buyer, newPolicyId, metadata);
    }

    function test_mintPolicy_WhenPoolPolicyIdEmpty_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.poolPolicyId = bytes32(0);
        vm.expectRevert(IPolicy.InvalidPolicyMetadata.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenTermsHashEmpty_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.termsHash = bytes32(0);
        vm.expectRevert(IPolicy.InvalidPolicyMetadata.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenSpecIdEmpty_Reverts() public {
        IPolicy.PolicyMetadata memory metadata = _defaultMetadata();
        metadata.specId = bytes32(0);
        vm.expectRevert(IPolicy.InvalidSpecId.selector);
        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }

    function test_mintPolicy_WhenValid_MintsSoulboundReceipt() public {
        IPolicy.PolicyMetadata memory metadata = _mintDefaultPolicy();

        assertEq(policy.ownerOf(POLICY_ID), buyer, "Owner mismatch");
        assertEq(policy.balanceOf(buyer), 1, "Balance mismatch");

        IPolicy.PolicyMetadata memory stored = policy.policyMetadata(POLICY_ID);
        assertEq(stored.buyer, metadata.buyer, "Buyer mismatch");
        assertEq(stored.beneficiary, metadata.beneficiary, "Beneficiary mismatch");
        assertEq(stored.premiumToken, metadata.premiumToken, "Premium token mismatch");
        assertEq(stored.basePremium, metadata.basePremium, "Base premium mismatch");
        assertEq(stored.payoutToken, metadata.payoutToken, "Payout token mismatch");
        assertEq(stored.pool, metadata.pool, "Pool mismatch");
        assertEq(stored.coverageLimit, metadata.coverageLimit, "Coverage limit mismatch");
        assertEq(stored.payoutReceiver, metadata.payoutReceiver, "Payout receiver mismatch");
        assertEq(stored.poolPolicyId, metadata.poolPolicyId, "Pool policy id mismatch");
        assertEq(stored.specId, metadata.specId, "Spec id mismatch");
        assertEq(stored.termsHash, metadata.termsHash, "Terms hash mismatch");
        assertEq(stored.policyCommit, metadata.policyCommit, "Policy commit mismatch");
        assertEq(stored.committeeId, metadata.committeeId, "Committee id mismatch");
        assertEq(stored.startTime, metadata.startTime, "Start time mismatch");
        assertEq(stored.maturityTime, metadata.maturityTime, "Maturity time mismatch");
        assertEq(stored.operator, metadata.operator, "Operator mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                           POLICY METADATA
    //////////////////////////////////////////////////////////////*/

    function test_policyMetadata_WhenPolicyMissing_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPolicy.PolicyNotFound.selector, POLICY_ID));
        policy.policyMetadata(POLICY_ID);
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER FROM
    //////////////////////////////////////////////////////////////*/

    function test_transferFrom_WhenCalled_Reverts() public {
        _mintDefaultPolicy();

        address recipient = makeAddr("recipient");
        vm.expectRevert(abi.encodeWithSelector(IPolicy.TransfersLocked.selector, POLICY_ID));
        vm.prank(buyer);
        policy.transferFrom(buyer, recipient, POLICY_ID);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _defaultMetadata() private view returns (IPolicy.PolicyMetadata memory metadata) {
        metadata = IPolicy.PolicyMetadata({
            buyer: buyer,
            beneficiary: beneficiary,
            premiumToken: premiumToken,
            basePremium: 100e18,
            payoutToken: payoutToken,
            pool: pool,
            coverageLimit: 1000,
            payoutReceiver: payoutReceiver,
            poolPolicyId: keccak256("pool-policy-id"),
            specId: keccak256("MorphoSpec"),
            termsHash: keccak256("terms-hash"),
            policyCommit: policyCommit,
            committeeId: uint96(123),
            startTime: uint64(block.timestamp),
            maturityTime: uint64(block.timestamp + 30 days),
            operator: operator
        });
    }

    function _mintDefaultPolicy() private returns (IPolicy.PolicyMetadata memory metadata) {
        metadata = _defaultMetadata();

        vm.expectEmit(true, true, true, true, address(policy));
        emit PolicyMinted(
            POLICY_ID,
            buyer,
            metadata.pool,
            metadata.startTime,
            metadata.maturityTime,
            metadata.coverageLimit,
            metadata.policyCommit
        );

        vm.prank(policyManager);
        policy.mintPolicy(buyer, POLICY_ID, metadata);
    }
}
