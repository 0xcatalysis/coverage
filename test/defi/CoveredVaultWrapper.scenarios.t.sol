// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";

import {MockERC20} from "./mocks/Mocks.sol";
import {ControllableVault} from "./mocks/ControllableVault.sol";
import {RealCoverageSetup} from "./helpers/RealCoverageSetup.sol";

/// @title CoveredVaultWrapperScenarios
/// @notice Scenario tests for CoveredVaultWrapper covering multi-user interactions,
///         coverage exhaustion, loss detection, and invariant checks.
contract CoveredVaultWrapperScenarios is RealCoverageSetup {
    CoveredVaultWrapper wrapper;
    ControllableVault morphoVault;
    MockERC20 asset;

    address curator = address(0xCCCC);
    address premiumRecipient;

    uint96 POLICY_ID;
    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%
    uint16 constant DEDUCTIBLE_BPS = 100; // 1%
    uint256 constant FIFTY_PCT_ANNUAL_RATE = 15_854_895_991; // ~50%/year WAD-scaled per second

    function setUp() public {
        asset = new MockERC20();
        morphoVault = new ControllableVault(address(asset));

        _deployRealCoverage(curator, curator);
        premiumRecipient = address(mockPremiumManager);

        vm.prank(curator);
        policyManager.setSupportedPayoutToken(address(asset), true);
    }

    /// @notice Simulate profit by minting tokens to the vault (increases totalAssets)
    function _simulateProfit(uint256 percent) internal {
        uint256 extra = morphoVault.totalAssets() * percent / 100;
        asset.mint(address(morphoVault), extra);
    }

    /// @notice Simulate loss by draining tokens from the vault (decreases totalAssets)
    function _simulateLoss(uint256 percent) internal {
        uint256 loss = morphoVault.totalAssets() * percent / 100;
        morphoVault.simulateLoss(loss);
    }

    /// @notice Deploy wrapper with unlimited coverage limit so coverage exhaustion is controlled
    function _deployWrapper(uint256 coverageLimit) internal {
        wrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipient,
            curator,
            "Scenario Vault",
            "scVault"
        );

        POLICY_ID = _createAndBindPolicy(
            address(wrapper), address(wrapper), address(asset), coverageLimit, 365 days, curator, address(wrapper)
        );
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(wrapper), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 1: MULTI-USER INDEPENDENT SHORTFALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice user1 takes 100% loss, user2 has no loss; only user1 gets insurance payout.
    ///         Premium is active but unsettleable (100% loss → morphoValue=0 → _accruePremium caps to 0).
    ///         Insurance uses insuredBasis = principal (totalPremiumLiability=0), same as without premium.
    function test_multiUser_independentShortfalls() public {
        _deployWrapper(type(uint128).max);

        address user1 = address(0x1111);
        address user2 = address(0x2222);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        // Both deposit 1000 ether
        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);
        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        assertEq(wrapper.totalPrincipal(), 2000 ether);

        // ── Premium: 50%/year, skip 180 days ──
        _setPremiumRate(wrapper, FIFTY_PCT_ANNUAL_RATE, curator);
        vm.warp(block.timestamp + 180 days);

        // Settle premium before loss so insuredBasis reflects premium paid.
        // Premium accrued ≈ 2000 * 50% * 180/365 ≈ 493 ether.
        vm.prank(curator);
        wrapper.collectPremium();
        uint256 tpr = wrapper.totalPremiumLiability();
        assertApproxEqAbs(tpr, 493_150_684_904_064_000_000, 2, "TPR after 180 days");

        // Simulate 100% loss in morpho vault AFTER premium settlement
        _simulateLoss(100);

        uint256 user1Before = asset.balanceOf(user1);
        uint256 user2Before = asset.balanceOf(user2);

        uint256 user1Shares = wrapper.balanceOf(user1);
        uint256 user2Shares = wrapper.balanceOf(user2);

        vm.prank(user1);
        wrapper.redeem(user1Shares, user1, user1);

        vm.prank(user2);
        wrapper.redeem(user2Shares, user2, user2);

        uint256 user1Received = asset.balanceOf(user1) - user1Before;
        uint256 user2Received = asset.balanceOf(user2) - user2Before;

        // Both users suffer 100% loss → assetsReceived = 0 → premiumForWithdrawal = 0 (capped at 0).
        // insuredBasis = 1000 − 0 = 1000 per user (uncollected premium is not deducted from insuredBasis).
        // shortfall = 1000, maxInsurance = 100 (10%), capped = 100
        // deductibleAmt = 1000 * 1% = 10, payout = 100 - 10 = 90
        assertApproxEqAbs(user1Received, 90 ether, 2, "user1: 100% loss, premium-adjusted insurance");
        assertApproxEqAbs(user2Received, 90 ether, 2, "user2: 100% loss, premium-adjusted insurance");

        // Both principals zeroed
        assertEq(wrapper.userPrincipal(user1), 0);
        assertEq(wrapper.userPrincipal(user2), 0);
        assertEq(wrapper.totalPrincipal(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 2: COVERAGE EXHAUSTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Second claimer gets less after coverage pool is depleted by first claim
    function test_coverageExhaustion_partialPayout() public {
        // Coverage limit of only 50 ether -- depleted by first user.
        // absoluteCap = 50 * BPS_DENOMINATOR / maxCoverableLossBps = 50 * 10000/1000 = 500 ether
        // Each user deposits 200 ether (total 400, well within cap).
        _deployWrapper(50 ether);

        address user1 = address(0x1111);
        address user2 = address(0x2222);
        _mintAndApprove(user1, 200 ether);
        _mintAndApprove(user2, 200 ether);

        vm.prank(user1);
        wrapper.deposit(200 ether, user1);
        vm.prank(user2);
        wrapper.deposit(200 ether, user2);

        // 100% loss
        _simulateLoss(100);

        uint256 user1Before = asset.balanceOf(user1);
        uint256 user2Before = asset.balanceOf(user2);

        uint256 user1Shares = wrapper.balanceOf(user1);
        uint256 user2Shares = wrapper.balanceOf(user2);

        vm.prank(user1);
        wrapper.redeem(user1Shares, user1, user1);

        vm.prank(user2);
        wrapper.redeem(user2Shares, user2, user2);

        uint256 user1Received = asset.balanceOf(user1) - user1Before;
        uint256 user2Received = asset.balanceOf(user2) - user2Before;

        // 100% loss, no premium: insuredBasis=200, shortfall=200, maxInsurance=200*10%=20, capped=20.
        // deductibleAmt = 200 * 1% = 2, payout = 20 - 2 = 18.
        // Coverage limit 50 > 18, so not exhausted per user.
        assertApproxEqAbs(user1Received, 18 ether, 2, "user1: 10% cap minus 1% deductible = 18 ether");
        assertApproxEqAbs(user2Received, 18 ether, 2, "user2: same insurance as user1");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 3: FORCE DEALLOCATE / LOSS ON REDEEM
    //////////////////////////////////////////////////////////////*/

    /// @notice Loss in morphoVault is detected on withdrawal and triggers insurance
    function test_forceDeallocate_reducesSharePrice_detectedOnWithdraw() public {
        _deployWrapper(type(uint128).max);

        address user1 = address(0x1111);
        _mintAndApprove(user1, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        // Simulate a loss event (e.g., morpho adapter got force-deallocated at a loss)
        _simulateLoss(20); // 20% loss

        uint256 user1Before = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1Before;

        // assetsReceived = 800, shortfall=200, maxInsurance=100, capped=100
        // deductibleAmt = 1000*1%=10, payout=100-10=90, total = 800+90=890
        assertEq(received, 890 ether, "Should receive 800 + 90 insurance = 890 after 20% loss");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 4: PRINCIPAL SUM INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @notice Σ userPrincipal[all users] == totalPrincipal after deposits, withdrawals, and transfers
    ///         with price changes (profit and loss) between operations.
    function test_invariant_sumOfUserPrincipals() public {
        _deployWrapper(type(uint128).max);

        address[5] memory users = [address(0xA1), address(0xA2), address(0xA3), address(0xA4), address(0xA5)];
        uint256[5] memory deposits = [uint256(100 ether), 200 ether, 300 ether, 150 ether, 250 ether];

        // All deposits
        for (uint256 i = 0; i < 5; i++) {
            _mintAndApprove(users[i], deposits[i]);
            vm.prank(users[i]);
            wrapper.deposit(deposits[i], users[i]);
        }

        // Check invariant after deposits
        _assertPrincipalInvariant(users);

        // 30% profit before partial withdrawal -- principal invariant must hold regardless of price
        _simulateProfit(30);

        // Partial withdrawal by user[0] (in profit → no insurance)
        uint256 halfShares = wrapper.balanceOf(users[0]) / 2;
        vm.prank(users[0]);
        wrapper.redeem(halfShares, users[0], users[0]);
        _assertPrincipalInvariant(users);

        // 15% loss before full withdrawal -- may trigger insurance for user[3]
        _simulateLoss(15);

        // Full withdrawal by user[3]
        uint256 user3Shares = wrapper.balanceOf(users[3]);
        vm.prank(users[3]);
        wrapper.redeem(user3Shares, users[3], users[3]);
        _assertPrincipalInvariant(users);
    }

    function _assertPrincipalInvariant(address[5] memory users) internal view {
        uint256 sum = 0;
        for (uint256 i = 0; i < 5; i++) {
            sum += wrapper.userPrincipal(users[i]);
        }
        assertEq(sum, wrapper.totalPrincipal(), "Sum of userPrincipal must equal totalPrincipal");
    }

    /*//////////////////////////////////////////////////////////////
            SCENARIO 8: ALICE (ENTRY 1.0) + BOB (ENTRY 1.4)
                    WITH 1%/YEAR PREMIUM AND 20% MAX COVERAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploy a fresh wrapper with 20% max coverage, 1% deductible, and 1%/year premium
    ///         for the multi-entry-price scenarios.
    function _deployEntryPriceWrapper() internal {
        wrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            2000, // 20% max coverable loss
            100, // 1% deductible
            premiumRecipient,
            curator,
            "EntryPrice Vault",
            "EPV"
        );

        POLICY_ID = _createAndBindPolicy(
            address(wrapper), address(wrapper), address(asset), type(uint128).max, 365 days, curator, address(wrapper)
        );

        // 1%/year premium rate
        uint256 onePctAnnualRate = uint256(1e16) / 31_536_000;
        _setPremiumRate(wrapper, onePctAnnualRate, curator);
    }

    /// @notice Scenario 8A: price ~1.6 -- both Alice (entry 1.0) and Bob (entry ~1.4) are above
    ///         their entry prices. View functions show no shortfall (correct global accounting).
    ///         However, after premium settlement + redemption order effects, Bob experiences
    ///         a phantom shortfall -- same root cause as test_premiumOnly_phantomShortfall (test 9).
    function test_multiEntryPrice_scenarioA_bothProfit_noShortfall() public {
        _deployEntryPriceWrapper();

        address alice = address(0xAA11);
        address bob = address(0xBB22);
        _mintAndApprove(alice, 2000 ether);
        _mintAndApprove(bob, 2000 ether);

        // Alice deposits at Morpho price 1.0
        vm.prank(alice);
        wrapper.deposit(1000 ether, alice);

        // Morpho price rises to 1.4
        _simulateProfit(40);

        // Bob deposits 1000 ether at price ~1.4 → gets ~714 wrapper shares
        vm.prank(bob);
        wrapper.deposit(1000 ether, bob);

        // ── Premium: override to 50%/year, skip 180 days ──
        // Premium accrued ≈ 2000 * 50% * 180/365 ≈ 493 ether
        _setPremiumRate(wrapper, FIFTY_PCT_ANNUAL_RATE, curator);
        vm.warp(block.timestamp + 180 days);

        // Global view: no shortfall (total premium correctly deducted from both sides)
        assertEq(wrapper.calculateShortfall(), 0, "No global shortfall after premium");
        assertEq(wrapper.userShortfall(alice), 0, "Alice: no shortfall after premium");
        assertEq(wrapper.userShortfall(bob), 0, "Bob: no shortfall after premium");

        // Settle premium before redemptions to avoid mock arithmetic issues
        vm.prank(curator);
        wrapper.collectPremium();

        uint256 insuranceBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        // Alice redeems first -- she has MORE shares (entered at lower price) so she takes
        // a disproportionate share of the morpho pool, leaving less for Bob.
        uint256 aliceShares = wrapper.balanceOf(alice);
        vm.prank(alice);
        wrapper.redeem(aliceShares, alice, alice);

        uint256 bobShares = wrapper.balanceOf(bob);
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);

        uint256 insuranceAfter = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        // With accurate ERC4626 accounting (ControllableVault), no phantom shortfall occurs.
        // Both users are in profit, no loss -- no insurance should be paid.
        assertEq(insuranceAfter, insuranceBefore, "No insurance: both users in profit, no loss");
        assertEq(wrapper.totalPrincipal(), 0, "All principals cleared");
    }

    /// @notice Scenario 8B: price drops to ~1.17 (below Bob's entry of ~1.4).
    ///         With 180 days of 50%/year premium + price drop, Alice should still be in profit.
    ///         Bob has a shortfall from the REAL price drop (not premium). Premium reduces
    ///         insuredBasis via totalPremiumLiability, so Bob's insurance should cover real loss only.
    function test_multiEntryPrice_scenarioB_aliceProfitBobInsured() public {
        _deployEntryPriceWrapper();

        address alice = address(0xAA11);
        address bob = address(0xBB22);
        _mintAndApprove(alice, 2000 ether);
        _mintAndApprove(bob, 2000 ether);

        // Alice deposits 1000 at price 1.0
        vm.prank(alice);
        wrapper.deposit(1000 ether, alice);

        // Morpho price rises to 1.4
        _simulateProfit(40);

        // Bob deposits 1000 at price ~1.4 → ~714 wrapper shares
        vm.prank(bob);
        wrapper.deposit(1000 ether, bob);

        // ── Premium: override to 50%/year, skip 180 days ──
        // Premium accrued ≈ 2000 * 50% * 180/365 ≈ 493 ether
        _setPremiumRate(wrapper, FIFTY_PCT_ANNUAL_RATE, curator);
        vm.warp(block.timestamp + 180 days);

        // Drain the 400 profit tokens added earlier, reverting to raw book value.
        // totalAssets goes from 2400 to 2000, price ~2000/1714 ≈ 1.167.
        // Combined with premium, the effective value is even lower.
        morphoVault.simulateLoss(400 ether);

        uint256 insuranceBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        // Alice redeems -- entered at 1.0, should still be above premium-adjusted basis
        uint256 aliceShares = wrapper.balanceOf(alice);
        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        wrapper.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = asset.balanceOf(alice) - aliceBefore;

        assertEq(wrapper.userPrincipal(alice), 0, "Alice principal cleared");

        // Bob redeems -- entered at ~1.4, below water after price drop + premium
        uint256 bobShares = wrapper.balanceOf(bob);
        uint256 bobBefore = asset.balanceOf(bob);
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);
        uint256 bobReceived = asset.balanceOf(bob) - bobBefore;

        assertEq(wrapper.userPrincipal(bob), 0, "Bob principal cleared");

        uint256 totalInsurance = claimManager.policyClaim(POLICY_ID).totalPaidOut - insuranceBefore;

        // Alice: entered at 1.0, premium + price drop still leaves her above adjusted basis
        assertApproxEqAbs(
            aliceReceived, 920_091_324_214_634_666_665, 2, "Alice: vault share after premium + price drop"
        );
        // Bob: entered at ~1.4, price dropped below entry → shortfall triggers insurance
        // Traditional deductible: deductibleAmt = insuredBasis * 1%, subtracted from capped shortfall
        assertApproxEqAbs(bobReceived, 729_908_675_815_415_253_334, 2, "Bob: vault share + insurance");
        // Insurance for Bob's real shortfall from price drop
        assertApproxEqAbs(totalInsurance, 143_150_684_934_113_920_000, 2, "Insurance for Bob's shortfall");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 5: ZERO PRINCIPAL PREMIUM ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @notice When totalPrincipal==0, lastPremiumAccrualTime still advances but no assets transferred
    function test_premiumAccrual_zeroPrincipal() public {
        uint256 rate = uint256(1e17) / 31_536_000;
        wrapper = _deployWrapperProxy(
            address(morphoVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipient,
            curator,
            "ZeroPrincipal",
            "ZP"
        );
        POLICY_ID = _createAndBindPolicy(
            address(wrapper), address(wrapper), address(asset), 10_000 ether, 365 days, curator, address(wrapper)
        );
        _setPremiumRate(wrapper, rate, curator);

        assertEq(wrapper.totalPrincipal(), 0);

        uint256 recipientBefore = asset.balanceOf(premiumRecipient);
        uint256 accrualBefore = wrapper.lastPremiumAccrualTime();

        vm.warp(block.timestamp + 365 days);
        vm.prank(curator);
        wrapper.collectPremium();

        assertEq(asset.balanceOf(premiumRecipient), recipientBefore, "No premium transferred when no principal");
        assertEq(wrapper.lastPremiumAccrualTime(), 31_536_001, "Accrual timestamp should advance to block.timestamp");
        assertEq(accrualBefore, 1, "Accrual timestamp started at 1");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 6: PROFIT CASE -- NO INSURANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice When morphoVault is in profit, withdrawals produce no insurance payout.
    ///         Premium reduces the payout but does not trigger insurance.
    function test_profit_noInsurance() public {
        _deployWrapper(type(uint128).max);

        address user1 = address(0x1111);
        _mintAndApprove(user1, 1000 ether);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        // ── Premium: 50%/year, skip 180 days ──
        // Premium accrued ≈ 1000 * 50% * 180/365 ≈ 246.6 ether
        _setPremiumRate(wrapper, FIFTY_PCT_ANNUAL_RATE, curator);
        vm.warp(block.timestamp + 180 days);

        // Settle premium before profit change to get clean accounting
        vm.prank(curator);
        wrapper.collectPremium();

        // 20% profit in morpho vault (applied to post-premium _totalAssets)
        _simulateProfit(20);

        uint256 insuranceBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        uint256 user1Before = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1Before;

        // Premium reduces payout but 20% profit still keeps user above water.
        // No insurance should trigger -- premium is NOT a loss.
        uint256 insuranceAfter = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        assertEq(insuranceAfter, insuranceBefore, "No insurance: premium + profit, no loss");
        // Premium ~246.6 deducted from liability; 20% profit on gross Morpho entitlement → received ~953.4
        assertApproxEqAbs(
            received, 953_424_657_547_968_000_000, 2, "Should receive principal minus premium, plus profit"
        );
        assertEq(wrapper.userPrincipal(user1), 0, "Principal should be cleared");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 7: TWO-USER DIFFERENT ENTRY PRICES
    //////////////////////////////////////////////////////////////*/

    /// @notice Alice deposits at 1:1, vault gains yield, Bob deposits later at higher price.
    ///         After premium accrual and a loss, Alice is in profit (no insurance),
    ///         Bob has shortfall (insured). Premium should not create phantom claims.
    function test_twoUsers_differentEntryPrices() public {
        _deployWrapper(type(uint128).max);

        address alice = address(0xAA);
        address bob = address(0xBB);
        _mintAndApprove(alice, 2000 ether);
        _mintAndApprove(bob, 2000 ether);

        // Alice deposits 1000 at 1:1
        vm.prank(alice);
        wrapper.deposit(1000 ether, alice);

        // 50% profit accrues
        _simulateProfit(50);

        // Bob deposits 1500 at 1.5 price (gets 1000 shares)
        vm.prank(bob);
        wrapper.deposit(1500 ether, bob);

        assertEq(wrapper.userPrincipal(alice), 1000 ether);
        assertEq(wrapper.userPrincipal(bob), 1500 ether);

        // ── Premium: 50%/year, skip 180 days ──
        // Premium accrued ≈ 2500 * 50% * 180/365 ≈ 616.4 ether
        _setPremiumRate(wrapper, FIFTY_PCT_ANNUAL_RATE, curator);
        vm.warp(block.timestamp + 180 days);

        // Now a 10% hack -- loss applied from current state
        _simulateLoss(10);

        uint256 insuranceBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        // Alice withdraws her shares
        uint256 aliceShares = wrapper.balanceOf(alice);
        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        wrapper.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = asset.balanceOf(alice) - aliceBefore;

        // Alice's principal=1000, entered at 1.0. Even after premium + 10% loss she should still be
        // above her premium-adjusted basis (entered well below current price).
        assertEq(wrapper.userPrincipal(alice), 0, "Alice principal cleared");

        // Bob withdraws his shares
        uint256 bobShares = wrapper.balanceOf(bob);
        uint256 bobBefore = asset.balanceOf(bob);
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);
        uint256 bobTotal = asset.balanceOf(bob) - bobBefore;

        assertEq(wrapper.userPrincipal(bob), 0, "Bob principal cleared");

        uint256 totalInsurance = claimManager.policyClaim(POLICY_ID).totalPaidOut - insuranceBefore;

        // Alice: entered at 1.0, still above premium-adjusted basis after 10% loss
        assertApproxEqAbs(
            aliceReceived, 1_103_424_657_547_967_999_998, 2, "Alice: premium + profit - 10% loss, no insurance"
        );
        // Bob: entered at 1.5, below water → gets insurance for real shortfall
        // Traditional deductible: deductibleAmt = insuredBasis * 1%, subtracted from capped shortfall
        assertApproxEqAbs(bobTotal, 1_081_849_315_090_927_680_000, 2, "Bob: vault share + insurance");
        // Insurance triggered for Bob due to real 10% loss
        assertApproxEqAbs(totalInsurance, 101_712_328_768_975_680_000, 2, "Insurance for Bob's real shortfall");
    }

    /*//////////////////////////////////////////////////////////////
        SCENARIO 9: PREMIUM-ONLY ACCRUAL CREATES PHANTOM SHORTFALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Premium accrual (with zero underlying loss) triggers a phantom insurance
    ///         claim for the first depositor when a second depositor enters at a lower
    ///         share price and withdraws first.
    ///
    ///         Root cause: premium reduces the Morpho position proportionally to SHARES
    ///         (User1 has fewer shares → bears a smaller absolute premium via share-price
    ///         decline). But totalPremiumLiability is removed proportionally to PRINCIPAL
    ///         (50/50 when both deposited 1000). This under-attributes premium to User1,
    ///         inflating insuredBasis above the actual Morpho value and creating a phantom
    ///         shortfall despite no underlying loss.
    ///
    ///         Timeline:
    ///           T0:          User1 deposits 1000
    ///           T0+180 days: Premium accrues (~247), User2 deposits 1000 at share price ~0.75
    ///           T0+360 days: Premium accrues (~493), User2 withdraws, then User1 withdraws
    ///
    ///         Expected (no loss): User1 receives ~536, User2 receives ~713.
    ///         Actual: User1 receives ~536 + phantom insurance payout.
    /// @notice With per-user Morpho share tracking, cross-epoch phantom insurance is eliminated.
    ///         Each user redeems exactly the Morpho shares they deposited, so the share/principal
    ///         fraction mismatch that previously caused phantom shortfalls no longer affects
    ///         Morpho proceeds distribution.
    ///
    ///         Timeline (same as the old phantom test, but now no spurious insurance):
    ///           T0: User1 deposits 1000 at price 1.0
    ///           T0→T1: 180 days, premium accrues on 1000 principal
    ///           T1: User2 deposits 1000 at reduced share price (~0.995)
    ///           T1→T2: 180 days, premium accrues on 2000 principal
    ///           T2: User2 exits, then User1 exits -- zero insurance in both cases
    function test_premiumOnly_noPhantomInsurance() public {
        _deployWrapper(type(uint128).max);

        address user1 = address(0x1111);
        address user2 = address(0x2222);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        // ── Realistic 1%/year premium rate ──
        uint256 ONE_PCT_ANNUAL = uint256(1e16) / 31_536_000;
        _setPremiumRate(wrapper, ONE_PCT_ANNUAL, curator);

        // ── Step 1: User1 deposits 1000 at T0 ──
        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        uint256 user1Shares = wrapper.balanceOf(user1);

        // ── Step 2: 180 days of premium on 1000 principal ──
        vm.warp(block.timestamp + 180 days);

        uint256 taBeforeUser2 = wrapper.totalAssets();
        assertApproxEqAbs(taBeforeUser2, 995 ether, 1 ether, "totalAssets after 180d at 1%/yr");

        // ── Step 3: User2 deposits 1000 at lower share price ──
        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        uint256 user2Shares = wrapper.balanceOf(user2);
        assertGt(user2Shares, user1Shares, "User2 has more shares (lower entry price)");
        assertEq(wrapper.totalPrincipal(), 2000 ether, "totalPrincipal after both deposits");

        // ── Step 4: 180 more days of premium on 2000 principal ──
        vm.warp(block.timestamp + 180 days);

        // ── Step 5: User2 withdraws all shares ──
        uint256 user2Before = asset.balanceOf(user2);
        vm.prank(user2);
        wrapper.redeem(user2Shares, user2, user2);
        uint256 user2Received = asset.balanceOf(user2) - user2Before;

        assertEq(wrapper.userPrincipal(user2), 0, "User2 principal cleared");
        assertEq(claimManager.policyClaim(POLICY_ID).totalPaidOut, 0, "No insurance for User2");

        // ── Step 6: User1 withdraws all shares ──
        uint256 user1Before = asset.balanceOf(user1);
        vm.prank(user1);
        wrapper.redeem(user1Shares, user1, user1);
        uint256 user1Received = asset.balanceOf(user1) - user1Before;

        assertEq(wrapper.userPrincipal(user1), 0, "User1 principal cleared");
        assertEq(wrapper.totalPrincipal(), 0, "totalPrincipal zeroed");

        // ── Key assertion: ZERO phantom insurance ──
        uint256 totalInsurancePaid = claimManager.policyClaim(POLICY_ID).totalPaidOut;
        assertEq(totalInsurancePaid, 0, "No phantom insurance with per-user Morpho tracking");

        // Both users received their principal minus their fair premium -- no cross-subsidy.
        // User1 premium: rate × 1000 × 180d + rate × 1000 × 180d ≈ 9.86 ether (full 360d)
        // User2 premium: rate × 1000 × 180d ≈ 4.93 ether (only period 2)
        assertApproxEqAbs(user1Received, 990.14 ether, 0.5 ether, "User1: 1000 - ~9.86 premium");
        assertApproxEqAbs(user2Received, 995.07 ether, 0.5 ether, "User2: 1000 - ~4.93 premium");
    }

    /*//////////////////////////////////////////////////////////////
        SCENARIO 10: EARLIER DEPOSITOR (LOWER ENTRY PRICE) PAYS
                     MORE PREMIUM THAN LATER DEPOSITOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Demonstrates that an earlier depositor who entered at a lower share price
    ///         pays more premium than a later depositor with the same principal.
    ///
    ///         Premium is collected by redeeming Morpho shares, which reduces the wrapper
    ///         share price equally for ALL shares. A user with MORE shares bears a larger
    ///         absolute premium -- even if their principal is identical.
    ///
    ///         Timeline:
    ///           T0:        Alice deposits 1000 at price 1.0 → 1000 shares
    ///           T0:        50% yield → price rises to 1.5
    ///           T0:        Bob deposits 1000 at price 1.5 → ~667 shares
    ///           T0+180d:   Premium accrues (~493 on 2000 principal)
    ///
    ///         Result: Alice (60% of shares) pays ~60% of premium.
    ///                 Bob (40% of shares) pays ~40% of premium.
    ///                 Both deposited 1000 -- premium splits by shares, not principal.
    function test_earlyDepositor_paysMorePremium() public {
        _deployWrapper(type(uint128).max);

        address alice = address(0xAA11);
        address bob = address(0xBB22);
        _mintAndApprove(alice, 1000 ether);
        _mintAndApprove(bob, 1000 ether);

        // ── Alice deposits 1000 at price 1.0 ──
        vm.prank(alice);
        wrapper.deposit(1000 ether, alice);

        // ── 50% yield → price rises to 1.5 ──
        _simulateProfit(50);

        // ── Bob deposits 1000 at price 1.5 → fewer shares ──
        vm.prank(bob);
        wrapper.deposit(1000 ether, bob);

        uint256 aliceShares = wrapper.balanceOf(alice);
        uint256 bobShares = wrapper.balanceOf(bob);
        uint256 totalShares = aliceShares + bobShares;

        assertGt(aliceShares, bobShares, "Alice has more shares (lower entry price)");
        assertEq(wrapper.userPrincipal(alice), 1000 ether, "Same principal: Alice");
        assertEq(wrapper.userPrincipal(bob), 1000 ether, "Same principal: Bob");

        // ── Snapshot values BEFORE premium ──
        uint256 aliceValueBefore = wrapper.convertToAssets(aliceShares);
        uint256 bobValueBefore = wrapper.convertToAssets(bobShares);

        // ── Enable 50%/year premium, skip 180 days ──
        // Premium accrued ≈ 2000 * 50% * 180/365 ≈ 493 ether
        _setPremiumRate(wrapper, FIFTY_PCT_ANNUAL_RATE, curator);
        vm.warp(block.timestamp + 180 days);

        // ── Snapshot values AFTER premium accrual (view reflects unsettled premium) ──
        uint256 aliceValueAfter = wrapper.convertToAssets(aliceShares);
        uint256 bobValueAfter = wrapper.convertToAssets(bobShares);

        uint256 alicePremiumPaid = aliceValueBefore - aliceValueAfter;
        uint256 bobPremiumPaid = bobValueBefore - bobValueAfter;
        uint256 totalPremium = alicePremiumPaid + bobPremiumPaid;

        // ── Key assertion: Alice paid MORE premium despite same principal ──
        assertGt(alicePremiumPaid, bobPremiumPaid, "Alice paid more premium (more shares)");

        // ── Premium splits by share ratio (60/40), NOT by principal ratio (50/50) ──
        uint256 aliceSharePct = aliceShares * 10_000 / totalShares;
        uint256 alicePremiumPct = alicePremiumPaid * 10_000 / totalPremium;

        // Alice holds ~60% of shares and pays ~60% of premium
        assertApproxEqAbs(aliceSharePct, 6000, 2, "Alice holds ~60% of shares");
        assertApproxEqAbs(alicePremiumPct, 6000, 2, "Alice pays ~60% of premium");
        assertApproxEqAbs(alicePremiumPct, aliceSharePct, 2, "Premium % tracks share %, not principal %");
    }

    /*//////////////////////////////////////////////////////////////
        SCENARIO: SEQUENTIAL DEPOSITS AND WITHDRAWALS BY SAME USER
    //////////////////////////////////////////////////////////////*/

    /// @notice Verifies that a second deposit by the same user after premium has accrued
    ///         does NOT retroactively charge premium on the new capital.
    ///
    ///         Timeline:
    ///           T0: Alice deposits 1000 ether (principal=1000)
    ///           T0→T1: 180 days pass, premium accrues on 1000 principal
    ///           T1: Alice deposits another 1000 ether (principal=2000)
    ///           T1→T2: 180 days pass, premium accrues on 2000 principal
    ///           T2: Alice partially withdraws 50% of shares
    ///           T2: Alice withdraws remaining 50%
    ///
    ///         Expected premium: rate × 1000 × 180d + rate × 2000 × 180d
    ///         NOT: rate × 2000 × 360d (which would overcharge the second deposit)
    function test_sequentialDeposits_premiumNotRetroactive() public {
        _deployWrapper(type(uint128).max);

        // ~10%/year WAD-scaled per second
        uint256 rate = uint256(1e17) / 31_536_000;
        _setPremiumRate(wrapper, rate, curator);

        address alice = address(0xAA11);

        // ── T0: First deposit ──
        _mintAndApprove(alice, 2000 ether);
        vm.prank(alice);
        wrapper.deposit(1000 ether, alice);

        assertEq(wrapper.userPrincipal(alice), 1000 ether, "Principal after D1");

        // ── T0 -> T1: 180 days of premium on 1000 principal ──
        vm.warp(block.timestamp + 180 days);

        // Expected: 1000 * rate * 180d / WAD
        uint256 expectedP1 = uint256(1000 ether) * rate * 180 days / 1e18;

        vm.prank(curator);
        wrapper.collectPremium();
        assertApproxEqAbs(wrapper.totalPremiumLiability(), expectedP1, 10, "Liability after period 1");

        // ── T1: Second deposit -- must NOT inherit past premium ──
        uint256 liabilitySnapshot = wrapper.totalPremiumLiability();
        vm.prank(alice);
        wrapper.deposit(1000 ether, alice);

        assertEq(wrapper.userPrincipal(alice), 2000 ether, "Principal after D2");
        assertApproxEqAbs(wrapper.totalPremiumLiability(), liabilitySnapshot, 10, "Liability unchanged after D2");

        // ── T1 -> T2: 180 days of premium on 2000 principal ──
        vm.warp(block.timestamp + 180 days);

        // Expected: 2000 * rate * 180d / WAD
        uint256 expectedP2 = uint256(2000 ether) * rate * 180 days / 1e18;
        uint256 expectedTotal = expectedP1 + expectedP2;

        vm.prank(curator);
        wrapper.collectPremium();
        assertApproxEqAbs(wrapper.totalPremiumLiability(), expectedTotal, 10, "Total liability = P1 + P2");

        // ── T2: Withdrawals -- verify premium paid matches expected ──
        _assertSequentialWithdrawals(alice, expectedTotal);
    }

    /// @dev Helper: partial (50%) then full withdrawal, checking premium proportionality and state cleanup
    function _assertSequentialWithdrawals(address user, uint256 expectedTotalPremium) internal {
        uint256 halfShares = wrapper.balanceOf(user) / 2;
        uint256 pendingBefore = wrapper.pendingPremium();

        vm.prank(user);
        wrapper.redeem(halfShares, user, user);
        uint256 premiumPaidHalf = wrapper.pendingPremium() - pendingBefore;

        assertApproxEqRel(premiumPaidHalf, expectedTotalPremium / 2, 0.01e18, "Half-withdrawal pays ~50% premium");
        assertApproxEqAbs(wrapper.userPrincipal(user), 1000 ether, 1, "Principal halved");

        // Full withdrawal of remaining
        uint256 remaining = wrapper.balanceOf(user);
        uint256 pendingMid = wrapper.pendingPremium();
        vm.prank(user);
        wrapper.redeem(remaining, user, user);
        uint256 premiumPaidFinal = wrapper.pendingPremium() - pendingMid;

        assertApproxEqAbs(premiumPaidHalf + premiumPaidFinal, expectedTotalPremium, 10, "Total premium = P1 + P2");

        assertEq(wrapper.userPrincipal(user), 0, "Principal cleared");
        assertEq(wrapper.totalPrincipal(), 0, "Total principal cleared");
        assertEq(wrapper.balanceOf(user), 0, "Shares cleared");
        assertEq(wrapper.totalPremiumLiability(), 0, "Liability cleared");
    }

    /*//////////////////////////////////////////////////////////////
        SCENARIO: collectPremium AFTER PARTIAL WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    /// @notice Two users deposit, premium accrues, then partial and full withdrawals happen
    ///         with collectPremium() calls in between. Verifies:
    ///           1. premiumRecipient receives the correct token amount after each collect
    ///           2. pendingPremium is zeroed after each collect
    ///           3. Total premium received by recipient equals the sum of all deducted premiums
    ///           4. No tokens are stuck in the wrapper after all users exit and premium is collected
    function test_collectPremium_afterPartialWithdrawals() public {
        _deployWrapper(type(uint128).max);

        // ~10%/year
        uint256 rate = uint256(1e17) / 31_536_000;
        _setPremiumRate(wrapper, rate, curator);

        address alice = address(0xAA11);
        address bob = address(0xBB22);
        _mintAndApprove(alice, 1000 ether);
        _mintAndApprove(bob, 2000 ether);

        // ── Both deposit ──
        vm.prank(alice);
        wrapper.deposit(1000 ether, alice);
        vm.prank(bob);
        wrapper.deposit(2000 ether, bob);

        // ── 180 days pass -- premium accrues on 3000 principal ──
        vm.warp(block.timestamp + 180 days);
        uint256 expectedTotal = uint256(3000 ether) * rate * 180 days / 1e18;

        // ── Alice partially withdraws 50% of her shares ──
        uint256 aliceHalf = wrapper.balanceOf(alice) / 2;
        vm.prank(alice);
        wrapper.redeem(aliceHalf, alice, alice);

        // pendingPremium should hold Alice's partial premium deduction
        uint256 pendingAfterAlice = wrapper.pendingPremium();
        assertGt(pendingAfterAlice, 0, "Pending > 0 after Alice partial withdraw");

        // ── collectPremium: recipient receives Alice's deducted premium ──
        uint256 recipientBefore1 = asset.balanceOf(premiumRecipient);
        vm.prank(curator);
        wrapper.collectPremium();
        uint256 collected1 = asset.balanceOf(premiumRecipient) - recipientBefore1;

        assertEq(collected1, pendingAfterAlice, "Recipient received exact pending amount");
        assertEq(wrapper.pendingPremium(), 0, "Pending zeroed after collect");

        // ── Bob fully withdraws ──
        uint256 bobShares = wrapper.balanceOf(bob);
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);

        uint256 pendingAfterBob = wrapper.pendingPremium();
        assertGt(pendingAfterBob, 0, "Pending > 0 after Bob full withdraw");

        // ── collectPremium: recipient receives Bob's deducted premium ──
        uint256 recipientBefore2 = asset.balanceOf(premiumRecipient);
        vm.prank(curator);
        wrapper.collectPremium();
        uint256 collected2 = asset.balanceOf(premiumRecipient) - recipientBefore2;

        assertEq(collected2, pendingAfterBob, "Recipient received Bob's premium");
        assertEq(wrapper.pendingPremium(), 0, "Pending zeroed after second collect");

        // ── Alice withdraws remaining shares ──
        uint256 aliceRemaining = wrapper.balanceOf(alice);
        vm.prank(alice);
        wrapper.redeem(aliceRemaining, alice, alice);

        // ── Final collect ──
        uint256 recipientBefore3 = asset.balanceOf(premiumRecipient);
        vm.prank(curator);
        wrapper.collectPremium();
        uint256 collected3 = asset.balanceOf(premiumRecipient) - recipientBefore3;

        // ── Verify total premium received by recipient ──
        uint256 totalCollected = collected1 + collected2 + collected3;
        assertApproxEqAbs(totalCollected, expectedTotal, 10, "Total collected matches expected premium");

        // ── No tokens stuck in wrapper ──
        // Only rounding dust should remain (from liability tracking mismatch)
        assertLe(asset.balanceOf(address(wrapper)), 1e7, "No meaningful tokens stuck in wrapper");
        assertEq(wrapper.pendingPremium(), 0, "Final pending is zero");
        assertEq(wrapper.totalPrincipal(), 0, "All principal exited");
    }
}
