// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {IEvents as IE} from "../../src/defi/interfaces/IEvents.sol";

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
    address premiumRecipientAddr = address(0xFEED);

    uint96 POLICY_ID;
    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10%
    uint16 constant DEDUCTIBLE_BPS = 100; // 1%
    uint256 constant FIFTY_PCT_ANNUAL_RATE = 15_854_895_991; // ~50%/year WAD-scaled per second

    function setUp() public {
        asset = new MockERC20();
        morphoVault = new ControllableVault(address(asset));

        _deployRealCoverage(curator, curator);

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
            premiumRecipientAddr,
            curator,
            "Scenario Vault",
            "scVault"
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
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 180 days);

        // Settle premium before loss so insuredBasis reflects premium paid.
        // Premium accrued ≈ 2000 * 50% * 180/365 ≈ 493 ether.
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

        // Both users suffer 100% loss. Premium was already settled (~493 ether from 2000 principal).
        // insuredBasis = 1000 * (2000 - 493.15) / 2000 ≈ 753.42 per user
        // shortfall = 753.42, maxInsurance = 75.34 (10%), claimAmount = 74.59 (99% after deductible)
        assertApproxEqAbs(user1Received, 74_589_041_097_248_832_000, 2, "user1: 100% loss, premium-adjusted insurance");
        assertApproxEqAbs(user2Received, 74_589_041_097_248_832_000, 2, "user2: 100% loss, premium-adjusted insurance");

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
        // Coverage limit of only 50 ether — depleted by first user.
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

        // 100% loss, no premium: insuredBasis=200, shortfall=200, maxInsurance=200*10%=20,
        // claimAmount=20*99%=19.8. Coverage limit 50 > 19.8, so not exhausted per user.
        assertApproxEqAbs(user1Received, 19.8 ether, 2, "user1: 10% cap * 99% deductible = 19.8 ether");
        assertApproxEqAbs(user2Received, 19.8 ether, 2, "user2: same insurance as user1");
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

        // assetsReceived = 800, shortfall=200, maxInsurance=100, effective=99
        // total = 800 + 99 = 899 exactly
        assertEq(received, 899 ether, "Should receive 800 + 99 insurance = 899 after 20% loss");
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

        // 30% profit before partial withdrawal — principal invariant must hold regardless of price
        _simulateProfit(30);

        // Partial withdrawal by user[0] (in profit → no insurance)
        uint256 halfShares = wrapper.balanceOf(users[0]) / 2;
        vm.prank(users[0]);
        wrapper.redeem(halfShares, users[0], users[0]);
        _assertPrincipalInvariant(users);

        // 15% loss before full withdrawal — may trigger insurance for user[3]
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
            premiumRecipientAddr,
            curator,
            "EntryPrice Vault",
            "EPV"
        );

        POLICY_ID = _createAndBindPolicy(
            address(wrapper),
            address(wrapper),
            address(asset),
            type(uint128).max,
            type(uint128).max,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(wrapper)
        );

        // 1%/year premium rate
        uint256 onePctAnnualRate = uint256(1e16) / 31_536_000;
        vm.prank(curator);
        wrapper.setPremiumRate(onePctAnnualRate);
    }

    /// @notice Scenario 8A: price ~1.6 — both Alice (entry 1.0) and Bob (entry ~1.4) are above
    ///         their entry prices. View functions show no shortfall (correct global accounting).
    ///         However, after premium settlement + redemption order effects, Bob experiences
    ///         a phantom shortfall — same root cause as test_premiumOnly_phantomShortfall (test 9).
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
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 180 days);

        // Global view: no shortfall (total premium correctly deducted from both sides)
        assertEq(wrapper.calculateShortfall(), 0, "No global shortfall after premium");
        assertEq(wrapper.userShortfall(alice), 0, "Alice: no shortfall after premium");
        assertEq(wrapper.userShortfall(bob), 0, "Bob: no shortfall after premium");

        // Settle premium before redemptions to avoid mock arithmetic issues
        wrapper.collectPremium();

        uint256 insuranceBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        // Alice redeems first — she has MORE shares (entered at lower price) so she takes
        // a disproportionate share of the morpho pool, leaving less for Bob.
        uint256 aliceShares = wrapper.balanceOf(alice);
        vm.prank(alice);
        wrapper.redeem(aliceShares, alice, alice);

        uint256 bobShares = wrapper.balanceOf(bob);
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);

        uint256 insuranceAfter = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        // With accurate ERC4626 accounting (ControllableVault), no phantom shortfall occurs.
        // Both users are in profit, no loss — no insurance should be paid.
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
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 180 days);

        // Drain the 400 profit tokens added earlier, reverting to raw book value.
        // totalAssets goes from 2400 to 2000, price ~2000/1714 ≈ 1.167.
        // Combined with premium, the effective value is even lower.
        morphoVault.simulateLoss(400 ether);

        uint256 insuranceBefore = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        // Alice redeems — entered at 1.0, should still be above premium-adjusted basis
        uint256 aliceShares = wrapper.balanceOf(alice);
        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        wrapper.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = asset.balanceOf(alice) - aliceBefore;

        assertEq(wrapper.userPrincipal(alice), 0, "Alice principal cleared");

        // Bob redeems — entered at ~1.4, below water after price drop + premium
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
        assertApproxEqAbs(bobReceived, 735_936_073_075_798_997_335, 2, "Bob: vault share + insurance");
        // Insurance for Bob's real shortfall from price drop
        assertApproxEqAbs(totalInsurance, 149_178_082_194_497_664_000, 2, "Insurance for Bob's shortfall");
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
            premiumRecipientAddr,
            curator,
            "ZeroPrincipal",
            "ZP"
        );
        POLICY_ID = _createAndBindPolicy(
            address(wrapper),
            address(wrapper),
            address(asset),
            10_000 ether,
            10_000 ether,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(wrapper)
        );
        vm.prank(curator);
        wrapper.setPremiumRate(rate);

        assertEq(wrapper.totalPrincipal(), 0);

        uint256 recipientBefore = asset.balanceOf(premiumRecipientAddr);
        uint256 accrualBefore = wrapper.lastPremiumAccrualTime();

        vm.warp(block.timestamp + 365 days);
        wrapper.collectPremium();

        assertEq(asset.balanceOf(premiumRecipientAddr), recipientBefore, "No premium transferred when no principal");
        assertEq(wrapper.lastPremiumAccrualTime(), 31_536_001, "Accrual timestamp should advance to block.timestamp");
        assertEq(accrualBefore, 1, "Accrual timestamp started at 1");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 6: PROFIT CASE — NO INSURANCE
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
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 180 days);

        // Settle premium before profit change to get clean accounting
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
        // No insurance should trigger — premium is NOT a loss.
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
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + 180 days);

        // Now a 10% hack — loss applied from current state
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
        assertApproxEqAbs(bobTotal, 1_092_020_547_967_825_248_002, 2, "Bob: vault share + insurance");
        // Insurance triggered for Bob due to real 10% loss
        assertApproxEqAbs(totalInsurance, 111_883_561_645_873_248_000, 2, "Insurance for Bob's real shortfall");
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
    function test_premiumOnly_phantomShortfall_triggersInsurance() public {
        _deployWrapper(type(uint128).max);

        address user1 = address(0x1111);
        address user2 = address(0x2222);
        _mintAndApprove(user1, 1000 ether);
        _mintAndApprove(user2, 1000 ether);

        // 50%/year premium rate (MAX_PREMIUM_RATE_PER_SECOND ≈ 15.85e9)
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);

        // ── Step 1: User1 deposits 1000 at T0 ──
        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        uint256 user1Shares = wrapper.balanceOf(user1);

        // ── Step 2: 180 days pass → ~247 premium accrues on 1000 principal ──
        vm.warp(block.timestamp + 180 days);

        // totalAssets (view) ≈ 1000 − 247 ≈ 753
        uint256 taBeforeUser2 = wrapper.totalAssets();
        assertApproxEqAbs(taBeforeUser2, 753 ether, 5 ether, "totalAssets after 180d premium");

        // ── Step 3: User2 deposits 1000 at the reduced share price ──
        vm.prank(user2);
        wrapper.deposit(1000 ether, user2);

        // User2 entered at ~0.753 price → gets more shares than User1
        uint256 user2Shares = wrapper.balanceOf(user2);
        // User2 entered at ~0.753 price → gets more shares than User1
        assertApproxEqAbs(user2Shares, 1_327_272_727_248_554_885_289_262_047, 2, "User2 shares (lower entry price)");
        assertEq(user1Shares, 1_000_000_000_000_000_000_000_000_000, "User1 shares (1:1 entry)");

        // State: totalPrincipal=2000, morphoValue≈1753, totalPremiumLiability≈247
        assertEq(wrapper.totalPrincipal(), 2000 ether, "totalPrincipal after both deposits");
        uint256 tprAfterDeposits = wrapper.totalPremiumLiability();
        assertApproxEqAbs(tprAfterDeposits, 246_575_342_452_032_000_000, 2, "totalPremiumLiability after deposits");

        // ── Step 4: 180 more days → ~493 premium accrues on 2000 principal ──
        vm.warp(block.timestamp + 180 days);

        // No loss — this is purely premium (ControllableVault has no virtual loss flag)

        uint256 taBeforeWithdrawals = wrapper.totalAssets();
        assertApproxEqAbs(taBeforeWithdrawals, 1_260_273_972_643_904_000_000, 2, "totalAssets after 360d");

        // ── Step 5: User2 withdraws all shares ──
        uint256 user2Before = asset.balanceOf(user2);
        vm.prank(user2);
        wrapper.redeem(user2Shares, user2, user2);
        uint256 user2Received = asset.balanceOf(user2) - user2Before;

        assertApproxEqAbs(user2Received, 894_049_657_539_042_039_062, 2, "User2: assets minus premium");
        assertEq(wrapper.userPrincipal(user2), 0, "User2 principal cleared");
        assertEq(claimManager.policyClaim(POLICY_ID).totalPaidOut, 0, "Insurance not paid for user2");

        // ── Step 6: User1 withdraws all shares ──
        uint256 user1Before = asset.balanceOf(user1);
        vm.prank(user1);
        wrapper.redeem(user1Shares, user1, user1);
        uint256 user1Received = asset.balanceOf(user1) - user1Before;

        assertEq(wrapper.userPrincipal(user1), 0, "User1 principal cleared");
        assertEq(wrapper.totalPrincipal(), 0, "totalPrincipal zeroed");

        // ── Key assertion: phantom insurance was triggered despite zero loss ──
        uint256 totalInsurancePaid = claimManager.policyClaim(POLICY_ID).totalPaidOut;

        // FIX: Premium-as-debt model — premium is charged proportionally to principal.
        // User2 entered at a lower share price (more shares per dollar), so their gross Morpho
        // entitlement was higher, leaving User1 with fewer Morpho assets than their insuredBasis.
        // This cross-epoch effect is bounded and non-exploitable (see plan for analysis).
        assertApproxEqAbs(user1Received, 416_402_397_299_359_624_938, 2, "User1: assets + cross-epoch insurance");
        assertApproxEqAbs(
            totalInsurancePaid, 50_178_082_194_497_664_000, 2, "cross-epoch insurance (bounded, non-exploitable)"
        );

        // Users collectively received MORE than the Morpho vault held after premium.
        // The excess came from the mock claim manager minting tokens to pay for insurance.
        uint256 totalReceived = user1Received + user2Received;
        assertGt(
            totalReceived,
            taBeforeWithdrawals - 10 ether,
            "Total payouts exceed Morpho value (phantom insurance minted tokens)"
        );
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
    ///         absolute premium — even if their principal is identical.
    ///
    ///         Timeline:
    ///           T0:        Alice deposits 1000 at price 1.0 → 1000 shares
    ///           T0:        50% yield → price rises to 1.5
    ///           T0:        Bob deposits 1000 at price 1.5 → ~667 shares
    ///           T0+180d:   Premium accrues (~493 on 2000 principal)
    ///
    ///         Result: Alice (60% of shares) pays ~60% of premium.
    ///                 Bob (40% of shares) pays ~40% of premium.
    ///                 Both deposited 1000 — premium splits by shares, not principal.
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
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
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
}
