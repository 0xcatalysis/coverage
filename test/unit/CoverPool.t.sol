// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";

contract CoverPoolTest is Test {
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 committeeId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address payoutReceiver,uint64 startTime,address operator,uint64 maturityTime,uint64 expirationTime)"
    );
    string internal constant NAME = "Catalysis Cover Pool";
    string internal constant VERSION = "1";

    CoverPool internal implementation;
    CoverPool internal coverPool;

    address internal curator;
    address internal policyManager;
    address internal buyer;
    address internal payoutRecipient;
    address internal premiumToken;
    address internal payoutToken;
    address internal operator;
    address internal stakeManager;

    MockPolicyManager internal mockPolicyManager;

    uint256 internal quoteSignerKey;
    address internal quoteSigner;

    bytes32 internal specId;
    bytes32 internal termsHash;
    uint16 internal poolFeeBps;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/
    function setUp() public {
        vm.warp(1_000_000);

        curator = makeAddr("curator");
        buyer = makeAddr("buyer");
        premiumToken = makeAddr("premiumToken");
        payoutToken = makeAddr("payoutToken");
        payoutRecipient = makeAddr("payoutRecipient");
        operator = makeAddr("operator");
        stakeManager = makeAddr("stakeManager");
        quoteSignerKey = uint256(keccak256("quote-signer-key"));
        quoteSigner = vm.addr(quoteSignerKey);

        vm.label(curator, "Curator");
        vm.label(policyManager, "PolicyManager");
        vm.label(buyer, "Buyer");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");
        vm.label(payoutRecipient, "PayoutRecipient");
        vm.label(operator, "Operator");
        vm.label(stakeManager, "StakeManager");
        vm.label(quoteSigner, "QuoteSigner");

        specId = keccak256("SPEC_ID");
        termsHash = keccak256("TERMS");
        poolFeeBps = 125;

        mockPolicyManager = new MockPolicyManager();
        policyManager = address(mockPolicyManager);
        vm.label(policyManager, "PolicyManager");

        implementation = new CoverPool();
        address clone = Clones.clone(address(implementation));
        coverPool = CoverPool(clone);
        coverPool.initialize(curator, policyManager, quoteSigner, stakeManager, poolFeeBps, operator);
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/
    function test_initialize_WhenCuratorZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(address(0), policyManager, quoteSigner, stakeManager, poolFeeBps, operator);
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, address(0), quoteSigner, stakeManager, poolFeeBps, operator);
    }

    function test_initialize_WhenQuoteSignerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, policyManager, address(0), stakeManager, poolFeeBps, operator);
    }

    function test_initialize_WhenStakeManagerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, policyManager, quoteSigner, address(0), poolFeeBps, operator);
    }

    function test_initialize_WhenFeeTooHigh_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.InvalidFeeBps.selector);
        pool.initialize(curator, policyManager, quoteSigner, stakeManager, 2100, operator);
    }

    function test_initialize_WhenPoolOperatorZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, policyManager, quoteSigner, stakeManager, poolFeeBps, address(0));
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertEq(coverPool.owner(), curator, "Owner mismatch");
        assertEq(coverPool.defaultAdmin(), curator, "Default admin mismatch");
        assertTrue(coverPool.hasRole(coverPool.DEFAULT_ADMIN_ROLE(), curator), "Default admin role missing");
        assertTrue(coverPool.hasRole(coverPool.POLICY_MANAGER_ROLE(), policyManager), "Policy manager role missing");
        assertTrue(coverPool.hasRole(coverPool.QUOTE_SIGNER_ROLE(), quoteSigner), "Quote signer role missing");

        assertTrue(
            coverPool.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId),
            "AccessControlDefaultAdminRules interface missing"
        );
        assertEq(coverPool.poolFeeBps(), poolFeeBps, "Pool fee mismatch");
        assertEq(coverPool.poolOperator(), operator, "Pool operator mismatch");
        assertFalse(coverPool.paused(), "Pool unexpectedly paused");
        assertEq(coverPool.defaultAdminDelay(), 0, "Default admin delay mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                                 PAUSE
    //////////////////////////////////////////////////////////////*/
    function test_pause_WhenCallerNotCurator_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, policyManager, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(policyManager);
        coverPool.pause();
    }

    function test_pause_WhenCalledByCurator_PausesPool() public {
        vm.prank(curator);
        coverPool.pause();
        assertTrue(coverPool.paused(), "Pool not paused");
    }

    /*//////////////////////////////////////////////////////////////
                                UNPAUSE
    //////////////////////////////////////////////////////////////*/
    function test_unpause_WhenCallerNotCurator_Reverts() public {
        vm.prank(curator);
        coverPool.pause();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, policyManager, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(policyManager);
        coverPool.unpause();
    }

    function test_unpause_WhenCalledByCurator_ClearsPause() public {
        vm.prank(curator);
        coverPool.pause();
        assertTrue(coverPool.paused(), "Pool not paused");

        vm.prank(curator);
        coverPool.unpause();
        assertFalse(coverPool.paused(), "Pool still paused");
    }

    /*//////////////////////////////////////////////////////////////
                          SET POOL FEE BPS
    //////////////////////////////////////////////////////////////*/
    function test_setPoolFeeBps_WhenCallerNotCurator_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, policyManager, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(policyManager);
        coverPool.setPoolFeeBps(poolFeeBps);
    }

    function test_setPoolFeeBps_WhenFeeTooHigh_Reverts() public {
        vm.expectRevert(ICoverPool.InvalidFeeBps.selector);
        vm.prank(curator);
        coverPool.setPoolFeeBps(2500);
    }

    function test_setPoolFeeBps_WhenValid_UpdatesState() public {
        uint16 newFee = 250;

        vm.expectEmit(true, true, true, true, address(coverPool));
        emit ICoverPool.PoolFeeBpsSet(poolFeeBps, newFee);

        vm.prank(curator);
        coverPool.setPoolFeeBps(newFee);

        assertEq(coverPool.poolFeeBps(), newFee, "Pool fee not updated");
    }

    /*//////////////////////////////////////////////////////////////
                           BIND POLICY
    //////////////////////////////////////////////////////////////*/
    function test_recordBoundPolicy_WhenPaused_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.verifyQuote(quote, signature);
        uint256 policyId = 1;

        vm.prank(curator);
        coverPool.pause();

        vm.prank(policyManager);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        coverPool.recordBoundPolicy(policyId, policyCommit, quote);
    }

    function test_recordBoundPolicy_WhenCalledByPolicyManager_BindsMetadata() public {
        uint256 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.committeeId = uint96(policyId);
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.verifyQuote(quote, signature);

        vm.expectEmit(true, true, false, true, address(coverPool));
        emit ICoverPool.BoundPolicyRecorded(policyCommit, policyId, quote.coverageLimit);

        vm.prank(policyManager);
        ICoverPool.BoundPolicy memory bound = coverPool.recordBoundPolicy(policyId, policyCommit, quote);

        assertEq(bound.policyId, policyId, "Pool policy id mismatch");
        assertEq(bound.specId, quote.specId, "Spec id mismatch");
        assertEq(bound.termsHash, quote.termsHash, "Terms hash mismatch");
        assertEq(bound.coverageLimit, quote.coverageLimit, "Coverage limit mismatch");
        assertEq(bound.payoutReceiver, quote.payoutReceiver, "Payout receiver mismatch");
        assertEq(bound.committeeId, quote.committeeId, "Committee id mismatch");
        assertEq(bound.operator, quote.operator, "Operator mismatch");
        assertEq(bound.startTime, quote.startTime, "Start time mismatch");
        assertEq(bound.maturityTime, quote.maturityTime, "Maturity time mismatch");

        ICoverPool.BoundPolicy memory stored = coverPool.getBoundPolicy(bound.policyId);
        assertEq(stored.policyId, bound.policyId, "Stored policy not found");
    }

    function test_recordBoundPolicy_WhenCalledTwice_Reverts() public {
        uint256 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.committeeId = uint96(policyId);
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.verifyQuote(quote, signature);

        vm.prank(policyManager);
        coverPool.recordBoundPolicy(policyId, policyCommit, quote);

        vm.prank(policyManager);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyAlreadyBound.selector, policyCommit));
        coverPool.recordBoundPolicy(policyId, policyCommit, quote);
    }

    function test_recordBoundPolicy_WhenCommitMismatch_Reverts() public {
        uint256 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.committeeId = uint96(policyId);
        bytes memory originalSignature = _signQuote(quote);
        bytes32 validCommit = coverPool.verifyQuote(quote, originalSignature);

        quote.coverageLimit += 1;

        vm.prank(policyManager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.PolicyCommitMismatch.selector, _structHash(quote), validCommit)
        );
        coverPool.recordBoundPolicy(policyId, validCommit, quote);
    }

    function test_recordBoundPolicy_WhenCallerNotPolicyManager_Reverts() public {
        uint256 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.committeeId = uint96(policyId);
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.verifyQuote(quote, signature);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), coverPool.POLICY_MANAGER_ROLE()
            )
        );
        coverPool.recordBoundPolicy(policyId, policyCommit, quote);
    }

    function test_recordBoundPolicy_WhenPolicyCommitZero_Reverts() public {
        uint256 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.committeeId = uint96(policyId);

        vm.prank(policyManager);
        vm.expectRevert(ICoverPool.InvalidPolicyCommit.selector);
        coverPool.recordBoundPolicy(policyId, bytes32(0), quote);
    }

    /*//////////////////////////////////////////////////////////////
                        QUOTE DOMAIN SEPARATOR
    //////////////////////////////////////////////////////////////*/
    function test_quoteDomainSeparator_ReturnsExpectedSeparator() public view {
        bytes32 expectedDomain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(NAME)),
                keccak256(bytes(VERSION)),
                block.chainid,
                address(coverPool)
            )
        );
        assertEq(coverPool.quoteDomainSeparator(), expectedDomain, "Domain separator mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                          GET BOUND POLICY
    //////////////////////////////////////////////////////////////*/
    function test_getBoundPolicy_WhenUnknown_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyNotFound.selector, 999));
        coverPool.getBoundPolicy(999);
    }

    /*//////////////////////////////////////////////////////////////
                           VERIFY QUOTE
    //////////////////////////////////////////////////////////////*/
    function test_verifyQuote_WhenPaused_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);

        vm.prank(curator);
        coverPool.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenValidSignature_ReturnsCommit() public view {
        ICoverPool.Quote memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);

        bytes32 policyCommit = coverPool.verifyQuote(quote, signature);
        assertEq(policyCommit, _structHash(quote), "Policy commit mismatch");
    }

    function test_verifyQuote_WhenSignatureInvalid_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        uint256 otherKey = uint256(keccak256("invalid-key"));
        bytes memory signature = _signQuoteWithKey(quote, otherKey);

        vm.expectRevert(ICoverPool.InvalidQuoteSignature.selector);
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenQuoteExpired_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.expirationTime = uint64(block.timestamp - 1);
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(abi.encodeWithSelector(ICoverPool.QuoteExpired.selector, quote.expirationTime, block.timestamp));
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenPoolAddressMismatch_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.pool = makeAddr("otherPool");
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PoolAddressMismatch.selector, address(coverPool), quote.pool));
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenCoverageLimitZero_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.coverageLimit = 0;
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidCoverageLimit.selector);
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenSpecIdZero_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.specId = bytes32(0);
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidSpecId.selector);
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenTermsHashZero_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.termsHash = bytes32(0);
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidTermsHash.selector);
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenPayoutAddressZero_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.payoutReceiver = address(0);
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidPayoutReceiver.selector);
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenOperatorZero_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.operator = address(0);
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidOperator.selector);
        coverPool.verifyQuote(quote, signature);
    }

    function test_verifyQuote_WhenWindowInvalid_Reverts() public {
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.startTime = quote.maturityTime;
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidCoverageWindow.selector);
        coverPool.verifyQuote(quote, signature);
    }

    /*//////////////////////////////////////////////////////////////
                             GRANT ROLE
    //////////////////////////////////////////////////////////////*/
    function test_grantRole_WhenCalledByOwner_AddsQuoteSigner() public {
        address newSigner = makeAddr("newSigner");
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();
        vm.prank(curator);
        coverPool.grantRole(signerRole, newSigner);

        assertTrue(coverPool.hasRole(signerRole, newSigner), "Quote signer role not granted");
    }

    function test_grantRole_WhenCallerNotAdmin_Reverts() public {
        address caller = makeAddr("notAdmin");
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(caller);
        coverPool.grantRole(signerRole, makeAddr("randomSigner"));
    }

    function test_grantRole_WhenDefaultAdminRequested_Reverts() public {
        bytes32 adminRole = coverPool.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector)
        );
        vm.prank(curator);
        coverPool.grantRole(adminRole, policyManager);
    }

    /*//////////////////////////////////////////////////////////////
                             REVOKE ROLE
    //////////////////////////////////////////////////////////////*/
    function test_revokeRole_WhenCalledByOwner_RemovesQuoteSigner() public {
        address newSigner = makeAddr("newSigner");
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();

        vm.startPrank(curator);
        coverPool.grantRole(signerRole, newSigner);
        coverPool.revokeRole(signerRole, newSigner);
        assertFalse(coverPool.hasRole(signerRole, newSigner), "Quote signer role not revoked");
        vm.stopPrank();
    }

    function test_revokeRole_WhenCallerNotAdmin_Reverts() public {
        address caller = makeAddr("randomCaller");
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();

        vm.prank(curator);
        coverPool.grantRole(signerRole, caller);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, caller, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(caller);
        coverPool.revokeRole(signerRole, quoteSigner);
    }

    function test_revokeRole_WhenDefaultAdminRequested_Reverts() public {
        bytes32 adminRole = coverPool.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminRules.selector)
        );
        vm.prank(curator);
        coverPool.revokeRole(adminRole, curator);
    }

    /*//////////////////////////////////////////////////////////////
                            RENOUNCE ROLE
    //////////////////////////////////////////////////////////////*/
    function test_renounceRole_WhenDefaultAdminRequested_Reverts() public {
        bytes32 adminRole = coverPool.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, 0)
        );
        vm.prank(curator);
        coverPool.renounceRole(adminRole, curator);
    }

    function test_renounceRole_WhenQuoteSignerRenounces_RemovesRole() public {
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();
        address newSigner = makeAddr("renouncingSigner");

        vm.prank(curator);
        coverPool.grantRole(signerRole, newSigner);

        vm.prank(newSigner);
        coverPool.renounceRole(signerRole, newSigner);

        assertFalse(coverPool.hasRole(signerRole, newSigner), "Quote signer role not renounced");
    }

    function test_renounceRole_WhenOwnerRenouncesNonAdmin_RemovesRole() public {
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();

        vm.prank(curator);
        coverPool.grantRole(signerRole, curator);

        vm.prank(curator);
        coverPool.renounceRole(signerRole, curator);

        assertFalse(coverPool.hasRole(signerRole, curator), "Owner role renounce failed");
    }

    /*//////////////////////////////////////////////////////////////
                    DEFAULT ADMIN TRANSFER
    //////////////////////////////////////////////////////////////*/
    function test_beginDefaultAdminTransfer_SchedulesTransfer() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(curator);
        coverPool.beginDefaultAdminTransfer(newAdmin);

        (address pendingAdmin, uint48 schedule) = coverPool.pendingDefaultAdmin();
        assertEq(pendingAdmin, newAdmin, "Pending admin mismatch");
        assertEq(schedule, block.timestamp, "Schedule mismatch");
    }

    function test_acceptDefaultAdminTransfer_WhenDelayNotPassed_Reverts() public {
        address newAdmin = makeAddr("newAdmin");

        vm.prank(curator);
        coverPool.beginDefaultAdminTransfer(newAdmin);

        (, uint48 schedule) = coverPool.pendingDefaultAdmin();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlEnforcedDefaultAdminDelay.selector, schedule
            )
        );
        vm.prank(newAdmin);
        coverPool.acceptDefaultAdminTransfer();
    }

    function test_acceptDefaultAdminTransfer_TwoStep_UpdatesAdminRole() public {
        address newAdmin = makeAddr("newAdmin");
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();
        address additionalSigner = makeAddr("additionalSigner");

        vm.prank(curator);
        coverPool.beginDefaultAdminTransfer(newAdmin);

        (address pendingAdmin, uint48 schedule) = coverPool.pendingDefaultAdmin();
        assertEq(pendingAdmin, newAdmin, "Pending admin mismatch");

        vm.warp(schedule + 1);

        vm.startPrank(newAdmin);
        coverPool.acceptDefaultAdminTransfer();

        assertEq(coverPool.owner(), newAdmin, "Owner not updated");
        assertEq(coverPool.defaultAdmin(), newAdmin, "Default admin not updated");
        assertTrue(coverPool.hasRole(coverPool.DEFAULT_ADMIN_ROLE(), newAdmin), "New admin missing admin role");
        assertFalse(coverPool.hasRole(coverPool.DEFAULT_ADMIN_ROLE(), curator), "Old admin still has role");

        coverPool.grantRole(signerRole, additionalSigner);
        assertTrue(coverPool.hasRole(signerRole, additionalSigner), "New admin failed to grant role");
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, curator, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(curator);
        coverPool.grantRole(signerRole, makeAddr("shouldFail"));
    }

    function test_acceptDefaultAdminTransfer_WhenNotPendingAdmin_Reverts() public {
        address newAdmin = makeAddr("nextAdmin");
        address unauthorized = makeAddr("unauthorized");

        vm.prank(curator);
        coverPool.beginDefaultAdminTransfer(newAdmin);

        (, uint48 schedule) = coverPool.pendingDefaultAdmin();
        vm.warp(schedule + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControlDefaultAdminRules.AccessControlInvalidDefaultAdmin.selector, unauthorized
            )
        );
        vm.prank(unauthorized);
        coverPool.acceptDefaultAdminTransfer();
    }

    function test_cancelDefaultAdminTransfer_CancelsPendingTransfer() public {
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(curator);
        coverPool.beginDefaultAdminTransfer(newAdmin);

        (address pendingAdmin,) = coverPool.pendingDefaultAdmin();
        assertEq(pendingAdmin, newAdmin, "Pending admin not set");

        coverPool.cancelDefaultAdminTransfer();

        (pendingAdmin,) = coverPool.pendingDefaultAdmin();
        assertEq(pendingAdmin, address(0), "Pending admin not cleared");
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/
    function _createDraft() private returns (uint256 policyId) {
        vm.mockCall(stakeManager, abi.encodeWithSignature("createCommittee(uint96,uint256)"), "");
        vm.mockCall(stakeManager, abi.encodeWithSignature("addOperatorToCommittee(address,uint96)"), "");

        // Mock that coverPool exists in factory
        vm.mockCall(
            address(mockPolicyManager),
            abi.encodeWithSignature("getCoverPoolFactory()"),
            abi.encode(makeAddr("factory"))
        );

        // Create draft through MockPolicyManager
        vm.prank(address(coverPool));
        policyId = mockPolicyManager.generatePolicyId();

        // Mock the draft in PolicyManager
        mockPolicyManager.mockPolicyDraft(policyId, address(coverPool), buyer);
    }

    function _defaultQuote() private view returns (ICoverPool.Quote memory quote) {
        quote = ICoverPool.Quote({
            pool: address(coverPool),
            committeeId: uint96(123),
            coverageLimit: 1000 ether,
            basePremium: 100 ether,
            specId: specId,
            termsHash: termsHash,
            payoutReceiver: payoutRecipient,
            startTime: uint64(block.timestamp + 1 hours),
            operator: operator,
            maturityTime: uint64(block.timestamp + 25 hours),
            expirationTime: uint64(block.timestamp + 2 days)
        });
    }

    function _signQuote(ICoverPool.Quote memory quote) private view returns (bytes memory) {
        return _signQuoteWithKey(quote, quoteSignerKey);
    }

    function _signQuoteWithKey(ICoverPool.Quote memory quote, uint256 key) private view returns (bytes memory) {
        bytes32 structHash = _structHash(quote);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", coverPool.quoteDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _structHash(ICoverPool.Quote memory quote) private pure returns (bytes32) {
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

contract MockPolicyManager {
    uint256 public nextPolicyId;
    uint256 public bindPolicyCallCount;
    IPolicyManager.BindPolicyRequest private _lastBindRequest;
    mapping(uint256 => IPolicyManager.PolicyDraft) private _drafts;

    function generatePolicyId() external returns (uint256 policyId) {
        policyId = ++nextPolicyId;
    }

    function bindPolicy(IPolicyManager.BindPolicyRequest calldata request) external {
        bindPolicyCallCount++;
        _lastBindRequest = request;
    }

    function lastBindRequest() external view returns (IPolicyManager.BindPolicyRequest memory) {
        return _lastBindRequest;
    }

    function mockPolicyDraft(uint256 policyId, address pool, address buyer) external {
        _drafts[policyId] = IPolicyManager.PolicyDraft({
            pool: pool,
            buyer: buyer,
            beneficiary: address(0),
            claimer: address(0),
            premiumToken: address(0),
            payoutToken: address(0),
            coverageAmount: 1_000_000e8,
            committeeId: uint96(policyId),
            status: IPolicyManager.PolicyStatus.Created
        });
    }

    function getPolicyDraft(uint256 policyId) external view returns (IPolicyManager.PolicyDraft memory) {
        IPolicyManager.PolicyDraft memory draft = _drafts[policyId];
        require(draft.status != IPolicyManager.PolicyStatus.None, "PolicyDraftNotFound");
        return draft;
    }
}
