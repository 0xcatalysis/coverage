// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
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
                        WITHDRAW TESTS -- NO LOSS
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
                        WITHDRAW TESTS -- WITH LOSS
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

        // 50% loss -- beyond maxCoverableLossBps of 10%
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
        vm.expectRevert(abi.encodeWithSignature("TransfersDisabled()"));
        wrapper.transfer(user2, shares);
    }

    function test_transfer_partialMigratesPrincipal() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 halfShares = wrapper.balanceOf(user1) / 2;

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("TransfersDisabled()"));
        wrapper.transfer(user2, halfShares);
    }

    function test_transfer_doesNotChangeTotalPrincipal() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("TransfersDisabled()"));
        wrapper.transfer(user2, shares);
    }

    function test_transfer_reverts() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 shares = wrapper.balanceOf(user1);

        // transfer() reverts
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSignature("TransfersDisabled()"));
        wrapper.transfer(user2, shares);

        // transferFrom() reverts
        vm.prank(user1);
        wrapper.approve(user2, shares);
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSignature("TransfersDisabled()"));
        wrapper.transferFrom(user1, user2, shares);
    }

    /*//////////////////////////////////////////////////////////////
                        PREMIUM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setPremiumRate_updatesRate() public {
        uint256 newRate = uint256(1e17) / 31_536_000;
        uint64 expectedExecuteAfter = uint64(block.timestamp + 2 days);
        vm.prank(curator);
        vm.expectEmit(false, false, false, true);
        emit IE.PremiumRateProposed(newRate, expectedExecuteAfter);
        wrapper.setPremiumRate(newRate);
        // Rate is not yet active (only proposed)
        assertEq(wrapper.premiumRatePerSecond(), 0, "Rate must not change until executed");
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

        _setPremiumRate(wrapper, rate, curator);

        vm.warp(block.timestamp + 365 days / 2);

        // Change rate again -- executePremiumRate must settle half-year accrual at old rate first (via _accruePremium)
        _setPremiumRate(wrapper, rate * 2, curator);

        // With premium-as-debt, accrual lands in totalPremiumLiability (not pendingPremium) until
        // users withdraw. Verify the liability grew by the right amount.
        // ~5% of 1000 ether accrued over half-year at 10% annual rate
        assertGt(wrapper.totalPremiumLiability(), 40 ether, "Should have accrued ~5% over half year");
        assertLt(wrapper.totalPremiumLiability(), 60 ether, "Should not exceed ~5% over half year");
        assertEq(wrapper.premiumRatePerSecond(), rate * 2);
    }

    function test_collectPremium_zeroRate_noTransfer() public {
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        uint256 recipientBefore = asset.balanceOf(premiumRecipientAddr);
        vm.warp(block.timestamp + 365 days);
        vm.prank(curator);
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
        _setPremiumRate(wrapperWithPremium, tenPctAnnualRate, curator);

        vm.prank(user1);
        asset.approve(address(wrapperWithPremium), type(uint256).max);
        vm.prank(user1);
        wrapperWithPremium.deposit(DEPOSIT_AMOUNT, user1);

        // Advance 1 year (stay 1 second before maturity to keep policy active -- L-11 exclusive boundary)
        vm.warp(block.timestamp + 365 days - 1);
        // collectPremium() calls _accruePremium(), recording liability. With premium-as-debt, no tokens
        // flow to the recipient until users withdraw -- verify the liability accumulated correctly instead.
        vm.prank(curator);
        wrapperWithPremium.collectPremium();

        // ~10% of 1000 ether = ~100 ether (WAD math floors so ~99.99...)
        assertGt(
            wrapperWithPremium.totalPremiumLiability(), 90 ether, "Should accrue >90 ether premium liability in 1 year"
        );
        assertLt(
            wrapperWithPremium.totalPremiumLiability(),
            105 ether,
            "Should accrue <105 ether premium liability in 1 year"
        );
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
        _setPremiumRate(wrapperWithPremium, tenPctAnnualRate, curator);

        vm.prank(user1);
        asset.approve(address(wrapperWithPremium), type(uint256).max);
        vm.prank(user1);
        wrapperWithPremium.deposit(DEPOSIT_AMOUNT, user1);

        // Without time passage, totalAssets = morphoValue
        uint256 ta0 = wrapperWithPremium.totalAssets();
        assertApproxEqAbs(ta0, DEPOSIT_AMOUNT, 1);

        // After 1 year (stay 1 second before maturity to keep policy active -- exclusive boundary)
        vm.warp(block.timestamp + 365 days - 1);
        uint256 ta1 = wrapperWithPremium.totalAssets();
        assertLt(ta1, ta0, "totalAssets decreases as premium accrues");
    }

    /*//////////////////////////////////////////////////////////////
                        POLICY BOUND TESTS
    //////////////////////////////////////////////////////////////*/

    function test_maxDeposit_zeroBeforeBound() public {
        // Deploy fresh wrapper -- policy not yet bound
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
        // wrapper is already bound in setUp -- depositCap = coverageLimit * BPS / maxCoverableLossBps
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

    function test_totalPremiumLiability_tracksAccrual() public {
        uint256 rate = uint256(1e17) / 31_536_000; // ~10% per year
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        assertEq(wrapper.totalPremiumLiability(), 0, "No premium before time passes");

        // Stay 1 second before maturity to keep policy active (L-11 exclusive boundary)
        vm.warp(block.timestamp + 365 days - 1);
        vm.prank(curator);
        wrapper.collectPremium();

        uint256 redeemed = wrapper.totalPremiumLiability();
        assertGt(redeemed, 90 ether, "totalPremiumLiability should exceed 90 ether after 1 year at 10%");
        assertLt(redeemed, 105 ether, "totalPremiumLiability should be under 105 ether after 1 year at 10%");
        assertEq(wrapper.pendingPremium(), 0, "pendingPremium is cleared after collectPremium");
    }

    /// @dev Regression: premium deductions must NOT trigger insurance claims.
    ///      Before the fix, any non-zero premium rate produced userPrincipalForWithdrawal > assetsReceived,
    ///      causing the vault to file spurious insurance claims against the coverage pool.
    function test_withdraw_premiumOnly_noInsuranceClaim() public {
        uint256 rate = uint256(1e17) / 31_536_000; // ~10% per year
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // 1 year passes -- ~10% of principal (≈100 ether) accrues as premium, no hack
        // Stay 1 second before maturity to keep policy active (L-11 exclusive boundary)
        vm.warp(block.timestamp + 365 days - 1);

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);
        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1BalanceBefore;

        // User paid ~100 ether in premium, receives ~900 ether back -- no insurance payout
        assertGt(received, 890 ether, "Should receive ~900 (principal minus premium)");
        assertLt(received, 910 ether, "Should not receive more than principal minus premium");

        // Key assertion: received is ~900, NOT ~999. The old buggy code filed an insurance
        // claim for the premium-induced gap and paid ~99 ether on top (≈999 total). If this
        // passes, no spurious claim was filed.
        assertLt(received, 950 ether, "Insurance must NOT have been paid for premium deductions");

        // Confirm premium was actually taken from the Morpho position during the redeem.
        // After the last user exits, totalPremiumLiability is zeroed by the pro-rata decrement
        // (correct: no principal remains to carry premium history). The accrued premium is
        // instead held in pendingPremium, waiting for collectPremium() to forward it.
        assertGt(wrapper.pendingPremium(), 90 ether, "Premium must be in pendingPremium after redeem");
    }

    /// @dev Premium reduces the insured basis; only losses BEYOND that basis trigger insurance.
    function test_withdraw_premiumPlusLoss_onlyLossInsured() public {
        uint256 rate = uint256(1e17) / 31_536_000; // ~10% per year
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // Advance half a year -- ~50 ether premium paid; morpho position → ~950
        vm.warp(block.timestamp + 365 days / 2);
        vm.prank(curator);
        wrapper.collectPremium();

        // Confirm premium was deducted BEFORE the loss event.
        // totalPremiumLiability is checked here (after collectPremium but before redeem)
        // because the pro-rata decrement in _withdraw() will zero it for the last exiting user.
        assertGt(wrapper.totalPremiumLiability(), 40 ether, "Premium must have been deducted before loss");

        // 10% hack loss on the remaining ~950 ether position → ~95 ether loss
        morphoVault.setLoss(10);

        uint256 user1BalanceBefore = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);
        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1BalanceBefore;

        // With premium-as-debt: gross Morpho = 1000 (not redeemed upfront), 10% loss → assetsReceived = 900.
        // uncappedPremium = 50; netAssetsReceived = 850; insuredBasis = 950; shortfall = 100;
        // maxInsurance = 95 (10% of 950); claimAmount = 94 (99% after deductible); total = 850 + 94 = 944.
        assertApproxEqAbs(received, 944 ether, 3 ether, "Should receive assets + insurance for the loss only");
    }

    /// @dev Regression: calculateShortfall() must return 0 when there is pending (unaccrued)
    ///      premium but no actual loss, even before collectPremium() is called.
    ///
    ///      Bug: netValue = morphoValue − accrued (full premium deducted) but
    ///           adjustedPrincipal = totalPrincipal − totalPremiumLiability (only settled premium).
    ///           With accrued=100 and totalPremiumLiability=0, netValue=900 vs adjustedPrincipal=1000
    ///           → phantom shortfall of 100 even though no loss occurred.
    function test_calculateShortfall_pendingAccrual_noLoss_returnsZero() public {
        uint256 rate = uint256(1e17) / 31_536_000; // 10%/year
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // 1 year: ~100 ether premium accrued but collectPremium() NOT called
        vm.warp(block.timestamp + 365 days);

        // No loss -- only pending premium. View must return 0.
        assertEq(wrapper.calculateShortfall(), 0, "Pending accrual must not appear as shortfall");
    }

    /// @dev Regression: userShortfall() must return 0 with pending premium and no loss.
    function test_userShortfall_pendingAccrual_noLoss_returnsZero() public {
        uint256 rate = uint256(1e17) / 31_536_000;
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        vm.warp(block.timestamp + 365 days);

        assertEq(wrapper.userShortfall(user1), 0, "Pending accrual must not appear as user shortfall");
    }

    function test_calculateShortfall_premiumOnly_returnsZero() public {
        uint256 rate = uint256(1e17) / 31_536_000;
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(curator);
        wrapper.collectPremium(); // settle; totalPremiumLiability updated, morpho position reduced

        // No hack -- only premium has reduced the Morpho position
        assertEq(wrapper.calculateShortfall(), 0, "Premium deductions must not appear as coverable shortfall");
    }

    function test_userShortfall_premiumOnly_returnsZero() public {
        uint256 rate = uint256(1e17) / 31_536_000;
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        vm.warp(block.timestamp + 365 days);
        vm.prank(curator);
        wrapper.collectPremium();

        assertEq(wrapper.userShortfall(user1), 0, "Premium deductions must not appear as user shortfall");
    }

    /// @dev Regression: calculateShortfall() must not overcount expected loss for late depositors.
    ///      Bug: totalPrincipal * cumulativeExpectedLossPerUnit / WAD ignores per-user userExpectedLossDebt,
    ///      so users who deposited after the accumulator increased were double-charged, lowering adjustedPrincipal
    ///      and underreporting the shortfall.
    ///      Fix: use totalExpectedLossLiability (mirrors totalPremiumLiability) which correctly subtracts debt.
    function test_calculateShortfall_lateDepositor_expectedLossNotOvercounted() public {
        // Use 5%/year expected loss rate (no premium to isolate the expected-loss path)
        // H-01 timelock: propose → warp 2 days → execute
        vm.prank(curator);
        wrapper.setUnderlyingExpectedLossBps(500); // 5%/year (propose)
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(curator);
        wrapper.executeUnderlyingExpectedLossBps(); // execute

        // user1 deposits at t=2d (EL rate now active)
        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1); // 1000 ether

        // Half a year passes -- ~25 ether expected loss accumulates
        vm.warp(block.timestamp + 365 days / 2);
        vm.prank(curator);
        wrapper.collectPremium(); // trigger _accruePremium to advance accumulator

        // user2 deposits at t=0.5y (after accumulator already increased)
        vm.prank(user2);
        asset.mint(user2, DEPOSIT_AMOUNT);
        vm.prank(user2);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(user2);
        wrapper.deposit(DEPOSIT_AMOUNT, user2); // another 1000 ether

        // Apply a hack loss so there is a non-zero shortfall
        morphoVault.setLoss(20);

        uint256 global = wrapper.calculateShortfall();
        uint256 user1Sf = wrapper.userShortfall(user1);
        uint256 user2Sf = wrapper.userShortfall(user2);

        // Global shortfall must equal sum of per-user shortfalls.
        // Before the fix, calculateShortfall() overcounted totalExpectedLoss by using
        // totalPrincipal * cumulativeExpectedLossPerUnit / WAD, which charged user2 for
        // the 0.5-year pre-deposit period they were not in the vault.
        assertApproxEqAbs(
            global, user1Sf + user2Sf, 5, "calculateShortfall must equal sum of per-user shortfalls with late depositor"
        );
        assertGt(global, 0, "There must be a non-zero shortfall after a real loss");

        // user2 entered after the expected-loss accumulator had already advanced; their
        // userExpectedLossDebt offsets the pre-deposit period, so their shortfall is strictly
        // larger than user1's (user1 has more expected-loss deduction from their insured basis).
        assertGt(user2Sf, user1Sf, "user2 (no pre-deposit EL) must have a larger shortfall than user1");
    }

    /// @dev Regression: calculateShortfall() must not underreport when settled premium is outstanding.
    ///      Bug: netValue was computed as morphoValue - accrued (omitting totalPremiumLiability).
    ///      Since no Morpho shares are redeemed during accrual, morphoValue includes settled premium.
    ///      Fix: netValue = morphoValue - totalPremiumLiability - accrued (== totalAssets()).
    ///      Without the fix, calculateShortfall() < userShortfall() when settled premium > 0.
    function test_calculateShortfall_settledPremium_matchesUserShortfall() public {
        uint256 rate = uint256(1e17) / 31_536_000; // 10%/year
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        // Let half a year pass and settle (creates non-zero totalPremiumLiability)
        vm.warp(block.timestamp + 365 days / 2);
        vm.prank(curator);
        wrapper.collectPremium();

        // Apply a real loss so there is a non-zero shortfall
        morphoVault.setLoss(20); // 20% hack loss on remaining position

        uint256 global = wrapper.calculateShortfall();
        uint256 perUser = wrapper.userShortfall(user1);

        // With a single user, global and per-user shortfall must match
        assertApproxEqAbs(global, perUser, 2, "calculateShortfall must match userShortfall with settled premium");
        assertGt(global, 0, "There must be a non-zero shortfall after a real loss");
    }

    /// @dev Regression: when a user exits, their pro-rata share of totalPremiumLiability must be
    ///      removed so the (totalPrincipal − totalPremiumLiability) / totalPrincipal ratio stays
    ///      stable for remaining users.
    ///
    ///      Bug: totalPrincipal decrements on each withdrawal but totalPremiumLiability never does.
    ///      With two equal users and totalPremiumLiability=200:
    ///        user1 exits → insuredBasis=900 (correct)
    ///        user2 exits → insuredBasis=800 instead of 900 (bug: full 200 hangs against 1000)
    ///
    ///      Fix: after user1 exits, totalPremiumLiability halves to 100.
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
        _setPremiumRate(w, rate, curator);

        vm.prank(user1);
        asset.approve(address(w), type(uint256).max);
        vm.prank(user1);
        w.deposit(1000 ether, user1);

        vm.prank(user2);
        asset.approve(address(w), type(uint256).max);
        vm.prank(user2);
        w.deposit(1000 ether, user2);

        // 1 year - 1s: ~200 ether premium accrues on totalPrincipal=2000 at 10%/year
        // Warp to 1 second before maturity to keep policy active (L-11: exclusive upper bound).
        vm.warp(block.timestamp + 365 days - 1);
        vm.prank(curator);
        w.collectPremium();

        uint256 premRedeemed = w.totalPremiumLiability();
        assertGt(premRedeemed, 180 ether, "At least 180 ether premium after 1 year");
        assertLt(premRedeemed, 220 ether, "At most 220 ether premium after 1 year");

        // user1 exits at NO loss -- receives ~900 (half of remaining 1800 post-premium position)
        uint256 shares1 = w.balanceOf(user1);
        vm.prank(user1);
        w.redeem(shares1, user1, user1);

        // Verify that totalPremiumLiability halved because user1's 100-ether debt was settled.
        uint256 liabilityAfter = w.totalPremiumLiability();
        assertApproxEqAbs(
            liabilityAfter, premRedeemed / 2, 5 ether, "totalPremiumLiability must halve when half the principal exits"
        );

        // Now apply a 20% loss -- only user2 remains
        morphoVault.setLoss(20);

        // user2 exits (premium-as-debt calculation):
        //   gross Morpho = 1000 (user1's 1000 redeemed, user2's 1000 remains → 20% loss → 800)
        //   uncappedPremium = 100; netAssetsReceived = 700
        //   insuredBasis = 900; shortfall = 200; maxInsurance = 180 (20% of 900); insurance = 180
        //   total = 700 + 180 = 880
        uint256 before2 = asset.balanceOf(user2);
        uint256 shares2 = w.balanceOf(user2);
        vm.prank(user2);
        w.redeem(shares2, user2, user2);
        uint256 received2 = asset.balanceOf(user2) - before2;

        assertApproxEqAbs(received2, 880 ether, 5 ether, "user2 must receive correct insurance via fair insuredBasis");
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

    function test_evaluate_noPendingClaim() public {
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
        vm.prank(address(claimManager));
        ISpec.EvaluationResult memory result = wrapper.evaluate(context);
        assertFalse(result.isPayable);
    }

    /*//////////////////////////////////////////////////////////////
                SET MAX COVERABLE LOSS BPS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setMaxCoverableLossBps_updatesValue() public {
        vm.prank(curator);
        wrapper.setMaxCoverableLossBps(2000);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(curator);
        wrapper.executeMaxCoverableLossBps();
        assertEq(wrapper.maxCoverableLossBps(), 2000);
    }

    function test_setMaxCoverableLossBps_revertsOnZero() public {
        vm.prank(curator);
        vm.expectRevert(IA.InvalidMaxCoverableLoss.selector);
        wrapper.setMaxCoverableLossBps(0);
    }

    function test_setMaxCoverableLossBps_revertsAboveBpsDenominator() public {
        vm.prank(curator);
        vm.expectRevert(IA.InvalidMaxCoverableLoss.selector);
        wrapper.setMaxCoverableLossBps(10_001);
    }

    function test_setMaxCoverableLossBps_revertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        wrapper.setMaxCoverableLossBps(2000);
    }

    function test_setMaxCoverableLossBps_emitsEvent() public {
        vm.prank(curator);
        uint64 expectedExecuteAfter = uint64(block.timestamp + 2 days);
        vm.expectEmit(true, false, false, true);
        emit IE.MaxCoverableLossBpsProposed(2000, expectedExecuteAfter);
        wrapper.setMaxCoverableLossBps(2000);
    }

    /// @dev Changing maxCoverableLossBps after policy binding must recalculate depositCap.
    ///      setUp binds with coverageLimit=10_000 ether and maxCoverableLossBps=1000 (10%)
    ///      → depositCap = 10_000 * 10_000 / 1000 = 100_000 ether.
    ///      After setMaxCoverableLossBps(2000) (20%):
    ///      → depositCap = 10_000 * 10_000 / 2000 = 50_000 ether.
    function test_setMaxCoverableLossBps_recalculatesDepositCapWhenBound() public {
        assertEq(wrapper.depositCap(), 100_000 ether, "Initial depositCap at 10%");

        vm.prank(curator);
        wrapper.setMaxCoverableLossBps(2000); // 20%
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(curator);
        wrapper.executeMaxCoverableLossBps();

        assertEq(wrapper.depositCap(), 50_000 ether, "depositCap halves when maxCoverableLossBps doubles");
    }

    /// @dev Before policy binding, depositCap stays 0; onPolicyBound will use the new bps.
    function test_setMaxCoverableLossBps_beforeBind_depositCapStaysZero() public {
        CoveredVaultWrapper freshWrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Fresh4",
            "FR4"
        );
        assertEq(freshWrapper.depositCap(), 0, "depositCap 0 before binding");

        vm.prank(curator);
        freshWrapper.setMaxCoverableLossBps(500); // 5%

        assertEq(freshWrapper.depositCap(), 0, "depositCap stays 0 until policy bound");
    }

    /// @dev coverageLimit stored during onPolicyBound; correct depositCap uses the latest bps.
    function test_setMaxCoverableLossBps_storesCoverageLimitOnBind() public {
        assertEq(wrapper.coverageLimit(), 10_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    SET DEDUCTIBLE BPS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setDeductibleBps_updatesValue() public {
        vm.prank(curator);
        wrapper.setDeductibleBps(500);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(curator);
        wrapper.executeDeductibleBps();
        assertEq(wrapper.deductibleBps(), 500);
    }

    function test_setDeductibleBps_allowsZero() public {
        vm.prank(curator);
        wrapper.setDeductibleBps(0);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(curator);
        wrapper.executeDeductibleBps();
        assertEq(wrapper.deductibleBps(), 0);
    }

    function test_setDeductibleBps_revertsAt10000() public {
        vm.prank(curator);
        vm.expectRevert(IA.InvalidParameters.selector);
        wrapper.setDeductibleBps(10_000);
    }

    function test_setDeductibleBps_revertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        wrapper.setDeductibleBps(200);
    }

    function test_setDeductibleBps_emitsEvent() public {
        vm.prank(curator);
        uint64 expectedExecuteAfter = uint64(block.timestamp + 2 days);
        vm.expectEmit(true, false, false, true);
        emit IE.DeductibleBpsProposed(200, expectedExecuteAfter);
        wrapper.setDeductibleBps(200);
    }

    /// @dev Regression: deductible must apply to the CAPPED shortfall, not to the cap itself.
    ///
    ///      Bug: write path computed effectiveInsurance = maxInsurance × (1 − deductible), then
    ///      claimAmount = min(shortfall, effectiveInsurance). When shortfall < effectiveInsurance the
    ///      deductible was never applied and the user received the full shortfall -- no deductible at all.
    ///
    ///      Fix: cap the raw shortfall first, then apply the deductible to the capped amount,
    ///      matching calculateShortfall() / userShortfall().
    ///
    ///      Setup: principal=1000, maxCoverable=20% (max=200), deductible=50%, 5% loss.
    ///        shortfall = 50, maxInsurance = 200
    ///        Bug:  effectiveInsurance = 200×50% = 100; claimAmount = min(50,100) = 50  (no deductible!)
    ///        Fix:  capped = min(50, 200) = 50; claimAmount = 50×50% = 25
    function test_deductible_appliedToCappedShortfall_notToCap() public {
        CoveredVaultWrapper w = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            2000, // 20% max coverable loss
            5000, // 50% deductible
            premiumRecipientAddr,
            curator,
            "DeductibleTest",
            "DT"
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

        vm.prank(user1);
        asset.approve(address(w), type(uint256).max);
        vm.prank(user1);
        w.deposit(1000 ether, user1);

        morphoVault.setLoss(5); // 5% loss → assetsReceived≈950, shortfall=50

        uint256 before = asset.balanceOf(user1);
        uint256 shares = w.balanceOf(user1);
        vm.prank(user1);
        w.redeem(shares, user1, user1);
        uint256 received = asset.balanceOf(user1) - before;

        // Correct: 950 + 25 = 975.  Bug would give: 950 + 50 = 1000 (deductible skipped).
        assertApproxEqAbs(received, 975 ether, 1 ether, "Deductible must apply to the actual shortfall");
        assertLt(received, 990 ether, "Full shortfall must NOT be paid when deductible > 0");
    }

    /// @dev Raising deductible reduces effective insurance payout proportionally.
    ///      10% loss → shortfall=100, maxInsurance=100; with 50% deductible: payout=50.
    function test_setDeductibleBps_affectsInsurancePayout() public {
        vm.prank(curator);
        wrapper.setDeductibleBps(5000); // 50% deductible -- propose
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(curator);
        wrapper.executeDeductibleBps(); // execute after delay

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);
        morphoVault.setLoss(10);

        uint256 before = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);
        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);
        uint256 received = asset.balanceOf(user1) - before;

        // assetsReceived=900, shortfall=100, maxInsurance=100, effective=50 (50% deductible)
        assertApproxEqAbs(received, 950 ether, 1 ether, "50% deductible halves the insurance payout");
    }

    /*//////////////////////////////////////////////////////////////
                    SET PREMIUM RECIPIENT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_setPremiumRecipient_updatesRecipient() public {
        address newRecipient = address(0xBEEF);
        vm.prank(curator);
        wrapper.setPremiumRecipient(newRecipient);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(curator);
        wrapper.executePremiumRecipient();
        assertEq(wrapper.premiumRecipient(), newRecipient);
    }

    function test_setPremiumRecipient_revertsOnZeroAddress() public {
        vm.prank(curator);
        vm.expectRevert(IA.ZeroAddress.selector);
        wrapper.setPremiumRecipient(address(0));
    }

    function test_setPremiumRecipient_revertsIfNotOwner() public {
        vm.prank(user1);
        vm.expectRevert();
        wrapper.setPremiumRecipient(address(0xBEEF));
    }

    function test_setPremiumRecipient_emitsEvent() public {
        address newRecipient = address(0xBEEF);
        vm.prank(curator);
        vm.expectEmit(true, false, false, false);
        emit IE.PremiumRecipientProposed(newRecipient, 0);
        wrapper.setPremiumRecipient(newRecipient);
    }

    /// @dev EF-2: setPremiumRecipient() must NOT transfer funds -- it only updates the storage slot.
    ///      If the old recipient is on a token blocklist, the old flush would revert and prevent
    ///      the owner from ever switching. The owner calls collectPremium() separately if needed.
    function test_setPremiumRecipient_noFlushOnSwitch() public {
        uint256 rate = uint256(1e17) / 31_536_000; // 10%/year
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1);

        vm.warp(block.timestamp + 365 days);
        // Settle premium into pendingPremium so there is a non-zero balance before the switch
        vm.prank(curator);
        wrapper.collectPremium();
        uint256 pendingAfterCollect = wrapper.pendingPremium();
        assertEq(pendingAfterCollect, 0, "pendingPremium zeroed by collectPremium");

        // Accrue more premium that has NOT been collected yet
        vm.warp(block.timestamp + 30 days);

        uint256 oldRecipientBefore = asset.balanceOf(premiumRecipientAddr);
        address newRecipient = address(0xBEEF);
        uint256 newRecipientBefore = asset.balanceOf(newRecipient);
        uint256 pendingBefore = wrapper.pendingPremium(); // 0 -- not yet settled

        vm.prank(curator);
        wrapper.setPremiumRecipient(newRecipient);
        vm.warp(block.timestamp + 2 days + 1);
        vm.prank(curator);
        wrapper.executePremiumRecipient();

        // State: recipient updated, no transfer occurred, pendingPremium unchanged
        assertEq(wrapper.premiumRecipient(), newRecipient, "Recipient must be updated");
        assertEq(wrapper.pendingPremium(), pendingBefore, "pendingPremium must be unchanged by setPremiumRecipient");
        assertEq(
            asset.balanceOf(premiumRecipientAddr), oldRecipientBefore, "Old recipient must not receive funds on switch"
        );
        assertEq(asset.balanceOf(newRecipient), newRecipientBefore, "New recipient must not receive funds on switch");
    }

    /*//////////////////////////////////////////////////////////////
                    PREMIUM RATE CAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev M-01 fix: setPremiumRate must revert when the new rate exceeds ~50%/year
    function test_setPremiumRate_revertsAboveMaxRate() public {
        // MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991; one above must revert
        vm.prank(curator);
        vm.expectRevert(IA.InvalidParameters.selector);
        wrapper.setPremiumRate(15_854_895_992);
    }

    function test_setPremiumRate_acceptsMaxRate() public {
        _setPremiumRate(wrapper, 15_854_895_991, curator); // exactly at cap must succeed
        assertEq(wrapper.premiumRatePerSecond(), 15_854_895_991);
    }

    /// @dev Regression: setPremiumRate() must advance lastPremiumAccrualTime even when _accruePremium()
    ///      hits the dust path (accrued > 0 but rounds to 0 Morpho shares).
    ///
    ///      Without the fix, lastPremiumAccrualTime stays stale and newRate is charged retroactively
    ///      over the period when oldRate was active, overcharging by (newRate − oldRate) × oldElapsed.
    ///
    ///      Setup:
    ///        - Deposit 1 ether. Morpho share price inflated to 1.01 via setProfit(1).
    ///        - premiumRatePerSecond = 1 (1 wei/s). After 1 second: accrued = 1 wei.
    ///        - previewWithdraw(1 wei) = 1 * 1e18 / 1.01e18 = 0  → dust path, timestamp not advanced.
    ///        - setPremiumRate(MAX) is called. With fix: timestamp is forced to block.timestamp.
    ///        - After 100 more seconds at MAX rate, collectPremium collects ≈ MAX × 100 seconds of premium.
    ///          Without fix it would collect MAX × 101 seconds (retroactive 1-second overcharge).
    function test_setPremiumRate_advancesTimestamp_onDustPath() public {
        // Inflate Morpho share price so previewWithdraw(1 wei) == 0
        morphoVault.setProfit(1); // totalAssets = deposits × 101/100 → share price = 1.01

        _setPremiumRate(wrapper, 1, curator); // 1 wei/second: 1 ether × 1 × 1s / 1e18 = 1 wei (dust with profit=1%)

        vm.prank(user1);
        wrapper.deposit(1 ether, user1); // lastPremiumAccrualTime = t0

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1); // elapsed = 1s → accrued = 1 wei, morphoShares = 0 (dust path)

        // With the fix, executePremiumRate must force lastPremiumAccrualTime = block.timestamp
        // Propose the new rate
        uint256 maxRate = 15_854_895_991;
        vm.prank(curator);
        wrapper.setPremiumRate(maxRate);

        // Warp past the timelock and execute
        vm.warp(block.timestamp + 2 days);
        vm.prank(curator);
        wrapper.executePremiumRate();

        assertEq(
            wrapper.lastPremiumAccrualTime(),
            block.timestamp,
            "lastPremiumAccrualTime must equal block.timestamp after executePremiumRate, even via the dust path"
        );

        // Advance 100 more seconds at maxRate and collect
        uint256 U = 100;
        vm.warp(block.timestamp + U);

        // With premium-as-debt, tokens only reach the recipient on user withdrawal; check totalPremiumLiability
        // growth instead of recipient balance. The dust path is gone in the new system (no morpho-share rounding),
        // but the timestamp invariant (no retroactive overcharge) still applies.
        uint256 tprBefore = wrapper.totalPremiumLiability();
        vm.prank(curator);
        wrapper.collectPremium();
        uint256 accrualInPeriod = wrapper.totalPremiumLiability() - tprBefore;

        // Expected: 1 ether × maxRate × 100s / WAD (only 100 seconds at new rate, not 101)
        uint256 expected = uint256(1 ether) * maxRate * U / 1e18;
        // Bug would give: 1 ether × maxRate × (101+2days)s / WAD (retroactive overcharge)
        assertApproxEqAbs(
            accrualInPeriod,
            expected,
            100,
            "Premium must reflect only time elapsed since rate change, not retroactive period at old rate"
        );
    }

    /// @dev Regression: cumulativeExpectedLossPerUnit must not be double-counted when premium is
    ///      capped to zero by maxNewLiability (deep-loss state). Before the fix, the early-return
    ///      on line `if (accrued == 0) return` skipped the lastPremiumAccrualTime update, so the
    ///      next call to _accruePremium counted the same elapsed seconds again for expected loss.
    function test_accruePremium_cappedPremium_noDoubleCountExpectedLoss() public {
        // Deploy a fresh wrapper with 10% expected loss rate
        CoveredVaultWrapper w = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            1000,
            0,
            premiumRecipientAddr,
            curator,
            "ELTest",
            "ELT"
        );
        morphoVault.setCurator(address(w));
        _createAndBindPolicy(
            address(w),
            address(w),
            address(asset),
            type(uint128).max,
            type(uint128).max,
            uint32(block.timestamp),
            uint32(block.timestamp + 730 days),
            curator,
            address(w)
        );
        vm.prank(curator);
        w.setUnderlyingExpectedLossBps(1000); // 10%/year

        // Set premium rate to 50%/year so premium is very likely to be capped to 0 after a loss
        uint256 rate = uint256(5e17) / 31_536_000;
        _setPremiumRate(w, rate, curator);

        vm.prank(user1);
        asset.approve(address(w), type(uint256).max);
        vm.prank(user1);
        w.deposit(1000 ether, user1);

        // Simulate 100% loss -- morphoValue = 0, so maxNewLiability = 0, premium caps to 0
        morphoVault.setLoss(100);

        // Call accruePremium once -- advances cumulativeExpectedLossPerUnit for elapsed period
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 365 days);
        vm.prank(curator);
        w.collectPremium(); // triggers _accruePremium internally

        uint256 elAfterFirst = w.cumulativeExpectedLossPerUnit();

        // Call again immediately -- no time has passed, so expected loss must NOT change
        vm.prank(curator);
        w.collectPremium();
        assertEq(
            w.cumulativeExpectedLossPerUnit(),
            elAfterFirst,
            "cumulativeExpectedLossPerUnit must not increase on back-to-back calls with no elapsed time"
        );

        // Call again after another year -- expected loss should increase by exactly one more year
        vm.warp(block.timestamp + 365 days);
        vm.prank(curator);
        w.collectPremium();
        uint256 elAfterSecond = w.cumulativeExpectedLossPerUnit();

        // elAfterSecond should be ~2× elAfterFirst (two years at 10%/year)
        assertApproxEqAbs(
            elAfterSecond,
            2 * elAfterFirst,
            elAfterFirst / 100, // 1% tolerance
            "Expected loss accumulator must advance by exactly one year per year, even when premium is capped"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    MAX MINT / MINT TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev H-01 fix: maxMint must return 0 before policy is bound (mirrors maxDeposit)
    function test_maxMint_zeroBeforeBound() public {
        CoveredVaultWrapper freshWrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Fresh3",
            "FR3"
        );
        assertEq(freshWrapper.maxMint(user1), 0, "maxMint must be 0 before policy bound");
    }

    /// @dev H-01 fix: mint() must revert when totalPrincipal == depositCap (cap already reached).
    ///      Without the maxMint() override, OZ's mint() checks type(uint256).max and would
    ///      allow unlimited minting past the deposit cap.
    function test_mint_revertsWhenDepositCapReached() public {
        // Fill the entire deposit cap
        uint256 cap = wrapper.maxDeposit(user1); // = 100_000 ether in setUp
        asset.mint(user1, cap);
        vm.prank(user1);
        wrapper.deposit(cap, user1);

        // Any further mint must revert because maxMint(user1) == 0
        uint256 extraShares = 1;
        asset.mint(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert();
        wrapper.mint(extraShares, user1);
    }

    /*//////////////////////////////////////////////////////////////
                    INFLATION ATTACK PROTECTION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev EF-3: _decimalsOffset() == 6 makes inflation attacks economically infeasible.
    ///      An attacker who donates D assets after the first 1-wei deposit can only steal
    ///      floor(victim_deposit * 1 / (D + 1 + 10^6)) per unit donated.
    ///      With offset=6 the attacker must donate >10^6 × victim_deposit to gain 1 wei.
    function test_decimalsOffset_inflationProtection() public {
        // Attacker deposits 1 wei as the first depositor
        address attacker = address(0xA77AC);
        asset.mint(attacker, 1 ether + 1);
        vm.prank(attacker);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(attacker);
        wrapper.deposit(1, attacker); // 1 wei deposit

        // Attacker donates 1 ether directly to the Morpho vault to inflate share price
        vm.prank(attacker);
        asset.transfer(address(morphoVault), 1 ether);

        // Victim deposits 0.5 ether -- should receive shares > 0 despite donation
        uint256 victimDeposit = 0.5 ether;
        asset.mint(user1, victimDeposit);
        vm.prank(user1);
        asset.approve(address(wrapper), type(uint256).max);
        vm.prank(user1);
        wrapper.deposit(victimDeposit, user1);

        // With decimalsOffset=6, victim's shares must be > 0 (inflation attack defeated)
        assertGt(wrapper.balanceOf(user1), 0, "Victim must receive non-zero shares despite donation");

        // Attacker redeems -- gains must not exceed victim's deposit (no profit from inflation)
        uint256 attackerSharesBefore = wrapper.balanceOf(attacker);
        uint256 attackerAssetsBefore = asset.balanceOf(attacker);
        vm.prank(attacker);
        wrapper.redeem(attackerSharesBefore, attacker, attacker);
        uint256 attackerGain = asset.balanceOf(attacker) - attackerAssetsBefore;
        // Attacker deposited 1 wei and donated 1 ether; total cost = ~1 ether
        // They must not recover more than their total outlay (no theft of victim funds)
        assertLt(attackerGain, 1 ether + 1000, "Attacker must not profit from inflation attack");
    }

    /*//////////////////////////////////////////////////////////////
                    EF-4 CAP BASED ON INSURED BASIS TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev EF-4: When shortfall > insuredBasis × maxCoverableLoss but shortfall < principal × maxCoverableLoss,
    ///      the lower (insuredBasis-based) cap must apply -- not the raw-principal cap.
    ///
    ///      Setup: principal=1000, 40% premium paid → insuredBasis=600, 10% maxCoverable, 0% deductible.
    ///      30% loss on the remaining 600:
    ///        assetsReceived = 420, shortfall = 180
    ///        OLD cap: 1000 × 10% = 100 → payout = 100
    ///        NEW cap: 600 × 10% = 60  → payout = 60
    ///
    ///      The new cap is correct: coverage only applies to genuine hack losses on the insured basis,
    ///      not on principal that has already been consumed by premium.
    function test_EF4_maxInsurance_basedOnInsuredBasis() public {
        // Fresh wrapper: 10% max coverage, 0% deductible for clean assertions
        CoveredVaultWrapper w = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            1000, // 10% max coverage
            0, // 0% deductible
            premiumRecipientAddr,
            curator,
            "EF4Test",
            "EF4"
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

        // ~40%/year premium rate: 40e16 / 31536000
        uint256 rate = (uint256(4e17)) / 31_536_000;
        _setPremiumRate(w, rate, curator);

        vm.prank(user1);
        asset.approve(address(w), type(uint256).max);
        vm.prank(user1);
        w.deposit(1000 ether, user1);

        // 1 year - 1s: ~40% of 1000 = ~400 ether premium deducted; morpho position ≈ 600
        // Warp to 1 second before maturity to keep policy active (L-11: exclusive upper bound).
        vm.warp(block.timestamp + 365 days - 1);
        vm.prank(curator);
        w.collectPremium();

        uint256 premRedeemed = w.totalPremiumLiability();
        // insuredBasis = 1000 * (1000 - premRedeemed) / 1000 ≈ 600
        assertGt(premRedeemed, 350 ether, "Premium must be > 35% of principal");
        assertLt(premRedeemed, 450 ether, "Premium must be < 45% of principal");

        // 30% hack loss on remaining morpho position (~600 ether)
        morphoVault.setLoss(30);

        uint256 before = asset.balanceOf(user1);
        uint256 shares = w.balanceOf(user1);
        vm.prank(user1);
        w.redeem(shares, user1, user1);
        uint256 received = asset.balanceOf(user1) - before;

        // With premium-as-debt: gross Morpho = 1000 (not redeemed upfront), 30% loss → 700.
        // uncappedPremium = 400; netAssetsReceived = 300; insuredBasis = 600; shortfall = 300.
        // cap = 600 × 10% = 60 → payout = 60; total = 300 + 60 = 360.
        // (Old share-price system: morpho already at 600 post-premium, 30% loss → 420; total 420+60=480.)
        assertApproxEqAbs(received, 360 ether, 10 ether, "Payout must use insuredBasis cap, not raw principal cap");
        assertLt(received, 430 ether, "Must NOT pay out using the over-generous raw-principal cap");
    }

    /*//////////////////////////////////////////////////////////////
                    DEEP-LOSS PREMIUM CAP TESTS
    //////////////////////////////////////////////////////////////*/

    /// @dev When a catastrophic loss makes Morpho proceeds smaller than the accrued premium,
    ///      premiumForWithdrawal is capped at assetsReceived (line 273). The shortfall between
    ///      uncappedPremium and assetsReceived is effectively written off -- the premium recipient
    ///      does not collect premium that Morpho could not fund.
    ///
    ///      Setup:
    ///        - Deposit 1000, 10%/year premium, 1 year → uncappedPremium ≈ 100
    ///        - 95% loss → Morpho returns ≈ 50 (assetsReceived < uncappedPremium)
    ///
    ///      Expected:
    ///        - premiumForWithdrawal = 50 (capped at assetsReceived, not 100)
    ///        - netAssetsReceived = 0 (all Morpho proceeds absorbed by premium)
    ///        - insuredBasis = 1000 − 50 = 950 (uses premiumForWithdrawal, not uncappedPremium)
    ///          The 50 uncollected premium is effectively written off and does NOT reduce insuredBasis
    ///          (penalising the user twice for the same loss event would be incorrect).
    ///        - Insurance: shortfall = 950, maxInsurance = 95 (10%), claim ≈ 94.05 (99%)
    ///        - User receives ≈ 94.05 (insurance only, zero Morpho proceeds)
    ///        - pendingPremium = 50 (only what Morpho could fund; 50 written off)
    function test_withdraw_deepLoss_premiumCappedAtAssetsReceived() public {
        uint256 rate = uint256(1e17) / 31_536_000; // ~10%/year
        _setPremiumRate(wrapper, rate, curator);

        vm.prank(user1);
        wrapper.deposit(DEPOSIT_AMOUNT, user1); // 1000 ether

        // 1 year - 1s → ~100 ether premium accrues as liability (not redeemed from Morpho)
        // Warp to 1 second before maturity to keep policy active (L-11: exclusive upper bound).
        vm.warp(block.timestamp + 365 days - 1);

        // Settle the accumulator so totalPremiumLiability reflects the full year
        vm.prank(curator);
        wrapper.collectPremium();
        uint256 liabilityBeforeLoss = wrapper.totalPremiumLiability();
        assertGt(liabilityBeforeLoss, 90 ether, "Liability should be ~100 ether");
        assertLt(liabilityBeforeLoss, 105 ether, "Liability should be ~100 ether");

        // 95% catastrophic loss -- Morpho returns only ~50 ether on full redemption
        morphoVault.setLoss(95);

        uint256 user1Before = asset.balanceOf(user1);
        uint256 pendingBefore = wrapper.pendingPremium();
        uint256 shares = wrapper.balanceOf(user1);
        uint256 insuranceBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1Before;
        uint256 pendingAfter = wrapper.pendingPremium();
        uint256 insuranceAfter = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 premiumCollected = pendingAfter - pendingBefore;
        uint256 insurancePaid = insuranceAfter - insuranceBefore;

        // ── 1. Premium capped at assetsReceived (~50), not uncappedPremium (~100) ──
        assertApproxEqAbs(premiumCollected, 50 ether, 5 ether, "Premium must be capped at Morpho proceeds");
        assertLt(premiumCollected, liabilityBeforeLoss, "Premium collected < full liability (deep-loss write-off)");

        // ── 2. L-05 fix: totalPremiumLiability decremented by actually-collected amount only ──
        // premiumForWithdrawal = min(uncappedPremium~100, assetsReceived~50) = ~50.
        // Remaining liability = uncappedPremium - premiumForWithdrawal ≈ 50 (written-off, not entered into
        // pendingPremium).
        assertApproxEqAbs(
            wrapper.totalPremiumLiability(),
            liabilityBeforeLoss - premiumCollected,
            2 ether,
            "L-05 fix: liability decremented by collected amount only; written-off portion remains"
        );

        // ── 3. User receives only insurance (Morpho proceeds fully absorbed by premium) ──
        // insuredBasis = 1000 − 50 = 950 (premiumForWithdrawal, not uncapped 100); maxInsurance = 95 (10%); claim ≈
        // 94.05 (99%)
        assertApproxEqAbs(insurancePaid, 94.05 ether, 2 ether, "Insurance: 10% of 950 insuredBasis * 99%");
        assertApproxEqAbs(received, insurancePaid, 2 ether, "User receives insurance only, zero net Morpho proceeds");

        // ── 4. All principal and premium state is zeroed ──
        assertEq(wrapper.userPrincipal(user1), 0, "Principal cleared");
        assertEq(wrapper.totalPrincipal(), 0, "Total principal cleared");
    }
}
