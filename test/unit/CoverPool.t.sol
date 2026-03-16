// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IAccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/IAccessControlDefaultAdminRules.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";
import {Test} from "forge-std/Test.sol";
import {CoverPool} from "../../src/CoverPool.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";

contract CoverPoolTest is Test {
    bytes32 internal constant QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 startTime,uint32 maturityTime,uint32 expirationTime)"
    );
    string internal constant NAME = "Catalysis Cover Pool";
    string internal constant VERSION = "1";

    CoverPool internal implementation;
    CoverPool internal coverPool;

    address internal curator;
    address internal policyManager;
    address internal buyer;
    address internal beneficiary;
    address internal premiumToken;
    address internal payoutToken;
    address internal operator;
    address internal stakeManager;
    address internal specRegistry;

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
        beneficiary = makeAddr("beneficiary");
        operator = makeAddr("operator");
        stakeManager = makeAddr("stakeManager");
        specRegistry = makeAddr("specRegistry");
        quoteSignerKey = uint256(keccak256("quote-signer-key"));
        quoteSigner = vm.addr(quoteSignerKey);

        vm.label(curator, "Curator");
        vm.label(policyManager, "PolicyManager");
        vm.label(buyer, "Buyer");
        vm.label(premiumToken, "PremiumToken");
        vm.label(payoutToken, "PayoutToken");
        vm.label(beneficiary, "Beneficiary");
        vm.label(operator, "Operator");
        vm.label(stakeManager, "StakeManager");
        vm.label(specRegistry, "SpecRegistry");
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
        coverPool.initialize(curator, quoteSigner, policyManager, stakeManager, specRegistry, poolFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/
    function test_initialize_WhenCuratorZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(address(0), quoteSigner, policyManager, stakeManager, specRegistry, poolFeeBps);
    }

    function test_initialize_WhenPolicyManagerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, quoteSigner, address(0), stakeManager, specRegistry, poolFeeBps);
    }

    function test_initialize_WhenQuoteSignerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, address(0), policyManager, stakeManager, specRegistry, poolFeeBps);
    }

    function test_initialize_WhenStakeManagerZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, quoteSigner, policyManager, address(0), specRegistry, poolFeeBps);
    }

    function test_initialize_WhenSpecRegistryZero_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        pool.initialize(curator, quoteSigner, policyManager, stakeManager, address(0), poolFeeBps);
    }

    function test_initialize_WhenFeeTooHigh_Reverts() public {
        CoverPool pool = CoverPool(Clones.clone(address(implementation)));
        vm.expectRevert(ICoverPool.InvalidFeeBps.selector);
        pool.initialize(curator, quoteSigner, policyManager, stakeManager, specRegistry, 2100);
    }

    function test_initialize_SetsRolesAndConfiguration() public view {
        assertEq(coverPool.owner(), curator, "Owner mismatch");
        assertEq(coverPool.defaultAdmin(), curator, "Default admin mismatch");
        assertTrue(coverPool.hasRole(coverPool.DEFAULT_ADMIN_ROLE(), curator), "Default admin role missing");
        assertTrue(coverPool.hasRole(coverPool.QUOTE_SIGNER_ROLE(), quoteSigner), "Quote signer role missing");

        assertTrue(
            coverPool.supportsInterface(type(IAccessControlDefaultAdminRules).interfaceId),
            "AccessControlDefaultAdminRules interface missing"
        );
        assertEq(coverPool.poolFeeBps(), poolFeeBps, "Pool fee mismatch");
        assertFalse(coverPool.paused(), "Pool unexpectedly paused");
        assertEq(coverPool.defaultAdminDelay(), 24 hours, "Default admin delay mismatch");
        assertEq(coverPool.feeRecipient(), curator, "Fee recipient should default to curator");
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
                         SET FEE RECIPIENT
    //////////////////////////////////////////////////////////////*/
    function test_setFeeRecipient_WhenCallerNotCurator_Reverts() public {
        address newFeeRecipient = makeAddr("newFeeRecipient");
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, policyManager, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(policyManager);
        coverPool.setFeeRecipient(newFeeRecipient);
    }

    function test_setFeeRecipient_WhenAddressZero_Reverts() public {
        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        vm.prank(curator);
        coverPool.setFeeRecipient(address(0));
    }

    function test_setFeeRecipient_WhenValid_UpdatesStateAndEmits() public {
        address newFeeRecipient = makeAddr("newFeeRecipient");

        vm.expectEmit(true, true, true, true, address(coverPool));
        emit ICoverPool.FeeRecipientSet(curator, newFeeRecipient);

        vm.prank(curator);
        coverPool.setFeeRecipient(newFeeRecipient);

        assertEq(coverPool.feeRecipient(), newFeeRecipient, "Fee recipient not updated");
    }

    function test_setFeeRecipient_MultipleTimes_UpdatesCorrectly() public {
        address firstFeeRecipient = makeAddr("firstFeeRecipient");
        address secondFeeRecipient = makeAddr("secondFeeRecipient");

        vm.startPrank(curator);

        coverPool.setFeeRecipient(firstFeeRecipient);
        assertEq(coverPool.feeRecipient(), firstFeeRecipient, "First fee recipient not set");

        vm.expectEmit(true, true, true, true, address(coverPool));
        emit ICoverPool.FeeRecipientSet(firstFeeRecipient, secondFeeRecipient);

        coverPool.setFeeRecipient(secondFeeRecipient);
        assertEq(coverPool.feeRecipient(), secondFeeRecipient, "Second fee recipient not set");

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                      BIND POLICY FOR REQUEST
    //////////////////////////////////////////////////////////////*/
    function test_bindPolicyForRequest_WhenCallerNotAdmin_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, coverPool.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(operator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenPaused_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.prank(curator);
        coverPool.pause();

        vm.expectRevert();
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenDraftPoolMismatch_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        mockPolicyManager.mockPolicyDraft(policyId, makeAddr("differentPool"), buyer);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICoverPool.PoolAddressMismatch.selector, address(coverPool), makeAddr("differentPool")
            )
        );
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenDraftStatusNotCreated_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        mockPolicyManager.setDraftStatus(policyId, IPolicyManager.PolicyStatus.Bound);

        vm.expectRevert(
            abi.encodeWithSelector(IPolicyManager.InvalidPolicyStatus.selector, IPolicyManager.PolicyStatus.Bound)
        );
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenCuratorMismatch_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        address differentCurator = makeAddr("differentCurator");
        mockPolicyManager.setDraftCurator(policyId, differentCurator);

        vm.expectRevert(abi.encodeWithSelector(ICoverPool.CuratorMismatch.selector, differentCurator, curator));
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenQuotePoolMismatch_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.pool = makeAddr("wrongPool");
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.PoolAddressMismatch.selector, address(coverPool), makeAddr("wrongPool"))
        );
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenPolicyIdMismatch_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId + 1;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyIdMismatch.selector, policyId, policyId + 1));
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenBeneficiaryMismatch_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = makeAddr("wrongBeneficiary");
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.BeneficiaryMismatch.selector, beneficiary, makeAddr("wrongBeneficiary"))
        );
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenEmptyVaults_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](0);
        address spec = makeAddr("spec");

        vm.expectRevert(ICoverPool.EmptyVaults.selector);
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenQuoteCoverageLimitZero_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        quote.coverageLimit = 0;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(ICoverPool.InvalidCoverageLimit.selector);
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenQuoteSpecIdZero_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        quote.specId = bytes32(0);
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(ICoverPool.InvalidSpecId.selector);
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenQuoteTermsHashZero_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        quote.termsHash = bytes32(0);
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(ICoverPool.InvalidTermsHash.selector);
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenQuoteBeneficiaryZero_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = address(0);
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(abi.encodeWithSelector(ICoverPool.BeneficiaryMismatch.selector, beneficiary, address(0)));
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenQuoteStartTimeAfterMaturity_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        quote.startTime = uint32(block.timestamp + 25 hours);
        quote.maturityTime = uint32(block.timestamp + 1 hours);
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(ICoverPool.InvalidCoverageWindow.selector);
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenQuoteExpired_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        quote.expirationTime = uint32(block.timestamp - 1);
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.QuoteExpired.selector, uint32(block.timestamp - 1), block.timestamp)
        );
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenStartTimeInPast_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        quote.startTime = uint32(block.timestamp) - 1;
        quote.maturityTime = uint32(block.timestamp + 25 hours);
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(
            abi.encodeWithSelector(ICoverPool.InvalidStartTime.selector, uint32(block.timestamp) - 1, block.timestamp)
        );
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenVaultZeroAddress_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](2);
        vaults[0] = makeAddr("vault1");
        vaults[1] = address(0);
        address spec = makeAddr("spec");

        vm.expectRevert(ICoverPool.ZeroAddress.selector);
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WithDuplicateVaults_PassesThroughToCore() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address vault1 = makeAddr("vault1");
        address[] memory vaults = new address[](2);
        vaults[0] = vault1;
        vaults[1] = vault1;
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );
        vm.mockCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            ),
            abi.encode()
        );

        vm.expectCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            )
        );

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenInvalidSignature_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;

        uint256 wrongKey = uint256(keccak256("wrong-key"));
        bytes memory signature = _signQuoteWithKey(quote, wrongKey);

        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.expectRevert(ICoverPool.InvalidQuoteSignature.selector);
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_WhenValid_BindsPolicy() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](2);
        vaults[0] = makeAddr("vault1");
        vaults[1] = makeAddr("vault2");
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );

        vm.mockCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            ),
            abi.encode()
        );

        vm.expectEmit(true, true, true, true, address(coverPool));
        emit ICoverPool.PolicyForRequestBound(policyId, 2);

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);

        ICoverPool.BoundPolicy memory boundPolicy = coverPool.getBoundPolicy(policyId);
        assertEq(boundPolicy.policyId, policyId, "Policy ID mismatch");
        assertEq(boundPolicy.specId, quote.specId, "Spec ID mismatch");
        assertEq(boundPolicy.termsHash, quote.termsHash, "Terms hash mismatch");
        assertEq(boundPolicy.coverageLimit, quote.coverageLimit, "Coverage limit mismatch");
        assertEq(boundPolicy.beneficiary, quote.beneficiary, "Beneficiary mismatch");
        assertEq(boundPolicy.startTime, quote.startTime, "Start time mismatch");
        assertEq(boundPolicy.maturityTime, quote.maturityTime, "Maturity time mismatch");

        assertEq(mockPolicyManager.bindPolicyCallCount(), 1, "bindPolicy not called");
        IPolicyManager.BindPolicyRequest memory request = mockPolicyManager.lastBindRequest();
        assertEq(request.policyId, policyId, "Bind request policy ID mismatch");
        assertEq(request.buyer, buyer, "Bind request buyer mismatch");
        assertEq(request.beneficiary, beneficiary, "Bind request beneficiary mismatch");
    }

    function test_bindPolicyForRequest_WithSingleVault_Succeeds() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );
        vm.mockCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            ),
            abi.encode()
        );

        vm.expectEmit(true, true, true, true, address(coverPool));
        emit ICoverPool.PolicyForRequestBound(policyId, 1);

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);

        ICoverPool.BoundPolicy memory boundPolicy = coverPool.getBoundPolicy(policyId);
        assertEq(boundPolicy.policyId, policyId, "Policy not bound");
    }

    function test_bindPolicyForRequest_WithMultipleVaults_Succeeds() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            vaults[i] = makeAddr(string(abi.encodePacked("vault", i)));
        }
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );
        vm.mockCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            ),
            abi.encode()
        );

        vm.expectEmit(true, true, true, true, address(coverPool));
        emit ICoverPool.PolicyForRequestBound(policyId, 5);

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);

        ICoverPool.BoundPolicy memory boundPolicy = coverPool.getBoundPolicy(policyId);
        assertEq(boundPolicy.policyId, policyId, "Policy not bound");
    }

    function test_bindPolicyForRequest_CallsSpecRegistryRegisterSpec() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );
        vm.mockCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            ),
            abi.encode()
        );

        vm.expectCall(specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec));

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function test_bindPolicyForRequest_CallsStakeManagerSetCommitteeVaults() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](2);
        vaults[0] = makeAddr("vault1");
        vaults[1] = makeAddr("vault2");
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );

        vm.expectCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            )
        );

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
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

    function test_hasBoundPolicy_WhenPolicyNotBound_ReturnsFalse() public view {
        assertFalse(coverPool.hasBoundPolicy(999), "Should return false for unknown policy");
    }

    function test_hasBoundPolicy_WhenPolicyBound_ReturnsTrue() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );
        vm.mockCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            ),
            abi.encode()
        );

        assertFalse(coverPool.hasBoundPolicy(policyId), "Should be false before binding");

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);

        assertTrue(coverPool.hasBoundPolicy(policyId), "Should be true after binding");
    }

    function test_bindPolicyForRequest_WhenSamePolicyCommitReused_Reverts() public {
        uint96 policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );
        vm.mockCall(
            stakeManager,
            abi.encodeWithSignature(
                "setCommitteeVaults(uint96,address[],uint256)", policyId, vaults, quote.coverageLimit
            ),
            abi.encode()
        );

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);

        bytes32 policyCommit = _structHash(quote);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyAlreadyBound.selector, policyCommit));
        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
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
        assertEq(schedule, block.timestamp + 24 hours, "Schedule mismatch");
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
                         SET PREMIUM DEFAULTED
    //////////////////////////////////////////////////////////////*/

    function test_setPremiumDefaulted_WhenCallerNotCurator_Reverts() public {
        address unauthorized = makeAddr("unauthorized");
        bytes32 adminRole = coverPool.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorized, adminRole)
        );
        vm.prank(unauthorized);
        coverPool.setPremiumDefaulted(1, true);
    }

    function test_setPremiumDefaulted_WhenPolicyNotBound_Reverts() public {
        uint96 unboundPolicyId = 999;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(ICoverPool.PolicyNotFound.selector, unboundPolicyId));
        coverPool.setPremiumDefaulted(unboundPolicyId, true);
    }

    function test_setPremiumDefaulted_WhenPolicyBound_DelegatesToPolicyManager() public {
        uint96 policyId = _createAndBindPolicy();

        vm.prank(curator);
        coverPool.setPremiumDefaulted(policyId, true);

        assertEq(mockPolicyManager.setPremiumDefaultedCallCount(), 1);
        assertEq(mockPolicyManager.lastPremiumDefaultedPolicyId(), policyId);
        assertTrue(mockPolicyManager.lastPremiumDefaultedValue());
    }

    function test_setPremiumDefaulted_WhenClearingFlag_DelegatesToPolicyManager() public {
        uint96 policyId = _createAndBindPolicy();

        vm.prank(curator);
        coverPool.setPremiumDefaulted(policyId, true);

        vm.prank(curator);
        coverPool.setPremiumDefaulted(policyId, false);

        assertEq(mockPolicyManager.setPremiumDefaultedCallCount(), 2);
        assertFalse(mockPolicyManager.lastPremiumDefaultedValue());
    }

    /*//////////////////////////////////////////////////////////////
                                 HELPERS
    //////////////////////////////////////////////////////////////*/

    function _createAndBindPolicy() private returns (uint96 policyId) {
        policyId = _createDraft();
        ICoverPool.Quote memory quote = _defaultQuote();
        quote.policyId = policyId;
        quote.beneficiary = beneficiary;
        bytes memory signature = _signQuote(quote);
        address[] memory vaults = new address[](1);
        vaults[0] = makeAddr("vault1");
        address spec = makeAddr("spec");

        vm.mockCall(
            specRegistry, abi.encodeWithSignature("registerSpec(bytes32,address)", quote.specId, spec), abi.encode()
        );
        vm.mockCall(
            stakeManager,
            abi.encodeWithSignature("addCommitteeVaults(uint96,address[])", policyId, vaults),
            abi.encode()
        );

        vm.prank(curator);
        coverPool.bindPolicyForRequest(policyId, quote, spec, vaults, signature);
    }

    function _createDraft() private returns (uint96 policyId) {
        vm.mockCall(stakeManager, abi.encodeWithSignature("createCommittee(uint96,address,uint32)"), "");

        vm.mockCall(
            address(mockPolicyManager),
            abi.encodeWithSignature("getCoverPoolFactory()"),
            abi.encode(makeAddr("factory"))
        );

        policyId = uint96(mockPolicyManager.nextPolicyId() + 1);
        mockPolicyManager.mockPolicyDraft(policyId, address(coverPool), buyer);
        mockPolicyManager.setDraftBeneficiary(policyId, beneficiary);
        mockPolicyManager.setDraftCurator(policyId, curator);
    }

    function _defaultQuote() private view returns (ICoverPool.Quote memory quote) {
        quote = ICoverPool.Quote({
            pool: address(coverPool),
            policyId: uint96(123),
            coverageLimit: 1000 ether,
            basePremium: 100 ether,
            specId: specId,
            termsHash: termsHash,
            beneficiary: beneficiary,
            startTime: uint32(block.timestamp + 1 hours),
            maturityTime: uint32(block.timestamp + 25 hours),
            expirationTime: uint32(block.timestamp + 2 days)
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

contract MockPolicyManager {
    uint256 public nextPolicyId;
    uint256 public bindPolicyCallCount;
    IPolicyManager.BindPolicyRequest private _lastBindRequest;
    ICoverPool.BoundPolicy private _lastBoundPolicy;
    mapping(uint256 => IPolicyManager.PolicyDraft) private _drafts;
    mapping(uint96 => bool) public premiumDefaulted;
    uint256 public setPremiumDefaultedCallCount;
    uint96 public lastPremiumDefaultedPolicyId;
    bool public lastPremiumDefaultedValue;

    function bindPolicy(
        IPolicyManager.BindPolicyRequest calldata request,
        ICoverPool.BoundPolicy calldata boundPolicy
    )
        external
    {
        bindPolicyCallCount++;
        _lastBindRequest = request;
        _lastBoundPolicy = boundPolicy;
    }

    function lastBindRequest() external view returns (IPolicyManager.BindPolicyRequest memory) {
        return _lastBindRequest;
    }

    function lastBoundPolicy() external view returns (ICoverPool.BoundPolicy memory) {
        return _lastBoundPolicy;
    }

    function mockPolicyDraft(uint96 policyId, address pool, address buyer) external {
        _drafts[policyId] = IPolicyManager.PolicyDraft({
            pool: pool,
            buyer: buyer,
            beneficiary: address(0),
            claimer: address(0),
            payoutToken: address(0),
            curator: address(0),
            duration: 30 days,
            policyId: policyId,
            status: IPolicyManager.PolicyStatus.Created,
            bindPolicyHook: address(1)
        });
    }

    function setDraftStatus(uint96 policyId, IPolicyManager.PolicyStatus status) external {
        _drafts[policyId].status = status;
    }

    function setDraftBeneficiary(uint96 policyId, address beneficiary) external {
        _drafts[policyId].beneficiary = beneficiary;
    }

    function setDraftCurator(uint96 policyId, address curator_) external {
        _drafts[policyId].curator = curator_;
    }

    function getPolicyDraft(uint96 policyId) external view returns (IPolicyManager.PolicyDraft memory) {
        IPolicyManager.PolicyDraft memory draft = _drafts[policyId];
        require(draft.status != IPolicyManager.PolicyStatus.None, "PolicyDraftNotFound");
        return draft;
    }

    function getCoverPoolFactory() external pure returns (address) {
        return address(0);
    }

    function setPremiumDefaulted(uint96 policyId, bool defaulted) external {
        setPremiumDefaultedCallCount++;
        lastPremiumDefaultedPolicyId = policyId;
        lastPremiumDefaultedValue = defaulted;
        premiumDefaulted[policyId] = defaulted;
    }
}
