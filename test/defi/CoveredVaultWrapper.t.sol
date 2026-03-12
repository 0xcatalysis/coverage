// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {ICoveredVaultWrapper} from "../../src/defi/interfaces/ICoveredVaultWrapper.sol";
import {IAlerts as IA} from "../../src/defi/interfaces/IAlerts.sol";
import {IEvents as IE} from "../../src/defi/interfaces/IEvents.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";
import {IBindPolicyHook} from "coverage/interfaces/IBindPolicyHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {MockERC20, MockVaultV2} from "./mocks/Mocks.sol";
import {RealCoverageSetup} from "./helpers/RealCoverageSetup.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title CoveredVaultWrapperTest
/// @notice Unit tests for CoveredVaultWrapper
contract CoveredVaultWrapperTest is RealCoverageSetup {
    CoveredVaultWrapper wrapper;
    MockVaultV2 morphoVault;
    MockERC20 asset;

    address curator = address(0xCCCC);
    address user1 = address(0x1111);
    address user2 = address(0x2222);
    address premiumRecipientAddr = address(0xFEED);

    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
    uint96 POLICY_ID;
    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%
    uint16 constant DEDUCTIBLE_BPS = 100; // 1%

    function setUp() public {
        asset = new MockERC20();
        morphoVault = new MockVaultV2(address(asset), "Morpho Vault", "mVault");
        morphoVault.setOwner(curator);
        morphoVault.setCurator(curator);

        _deployRealCoverage(curator, curator);

        vm.prank(curator);
        policyManager.setSupportedPayoutToken(address(asset), true);

        wrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Covered Vault",
            "cvVault"
        );

        morphoVault.setCurator(address(wrapper));

        POLICY_ID = _createAndBindPolicy(
            address(wrapper), // beneficiary
            address(wrapper), // claimer
            address(asset),
            10_000 ether,
            10_000 ether,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator, // buyer = wrapper.owner()
            address(wrapper)
        );

        // Fund users and morphoVault
        asset.mint(user1, 100_000 ether);
        asset.mint(user2, 100_000 ether);
        asset.mint(address(morphoVault), 100_000 ether);

        // Approve wrapper to pull from users
        vm.prank(user1);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(user2);
        asset.approve(address(wrapper), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                        INITIALIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_initialize_setsState() public view {
        assertEq(address(wrapper.morphoVault()), address(morphoVault));
        assertEq(wrapper.maxCoverableLossBps(), MAX_COVERABLE_LOSS_BPS);
        assertEq(wrapper.deductibleBps(), DEDUCTIBLE_BPS);
        assertEq(wrapper.premiumRecipient(), premiumRecipientAddr);
        assertEq(wrapper.premiumRatePerSecond(), 0, "premiumRate starts at zero");
        assertEq(wrapper.owner(), curator);
        assertEq(wrapper.asset(), address(asset));
        assertEq(wrapper.name(), "Covered Vault");
        assertEq(wrapper.symbol(), "cvVault");
    }

    function test_initialize_revertsOnZeroMorphoVault() public {
        CoveredVaultWrapper freshImpl = new CoveredVaultWrapper();
        CoveredVaultWrapper proxy = CoveredVaultWrapper(address(new ERC1967Proxy(address(freshImpl), "")));
        vm.expectRevert(IA.ZeroAddress.selector);
        proxy.initialize(
            address(0),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "X",
            "X"
        );
    }

    function test_initialize_revertsOnInvalidDeductible() public {
        CoveredVaultWrapper freshImpl = new CoveredVaultWrapper();
        CoveredVaultWrapper proxy = CoveredVaultWrapper(address(new ERC1967Proxy(address(freshImpl), "")));
        vm.expectRevert(IA.InvalidParameters.selector);
        proxy.initialize(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            10_000,
            premiumRecipientAddr,
            curator,
            "X",
            "X"
        );
    }

    function test_initialize_revertsOnInvalidMaxCoverableLoss() public {
        CoveredVaultWrapper freshImpl = new CoveredVaultWrapper();
        CoveredVaultWrapper proxy = CoveredVaultWrapper(address(new ERC1967Proxy(address(freshImpl), "")));
        vm.expectRevert(IA.InvalidMaxCoverableLoss.selector);
        proxy.initialize(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            0,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "X",
            "X"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_deposit_tracksPrincipal() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        assertEq(wrapper.userPrincipal(user1), DEPOSIT_AMOUNT, "userPrincipal should equal deposited assets");
        assertEq(wrapper.totalPrincipal(), DEPOSIT_AMOUNT, "totalPrincipal should equal deposited assets");
    }

    function test_deposit_mintsShares() public {
        vm.prank(user1);
        uint256 shares = wrapper.deposit(DEPOSIT_AMOUNT, user1);

        assertGt(shares, 0, "Should receive shares");
        assertEq(wrapper.balanceOf(user1), shares);
    }

    function test_deposit_tracksPrincipalForReceiver() public {
        // caller = user1, receiver = user2
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user2);

        assertEq(wrapper.userPrincipal(user2), DEPOSIT_AMOUNT, "Principal tracked for receiver");
        assertEq(wrapper.userPrincipal(user1), 0, "No principal for caller");
    }

    function test_deposit_multipleUsers() public {
        vm.prank(user1);
        wrapper.deposit(600 ether, user1);

        vm.prank(user2);
        wrapper.deposit(400 ether, user2);

        assertEq(wrapper.userPrincipal(user1), 600 ether);
        assertEq(wrapper.userPrincipal(user2), 400 ether);
        assertEq(wrapper.totalPrincipal(), 1000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW TESTS — NO LOSS
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_noLoss_noPayout() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 shares = wrapper.balanceOf(user1);
        uint256 user1BalanceBefore = asset.balanceOf(user1);

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 payout = asset.balanceOf(user1) - user1BalanceBefore;
        // Should receive exactly deposited amount (no loss, no insurance)
        assertEq(payout, DEPOSIT_AMOUNT, "Should receive deposited amount back");
        assertEq(wrapper.userPrincipal(user1), 0);
        assertEq(wrapper.totalPrincipal(), 0);
    }

    function test_withdraw_partialNoLoss_reducedPrincipal() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 shares = wrapper.balanceOf(user1);
        uint256 halfShares = shares / 2;

        vm.prank(user1);
        wrapper.redeem(halfShares, user1, user1);

        // Principal halved
        assertApproxEqAbs(wrapper.userPrincipal(user1), DEPOSIT_AMOUNT / 2, 1);
        assertApproxEqAbs(wrapper.totalPrincipal(), DEPOSIT_AMOUNT / 2, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        WITHDRAW TESTS — WITH LOSS
    //////////////////////////////////////////////////////////////*/

    function test_withdraw_withLoss_paysInsurance() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // 10% loss
        morphoVault.setLoss(10);

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1BalanceBefore;
        // assetsReceived ≈ 900, insurance shortfall=100, max=100, effective=99 (1% deductible)
        // total received = 900 + 99 = 999
        assertApproxEqAbs(received, 999 ether, 1 ether, "Should receive ~999 (assets + insurance)");
        assertEq(wrapper.userPrincipal(user1), 0);
        assertEq(wrapper.totalPrincipal(), 0);
    }

    function test_withdraw_100pctLoss_fullClaim() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // 100% loss in underlying
        morphoVault.setLoss(100);

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1BalanceBefore;
        // assetsReceived=0, shortfall=1000, maxInsurance=1000*10%=100, effective=99
        assertApproxEqAbs(received, 99 ether, 1 ether, "Should receive insurance payout on 100% loss");
        assertEq(wrapper.userPrincipal(user1), 0);
    }

    function test_withdraw_largeLoss_cappedByMaxCoverable() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // 50% loss — beyond maxCoverableLossBps of 10%
        morphoVault.setLoss(50);

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1BalanceBefore;
        // assetsReceived=500, maxInsurance=100, effective=99
        // total = 500 + 99 = 599
        assertApproxEqAbs(received, 599 ether, 1 ether, "Insurance capped at maxCoverableLossBps");
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_transfer_migratesPrincipal() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.transfer(user2, shares);

        assertEq(wrapper.userPrincipal(user1), 0, "user1 principal cleared");
        assertEq(wrapper.userPrincipal(user2), DEPOSIT_AMOUNT, "user2 received principal");
    }

    function test_transfer_partialMigratesPrincipal() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 shares = wrapper.balanceOf(user1);
        uint256 halfShares = shares / 2;

        vm.prank(user1);
        wrapper.transfer(user2, halfShares);

        assertApproxEqAbs(wrapper.userPrincipal(user1), DEPOSIT_AMOUNT / 2, 1);
        assertApproxEqAbs(wrapper.userPrincipal(user2), DEPOSIT_AMOUNT / 2, 1);
    }

    function test_transfer_doesNotChangeTotalPrincipal() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 principalBefore = wrapper.totalPrincipal();
        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.transfer(user2, shares);

        assertEq(wrapper.totalPrincipal(), principalBefore, "Transfer must not change totalPrincipal");
    }

    /*//////////////////////////////////////////////////////////////
                        PREMIUM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setPremiumRate_updatesRate() public {
        uint256 newRate = uint256(1e17) / 31_536_000;
        vm.prank(curator);
        vm.expectEmit(false, false, false, true);
        emit IE.PremiumRateUpdated(0, newRate);
        wrapper.setPremiumRate(newRate);
        assertEq(wrapper.premiumRatePerSecond(), newRate);
    }

    function test_setPremiumRate_revertsIfNotOwner() public {
        vm.expectRevert();
        vm.prank(user1);
        wrapper.setPremiumRate(1);
    }

    function test_setPremiumRate_accruesPendingPremiumFirst() public {
        uint256 rate = uint256(1e17) / 31_536_000;
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        vm.prank(curator);
        wrapper.setPremiumRate(rate);

        vm.warp(block.timestamp + 365 days / 2);
        uint256 recipientBefore = asset.balanceOf(premiumRecipientAddr);

        // Change rate again — must settle half-year accrual at old rate first
        vm.prank(curator);
        wrapper.setPremiumRate(rate * 2);

        uint256 premiumPaid = asset.balanceOf(premiumRecipientAddr) - recipientBefore;
        // ~5% of 1000 ether accrued over half-year at 10% annual rate
        assertGt(premiumPaid, 40 ether, "Should have accrued ~5% over half year");
        assertLt(premiumPaid, 60 ether, "Should not exceed ~5% over half year");
        assertEq(wrapper.premiumRatePerSecond(), rate * 2);
    }

    function test_collectPremium_zeroRate_noTransfer() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 recipientBefore = asset.balanceOf(premiumRecipientAddr);
        vm.warp(block.timestamp + 365 days);
        wrapper.collectPremium();

        assertEq(asset.balanceOf(premiumRecipientAddr), recipientBefore, "Zero rate: no premium transferred");
    }

    function test_collectPremium_accrues() public {
        // Deploy a wrapper and set 10% annual rate dynamically
        uint256 tenPctAnnualRate = uint256(1e17) / 31_536_000;

        CoveredVaultWrapper wrapperWithPremium = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Premium Vault",
            "pVault"
        );
        morphoVault.setCurator(address(wrapperWithPremium));
        _createAndBindPolicy(
            address(wrapperWithPremium),
            address(wrapperWithPremium),
            address(asset),
            10_000 ether,
            10_000 ether,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(wrapperWithPremium)
        );
        vm.prank(curator);
        wrapperWithPremium.setPremiumRate(tenPctAnnualRate);

        vm.prank(user1);
        asset.approve(address(wrapperWithPremium), type(uint256).max);
        vm.prank(user1);
        wrapperWithPremium.deposit(DEPOSIT_AMOUNT, user1);

        uint256 recipientBefore = asset.balanceOf(premiumRecipientAddr);

        // Advance 1 year
        vm.warp(block.timestamp + 365 days);
        wrapperWithPremium.collectPremium();

        uint256 premiumPaid = asset.balanceOf(premiumRecipientAddr) - recipientBefore;
        // ~10% of 1000 ether = ~100 ether (WAD math floors so ~99.99...)
        assertGt(premiumPaid, 90 ether, "Should collect >90 ether premium in 1 year");
        assertLt(premiumPaid, 105 ether, "Should collect <105 ether premium in 1 year");
    }

    function test_totalAssets_excludesAccruedPremium() public {
        uint256 tenPctAnnualRate = uint256(1e17) / 31_536_000;

        CoveredVaultWrapper wrapperWithPremium = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Premium Vault 2",
            "pVault2"
        );
        morphoVault.setCurator(address(wrapperWithPremium));
        _createAndBindPolicy(
            address(wrapperWithPremium),
            address(wrapperWithPremium),
            address(asset),
            10_000 ether,
            10_000 ether,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(wrapperWithPremium)
        );
        vm.prank(curator);
        wrapperWithPremium.setPremiumRate(tenPctAnnualRate);

        vm.prank(user1);
        asset.approve(address(wrapperWithPremium), type(uint256).max);
        vm.prank(user1);
        wrapperWithPremium.deposit(DEPOSIT_AMOUNT, user1);

        // Without time passage, totalAssets = morphoValue
        uint256 ta0 = wrapperWithPremium.totalAssets();
        assertApproxEqAbs(ta0, DEPOSIT_AMOUNT, 1);

        // After 1 year, totalAssets decreases by accrued premium
        vm.warp(block.timestamp + 365 days);
        uint256 ta1 = wrapperWithPremium.totalAssets();
        assertLt(ta1, ta0, "totalAssets decreases as premium accrues");
    }

    /*//////////////////////////////////////////////////////////////
                        POLICY BOUND TESTS
    //////////////////////////////////////////////////////////////*/

    function test_maxDeposit_zeroBeforeBound() public {
        // Deploy fresh wrapper — policy not yet bound
        CoveredVaultWrapper freshWrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Fresh",
            "FR"
        );
        assertEq(freshWrapper.maxDeposit(user1), 0, "maxDeposit must be 0 before policy bound");
    }

    function test_maxDeposit_cappedAfterBound() public {
        // wrapper is already bound in setUp — depositCap = coverageLimit * BPS / maxCoverableLossBps
        // = 10_000 ether * 10_000 / 1000 = 100_000 ether; wrapper has no deposits yet
        uint256 maxDep = wrapper.maxDeposit(user1);
        assertEq(maxDep, 100_000 ether);
    }

    function test_onPolicyBound_setsDepositCap() public view {
        assertTrue(wrapper.policyBoundExecuted());
        assertEq(wrapper.policyId(), POLICY_ID);

        uint256 expectedCap = (10_000 * 10_000) / MAX_COVERABLE_LOSS_BPS; // = 100_000
        assertEq(wrapper.depositCap(), expectedCap * 1 ether);
    }

    function test_onPolicyBound_revertIfNotPolicyManager() public {
        CoveredVaultWrapper freshWrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Fresh2",
            "FR2"
        );
        vm.expectRevert(CoveredVaultWrapper.NotAuthorized.selector);
        vm.prank(user1);
        freshWrapper.onPolicyBound(1, 10_000 ether);
    }

    function test_onPolicyBound_revertIfCalledTwice() public {
        vm.expectRevert(CoveredVaultWrapper.PolicyBoundAlreadyExecuted.selector);
        vm.prank(address(policyManager));
        wrapper.onPolicyBound(POLICY_ID, 10_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                        SHORTFALL VIEW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_calculateShortfall_noLoss() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);
        assertEq(wrapper.calculateShortfall(), 0);
    }

    function test_calculateShortfall_withLoss() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);
        morphoVault.setLoss(10);
        uint256 sf = wrapper.calculateShortfall();
        // raw=100, capped=100 (=maxCoverable at 10%), after deductible = 100*99%=99
        assertApproxEqAbs(sf, 99 ether, 1);
    }

    function test_userShortfall_noLoss() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);
        assertEq(wrapper.userShortfall(user1), 0);
    }

    function test_userShortfall_withLoss() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);
        morphoVault.setLoss(10);
        uint256 sf = wrapper.userShortfall(user1);
        assertApproxEqAbs(sf, 99 ether, 1);
    }

    /*//////////////////////////////////////////////////////////////
                        SUPPORTSINTERFACE
    //////////////////////////////////////////////////////////////*/

    function test_supportsInterface_bindPolicyHook() public view {
        assertTrue(wrapper.supportsInterface(type(IBindPolicyHook).interfaceId));
    }

    function test_supportsInterface_IERC165() public view {
        assertTrue(wrapper.supportsInterface(type(IERC165).interfaceId));
    }

    function test_supportsInterface_unknownReturnsFalse() public view {
        assertFalse(wrapper.supportsInterface(0xDEADBEEF));
    }

    /*//////////////////////////////////////////////////////////////
                        EVALUATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_evaluate_noPendingClaim() public view {
        ISpec.EvaluationContext memory context = ISpec.EvaluationContext({
            policyId: POLICY_ID,
            pool: address(coverPool),
            coverageLimit: 10_000 ether,
            startTime: uint32(block.timestamp),
            maturityTime: uint32(block.timestamp + 365 days),
            evaluationTime: uint32(block.timestamp),
            evidenceHash: keccak256("test"),
            additionalData: abi.encode(address(this), 100 ether)
        });
        ISpec.EvaluationResult memory result = wrapper.evaluate(context);
        assertFalse(result.isPayable);
    }
}
