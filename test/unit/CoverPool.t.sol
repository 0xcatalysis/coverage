// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

contract CoverPoolTest is Test {
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "QuoteData(address pool,uint256 coverageLimit,uint256 basePremium,uint256 riskBufferDeposit,bytes32 specId,bytes32 termsHash,address payoutReceiver,uint96 committeeId,address operator,uint64 startTime,uint64 maturityTime,uint64 quoteExpiry)"
    );
    string private constant NAME = "Catalysis Cover Pool";
    string private constant VERSION = "1";

    CoverPool private implementation;
    CoverPool private coverPool;

    address private curator;
    address private policyManager;
    address private payoutRecipient;
    address private operator;

    uint256 private quoteSignerKey;
    address private quoteSigner;

    bytes32 private specId;
    bytes32 private termsHash;
    bytes32 private defaultSpecId;
    uint16 private poolFeeBps;

    function setUp() public {
        vm.warp(1_000_000);

        curator = makeAddr("curator");
        policyManager = makeAddr("policyManager");
        payoutRecipient = makeAddr("payoutRecipient");
        operator = makeAddr("operator");
        quoteSignerKey = uint256(keccak256("quote-signer-key"));
        quoteSigner = vm.addr(quoteSignerKey);

        vm.label(curator, "Curator");
        vm.label(policyManager, "PolicyManager");
        vm.label(payoutRecipient, "PayoutRecipient");
        vm.label(operator, "Operator");
        vm.label(quoteSigner, "QuoteSigner");

        specId = keccak256("SPEC_ID");
        termsHash = keccak256("TERMS");
        // forge-lint: disable-next-line(unsafe-typecast)
        defaultSpecId = bytes32("DEFAULT_SPEC");
        poolFeeBps = 125;

        implementation = new CoverPool();
        address clone = Clones.clone(address(implementation));
        coverPool = CoverPool(clone);
        coverPool.initialize(curator, policyManager, quoteSigner, defaultSpecId, poolFeeBps);
    }

    function test_initialize_WhenCuratorZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(address(0), policyManager, quoteSigner, defaultSpecId, poolFeeBps);
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, address(0), quoteSigner, defaultSpecId, poolFeeBps);
    }

    function test_initialize_WhenQuoteSignerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, policyManager, address(0), defaultSpecId, poolFeeBps);
    }

    function test_initialize_WhenFeeTooHigh_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.InvalidFeeBps.selector);
        pool.initialize(curator, policyManager, quoteSigner, defaultSpecId, 2100);
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertEq(coverPool.owner(), curator, "Owner mismatch");
        assertTrue(coverPool.hasRole(coverPool.DEFAULT_ADMIN_ROLE(), curator), "Default admin role missing");
        assertTrue(coverPool.hasRole(coverPool.POLICY_MANAGER_ROLE(), policyManager), "Policy manager role missing");
        assertTrue(coverPool.hasRole(coverPool.QUOTE_SIGNER_ROLE(), quoteSigner), "Quote signer role missing");

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
        assertTrue(coverPool.supportsInterface(type(IAccessControl).interfaceId), "AccessControl interface missing");
        assertEq(coverPool.defaultSpecId(), defaultSpecId, "Default spec id mismatch");
        assertEq(coverPool.poolFeeBps(), poolFeeBps, "Pool fee mismatch");
        assertFalse(coverPool.paused(), "Pool unexpectedly paused");
    }

    function test_updateConfig_WhenCallerNotCurator_Reverts() public {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 newSpecId = bytes32("newSpec");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, policyManager, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(policyManager);
        coverPool.updateConfig(newSpecId, poolFeeBps);
    }

    function test_updateConfig_WhenFeeTooHigh_Reverts() public {
        vm.expectRevert(ICoverPool.InvalidFeeBps.selector);
        vm.prank(curator);
        // forge-lint: disable-next-line(unsafe-typecast)
        coverPool.updateConfig(bytes32("newSpec"), 2500);
    }

    function test_updateConfig_WhenValid_UpdatesState() public {
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes32 newSpecId = bytes32("newSpec");
        uint16 newFee = 250;

        vm.expectEmit(true, true, true, true, address(coverPool));
        emit ICoverPool.ConfigUpdated(defaultSpecId, newSpecId, poolFeeBps, newFee);

        vm.prank(curator);
        coverPool.updateConfig(newSpecId, newFee);

        assertEq(coverPool.defaultSpecId(), newSpecId, "Spec id not updated");
        assertEq(coverPool.poolFeeBps(), newFee, "Pool fee not updated");
    }

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

    function test_bindPolicy_WhenPaused_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.validateQuote(quote, signature);

        vm.prank(curator);
        coverPool.pause();

        vm.prank(policyManager);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        coverPool.bindPolicy(policyCommit, quote, signature);
    }

    function test_validateQuote_WhenPaused_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);

        vm.prank(curator);
        coverPool.pause();

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        coverPool.validateQuote(quote, signature);
    }

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

    function test_transferOwnershipTwoStep_UpdatesAdminRole() public {
        address newOwner = makeAddr("newOwner");
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();
        address additionalSigner = makeAddr("additionalSigner");

        vm.prank(curator);
        coverPool.transferOwnership(newOwner);
        assertEq(coverPool.pendingOwner(), newOwner, "Pending owner mismatch");

        vm.startPrank(newOwner);
        coverPool.acceptOwnership();

        assertEq(coverPool.owner(), newOwner, "Owner not updated");
        assertTrue(coverPool.hasRole(coverPool.DEFAULT_ADMIN_ROLE(), newOwner), "New owner missing admin");
        assertFalse(coverPool.hasRole(coverPool.DEFAULT_ADMIN_ROLE(), curator), "Old owner still admin");

        coverPool.grantRole(signerRole, additionalSigner);
        assertTrue(coverPool.hasRole(signerRole, additionalSigner), "New owner failed to grant role");
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, curator, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(curator);
        coverPool.grantRole(signerRole, makeAddr("shouldFail"));
    }

    function test_acceptOwnership_WhenNotPendingOwner_Reverts() public {
        address newOwner = makeAddr("nextOwner");
        address unauthorized = makeAddr("unauthorized");

        vm.prank(curator);
        coverPool.transferOwnership(newOwner);

        vm.expectRevert();
        vm.prank(unauthorized);
        coverPool.acceptOwnership();
    }

    function test_transferOwnershipTwoStep_UpdatesQuoteSignerAdmin() public {
        address newOwner = makeAddr("newOwnerB");
        address newSigner = makeAddr("signerAfterTransfer");
        bytes32 signerRole = coverPool.QUOTE_SIGNER_ROLE();

        vm.prank(curator);
        coverPool.transferOwnership(newOwner);

        vm.startPrank(newOwner);
        coverPool.acceptOwnership();
        coverPool.grantRole(signerRole, newSigner);
        assertTrue(coverPool.hasRole(signerRole, newSigner), "New owner could not grant quote signer role");
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, curator, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(curator);
        coverPool.revokeRole(signerRole, newSigner);
    }

    function test_validateQuote_WhenValidSignature_ReturnsCommit() public view {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);

        bytes32 policyCommit = coverPool.validateQuote(quote, signature);
        assertEq(policyCommit, _structHash(quote), "Policy commit mismatch");
    }

    function test_validateQuote_WhenSignatureInvalid_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        uint256 otherKey = uint256(keccak256("invalid-key"));
        bytes memory signature = _signQuoteWithKey(quote, otherKey);

        vm.expectRevert(ICoverPool.QuoteSignatureInvalid.selector);
        coverPool.validateQuote(quote, signature);
    }

    function test_validateQuote_WhenQuoteExpired_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        quote.quoteExpiry = uint64(block.timestamp - 1);
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(abi.encodeWithSelector(ICoverPool.QuoteExpired.selector, quote.quoteExpiry, block.timestamp));
        coverPool.validateQuote(quote, signature);
    }

    function test_validateQuote_WhenPoolAddressMismatch_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        quote.pool = makeAddr("otherPool");
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PoolAddressMismatch.selector, address(coverPool), quote.pool));
        coverPool.validateQuote(quote, signature);
    }

    function test_validateQuote_WhenCoverageLimitZero_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        quote.coverageLimit = 0;
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidCoverageLimit.selector);
        coverPool.validateQuote(quote, signature);
    }

    function test_validateQuote_WhenPayoutAddressZero_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        quote.payoutReceiver = address(0);
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidQuoteRecipient.selector);
        coverPool.validateQuote(quote, signature);
    }

    function test_validateQuote_WhenOperatorZero_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        quote.operator = address(0);
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidQuoteRecipient.selector);
        coverPool.validateQuote(quote, signature);
    }

    function test_validateQuote_WhenWindowInvalid_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        quote.startTime = quote.maturityTime;
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(ICoverPool.InvalidCoverageWindow.selector);
        coverPool.validateQuote(quote, signature);
    }

    function test_bindPolicy_WhenCalledByPolicyManager_BindsMetadata() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.validateQuote(quote, signature);

        bytes32 expectedPoolPolicyId = keccak256(abi.encodePacked(address(coverPool), policyCommit));

        vm.expectEmit(true, true, false, true, address(coverPool));
        emit ICoverPool.PolicyBound(policyCommit, expectedPoolPolicyId, quote.coverageLimit);

        vm.prank(policyManager);
        ICoverPool.BoundPolicy memory bound = coverPool.bindPolicy(policyCommit, quote, signature);

        assertEq(bound.poolPolicyId, expectedPoolPolicyId, "Pool policy id mismatch");
        assertEq(bound.specId, quote.specId, "Spec id mismatch");
        assertEq(bound.termsHash, quote.termsHash, "Terms hash mismatch");
        assertEq(bound.coverageLimit, quote.coverageLimit, "Coverage limit mismatch");
        assertEq(bound.payoutAddress, quote.payoutReceiver, "Payout address mismatch");
        assertEq(bound.committeeId, quote.committeeId, "Committee id mismatch");
        assertEq(bound.operator, quote.operator, "Operator mismatch");
        assertEq(bound.startTime, quote.startTime, "Start time mismatch");
        assertEq(bound.maturityTime, quote.maturityTime, "Maturity time mismatch");

        ICoverPool.BoundPolicy memory stored = coverPool.getPoolPolicy(bound.poolPolicyId);
        assertEq(stored.poolPolicyId, bound.poolPolicyId, "Stored policy not found");
    }

    function test_bindPolicy_WhenCalledTwice_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.validateQuote(quote, signature);

        vm.prank(policyManager);
        coverPool.bindPolicy(policyCommit, quote, signature);

        vm.prank(policyManager);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyAlreadyBound.selector, policyCommit));
        coverPool.bindPolicy(policyCommit, quote, signature);
    }

    function test_bindPolicy_WhenCommitMismatch_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory originalSignature = _signQuote(quote);
        bytes32 validCommit = coverPool.validateQuote(quote, originalSignature);

        quote.coverageLimit += 1;
        bytes memory mismatchedSignature = _signQuote(quote);

        vm.prank(policyManager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.PolicyCommitMismatch.selector, _structHash(quote), validCommit)
        );
        coverPool.bindPolicy(validCommit, quote, mismatchedSignature);
    }

    function test_bindPolicy_WhenQuoteExpired_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.validateQuote(quote, signature);

        vm.warp(quote.quoteExpiry + 1);

        vm.prank(policyManager);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.QuoteExpired.selector, quote.quoteExpiry, block.timestamp));
        coverPool.bindPolicy(policyCommit, quote, signature);
    }

    function test_bindPolicy_WhenCallerNotPolicyManager_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.validateQuote(quote, signature);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), coverPool.POLICY_MANAGER_ROLE()
            )
        );
        coverPool.bindPolicy(policyCommit, quote, signature);
    }

    function test_bindPolicy_WhenPolicyCommitZero_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);

        vm.prank(policyManager);
        vm.expectRevert(ICoverPool.InvalidPolicyCommit.selector);
        coverPool.bindPolicy(bytes32(0), quote, signature);
    }

    function test_getPoolPolicy_WhenUnknown_Reverts() public {
        // forge-lint: disable-next-line(unsafe-typecast)
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyNotFound.selector, bytes32("unknown")));
        // forge-lint: disable-next-line(unsafe-typecast)
        coverPool.getPoolPolicy(bytes32("unknown"));
    }

    function _defaultQuote() private view returns (ICoverPool.QuoteData memory quote) {
        quote = ICoverPool.QuoteData({
            pool: address(coverPool),
            coverageLimit: 1000 ether,
            basePremium: 100 ether,
            riskBufferDeposit: 50 ether,
            specId: specId,
            termsHash: termsHash,
            payoutReceiver: payoutRecipient,
            committeeId: uint96(123),
            operator: operator,
            startTime: uint64(block.timestamp + 1 hours),
            maturityTime: uint64(block.timestamp + 25 hours),
            quoteExpiry: uint64(block.timestamp + 2 days)
        });
    }

    function _signQuote(ICoverPool.QuoteData memory quote) private view returns (bytes memory) {
        return _signQuoteWithKey(quote, quoteSignerKey);
    }

    function _signQuoteWithKey(
        ICoverPool.QuoteData memory quote,
        uint256 key
    )
        private
        view
        returns (bytes memory)
    {
        bytes32 structHash = _structHash(quote);
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", coverPool.quoteDomainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    function _structHash(ICoverPool.QuoteData memory quote) private pure returns (bytes32) {
        return keccak256(
            abi.encode(
                QUOTE_TYPEHASH,
                quote.pool,
                quote.coverageLimit,
                quote.basePremium,
                quote.riskBufferDeposit,
                quote.specId,
                quote.termsHash,
                quote.payoutReceiver,
                quote.committeeId,
                quote.operator,
                quote.startTime,
                quote.maturityTime,
                quote.quoteExpiry
            )
        );
    }
}
