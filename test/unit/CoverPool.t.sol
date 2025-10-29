// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";

contract CoverPoolTest is Test {
    bytes32 private constant QUOTE_TYPEHASH = keccak256(
        "QuoteData(uint256 poolId,uint256 coverageLimit,uint256 basePremium,uint256 riskBufferDeposit,bytes32 specId,bytes32 termsHash,address payoutAddress,uint96 committeeId,address operator,uint64 startTime,uint64 maturityTime,uint64 quoteExpiry)"
    );
    string private constant NAME = "Catalysis Cover Pool";
    string private constant VERSION = "1";

    uint256 private constant POOL_ID = 1;

    CoverPool private implementation;
    CoverPool private coverPool;

    address private admin;
    address private curator;
    address private policyManager;
    address private payoutRecipient;
    address private operator;

    uint256 private quoteSignerKey;
    address private quoteSigner;

    bytes32 private specId;
    bytes32 private termsHash;

    function setUp() public {
        vm.warp(1_000_000);

        admin = makeAddr("Admin");
        curator = makeAddr("Curator");
        policyManager = makeAddr("PolicyManager");
        payoutRecipient = makeAddr("PayoutRecipient");
        operator = makeAddr("Operator");

        specId = keccak256("SPEC_ID");
        termsHash = keccak256("TERMS");

        quoteSignerKey = uint256(keccak256("quote-signer-key"));
        quoteSigner = vm.addr(quoteSignerKey);
        vm.label(quoteSigner, "QuoteSigner");

        implementation = new CoverPool();
        address clone = Clones.clone(address(implementation));
        coverPool = CoverPool(clone);
        coverPool.initialize(POOL_ID, admin, curator, policyManager, quoteSigner);
    }

    function test_initialize_WhenPoolIdZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.InvalidPoolId.selector);
        pool.initialize(0, admin, curator, policyManager, quoteSigner);
    }

    function test_initialize_WhenAdminZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(POOL_ID, address(0), curator, policyManager, quoteSigner);
    }

    function test_initialize_WhenCuratorZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(POOL_ID, admin, address(0), policyManager, quoteSigner);
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(POOL_ID, admin, curator, address(0), quoteSigner);
    }

    function test_initialize_WhenQuoteSignerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.QuoteSignerNotSet.selector);
        pool.initialize(POOL_ID, admin, curator, policyManager, address(0));
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertEq(coverPool.poolId(), POOL_ID, "Pool id mismatch");
        assertEq(coverPool.curator(), curator, "Curator mismatch");
        assertEq(coverPool.quoteSigner(), quoteSigner, "Quote signer mismatch");
        assertTrue(coverPool.hasRole(coverPool.DEFAULT_ADMIN_ROLE(), admin), "Admin role missing");
        assertTrue(coverPool.hasRole(coverPool.CURATOR_ROLE(), curator), "Curator role missing");
        assertTrue(coverPool.hasRole(coverPool.POLICY_MANAGER_ROLE(), policyManager), "Policy manager role missing");

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
        assertTrue(coverPool.supportsInterface(type(ICoverPool).interfaceId), "Interface not supported");
        assertTrue(coverPool.supportsInterface(type(IAccessControl).interfaceId), "AccessControl interface missing");
    }

    function test_setQuoteSigner_WhenCalledByCurator_UpdatesSigner() public {
        address newSigner = makeAddr("NewSigner");

        vm.expectEmit(true, false, false, true, address(coverPool));
        emit ICoverPool.QuoteSignerSet(newSigner);

        vm.prank(curator);
        coverPool.setQuoteSigner(newSigner);

        assertEq(coverPool.quoteSigner(), newSigner, "Quote signer not updated");
    }

    function test_setQuoteSigner_WhenZero_Reverts() public {
        vm.startPrank(curator);
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        coverPool.setQuoteSigner(address(0));
        vm.stopPrank();
    }

    function test_setQuoteSigner_WhenCallerNotCurator_Reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), coverPool.CURATOR_ROLE()
            )
        );
        coverPool.setQuoteSigner(makeAddr("RandomSigner"));
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

    function test_validateQuote_WhenPoolIdMismatch_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        quote.poolId = POOL_ID + 1;
        bytes memory signature = _signQuote(quote);

        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PoolIdMismatch.selector, POOL_ID, quote.poolId));
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
        quote.payoutAddress = address(0);
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
        ICoverPool.BoundPolicy memory bound = coverPool.bindPolicy(policyCommit, quote);

        assertEq(bound.poolPolicyId, expectedPoolPolicyId, "Pool policy id mismatch");
        assertEq(bound.specId, quote.specId, "Spec id mismatch");
        assertEq(bound.termsHash, quote.termsHash, "Terms hash mismatch");
        assertEq(bound.coverageLimit, quote.coverageLimit, "Coverage limit mismatch");
        assertEq(bound.payoutAddress, quote.payoutAddress, "Payout address mismatch");
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
        coverPool.bindPolicy(policyCommit, quote);

        vm.prank(policyManager);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyAlreadyBound.selector, policyCommit));
        coverPool.bindPolicy(policyCommit, quote);
    }

    function test_bindPolicy_WhenCommitMismatch_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);
        bytes32 validCommit = coverPool.validateQuote(quote, signature);

        quote.coverageLimit += 1;

        vm.prank(policyManager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.PolicyCommitMismatch.selector, _structHash(quote), validCommit)
        );
        coverPool.bindPolicy(validCommit, quote);
    }

    function test_bindPolicy_WhenQuoteExpired_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();
        bytes memory signature = _signQuote(quote);
        bytes32 policyCommit = coverPool.validateQuote(quote, signature);

        vm.warp(quote.quoteExpiry + 1);

        vm.prank(policyManager);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.QuoteExpired.selector, quote.quoteExpiry, block.timestamp));
        coverPool.bindPolicy(policyCommit, quote);
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
        coverPool.bindPolicy(policyCommit, quote);
    }

    function test_bindPolicy_WhenPolicyCommitZero_Reverts() public {
        ICoverPool.QuoteData memory quote = _defaultQuote();

        vm.prank(policyManager);
        vm.expectRevert(ICoverPool.InvalidPolicyCommit.selector);
        coverPool.bindPolicy(bytes32(0), quote);
    }

    function test_getPoolPolicy_WhenUnknown_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyNotFound.selector, bytes32("unknown")));
        coverPool.getPoolPolicy(bytes32("unknown"));
    }

    function _defaultQuote() private view returns (ICoverPool.QuoteData memory quote) {
        quote = ICoverPool.QuoteData({
            poolId: POOL_ID,
            coverageLimit: 1000 ether,
            basePremium: 100 ether,
            riskBufferDeposit: 50 ether,
            specId: specId,
            termsHash: termsHash,
            payoutAddress: payoutRecipient,
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
                quote.poolId,
                quote.coverageLimit,
                quote.basePremium,
                quote.riskBufferDeposit,
                quote.specId,
                quote.termsHash,
                quote.payoutAddress,
                quote.committeeId,
                quote.operator,
                quote.startTime,
                quote.maturityTime,
                quote.quoteExpiry
            )
        );
    }
}
