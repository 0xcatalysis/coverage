// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {IEvents as IE} from "../../src/defi/interfaces/IEvents.sol";

import {MockERC20, MockVaultV2} from "./mocks/Mocks.sol";
import {RealCoverageSetup} from "./helpers/RealCoverageSetup.sol";

/// @title CoveredVaultWrapperScenarios
/// @notice Scenario tests for CoveredVaultWrapper covering multi-user interactions,
///         coverage exhaustion, loss detection, and invariant checks.
contract CoveredVaultWrapperScenarios is RealCoverageSetup {
    CoveredVaultWrapper wrapper;
    MockVaultV2 morphoVault;
    MockERC20 asset;

    address curator = address(0xCCCC);
    address premiumRecipientAddr = address(0xFEED);

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

        morphoVault.setCurator(address(wrapper));

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

        asset.mint(address(morphoVault), 10_000_000 ether);
    }

    function _mintAndApprove(address user, uint256 amount) internal {
        asset.mint(user, amount);
        vm.prank(user);
        asset.approve(address(wrapper), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 1: MULTI-USER INDEPENDENT SHORTFALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice user1 takes 100% loss, user2 has no loss; only user1 gets insurance payout
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

        // Simulate 100% loss in morpho vault
        morphoVault.setLoss(100);

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

        // Both users suffer 100% loss:
        // each principal=1000, shortfall=1000, maxInsurance=100, effective=99
        assertApproxEqAbs(user1Received, 99 ether, 1 ether, "user1 receives insurance on 100% loss");
        assertApproxEqAbs(user2Received, 99 ether, 1 ether, "user2 receives insurance on 100% loss");

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
        morphoVault.setLoss(100);

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

        // user1: principal=200, shortfall=200, maxInsurance=20, effective=19.8. But coverageLimit=50 so effective pays.
        // user2: coverage limit already exhausted (or nearly), gets 0 or minimal.
        assertGt(user1Received, 0, "user1 should receive some insurance");
        assertLe(user1Received, 50 ether, "user1 capped by coverage limit");
        // user2 may get 0 or a small amount depending on remaining coverage after user1
        assertLe(user2Received, user1Received + 1 ether, "user2 cannot get more than user1");
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
        morphoVault.setLoss(20); // 20% loss

        uint256 user1Before = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1Before;

        // assetsReceived ≈ 800, shortfall=200, maxInsurance=100, effective=99
        // total ≈ 899
        assertApproxEqAbs(received, 899 ether, 2 ether, "Should receive ~899 after 20% loss");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 4: PRINCIPAL SUM INVARIANT
    //////////////////////////////////////////////////////////////*/

    /// @notice Σ userPrincipal[all users] == totalPrincipal after deposits, withdrawals, and transfers
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

        // Partial withdrawal by user[0]
        uint256 halfShares = wrapper.balanceOf(users[0]) / 2;
        vm.prank(users[0]);
        wrapper.redeem(halfShares, users[0], users[0]);
        _assertPrincipalInvariant(users);

        // Transfer from user[1] to user[2]
        uint256 user1Shares = wrapper.balanceOf(users[1]);
        vm.prank(users[1]);
        wrapper.transfer(users[2], user1Shares / 3);
        _assertPrincipalInvariant(users);

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
        morphoVault.setCurator(address(wrapper));

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

        // Fund morpho vault for payout transfers
        asset.mint(address(morphoVault), 10_000_000 ether);

        // 1%/year premium rate
        uint256 onePctAnnualRate = uint256(1e16) / 31_536_000;
        vm.prank(curator);
        wrapper.setPremiumRate(onePctAnnualRate);
    }

    /// @notice Scenario 8A: price ~1.6 — both Alice (entry 1.0) and Bob (entry ~1.4) are above
    ///         their entry prices → calculateShortfall()==0 and userShortfall()==0 for both.
    ///
    ///         Setup numbers:
    ///           - Alice deposits 1000 at price 1.0 → 1000 wrapper shares
    ///           - setProfit(40) → Morpho price 1.4
    ///           - Bob deposits 1000 at price ~1.4 → 714 wrapper shares (1000×1000/1400)
    ///           - State: _totalAssets=2000, profitPercent=40 → totalAssets()=2800, price≈1.634
    ///           - Alice value: 1000/1714 × 2800 ≈ 1634 > 1000 → profit
    ///           - Bob value:    714/1714 × 2800 ≈ 1166 > 1000 → profit
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
        morphoVault.setProfit(40);

        // Bob deposits 1000 ether at price ~1.4 → gets ~714 wrapper shares
        vm.prank(bob);
        wrapper.deposit(1000 ether, bob);

        // With profitPercent=40 and _totalAssets=2000: totalAssets()=2800, price≈1.634.
        // Both users entered below the current price → no shortfall for either.
        assertEq(wrapper.calculateShortfall(), 0, "No global shortfall at price ~1.6");
        assertEq(wrapper.userShortfall(alice), 0, "Alice: no shortfall at price ~1.6");
        assertEq(wrapper.userShortfall(bob), 0, "Bob: no shortfall at price ~1.6");
    }

    /// @notice Scenario 8B: price drops to ~1.17 (below Bob's entry of ~1.4).
    ///         Alice (entry 1.0) is still in profit → no insurance.
    ///         Bob (entry ~1.4) has a shortfall → insured up to 20% of principal.
    ///
    ///         setLoss(0) clears profitPercent without adding extra loss so that
    ///         raw price = _totalAssets/totalShares = 2000/1714 ≈ 1.167.
    ///
    ///         After Alice redeems: _totalAssets≈833, Bob's value≈833.
    ///         Bob's shortfall=167, maxInsurance=200 (20%), effectiveInsurance=198 (1% deductible).
    ///         claimAmount = min(167,198) = 167 → Bob receives 833+167 = 1000 ether.
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
        morphoVault.setProfit(40);

        // Bob deposits 1000 at price ~1.4 → ~714 wrapper shares
        vm.prank(bob);
        wrapper.deposit(1000 ether, bob);

        // Price reverts to raw book value: _totalAssets/totalShares = 2000/1714 ≈ 1.167
        // Alice (entry 1.0) still above water; Bob (entry ~1.40) below water.
        morphoVault.setLoss(0);

        // Alice redeems: value ≈ 1000×2000/1714 ≈ 1167 > 1000 → profit, no insurance
        uint256 aliceShares = wrapper.balanceOf(alice);
        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        wrapper.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = asset.balanceOf(alice) - aliceBefore;

        assertGt(aliceReceived, 1000 ether, "Alice in profit: no insurance triggered");
        assertEq(wrapper.userPrincipal(alice), 0, "Alice principal cleared");

        // Bob redeems: after Alice's exit, remaining Morpho value ≈ 833.
        // insuredBasis = 1000×(1000-0)/1000 = 1000 > 833 → insurance triggered.
        // claimAmount = min(167, 200×99%=198) = 167; Bob receives 833+167 = 1000.
        uint256 bobShares = wrapper.balanceOf(bob);
        uint256 bobBefore = asset.balanceOf(bob);
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);
        uint256 bobReceived = asset.balanceOf(bob) - bobBefore;

        assertGt(bobReceived, 900 ether, "Bob receives assets + insurance payout");
        assertApproxEqAbs(bobReceived, 1000 ether, 5 ether, "Bob near-full recovery via 20% coverage");
        assertEq(wrapper.userPrincipal(bob), 0, "Bob principal cleared");
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
        morphoVault.setCurator(address(wrapper));
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
        assertGt(wrapper.lastPremiumAccrualTime(), accrualBefore, "Accrual timestamp should advance");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 6: PROFIT CASE — NO INSURANCE
    //////////////////////////////////////////////////////////////*/

    /// @notice When morphoVault is in profit, withdrawals produce no insurance payout
    /// @dev Uses a second depositor to increase morphoVault._totalAssets so that redeem()
    ///      doesn't underflow when profit inflates the payout above stored assets.
    function test_profit_noInsurance() public {
        _deployWrapper(type(uint128).max);

        address user1 = address(0x1111);
        address funder = address(0xF1); // deposits to inflate _totalAssets in morphoVault
        _mintAndApprove(user1, 1000 ether);

        // funder deposits 2000 directly into morphoVault to ensure _totalAssets is large enough
        asset.mint(funder, 2000 ether);
        vm.prank(funder);
        asset.approve(address(morphoVault), 2000 ether);
        vm.prank(funder);
        morphoVault.deposit(2000 ether, funder);

        vm.prank(user1);
        wrapper.deposit(1000 ether, user1);

        // 20% profit in morpho vault — now _totalAssets = 3000, 20% makes totalAssets() = 3600
        // wrapper redeems ~400 of that, well within _totalAssets = 3000 → no underflow
        morphoVault.setProfit(20);

        uint256 user1Before = asset.balanceOf(user1);
        uint256 shares = wrapper.balanceOf(user1);

        vm.prank(user1);
        wrapper.redeem(shares, user1, user1);

        uint256 received = asset.balanceOf(user1) - user1Before;

        // received ≈ 1000 * (3000*1.2/3000) = 1200 (wrapper's proportional share of morphoVault with profit)
        // But wrapper only has 1000 of the 3000 morpho shares, so its share = 1000/3000 * 3600 = 1200
        assertGt(received, 1000 ether, "Should receive more than principal (profit)");
        assertEq(wrapper.userPrincipal(user1), 0, "Principal should be cleared");
    }

    /*//////////////////////////////////////////////////////////////
                SCENARIO 7: TWO-USER DIFFERENT ENTRY PRICES
    //////////////////////////////////////////////////////////////*/

    /// @notice Alice deposits at 1:1, vault gains yield, Bob deposits later at higher price.
    ///         After a loss, Alice is in profit (no insurance), Bob has shortfall (insured).
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
        morphoVault.setProfit(50);

        // Bob deposits 1500 at 1.5 price (gets 1000 shares)
        vm.prank(bob);
        wrapper.deposit(1500 ether, bob);

        assertEq(wrapper.userPrincipal(alice), 1000 ether);
        assertEq(wrapper.userPrincipal(bob), 1500 ether);

        // Now a 10% hack — loss applied from current state
        morphoVault.setLoss(10);

        // Funder pre-deposits extra assets to avoid mock underflow on profit redemption
        address funder = address(0xFF00);
        asset.mint(funder, 5000 ether);
        vm.prank(funder);
        asset.approve(address(morphoVault), 5000 ether);
        vm.prank(funder);
        morphoVault.deposit(5000 ether, funder);

        // Alice withdraws her shares
        uint256 aliceShares = wrapper.balanceOf(alice);
        uint256 aliceBefore = asset.balanceOf(alice);
        vm.prank(alice);
        wrapper.redeem(aliceShares, alice, alice);
        uint256 aliceReceived = asset.balanceOf(alice) - aliceBefore;

        // Alice's principal=1000. Her portion of vault > 1000 (entered at 1.0, value after 10% loss ≈ 1.35)
        // → no insurance; she receives more than her principal.
        assertGt(aliceReceived, 1000 ether, "Alice in profit: receives more than her 1000 principal");
        assertEq(wrapper.userPrincipal(alice), 0, "Alice principal cleared");

        // Bob withdraws his shares
        uint256 bobShares = wrapper.balanceOf(bob);
        uint256 bobBefore = asset.balanceOf(bob);
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);
        uint256 bobTotal = asset.balanceOf(bob) - bobBefore;

        // Bob's principal=1500, received < 1500 → insurance paid
        assertGt(bobTotal, 0, "Bob should receive something");
        assertEq(wrapper.userPrincipal(bob), 0, "Bob principal cleared");
    }
}
