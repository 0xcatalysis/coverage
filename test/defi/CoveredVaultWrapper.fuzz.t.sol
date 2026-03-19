// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";

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
    ) public {
        // ── Setup: deploy wrapper with fuzzed coverage limit ──
        coverageLimit = bound(coverageLimit, 100 ether, 100_000 ether);
        uint256 cap = (coverageLimit * 10_000) / uint256(MAX_COVERABLE_LOSS_BPS);

        _deployWrapperWithCap(coverageLimit);
        assertEq(wrapper.depositCap(), cap, "depositCap matches coverage math");

        // Bound deposits (each individually could fill the cap)
        deposit1 = bound(deposit1, 1 ether, cap);
        deposit2 = bound(deposit2, 1 ether, cap);
        deposit3 = bound(deposit3, 1 ether, cap);

        // Bound price changes — losses capped at 90% to avoid zero-totalAssets edge
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
    /// @dev MAX_PREMIUM_RATE_PER_SECOND in the wrapper — equals ~50%/year WAD-scaled
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
    ) public {
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
        vm.prank(curator);
        wrapper.setPremiumRate(rate1);
        vm.warp(block.timestamp + duration1);

        // ── Period 2 (setPremiumRate settles period 1) ──
        vm.prank(curator);
        wrapper.setPremiumRate(rate2);
        vm.warp(block.timestamp + duration2);

        // ── Period 3 (setPremiumRate settles period 2) ──
        vm.prank(curator);
        wrapper.setPremiumRate(rate3);
        vm.warp(block.timestamp + duration3);

        // ── Settle final period ──
        wrapper.collectPremium();

        // totalPremiumRedeemed should match the sum of per-period calculations
        assertApproxEqAbs(
            wrapper.totalPremiumRedeemed(),
            expectedTotal,
            10, // ≤10 wei tolerance for Morpho share rounding across 3 redemptions
            "Total premium must equal sum(principal * rate_i * duration_i / WAD)"
        );

        // Cross-check: morpho position should equal deposit minus premium
        uint256 morphoValue = morphoVault.totalAssets();
        // morphoVault.totalAssets() only reflects the wrapper's position (sole depositor)
        // pendingPremium sits in the wrapper as ERC20, not in morpho
        assertApproxEqAbs(
            morphoValue + wrapper.totalPremiumRedeemed(),
            principal,
            10,
            "morphoValue + premium == original deposit (conservation of assets)"
        );
    }

    /// @dev Mirrors the contract's _accruedPremium() calculation
    function _expectedPremium(uint256 principal_, uint256 rate, uint256 duration) internal pure returns (uint256) {
        return principal_ * rate * duration / WAD;
    }

    /// @notice Fuzz test: premium should be distributed proportionally to principal.
    ///
    ///         The INTENDED behavior is that two users with equal principal pay equal
    ///         premium, regardless of their entry share price. However, premium is
    ///         currently collected by redeeming Morpho shares (reducing the share price),
    ///         which distributes premium proportionally to SHARES, not to PRINCIPAL.
    ///
    ///         When users enter at different prices they hold different share counts for
    ///         the same principal. The user with more shares (lower entry price) absorbs
    ///         more premium through the share-price decline.
    ///
    ///         This test is expected to FAIL — confirming the known issue. A fix will be
    ///         issued later to make premium distribution principal-proportional.
    function testFuzz_premiumAccrual_shouldBeProportionalToPrincipal(
        uint256 deposit,
        uint256 yieldPct,
        uint256 premiumDays
    ) public {
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

        // ── Snapshot values BEFORE premium ──
        uint256 aliceValueBefore = wrapper.convertToAssets(aliceShares);
        uint256 bobValueBefore = wrapper.convertToAssets(bobShares);

        // ── Enable premium and let time pass ──
        vm.prank(curator);
        wrapper.setPremiumRate(FIFTY_PCT_ANNUAL_RATE);
        vm.warp(block.timestamp + premiumDays * 1 days);

        // ── Snapshot values AFTER premium accrual ──
        uint256 aliceValueAfter = wrapper.convertToAssets(aliceShares);
        uint256 bobValueAfter = wrapper.convertToAssets(bobShares);

        uint256 alicePremiumPaid = aliceValueBefore - aliceValueAfter;
        uint256 bobPremiumPaid = bobValueBefore - bobValueAfter;

        // ── INTENDED invariant: equal principal → equal premium ──
        // Allow 0.1% relative tolerance for rounding
        assertApproxEqRel(
            alicePremiumPaid,
            bobPremiumPaid,
            0.001e18,
            "KNOWN ISSUE: premium distributed by shares, not principal"
        );
    }

    /*//////////////////////////////////////////////////////////////
                   TRANSFER INVARIANT FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: share transfers preserve principal accounting and transferred
    ///         principal determines insurance payout on withdrawal after a loss.
    ///
    ///         Invariants:
    ///           1. totalPrincipal unchanged after transfer
    ///           2. Σ userPrincipal == totalPrincipal after transfer
    ///           3. After a loss, the receiver gets insurance based on their NEW principal
    ///              (original + transferred portion), not their original deposit
    function testFuzz_transfer_principalInvariants_and_insurance(
        uint256 deposit1,
        uint256 deposit2,
        uint256 transferPct,
        uint256 lossPct
    ) public {
        uint96 policyId = _deployWrapperWithCap(type(uint128).max);

        deposit1 = bound(deposit1, 10 ether, 1_000_000 ether);
        deposit2 = bound(deposit2, 10 ether, 1_000_000 ether);
        transferPct = bound(transferPct, 1, 99); // 1-99% of sender's shares
        lossPct = bound(lossPct, 20, 80); // 20-80% loss to ensure shortfall

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

        // ── Alice transfers a portion of her shares to Bob ──
        _transferAndAssertInvariants(alice, bob, transferPct, totalPrincipalBefore);

        // Cache post-transfer principals for insurance assertions
        uint256 bobPrincipalAfter = wrapper.userPrincipal(bob);
        uint256 alicePrincipalAfter = wrapper.userPrincipal(alice);

        // ── Simulate loss → both users should have shortfall ──
        _simulateLoss(lossPct);

        // ── Withdraw both and verify insurance is based on post-transfer principal ──
        _withdrawAndAssertInsurance(alice, bob, policyId, alicePrincipalAfter, bobPrincipalAfter);
    }

    function _transferAndAssertInvariants(
        address from,
        address to,
        uint256 transferPct,
        uint256 expectedTotal
    ) internal {
        uint256 fromPrincipalBefore = wrapper.userPrincipal(from);
        uint256 toPrincipalBefore = wrapper.userPrincipal(to);
        uint256 fromShares = wrapper.balanceOf(from);
        uint256 sharesToTransfer = fromShares * transferPct / 100;
        uint256 expectedPrincipalMoved = fromPrincipalBefore * sharesToTransfer / fromShares;

        vm.prank(from);
        wrapper.transfer(to, sharesToTransfer);

        // Invariant 1: totalPrincipal unchanged
        assertEq(wrapper.totalPrincipal(), expectedTotal, "totalPrincipal unchanged after transfer");

        // Invariant 2: sum of principals == totalPrincipal
        assertEq(
            wrapper.userPrincipal(from) + wrapper.userPrincipal(to),
            expectedTotal,
            "sum == total after transfer"
        );

        // Verify principal migrated correctly
        assertEq(wrapper.userPrincipal(from), fromPrincipalBefore - expectedPrincipalMoved, "Sender principal decreased");
        assertEq(wrapper.userPrincipal(to), toPrincipalBefore + expectedPrincipalMoved, "Receiver principal increased");
    }

    function _withdrawAndAssertInsurance(
        address alice,
        address bob,
        uint96 policyId,
        uint256 alicePrincipal,
        uint256 bobPrincipal
    ) internal {
        uint256 insuranceBefore = claimManager.policyClaim(policyId).totalPaidOut;

        // ── Bob withdraws — insurance based on his NEW (inflated) principal ──
        uint256 bobShares = wrapper.balanceOf(bob);
        uint256 bobBalBefore = asset.balanceOf(bob);
        vm.prank(bob);
        wrapper.redeem(bobShares, bob, bob);

        uint256 bobInsurance = claimManager.policyClaim(policyId).totalPaidOut - insuranceBefore;
        assertGt(bobInsurance, 0, "Bob receives insurance based on new principal");
        assertGt(asset.balanceOf(bob) - bobBalBefore, 0, "Bob received assets");

        // Bob's insurance bounded by his post-transfer principal cap
        // insuredBasis ≈ principal (no premium), maxInsurance = insuredBasis * 10%
        assertLe(bobInsurance, bobPrincipal * MAX_COVERABLE_LOSS_BPS / 10_000, "Bob insurance bounded by cap");

        uint256 insuranceAfterBob = claimManager.policyClaim(policyId).totalPaidOut;

        // ── Alice withdraws ──
        uint256 aliceShares = wrapper.balanceOf(alice);
        if (aliceShares > 0) {
            vm.prank(alice);
            wrapper.redeem(aliceShares, alice, alice);

            uint256 aliceInsurance = claimManager.policyClaim(policyId).totalPaidOut - insuranceAfterBob;
            if (alicePrincipal > 0) {
                assertLe(
                    aliceInsurance,
                    alicePrincipal * MAX_COVERABLE_LOSS_BPS / 10_000,
                    "Alice insurance bounded by cap"
                );
            }
        }

        // Both principals cleared
        assertEq(wrapper.userPrincipal(alice), 0, "Alice principal cleared");
        assertEq(wrapper.userPrincipal(bob), 0, "Bob principal cleared");
        assertEq(wrapper.totalPrincipal(), 0, "totalPrincipal zeroed");

        // Total insurance was paid
        assertGt(claimManager.policyClaim(policyId).totalPaidOut - insuranceBefore, 0, "Insurance paid after loss");
    }
}
