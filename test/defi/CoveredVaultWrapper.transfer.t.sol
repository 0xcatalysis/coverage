// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";

import {MockERC20} from "./mocks/Mocks.sol";
import {ControllableVault} from "./mocks/ControllableVault.sol";
import {RealCoverageSetup} from "./helpers/RealCoverageSetup.sol";

/// @title CoveredVaultWrapperTransferTests
/// @notice Snapshot-based transfer tests for CoveredVaultWrapper.
///         Each test compares two execution paths from an identical state:
///         Path A (no transfer) vs Path B (with transfer).
///         Verifies that share transfers cannot inflate insurance payouts.
contract CoveredVaultWrapperTransferTests is RealCoverageSetup {
    CoveredVaultWrapper wrapper;
    ControllableVault morphoVault;
    MockERC20 asset;

    address curator = address(0xCCCC);
    address premiumRecipientAddr = address(0xFEED);

    uint96 POLICY_ID;
    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%
    uint16 constant DEDUCTIBLE_BPS = 100; // 1%
    uint256 constant FIFTY_PCT_ANNUAL_RATE = 15_854_895_991; // ~50%/year WAD-scaled per second

    address user1 = address(0x1111);
    address user2 = address(0x2222);

    function setUp() public {
        asset = new MockERC20();
        morphoVault = new ControllableVault(address(asset));

        _deployRealCoverage(curator, curator);

        vm.prank(curator);
        policyManager.setSupportedPayoutToken(address(asset), true);
    }

    function _simulateProfit(uint256 percent) internal {
        uint256 extra = morphoVault.totalAssets() * percent / 100;
        asset.mint(address(morphoVault), extra);
    }

    function _simulateLoss(uint256 percent) internal {
        uint256 loss = morphoVault.totalAssets() * percent / 100;
        morphoVault.simulateLoss(loss);
    }

    function _deployWrapper(uint256 coverageLimit) internal {
        wrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Transfer Test Vault",
            "ttVault"
        );

        POLICY_ID = _createAndBindPolicy(
            address(wrapper),
            address(wrapper),
            address(asset),
            coverageLimit,
            coverageLimit,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(wrapper)
        );
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(wrapper), type(uint256).max);
    }

    function _redeemAll(address user) internal returns (uint256 received) {
        uint256 shares = wrapper.balanceOf(user);
        if (shares == 0) return 0;
        uint256 bal = asset.balanceOf(user);
        vm.prank(user);
        wrapper.redeem(shares, user, user);
        return asset.balanceOf(user) - bal;
    }

    /*//////////////////////////////////////////////////////////////
        1: PREMIUM + LOSS — DIFFERENT ENTRY PRICES, TRANSFER DIRECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Price up, early depositor (User1) transfers half shares to late depositor (User2).
    ///         User1 enters at 1.0, User2 enters at 1.5, premium 50%/yr for 90 days, 20% loss.
    function test_snapshot_priceUp_earlyDepositorTransfers() public {
        _deployWrapper(type(uint128).max);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        _simulateProfit(50);
        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        uint256 snap = vm.snapshotState();

        // ════════════════════════════════════════════
        // Path A: NO transfer
        // ════════════════════════════════════════════
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 noTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(20);

        uint256 noTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 noTransfer_r1 = _redeemAll(user1);
        uint256 noTransfer_r2 = _redeemAll(user2);
        uint256 noTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - noTransferInsBefore;
        uint256 noTransferTotal = noTransfer_r1 + noTransfer_r2;

        // ════════════════════════════════════════════
        // Path B: User1 transfers half shares to User2
        // ════════════════════════════════════════════
        vm.revertToState(snap);

        uint256 halfShares = wrapper.balanceOf(user1) / 2;
        vm.prank(user1);
        wrapper.transfer(user2, halfShares);

        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 withTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(20);

        uint256 withTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 withTransfer_r1 = _redeemAll(user1);
        uint256 withTransfer_r2 = _redeemAll(user2);
        uint256 withTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - withTransferInsBefore;
        uint256 withTransferTotal = withTransfer_r1 + withTransfer_r2;

        // ════════════════════════════════════════════
        // Compare
        // ════════════════════════════════════════════
        assertEq(withTransferTPR, noTransferTPR, "TPR identical: transfer does not affect premium");

        assertApproxEqAbs(noTransfer_r1, 1_081_643_835_623_024_640_000, 2, "No transfer: User1 received");
        assertApproxEqAbs(noTransfer_r2, 807_890_410_963_974_176_000, 2, "No transfer: User2 received");
        assertApproxEqAbs(noTransferIns, 86_794_520_548_624_416_000, 2, "No transfer: total insurance");

        assertApproxEqAbs(withTransfer_r1, 540_821_917_811_512_319_999, 2, "With transfer: User1 received");
        assertApproxEqAbs(withTransfer_r2, 1_314_536_986_311_634_860_801, 2, "With transfer: User2 received");
        assertApproxEqAbs(withTransferIns, 52_619_178_084_772_780_800, 2, "With transfer: total insurance");

        assertApproxEqAbs(
            noTransferIns - withTransferIns, 34_175_342_463_851_635_200, 2, "Transfer reduced insurance by ~34.2 ether"
        );

        assertApproxEqAbs(noTransferTotal, 1_889_534_246_586_998_816_000, 2, "No transfer: total payout");
        assertApproxEqAbs(withTransferTotal, 1_855_358_904_123_147_180_800, 2, "With transfer: total payout");
    }

    /// @notice Price up, late depositor (User2) transfers half shares to early depositor (User1).
    ///         User1 enters at 1.0, User2 enters at 1.5, premium 50%/yr for 90 days, 20% loss.
    function test_snapshot_priceUp_lateDepositorTransfers() public {
        _deployWrapper(type(uint128).max);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        _simulateProfit(50);
        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        uint256 snap = vm.snapshotState();

        // ════════════════════════════════════════════
        // Path A: NO transfer
        // ════════════════════════════════════════════
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 noTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(20);

        uint256 noTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 noTransfer_r1 = _redeemAll(user1);
        uint256 noTransfer_r2 = _redeemAll(user2);
        uint256 noTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - noTransferInsBefore;
        uint256 noTransferTotal = noTransfer_r1 + noTransfer_r2;

        // ════════════════════════════════════════════
        // Path B: User2 transfers half shares to User1
        // ════════════════════════════════════════════
        vm.revertToState(snap);

        uint256 halfShares = wrapper.balanceOf(user2) / 2;
        vm.prank(user2);
        wrapper.transfer(user1, halfShares);

        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 withTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(20);

        uint256 withTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 withTransfer_r1 = _redeemAll(user1);
        uint256 withTransfer_r2 = _redeemAll(user2);
        uint256 withTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - withTransferInsBefore;
        uint256 withTransferTotal = withTransfer_r1 + withTransfer_r2;

        // ════════════════════════════════════════════
        // Compare
        // ════════════════════════════════════════════
        assertEq(withTransferTPR, noTransferTPR, "TPR identical: transfer does not affect premium");

        assertApproxEqAbs(noTransfer_r1, 1_081_643_835_623_024_640_000, 2, "No transfer: User1 received");
        assertApproxEqAbs(noTransfer_r2, 807_890_410_963_974_176_000, 2, "No transfer: User2 received");
        assertApproxEqAbs(noTransferIns, 86_794_520_548_624_416_000, 2, "No transfer: total insurance");

        assertApproxEqAbs(withTransfer_r1, 1_442_191_780_830_699_520_000, 2, "With transfer: User1 received");
        assertApproxEqAbs(withTransfer_r2, 403_945_205_481_987_088_000, 2, "With transfer: User2 received");
        assertApproxEqAbs(withTransferIns, 43_397_260_274_312_208_000, 2, "With transfer: total insurance");

        assertApproxEqAbs(
            noTransferIns - withTransferIns, 43_397_260_274_312_208_000, 2, "Transfer reduced insurance by ~43.4 ether"
        );

        assertApproxEqAbs(noTransferTotal, 1_889_534_246_586_998_816_000, 2, "No transfer: total payout");
        assertApproxEqAbs(withTransferTotal, 1_846_136_986_312_686_608_000, 2, "With transfer: total payout");
    }

    /// @notice Price down (premium), early depositor (User1) transfers half shares to User2.
    ///         User1 enters at 1.0, premium drops price, User2 enters at ~0.877.
    ///         Then more premium + 20% loss.
    function test_snapshot_priceDown_earlyDepositorTransfers() public {
        _deployWrapper(type(uint128).max);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        // Premium drops price: 50%/yr, 90 days on 1000 principal
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium(); // price now ~0.877

        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        uint256 snap = vm.snapshotState();

        // ════════════════════════════════════════════
        // Path A: NO transfer
        // ════════════════════════════════════════════
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 noTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(20);

        uint256 noTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 noTransfer_r1 = _redeemAll(user1);
        uint256 noTransfer_r2 = _redeemAll(user2);
        uint256 noTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - noTransferInsBefore;
        uint256 noTransferTotal = noTransfer_r1 + noTransfer_r2;

        // ════════════════════════════════════════════
        // Path B: User1 transfers half shares to User2
        // ════════════════════════════════════════════
        vm.revertToState(snap);

        uint256 halfShares = wrapper.balanceOf(user1) / 2;
        vm.prank(user1);
        wrapper.transfer(user2, halfShares);

        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 withTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(20);

        uint256 withTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 withTransfer_r1 = _redeemAll(user1);
        uint256 withTransfer_r2 = _redeemAll(user2);
        uint256 withTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - withTransferInsBefore;
        uint256 withTransferTotal = withTransfer_r1 + withTransfer_r2;

        // ════════════════════════════════════════════
        // Compare
        // ════════════════════════════════════════════
        assertEq(withTransferTPR, noTransferTPR, "TPR identical: transfer does not affect premium");

        assertApproxEqAbs(noTransfer_r1, 689_910_858_925_359_732_060, 2, "No transfer: User1 received");
        assertApproxEqAbs(noTransfer_r2, 775_582_291_778_075_115_940, 2, "No transfer: User2 received");
        assertApproxEqAbs(noTransferIns, 161_383_561_645_873_248_000, 2, "No transfer: total insurance");

        assertApproxEqAbs(withTransfer_r1, 344_955_429_462_679_866_029, 2, "With transfer: User1 received");
        assertApproxEqAbs(withTransfer_r2, 1_120_537_721_240_754_981_971, 2, "With transfer: User2 received");
        assertApproxEqAbs(withTransferIns, 161_383_561_645_873_248_000, 2, "With transfer: total insurance");

        // Transfer has ZERO effect on insurance in price-down scenario — both users are underwater
        assertEq(withTransferIns, noTransferIns, "Transfer does not change insurance when price is down");

        assertApproxEqAbs(noTransferTotal, 1_465_493_150_703_434_848_000, 2, "No transfer: total payout");
        assertApproxEqAbs(withTransferTotal, 1_465_493_150_703_434_848_000, 2, "With transfer: total payout");
    }

    /// @notice Price down (premium), late depositor (User2) transfers half shares to User1.
    ///         User1 enters at 1.0, premium drops price, User2 enters at ~0.877.
    ///         Then more premium + 20% loss.
    function test_snapshot_priceDown_lateDepositorTransfers() public {
        _deployWrapper(type(uint128).max);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        // Premium drops price
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        uint256 snap = vm.snapshotState();

        // ════════════════════════════════════════════
        // Path A: NO transfer
        // ════════════════════════════════════════════
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 noTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(20);

        uint256 noTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 noTransfer_r1 = _redeemAll(user1);
        uint256 noTransfer_r2 = _redeemAll(user2);
        uint256 noTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - noTransferInsBefore;
        uint256 noTransferTotal = noTransfer_r1 + noTransfer_r2;

        // ════════════════════════════════════════════
        // Path B: User2 transfers half shares to User1
        // ════════════════════════════════════════════
        vm.revertToState(snap);

        uint256 halfShares = wrapper.balanceOf(user2) / 2;
        vm.prank(user2);
        wrapper.transfer(user1, halfShares);

        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 withTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(20);

        uint256 withTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 withTransfer_r1 = _redeemAll(user1);
        uint256 withTransfer_r2 = _redeemAll(user2);
        uint256 withTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - withTransferInsBefore;
        uint256 withTransferTotal = withTransfer_r1 + withTransfer_r2;

        // ════════════════════════════════════════════
        // Compare
        // ════════════════════════════════════════════
        assertEq(withTransferTPR, noTransferTPR, "TPR identical: transfer does not affect premium");

        assertApproxEqAbs(noTransfer_r1, 689_910_858_925_359_732_060, 2, "No transfer: User1 received");
        assertApproxEqAbs(noTransfer_r2, 775_582_291_778_075_115_940, 2, "No transfer: User2 received");
        assertApproxEqAbs(noTransferIns, 161_383_561_645_873_248_000, 2, "No transfer: total insurance");

        assertApproxEqAbs(withTransfer_r1, 1_077_702_004_814_397_290_028, 2, "With transfer: User1 received");
        assertApproxEqAbs(withTransfer_r2, 387_791_145_889_037_557_971, 2, "With transfer: User2 received");
        assertApproxEqAbs(withTransferIns, 161_383_561_645_873_247_999, 2, "With transfer: total insurance");

        // Transfer has near-ZERO effect on insurance in price-down scenario (1 wei rounding)
        assertApproxEqAbs(withTransferIns, noTransferIns, 1, "Transfer does not change insurance when price is down");

        assertApproxEqAbs(noTransferTotal, 1_465_493_150_703_434_848_000, 2, "No transfer: total payout");
        assertApproxEqAbs(withTransferTotal, 1_465_493_150_703_434_847_999, 2, "With transfer: total payout");
    }

    /*//////////////////////////////////////////////////////////////
        2: PROFIT AFTER TRANSFER (NO LOSS) — NO PHANTOM INSURANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice User1 enters at 1.0, User2 enters at 1.0, User1 transfers half to User2.
    ///         Vault profits 50%, no loss. Transfer should not create phantom insurance.
    function test_snapshot_profitOnly_noPhantomInsurance() public {
        _deployWrapper(type(uint128).max);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);
        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        uint256 snap = vm.snapshotState();

        // ════════════════════════════════════════════
        // Path A: NO transfer → profit → redeem
        // ════════════════════════════════════════════
        _simulateProfit(50);

        uint256 noTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 noTransfer_r1 = _redeemAll(user1);
        uint256 noTransfer_r2 = _redeemAll(user2);
        uint256 noTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - noTransferInsBefore;

        // ════════════════════════════════════════════
        // Path B: User1 transfers half shares to User2 → profit → redeem
        // ════════════════════════════════════════════
        vm.revertToState(snap);

        uint256 halfShares = wrapper.balanceOf(user1) / 2;
        vm.prank(user1);
        wrapper.transfer(user2, halfShares);

        _simulateProfit(50);

        uint256 withTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 withTransfer_r1 = _redeemAll(user1);
        uint256 withTransfer_r2 = _redeemAll(user2);
        uint256 withTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - withTransferInsBefore;

        // ════════════════════════════════════════════
        // Compare
        // ════════════════════════════════════════════
        // No insurance in either path — pure profit, no shortfall
        assertEq(noTransferIns, 0, "No transfer: zero insurance (profit only)");
        assertEq(withTransferIns, 0, "With transfer: zero insurance (no phantom claims)");

        assertApproxEqAbs(noTransfer_r1, 1500 ether, 2, "No transfer: User1 received (1000 + 50% profit)");
        assertApproxEqAbs(noTransfer_r2, 1500 ether, 2, "No transfer: User2 received (1000 + 50% profit)");
        assertApproxEqAbs(withTransfer_r1, 750 ether, 2, "With transfer: User1 (half shares left)");
        assertApproxEqAbs(withTransfer_r2, 2250 ether, 2, "With transfer: User2 (own + received shares)");

        // Total payout identical — transfer only redistributes, no value created or destroyed
        assertApproxEqAbs(
            noTransfer_r1 + noTransfer_r2,
            withTransfer_r1 + withTransfer_r2,
            2,
            "Total payout identical with and without transfer"
        );
    }

    /*//////////////////////////////////////////////////////////////
        3: LOSS WITHOUT PREMIUM — ISOLATE PREMIUM INTERACTION
    //////////////////////////////////////////////////////////////*/

    /// @notice User1 enters at 1.0, profit 50%, User2 enters at 1.5. No premium, 20% loss.
    ///         Isolates the transfer effect on insurance without premium complicating it.
    function test_snapshot_lossOnly_noPremium() public {
        _deployWrapper(type(uint128).max);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        _simulateProfit(50);
        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        uint256 snap = vm.snapshotState();

        // ════════════════════════════════════════════
        // Path A: NO transfer → loss → redeem
        // ════════════════════════════════════════════
        _simulateLoss(20);

        uint256 noTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 noTransfer_r1 = _redeemAll(user1);
        uint256 noTransfer_r2 = _redeemAll(user2);
        uint256 noTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - noTransferInsBefore;

        // ════════════════════════════════════════════
        // Path B: User1 transfers half to User2 → loss → redeem
        // ════════════════════════════════════════════
        vm.revertToState(snap);

        uint256 halfShares = wrapper.balanceOf(user1) / 2;
        vm.prank(user1);
        wrapper.transfer(user2, halfShares);

        _simulateLoss(20);

        uint256 withTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 withTransfer_r1 = _redeemAll(user1);
        uint256 withTransfer_r2 = _redeemAll(user2);
        uint256 withTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - withTransferInsBefore;

        // ════════════════════════════════════════════
        // Compare
        // ════════════════════════════════════════════

        // Without premium, insurance is nearly identical — transfer barely affects shortfall
        assertApproxEqAbs(
            noTransfer_r1, 1_199_999_999_999_999_999_998, 2, "No transfer: User1 (entered at 1.0, has profit buffer)"
        );
        assertApproxEqAbs(noTransfer_r2, 899 ether, 2, "No transfer: User2 (entered at 1.5, shortfall)");
        assertApproxEqAbs(noTransferIns, 99 ether, 2, "No transfer: total insurance");

        assertApproxEqAbs(withTransfer_r1, 599_999_999_999_999_999_997, 3, "With transfer: User1 (half shares)");
        assertApproxEqAbs(withTransfer_r2, 1499 ether, 2, "With transfer: User2 (own + received shares)");
        assertApproxEqAbs(withTransferIns, 98_999_999_999_999_999_999, 2, "With transfer: total insurance");

        // Insurance nearly identical (1 wei rounding) — without premium, no TPR distortion
        assertApproxEqAbs(withTransferIns, noTransferIns, 1, "Insurance unchanged without premium");

        // Total payout identical
        assertApproxEqAbs(noTransfer_r1 + noTransfer_r2, withTransfer_r1 + withTransfer_r2, 2, "Total payout identical");
    }

    /*//////////////////////////////////////////////////////////////
        4: LARGER LOSS (40%) — VERIFY EFFECT SCALES
    //////////////////////////////////////////////////////////////*/

    /// @notice Same as test 1A but with 40% loss instead of 20%.
    ///         Shows insurance reduction from transfer scales with loss severity.
    function test_snapshot_priceUp_largerLoss() public {
        _deployWrapper(type(uint128).max);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        _simulateProfit(50);
        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        uint256 snap = vm.snapshotState();

        // ════════════════════════════════════════════
        // Path A: NO transfer → premium → 40% loss → redeem
        // ════════════════════════════════════════════
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 noTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(40);

        uint256 noTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 noTransfer_r1 = _redeemAll(user1);
        uint256 noTransfer_r2 = _redeemAll(user2);
        uint256 noTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - noTransferInsBefore;
        uint256 noTransferTotal = noTransfer_r1 + noTransfer_r2;

        // ════════════════════════════════════════════
        // Path B: User1 transfers half to User2 → premium → 40% loss → redeem
        // ════════════════════════════════════════════
        vm.revertToState(snap);

        uint256 halfShares = wrapper.balanceOf(user1) / 2;
        vm.prank(user1);
        wrapper.transfer(user2, halfShares);

        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 90 days);
        wrapper.collectPremium();

        uint256 withTransferTPR = wrapper.totalPremiumRedeemed();

        _simulateLoss(40);

        uint256 withTransferInsBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        uint256 withTransfer_r1 = _redeemAll(user1);
        uint256 withTransfer_r2 = _redeemAll(user2);
        uint256 withTransferIns = claimManager.policyClaim(POLICY_ID).totalPaidOut - withTransferInsBefore;
        uint256 withTransferTotal = withTransfer_r1 + withTransfer_r2;

        // ════════════════════════════════════════════
        // Compare
        // ════════════════════════════════════════════
        assertEq(withTransferTPR, noTransferTPR, "TPR identical: transfer does not affect premium");

        assertApproxEqAbs(noTransfer_r1, 876_057_534_253_416_844_800, 2, "No transfer: User1 received");
        assertApproxEqAbs(noTransfer_r2, 627_616_438_360_136_736_002, 2, "No transfer: User2 received");
        assertApproxEqAbs(noTransferIns, 151_619_178_084_772_780_800, 2, "No transfer: total insurance");

        assertApproxEqAbs(withTransfer_r1, 438_028_767_126_708_422_399, 2, "With transfer: User1 received");
        assertApproxEqAbs(withTransfer_r2, 1_076_630_136_993_083_184_003, 2, "With transfer: User2 received");
        assertApproxEqAbs(withTransferIns, 162_604_109_591_010_806_400, 2, "With transfer: total insurance");

        // At 40% loss, transfer INCREASED insurance by ~11 ether — deeper loss means User2's
        // blended principal crosses the maxCoverableLoss cap differently
        assertApproxEqAbs(
            withTransferIns - noTransferIns,
            10_984_931_506_238_025_600,
            2,
            "Transfer increased insurance by ~11 ether at 40% loss"
        );

        assertApproxEqAbs(noTransferTotal, 1_503_673_972_613_553_580_802, 2, "No transfer: total payout");
        assertApproxEqAbs(withTransferTotal, 1_514_658_904_119_791_606_402, 2, "With transfer: total payout");
    }
}
