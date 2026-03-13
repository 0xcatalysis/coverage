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

        // Change rate again — must settle half-year accrual at old rate into pendingPremium first
        vm.prank(curator);
        wrapper.setPremiumRate(rate * 2);

        // setPremiumRate now uses pull-payment: accrual lands in pendingPremium, not the recipient.
        // collectPremium() pushes the pending amount to the recipient.
        wrapper.collectPremium();

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
               PREMIUM × INSURANCE REGRESSION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_totalPremiumRedeemed_tracksAccrual() public {
        uint256 rate = uint256(1e17) / 31_536_000; // ~10% per year
        vm.prank(curator);
        wrapper.setPremiumRate(rate);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        assertEq(wrapper.totalPremiumRedeemed(), 0, "No premium before time passes");

        vm.warp(block.timestamp + 365 days);
        wrapper.collectPremium();

        uint256 redeemed = wrapper.totalPremiumRedeemed();
        assertGt(redeemed, 90 ether, "totalPremiumRedeemed should exceed 90 ether after 1 year at 10%");
        assertLt(redeemed, 105 ether, "totalPremiumRedeemed should be under 105 ether after 1 year at 10%");
        assertEq(wrapper.pendingPremium(), 0, "pendingPremium is cleared after collectPremium");
    }

    /// @dev Regression: premium deductions must NOT trigger insurance claims.
    ///      Before the fix, any non-zero premium rate produced userPrincipalForWithdrawal > assetsReceived,
    ///      causing the vault to file spurious insurance claims against the coverage pool.
    function test_withdraw_premiumOnly_noInsuranceClaim() public {
        uint256 rate = uint256(1e17) / 31_536_000; // ~10% per year
        vm.prank(curator);
        wrapper.setPremiumRate(rate);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // 1 year passes — ~10% of principal (≈100 ether) accrues as premium, no hack
        vm.warp(block.timestamp + 365 days);

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);
        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1BalanceBefore;

        // User paid ~100 ether in premium, receives ~900 ether back — no insurance payout
        assertGt(received, 890 ether, "Should receive ~900 (principal minus premium)");
        assertLt(received, 910 ether, "Should not receive more than principal minus premium");

        // Key assertion: received is ~900, NOT ~999. The old buggy code filed an insurance
        // claim for the premium-induced gap and paid ~99 ether on top (≈999 total). If this
        // passes, no spurious claim was filed.
        assertLt(received, 950 ether, "Insurance must NOT have been paid for premium deductions");

        // Confirm premium was actually taken from the Morpho position during the redeem.
        // After the last user exits, totalPremiumRedeemed is zeroed by the pro-rata decrement
        // (correct: no principal remains to carry premium history). The accrued premium is
        // instead held in pendingPremium, waiting for collectPremium() to forward it.
        assertGt(wrapper.pendingPremium(), 90 ether, "Premium must be in pendingPremium after redeem");
    }

    /// @dev Premium reduces the insured basis; only losses BEYOND that basis trigger insurance.
    function test_withdraw_premiumPlusLoss_onlyLossInsured() public {
        uint256 rate = uint256(1e17) / 31_536_000; // ~10% per year
        vm.prank(curator);
        wrapper.setPremiumRate(rate);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // Advance half a year — ~50 ether premium paid; morpho position → ~950
        vm.warp(block.timestamp + 365 days / 2);
        wrapper.collectPremium();

        // Confirm premium was deducted BEFORE the loss event.
        // totalPremiumRedeemed is checked here (after collectPremium but before redeem)
        // because the pro-rata decrement in _withdraw() will zero it for the last exiting user.
        assertGt(wrapper.totalPremiumRedeemed(), 40 ether, "Premium must have been deducted before loss");

        // 10% hack loss on the remaining ~950 ether position → ~95 ether loss
        morphoVault.setLoss(10);

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);
        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1BalanceBefore;

        // assetsReceived ≈ 855, insuredBasis ≈ 950, shortfall ≈ 95, insurance ≈ 94 (after 1% deductible)
        // total ≈ 855 + 94 = 949
        // Old bug: shortfall = 1000−855 = 145, capped at effectiveMaxInsurance = 99 → total ≈ 954
        assertApproxEqAbs(received, 949 ether, 3 ether, "Should receive assets + insurance for the loss only");
    }

    function test_calculateShortfall_premiumOnly_returnsZero() public {
        uint256 rate = uint256(1e17) / 31_536_000;
        vm.prank(curator);
        wrapper.setPremiumRate(rate);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        vm.warp(block.timestamp + 365 days);
        wrapper.collectPremium(); // settle; totalPremiumRedeemed updated, morpho position reduced

        // No hack — only premium has reduced the Morpho position
        assertEq(wrapper.calculateShortfall(), 0, "Premium deductions must not appear as coverable shortfall");
    }

    function test_userShortfall_premiumOnly_returnsZero() public {
        uint256 rate = uint256(1e17) / 31_536_000;
        vm.prank(curator);
        wrapper.setPremiumRate(rate);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        vm.warp(block.timestamp + 365 days);
        wrapper.collectPremium();

        assertEq(wrapper.userShortfall(user1), 0, "Premium deductions must not appear as user shortfall");
    }

    /// @dev Regression: when a user exits, their pro-rata share of totalPremiumRedeemed must be
    ///      removed so the (totalPrincipal − totalPremiumRedeemed) / totalPrincipal ratio stays
    ///      stable for remaining users.
    ///
    ///      Bug: totalPrincipal decrements on each withdrawal but totalPremiumRedeemed never does.
    ///      With two equal users and totalPremiumRedeemed=200:
    ///        user1 exits → insuredBasis=900 (correct)
    ///        user2 exits → insuredBasis=800 instead of 900 (bug: full 200 hangs against 1000)
    ///
    ///      Fix: after user1 exits, totalPremiumRedeemed halves to 100.
    ///        user2 exits → insuredBasis = 1000*(1000−100)/1000 = 900 (correct)
    function test_withdrawal_preservesInsuredBasisRatioForRemainingUsers() public {
        // Fresh wrapper: 20% max coverage, 0% deductible for clean arithmetic
        CoveredVaultWrapper w = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            2000, // 20% max coverage
            0, // 0% deductible
            premiumRecipientAddr,
            curator,
            "RatioTest",
            "RT"
        );
        morphoVault.setCurator(address(w));
        _createAndBindPolicy(
            address(w),
            address(w),
            address(asset),
            type(uint128).max,
            type(uint128).max,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(w)
        );

        // 10%/year premium
        uint256 rate = uint256(1e17) / 31_536_000;
        vm.prank(curator);
        w.setPremiumRate(rate);

        vm.prank(user1);
        asset.approve(address(w), type(uint256).max);
        vm.prank(user1);
        w.deposit(1000 ether, user1);

        vm.prank(user2);
        asset.approve(address(w), type(uint256).max);
        vm.prank(user2);
        w.deposit(1000 ether, user2);

        // 1 year: ~200 ether premium accrues on totalPrincipal=2000 at 10%/year
        vm.warp(block.timestamp + 365 days);
        w.collectPremium();

        uint256 premRedeemed = w.totalPremiumRedeemed();
        assertGt(premRedeemed, 180 ether, "At least 180 ether premium after 1 year");
        assertLt(premRedeemed, 220 ether, "At most 220 ether premium after 1 year");

        // user1 exits at NO loss — receives ~900 (half of remaining 1800 post-premium position)
        uint256 shares1 = w.balanceOf(user1);
        vm.prank(user1);
        w.redeem(shares1, user1, user1);

        // After user1 exits with half the principal, totalPremiumRedeemed must halve
        uint256 premAfter = w.totalPremiumRedeemed();
        assertApproxEqAbs(
            premAfter, premRedeemed / 2, 5 ether, "totalPremiumRedeemed must halve when half the principal exits"
        );

        // Now apply a 20% loss — only user2 remains
        morphoVault.setLoss(20);

        // user2 exits:
        //   insuredBasis = 1000 * (1000 − ~100) / 1000 ≈ 900  (correct with fix)
        //   insuredBasis = 1000 * (1000 − ~200) / 1000 ≈ 800  (wrong without fix)
        //   assetsReceived ≈ 720 (900 remaining × 80%)
        //   shortfall ≈ 180, insurance ≈ 180 (< maxInsurance=200, deductible=0)
        //   total ≈ 900
        uint256 before2 = asset.balanceOf(user2);
        uint256 shares2 = w.balanceOf(user2);
        vm.prank(user2);
        w.redeem(shares2, user2, user2);
        uint256 received2 = asset.balanceOf(user2) - before2;

        assertApproxEqAbs(received2, 900 ether, 5 ether, "user2 must receive correct insurance via fair insuredBasis");
        assertGt(received2, 850 ether, "user2 must NOT suffer from skewed premium ratio after user1 exited");
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
