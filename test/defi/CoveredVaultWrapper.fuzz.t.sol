// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {CoveredVaultStorage} from "../../src/defi/adapters/morpho/CoveredVaultStorage.sol";

import {MockERC20} from "./mocks/Mocks.sol";
import {ControllableVault} from "./mocks/ControllableVault.sol";
import {RealCoverageSetup} from "./helpers/RealCoverageSetup.sol";

/// @title CoveredVaultWrapperFuzzTest
/// @notice Fuzz tests for CoveredVaultWrapper: deposit invariants, premium accrual, and transfer behavior
contract CoveredVaultWrapperFuzzTest is RealCoverageSetup {
    CoveredVaultWrapper wrapper;
    ControllableVault morphoVault;
    MockERC20 asset;

    address curator = address(0xCCCC);
    address premiumRecipientAddr = address(0xFEED);

    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%
    uint16 constant DEDUCTIBLE_BPS = 100; // 1%

    function setUp() public {
        asset = new MockERC20();
        morphoVault = new ControllableVault(address(asset));

        _deployRealCoverage(curator, curator);

        vm.prank(curator);
        policyManager.setSupportedPayoutToken(address(asset), true);
    }

    function _deployWrapperWithCap(uint256 coverageLimit) internal returns (uint96 policyId) {
        wrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipientAddr,
            curator,
            "Fuzz Vault",
            "fzVault"
        );

        policyId = _createAndBindPolicy(
            address(wrapper),
            address(wrapper),
            address(asset),
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

    function _simulateProfit(uint256 percent) internal {
        uint256 extra = morphoVault.totalAssets() * percent / 100;
        asset.mint(address(morphoVault), extra);
    }

    function _simulateLoss(uint256 percent) internal {
        uint256 loss = morphoVault.totalAssets() * percent / 100;
        morphoVault.simulateLoss(loss);
    }

    /*//////////////////////////////////////////////////////////////
                     DEPOSIT INVARIANT FUZZ TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test verifying deposit invariants hold across multiple users
    ///         entering at different share prices (yield/loss between deposits).
    ///
    ///         Invariants checked after every deposit:
    ///           1. totalPrincipal <= depositCap
    ///           2. Σ userPrincipal[i] == totalPrincipal
    ///           3. Invariants 1 & 2 hold regardless of share price at entry
    ///
    ///         Additionally verifies that depositing beyond the cap reverts.
    function testFuzz_deposit_invariants(
        uint256 coverageLimit,
        uint256 deposit1,
        uint256 deposit2,
        uint256 deposit3,
        uint256 priceChangePct1,
        uint256 priceChangePct2,
        bool isLoss1,
        bool isLoss2
    )
        public
    {
        // ── Setup: deploy wrapper with fuzzed coverage limit ──
        coverageLimit = bound(coverageLimit, 100 ether, 100_000 ether);
        uint256 cap = (coverageLimit * 10_000) / uint256(MAX_COVERABLE_LOSS_BPS);

        _deployWrapperWithCap(coverageLimit);
        assertEq(wrapper.depositCap(), cap, "depositCap matches coverage math");

        // Bound deposits (each individually could fill the cap)
        deposit1 = bound(deposit1, 1 ether, cap);
        deposit2 = bound(deposit2, 1 ether, cap);
        deposit3 = bound(deposit3, 1 ether, cap);

        // Bound price changes -- losses capped at 90% to avoid zero-totalAssets edge
        priceChangePct1 = bound(priceChangePct1, 1, isLoss1 ? 90 : 200);
        priceChangePct2 = bound(priceChangePct2, 1, isLoss2 ? 90 : 200);

        address[3] memory users = [address(0x1111), address(0x2222), address(0x3333)];

        // ── User 1 deposits at initial price ──
        _mintAndApprove(users[0], deposit1);
        vm.prank(users[0]);
        wrapper.deposit(deposit1, users[0]);

        _assertInvariants(users, cap, "after user1 deposit");

        // ── Price change → user 2 enters at different share price ──
        if (isLoss1) _simulateLoss(priceChangePct1);
        else _simulateProfit(priceChangePct1);

        // ── User 2 deposits (bounded by remaining cap room) ──
        uint256 remaining2 = wrapper.maxDeposit(users[1]);
        if (remaining2 > 0) {
            uint256 actual2 = deposit2 > remaining2 ? remaining2 : deposit2;
            _mintAndApprove(users[1], actual2);
            vm.prank(users[1]);
            wrapper.deposit(actual2, users[1]);
        }

        _assertInvariants(users, cap, "after user2 deposit");

        // ── Another price change → user 3 enters at yet another share price ──
        if (isLoss2) _simulateLoss(priceChangePct2);
        else _simulateProfit(priceChangePct2);

        // ── User 3 deposits (bounded by remaining cap room) ──
        uint256 remaining3 = wrapper.maxDeposit(users[2]);
        if (remaining3 > 0) {
            uint256 actual3 = deposit3 > remaining3 ? remaining3 : deposit3;
            _mintAndApprove(users[2], actual3);
            vm.prank(users[2]);
            wrapper.deposit(actual3, users[2]);
        }

        _assertInvariants(users, cap, "after user3 deposit");

        // ── Cap enforcement: depositing beyond remaining capacity must revert ──
        uint256 remainingFinal = wrapper.maxDeposit(address(0x9999));
        if (remainingFinal < 1 ether) {
            address overflowUser = address(0x9999);
            uint256 overDeposit = remainingFinal + 1 ether;
            _mintAndApprove(overflowUser, overDeposit);
            vm.expectRevert();
            vm.prank(overflowUser);
            wrapper.deposit(overDeposit, overflowUser);
        }
    }

    function _assertInvariants(address[3] memory users, uint256 cap, string memory label) internal view {
        // Invariant 1: totalPrincipal never exceeds depositCap
        assertLe(wrapper.totalPrincipal(), cap, string.concat("totalPrincipal <= cap: ", label));

        // Invariant 2: sum of per-user principals == totalPrincipal
        uint256 sum = 0;
        for (uint256 i = 0; i < users.length; i++) {
            sum += wrapper.userPrincipal(users[i]);
        }
        assertEq(sum, wrapper.totalPrincipal(), string.concat("sum(principals) == totalPrincipal: ", label));
    }

    /*//////////////////////////////////////////////////////////////
            PREMIUM ACCRUAL ACROSS RATE CHANGES FUZZ TEST
    //////////////////////////////////////////////////////////////*/

    uint256 constant WAD = 1e18;
    /// @dev MAX_PREMIUM_RATE_PER_SECOND in the wrapper -- equals ~50%/year WAD-scaled
    uint256 constant FIFTY_PCT_ANNUAL_RATE = 15_854_895_991;

    /// @notice Fuzz test: a single user's total premium across multiple rate changes
    ///         should equal Σ(principal × rate_i × duration_i / WAD).
    ///
    ///         setPremiumRate() calls _accruePremium() to settle the previous period
    ///         before applying the new rate. This test verifies that no premium is lost
    ///         or double-counted across rate transitions.
    function testFuzz_premiumAccrual_correctTotalAcrossRateChanges(
        uint256 principal,
        uint256 rate1,
        uint256 rate2,
        uint256 rate3,
        uint256 duration1,
        uint256 duration2,
        uint256 duration3
    )
        public
    {
        _deployWrapperWithCap(type(uint128).max);

        principal = bound(principal, 100 ether, 10_000_000 ether);
        rate1 = bound(rate1, 0, FIFTY_PCT_ANNUAL_RATE);
        rate2 = bound(rate2, 0, FIFTY_PCT_ANNUAL_RATE);
        rate3 = bound(rate3, 0, FIFTY_PCT_ANNUAL_RATE);
        duration1 = bound(duration1, 1 days, 90 days);
        duration2 = bound(duration2, 1 days, 90 days);
        duration3 = bound(duration3, 1 days, 90 days);

        // Ensure total premium won't hit the morphoValue cap
        uint256 expectedTotal = _expectedPremium(principal, rate1, duration1)
            + _expectedPremium(principal, rate2, duration2) + _expectedPremium(principal, rate3, duration3);
        vm.assume(expectedTotal > 0 && expectedTotal < principal * 90 / 100);

        address user = address(0x1111);
        _mintAndApprove(user, principal);

        vm.prank(user);
        wrapper.deposit(principal, user);

        // ── Period 1 ──
        _setPremiumRate(wrapper, rate1, curator);
        vm.warp(block.timestamp + duration1);

        // ── Period 2 (executePremiumRate settles period 1) ──
        _setPremiumRate(wrapper, rate2, curator);
        vm.warp(block.timestamp + duration2);

        // ── Period 3 (executePremiumRate settles period 2) ──
        _setPremiumRate(wrapper, rate3, curator);
        vm.warp(block.timestamp + duration3);

        // ── Settle final period ──
        vm.prank(curator);
        wrapper.collectPremium();

        // totalPremiumLiability should match sum of per-period calculations (no withdrawals have occurred)
        assertApproxEqAbs(
            wrapper.totalPremiumLiability(),
            expectedTotal,
            10,
            "Total premium must equal sum(principal * rate_i * duration_i / WAD)"
        );
    }

    /// @dev Mirrors the contract's _accruedPremium() calculation
    function _expectedPremium(uint256 principal_, uint256 rate, uint256 duration) internal pure returns (uint256) {
        return principal_ * rate * duration / WAD;
    }

    /// @notice Fuzz test: premium should be distributed proportionally to principal.
    ///
    ///         With the premium-as-debt model (Option A fix), each user's premium is
    ///         tracked via a per-user debt accumulator (cumulativePremiumPerUnit).
    ///         Accrual is principal-proportional: a user with 1000 principal always pays
    ///         exactly principal × rate × elapsed / WAD regardless of their entry share price.
    ///
    ///         This test verifies the fix by having both Alice and Bob withdraw after premium
    ///         accrues. The premium deducted from each (= pendingPremium increase) must be
    ///         equal since they hold equal principals, despite Alice holding more shares
    ///         (lower entry price) than Bob.
    function testFuzz_premiumAccrual_shouldBeProportionalToPrincipal(
        uint256 deposit,
        uint256 yieldPct,
        uint256 premiumDays
    )
        public
    {
        _deployWrapperWithCap(type(uint128).max);

        deposit = bound(deposit, 10 ether, 1_000_000 ether);
        yieldPct = bound(yieldPct, 10, 200); // 10-200% yield to create meaningful price gap
        premiumDays = bound(premiumDays, 30, 180);

        address alice = address(0xAA11);
        address bob = address(0xBB22);
        _mintAndApprove(alice, deposit);
        _mintAndApprove(bob, deposit);

        // ── Alice deposits at initial price ──
        vm.prank(alice);
        wrapper.deposit(deposit, alice);

        // ── Yield raises share price ──
        _simulateProfit(yieldPct);

        // ── Bob deposits same principal at higher price → fewer shares ──
        vm.prank(bob);
        wrapper.deposit(deposit, bob);

        uint256 aliceShares = wrapper.balanceOf(alice);
        uint256 bobShares = wrapper.balanceOf(bob);
        // Confirm different share counts from different entry prices
        assertGt(aliceShares, bobShares, "Alice has more shares (lower entry price)");
        assertEq(wrapper.userPrincipal(alice), deposit, "Same principal: Alice");
        assertEq(wrapper.userPrincipal(bob), deposit, "Same principal: Bob");

        // ── Enable premium and let time pass ──
        _setPremiumRate(wrapper, FIFTY_PCT_ANNUAL_RATE, curator);
        vm.warp(block.timestamp + premiumDays * 1 days);

        // ── Alice withdraws: measure premium deducted (pendingPremium increase) ──
        uint256 pendingBefore = wrapper.pendingPremium();
        vm.prank(alice);
        wrapper.redeem(aliceShares, alice, alice);
        uint256 alicePremiumPaid = wrapper.pendingPremium() - pendingBefore;

        // ── Bob withdraws: measure premium deducted ──
        uint256 pendingAfterAlice = wrapper.pendingPremium();
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);
        uint256 bobPremiumPaid = wrapper.pendingPremium() - pendingAfterAlice;

        // ── FIXED invariant: equal principal → equal premium paid at withdrawal ──
        // Allow 0.1% relative tolerance for accumulator rounding
        assertApproxEqRel(
            alicePremiumPaid, bobPremiumPaid, 0.001e18, "Premium must be distributed proportionally to principal"
        );
    }

    /*//////////////////////////////////////////////////////////////
                   TRANSFER INVARIANT FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: share transfers are disabled (soulbound). Attempting any transfer
    ///         between two non-zero addresses reverts with TransfersDisabled().
    ///         Invariants verified: principal sums remain correct after deposits.
    function testFuzz_transfer_principalInvariants_and_insurance(
        uint256 deposit1,
        uint256 deposit2,
        uint256 transferPct,
        uint256 lossPct
    )
        public
    {
        _deployWrapperWithCap(type(uint128).max);

        deposit1 = bound(deposit1, 10 ether, 1_000_000 ether);
        deposit2 = bound(deposit2, 10 ether, 1_000_000 ether);
        transferPct = bound(transferPct, 1, 99);
        lossPct = bound(lossPct, 20, 80);

        address alice = address(0xAA11);
        address bob = address(0xBB22);
        _mintAndApprove(alice, deposit1);
        _mintAndApprove(bob, deposit2);

        // ── Both deposit ──
        vm.prank(alice);
        wrapper.deposit(deposit1, alice);
        vm.prank(bob);
        wrapper.deposit(deposit2, bob);

        uint256 totalPrincipalBefore = wrapper.totalPrincipal();
        assertEq(totalPrincipalBefore, deposit1 + deposit2, "totalPrincipal after deposits");
        assertEq(
            wrapper.userPrincipal(alice) + wrapper.userPrincipal(bob),
            totalPrincipalBefore,
            "sum == total before transfer"
        );

        // ── Transfer reverts: shares are soulbound ──
        uint256 sharesToTransfer = wrapper.balanceOf(alice) * transferPct / 100;
        vm.prank(alice);
        vm.expectRevert(CoveredVaultStorage.TransfersDisabled.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        wrapper.transfer(bob, sharesToTransfer);

        // Principals are unchanged since the transfer reverted
        assertEq(wrapper.totalPrincipal(), totalPrincipalBefore, "totalPrincipal unchanged after failed transfer");
        assertEq(
            wrapper.userPrincipal(alice) + wrapper.userPrincipal(bob),
            totalPrincipalBefore,
            "sum == total after failed transfer"
        );
    }

    /*//////////////////////////////////////////////////////////////
        SEQUENTIAL DEPOSIT + WITHDRAWAL PREMIUM INVARIANT FUZZ TEST
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: a user makes two sequential deposits separated by a premium accrual
    ///         period, then withdraws in two steps. Verifies:
    ///
    ///           1. The second deposit does NOT retroactively pay premium for the first period.
    ///              Total premium = rate * D1 * P1 + rate * (D1+D2) * P2,
    ///              NOT rate * (D1+D2) * (P1+P2).
    ///           2. Partial withdrawal pays proportional premium (shares redeemed / total shares).
    ///           3. Full withdrawal clears all state (principal, shares, liability).
    ///           4. Sum of premium paid across both withdrawals equals total accrued premium.
    function testFuzz_sequentialDeposits_premiumNotRetroactive(
        uint256 deposit1,
        uint256 deposit2,
        uint256 premiumRate,
        uint256 period1Days,
        uint256 period2Days,
        uint256 withdrawPct
    )
        public
    {
        _deployWrapperWithCap(type(uint128).max);

        deposit1 = bound(deposit1, 10 ether, 1_000_000 ether);
        deposit2 = bound(deposit2, 10 ether, 1_000_000 ether);
        premiumRate = bound(premiumRate, 1, FIFTY_PCT_ANNUAL_RATE);
        period1Days = bound(period1Days, 1, 180);
        period2Days = bound(period2Days, 1, 180);
        withdrawPct = bound(withdrawPct, 10, 90); // partial withdrawal: 10-90%

        uint256 period1 = period1Days * 1 days;
        uint256 period2 = period2Days * 1 days;

        // Guard: premium must not exceed Morpho value (would be capped and distort test)
        uint256 expectedP1 = deposit1 * premiumRate * period1 / WAD;
        uint256 expectedP2 = (deposit1 + deposit2) * premiumRate * period2 / WAD;
        uint256 expectedTotal = expectedP1 + expectedP2;
        vm.assume(expectedTotal > 0 && expectedTotal < (deposit1 + deposit2) * 80 / 100);

        _setPremiumRate(wrapper, premiumRate, curator);

        address user = address(0x1111);
        _mintAndApprove(user, deposit1 + deposit2);

        // ── D1: first deposit ──
        vm.prank(user);
        wrapper.deposit(deposit1, user);

        // ── Period 1: premium accrues on D1 ──
        vm.warp(block.timestamp + period1);
        vm.prank(curator);
        wrapper.collectPremium();
        uint256 liabilityAfterP1 = wrapper.totalPremiumLiability();

        // Invariant: liability after P1 matches rate * D1 * P1
        assertApproxEqAbs(liabilityAfterP1, expectedP1, 10, "Liability after period 1");

        // ── D2: second deposit -- must NOT increase liability ──
        vm.prank(user);
        wrapper.deposit(deposit2, user);
        assertApproxEqAbs(wrapper.totalPremiumLiability(), liabilityAfterP1, 10, "Liability unchanged after D2");
        assertEq(wrapper.userPrincipal(user), deposit1 + deposit2, "Principal = D1 + D2");

        // ── Period 2: premium accrues on D1+D2 ──
        vm.warp(block.timestamp + period2);
        vm.prank(curator);
        wrapper.collectPremium();
        assertApproxEqAbs(wrapper.totalPremiumLiability(), expectedTotal, 10, "Total liability = P1(D1) + P2(D1+D2)");

        // ── Partial withdrawal ──
        uint256 totalShares = wrapper.balanceOf(user);
        uint256 sharesToRedeem = totalShares * withdrawPct / 100;
        uint256 pendingBefore = wrapper.pendingPremium();

        vm.prank(user);
        wrapper.redeem(sharesToRedeem, user, user);

        uint256 premiumPaidPartial = wrapper.pendingPremium() - pendingBefore;

        // Invariant: partial premium is proportional to shares fraction
        uint256 expectedPartialPremium = expectedTotal * withdrawPct / 100;
        assertApproxEqRel(
            premiumPaidPartial, expectedPartialPremium, 0.02e18, "Partial withdrawal premium proportional"
        );

        // ── Full withdrawal of remaining shares ──
        uint256 remaining = wrapper.balanceOf(user);
        uint256 pendingBeforeFinal = wrapper.pendingPremium();

        vm.prank(user);
        wrapper.redeem(remaining, user, user);

        uint256 premiumPaidFinal = wrapper.pendingPremium() - pendingBeforeFinal;

        // Invariant: total premium across both withdrawals matches expected
        // Tolerance: 0.1% relative -- rounding accumulates across partial + full withdrawal
        assertApproxEqRel(premiumPaidPartial + premiumPaidFinal, expectedTotal, 0.001e18, "Total premium = P1 + P2");

        // Invariant: all state cleaned
        assertEq(wrapper.userPrincipal(user), 0, "Principal cleared");
        assertEq(wrapper.totalPrincipal(), 0, "Total principal cleared");
        assertEq(wrapper.balanceOf(user), 0, "Shares cleared");
        // Liability may have rounding dust from partial withdrawal's floor division
        // (uncappedPremium = totalOwed * shares / balance rounds down, leaving small residual).
        // Dust is bounded by the per-user accumulator rounding: < 1e7 for deposits up to 1M ether.
        assertLe(wrapper.totalPremiumLiability(), 1e7, "Liability dust bounded");
    }

    /*//////////////////////////////////////////////////////////////
        PER-USER MORPHO SHARE TRACKING FUZZ TEST
    //////////////////////////////////////////////////////////////*/

    struct MorphoTrackingParams {
        uint256 deposit1A;
        uint256 deposit1B;
        uint256 deposit2A;
        uint256 deposit2B;
        uint256 yieldPct;
        uint256 lossPct;
        uint256 premiumRate;
        uint256 hackLossPct;
    }

    struct WithdrawalResult {
        uint256 received;
        uint256 insurance;
    }

    /// @notice Fuzz test: two users each deposit twice at different Morpho share prices
    ///         (yield or loss between deposits), then both fully withdraw.
    ///         Verifies per-user Morpho share tracking correctly isolates each user's
    ///         underlying position:
    ///
    ///           1. No phantom insurance on zero-loss scenarios (premium-only)
    ///           2. Each user's insurance bounded by maxCoverable(insuredBasis)
    ///           3. Users don't receive more than principal + maxInsurance
    ///           4. Morpho shares sum always equals total held by wrapper
    ///           5. All state (principal, shares, morpho shares) is cleaned after full exit
    function testFuzz_perUserMorphoShares_multiDepositWithYieldAndLoss(
        uint256 deposit1A,
        uint256 deposit1B,
        uint256 deposit2A,
        uint256 deposit2B,
        uint256 yieldPct1,
        uint256 lossPct1,
        uint256 premiumRate,
        uint256 hackLossPct
    )
        public
    {
        MorphoTrackingParams memory p;
        p.deposit1A = bound(deposit1A, 10 ether, 500_000 ether);
        p.deposit1B = bound(deposit1B, 10 ether, 500_000 ether);
        p.deposit2A = bound(deposit2A, 10 ether, 500_000 ether);
        p.deposit2B = bound(deposit2B, 10 ether, 500_000 ether);
        p.yieldPct = bound(yieldPct1, 0, 30);
        p.lossPct = bound(lossPct1, 0, 20);
        p.premiumRate = bound(premiumRate, 1, FIFTY_PCT_ANNUAL_RATE);
        p.hackLossPct = bound(hackLossPct, 0, 30);

        uint96 policyId = _deployWrapperWithCap(type(uint128).max);
        _setupMorphoTrackingTest(p);
        _executeMorphoTrackingDeposits(p);

        // Guard: premium must not exceed Morpho value
        uint256 totalPrincipal = p.deposit1A + p.deposit1B + p.deposit2A + p.deposit2B;
        vm.assume(_approxPremium(p) < morphoVault.totalAssets() * 80 / 100);

        if (p.hackLossPct > 0) _simulateLoss(p.hackLossPct);

        _assertMorphoTrackingInvariants(p, policyId);
    }

    function _setupMorphoTrackingTest(MorphoTrackingParams memory p) internal {
        // Propose both timelocked changes
        vm.startPrank(curator);
        wrapper.setDeductibleBps(0);
        wrapper.setPremiumRate(p.premiumRate);
        vm.stopPrank();

        // Execute after timelock
        vm.warp(block.timestamp + 2 days + 1);
        vm.startPrank(curator);
        wrapper.executeDeductibleBps();
        wrapper.executePremiumRate();
        vm.stopPrank();

        _mintAndApprove(address(0xAA11), p.deposit1A + p.deposit1B);
        _mintAndApprove(address(0xBB22), p.deposit2A + p.deposit2B);
    }

    function _executeMorphoTrackingDeposits(MorphoTrackingParams memory p) internal {
        address alice = address(0xAA11);
        address bob = address(0xBB22);

        // Round 1: both deposit at initial Morpho price
        vm.prank(alice);
        wrapper.deposit(p.deposit1A, alice);
        vm.prank(bob);
        wrapper.deposit(p.deposit2A, bob);

        // 90 days of premium
        vm.warp(block.timestamp + 90 days);

        // Yield or loss changes Morpho share price before round 2
        if (p.yieldPct > p.lossPct) _simulateProfit(p.yieldPct);
        else if (p.lossPct > p.yieldPct) _simulateLoss(p.lossPct);

        // Round 2: both deposit again at new Morpho price
        vm.prank(alice);
        wrapper.deposit(p.deposit1B, alice);
        vm.prank(bob);
        wrapper.deposit(p.deposit2B, bob);

        // Morpho shares sum must equal total held by wrapper
        assertEq(
            wrapper.userMorphoShares(alice) + wrapper.userMorphoShares(bob),
            morphoVault.balanceOf(address(wrapper)),
            "Morpho shares sum = total after deposits"
        );

        // 90 more days of premium
        vm.warp(block.timestamp + 90 days);
    }

    function _approxPremium(MorphoTrackingParams memory p) internal pure returns (uint256) {
        uint256 p1 = (p.deposit1A + p.deposit2A) * p.premiumRate * 90 days / WAD;
        uint256 p2 = (p.deposit1A + p.deposit1B + p.deposit2A + p.deposit2B) * p.premiumRate * 90 days / WAD;
        return p1 + p2;
    }

    function _assertMorphoTrackingInvariants(MorphoTrackingParams memory p, uint96 policyId) internal {
        address alice = address(0xAA11);
        address bob = address(0xBB22);

        uint256 insuranceBefore = claimManager.policyClaim(policyId).totalPaidOut;
        WithdrawalResult memory a = _withdrawAndTrackInsurance(alice, policyId, insuranceBefore);
        WithdrawalResult memory b = _withdrawAndTrackInsurance(bob, policyId, insuranceBefore + a.insurance);

        uint256 alicePrincipal = p.deposit1A + p.deposit1B;
        uint256 bobPrincipal = p.deposit2A + p.deposit2B;

        // Invariant 1: no loss of any kind → no insurance
        // Both hackLossPct and lossPct (between rounds) must be zero for truly zero-loss
        if (p.hackLossPct == 0 && p.lossPct == 0) {
            assertEq(a.insurance, 0, "No loss: Alice insurance = 0");
            assertEq(b.insurance, 0, "No loss: Bob insurance = 0");
        }

        // Invariant 2: each user's insurance bounded by maxCoverable(principal)
        assertLe(a.insurance, alicePrincipal * MAX_COVERABLE_LOSS_BPS / 10_000, "Alice insurance bounded");
        assertLe(b.insurance, bobPrincipal * MAX_COVERABLE_LOSS_BPS / 10_000, "Bob insurance bounded");

        // Invariant 3: received bounded by Morpho value of user's shares + maxInsurance
        // User can receive up to their Morpho entitlement (which includes yield) + insurance.
        // Conservative bound: principal + yield (up to 30%) + maxInsurance, minus premium
        uint256 aliceUpperBound = alicePrincipal * 130 / 100 + a.insurance;
        uint256 bobUpperBound = bobPrincipal * 130 / 100 + b.insurance;
        assertLe(a.received, aliceUpperBound, "Alice received bounded");
        assertLe(b.received, bobUpperBound, "Bob received bounded");

        // Invariant 4: all state cleaned
        assertEq(wrapper.userPrincipal(alice), 0, "Alice principal cleared");
        assertEq(wrapper.userPrincipal(bob), 0, "Bob principal cleared");
        assertEq(wrapper.totalPrincipal(), 0, "Total principal cleared");
        assertEq(wrapper.balanceOf(alice), 0, "Alice shares cleared");
        assertEq(wrapper.balanceOf(bob), 0, "Bob shares cleared");
        assertEq(wrapper.userMorphoShares(alice), 0, "Alice Morpho shares cleared");
        assertEq(wrapper.userMorphoShares(bob), 0, "Bob Morpho shares cleared");
    }

    function _withdrawAndTrackInsurance(
        address user_,
        uint96 policyId_,
        uint256 insuranceSnapshot_
    )
        internal
        returns (WithdrawalResult memory r)
    {
        uint256 shares = wrapper.balanceOf(user_);
        uint256 balBefore = asset.balanceOf(user_);
        vm.prank(user_);
        wrapper.redeem(shares, user_, user_);
        r.received = asset.balanceOf(user_) - balBefore;
        r.insurance = claimManager.policyClaim(policyId_).totalPaidOut - insuranceSnapshot_;
    }
}
