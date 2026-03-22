// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CatalysisCoverAdapter} from "../../src/defi/adapters/morpho/CatalysisCoverAdapter.sol";
import {ICatalysisCoverAdapter} from "../../src/defi/interfaces/ICatalysisCoverAdapter.sol";
import {IAdapter} from "../../src/defi/interfaces/Morpho/IAdapter.sol";
import {IAlerts as IA} from "../../src/defi/interfaces/IAlerts.sol";
import {IEvents as IE} from "../../src/defi/interfaces/IEvents.sol";

import {MockERC20, MockVaultV2} from "./mocks/Mocks.sol";
import {RealCoverageSetup} from "./helpers/RealCoverageSetup.sol";

/// @title CatalysisCoverAdapterScenarios
/// @notice Comprehensive scenario tests for CatalysisCoverAdapter
/// @dev Tests various combinations of users, principal, profit/loss, maxCoverableLossBps
///      Key behavior: realAssets() = currentValue() (no insurance in share price)
///      Insurance is paid directly to users on withdrawal via _claimInsurance + safeTransfer
contract CatalysisCoverAdapterScenarios is RealCoverageSetup {
    CatalysisCoverAdapter adapter;
    MockVaultV2 parentVault;
    MockVaultV2 underlyingVault;
    MockERC20 asset;

    address curator = address(0xCCCC);
    address allocator = address(0xAAAA);

    uint96 POLICY_ID; // set by _deployAdapter (auto-assigned by real PolicyManager)

    // ERC4626 selectors (user operations -- triggers per-user principal tracking)
    bytes4 constant DEPOSIT_SELECTOR = 0x6e553f65; // deposit(uint256,address)
    bytes4 constant MINT_SELECTOR = 0x94bf804d; // mint(uint256,address)
    bytes4 constant WITHDRAW_SELECTOR = 0xb460af94; // withdraw(uint256,address,address)
    bytes4 constant REDEEM_SELECTOR = 0xba087652; // redeem(uint256,address,address)

    // V2 vault selectors (allocator operations -- no per-user tracking)
    bytes4 constant ALLOCATE_SELECTOR = 0x5c9ce04d; // allocate(address,bytes,uint256)
    bytes4 constant DEALLOCATE_SELECTOR = 0x4b219d16; // deallocate(address,bytes,uint256)
    bytes4 constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8; // forceDeallocate(address,bytes,uint256,address)

    function setUp() public {
        asset = new MockERC20();
        parentVault = new MockVaultV2(address(asset), "Covered Vault", "cvMORPHO");
        underlyingVault = new MockVaultV2(address(asset), "Underlying Vault", "uvMORPHO");

        parentVault.setCurator(curator);
        parentVault.setOwner(curator);

        // Deploy real PolicyManager + CoverPool + peripheral mocks
        _deployRealCoverage(curator, curator);

        // Register asset as supported payout token
        vm.prank(curator);
        policyManager.setSupportedPayoutToken(address(asset), true);
    }

    /// @notice Deploy adapter with specific maxCoverableLossBps
    function _deployAdapter(uint16 maxCoverableLossBps) internal {
        // Deploy adapter behind UUPS proxy (no policyId -- set via onPolicyBound hook)
        adapter = _deployAdapterProxy(
            address(parentVault),
            address(underlyingVault),
            address(claimManager),
            address(coverPool),
            maxCoverableLossBps
        );

        // Set adapter as curator so onPolicyBound can call submit + increaseAbsoluteCap
        parentVault.setCurator(address(adapter));

        // Create and bind policy through real PM + CoverPool flow
        // This triggers adapter.onPolicyBound which sets policyId + absoluteCap
        POLICY_ID = _createAndBindPolicy(
            address(adapter), // beneficiary = adapter
            address(adapter), // claimer = adapter
            address(asset), // payoutToken
            100_000 ether, // coverageAmount (stake requirement)
            type(uint128).max, // coverageLimit (max payout)
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator, // buyer
            address(adapter) // bindPolicyHook = adapter
        );

        parentVault.setAdapter(address(adapter), true);
        parentVault.setAllocator(allocator, true);

        asset.mint(address(parentVault), 1_000_000 ether);
        asset.mint(address(underlyingVault), 1_000_000 ether);
    }

    /// @dev Simulates a user deposit via allocate with DEPOSIT_SELECTOR (triggers per-user tracking)
    /// @param amount The amount to allocate
    function _allocate(uint256 amount) internal {
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount);
        vm.prank(address(parentVault));
        adapter.allocate("", amount, DEPOSIT_SELECTOR, allocator);
    }

    /// @dev Simulates a user deposit via allocate with DEPOSIT_SELECTOR for a specific sender
    /// @param sender The address to track principal for
    /// @param amount The amount to allocate
    function _allocateFor(address sender, uint256 amount) internal {
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount);
        vm.prank(address(parentVault));
        adapter.allocate("", amount, DEPOSIT_SELECTOR, sender);
    }

    /// @dev Simulates a user withdrawal via deallocate with WITHDRAW_SELECTOR (triggers per-user insurance)
    /// @param amount The amount to deallocate
    function _deallocate(uint256 amount) internal {
        vm.prank(address(parentVault));
        adapter.deallocate("", amount, WITHDRAW_SELECTOR, allocator);
    }

    /// @dev Simulates a user withdrawal via deallocate with WITHDRAW_SELECTOR for a specific sender
    /// @param sender The address withdrawing
    /// @param amount The amount to deallocate
    function _deallocateFor(address sender, uint256 amount) internal {
        vm.prank(address(parentVault));
        adapter.deallocate("", amount, WITHDRAW_SELECTOR, sender);
    }

    /*//////////////////////////////////////////////////////////////
                           FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test for multiple deposits and withdrawals
    function testFuzz_multipleDepositsWithdrawals(uint256 deposit1, uint256 deposit2, uint8 lossPercent) public {
        deposit1 = bound(deposit1, 1 ether, 10_000 ether);
        deposit2 = bound(deposit2, 1 ether, 10_000 ether);
        lossPercent = uint8(bound(lossPercent, 0, 50));

        _deployAdapter(1000); // 10% max coverage

        // User 1 deposits
        _allocate(deposit1);
        assertEq(adapter.totalPrincipal(), deposit1);

        // User 2 deposits
        _allocate(deposit2);
        assertEq(adapter.totalPrincipal(), deposit1 + deposit2);

        // Apply loss
        underlyingVault.setLoss(lossPercent);

        // Partial withdrawal should reduce principal
        uint256 currentVal = adapter.currentValue();
        if (currentVal > 0) {
            uint256 withdrawAmount = currentVal / 4;
            uint256 principalBefore = adapter.totalPrincipal();

            _deallocate(withdrawAmount);

            // Principal should decrease
            assertTrue(adapter.totalPrincipal() < principalBefore, "Principal should decrease after withdrawal");
        }
    }

    /*//////////////////////////////////////////////////////////////
                    SCENARIO TESTS FROM EXAMPLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Scenario: Profit case - Alice and Bob get full upside
    /// From the example: Initial 2000 USDC, +20% profit, Alice withdraws 50%
    function test_scenario_profitWithdrawal() public {
        _deployAdapter(1000); // 10% max coverage

        // Alice and Bob each deposit 1000
        uint256 aliceDeposit = 1000 ether;
        uint256 bobDeposit = 1000 ether;
        uint256 totalDeposit = aliceDeposit + bobDeposit;

        _allocate(totalDeposit);

        // +20% profit
        underlyingVault.setProfit(20);

        // Verify state - realAssets = currentValue in profit (no insurance needed)
        uint256 expectedValue = totalDeposit * 120 / 100; // 2400
        assertEq(adapter.currentValue(), expectedValue, "Current value should reflect profit");
        assertEq(adapter.realAssets(), expectedValue, "realAssets should equal currentValue in profit");

        // Alice withdraws 50% of current value (1200 USDC including profit)
        uint256 aliceWithdraw = expectedValue / 2; // 1200

        uint256 principalBefore = adapter.totalPrincipal();
        uint256 sharesBefore = adapter.underlyingShares();

        _deallocate(aliceWithdraw);

        uint256 principalAfter = adapter.totalPrincipal();
        uint256 sharesAfter = adapter.underlyingShares();

        // Principal should decrease proportionally: (aliceWithdraw / currentValue) * principal
        uint256 expectedPrincipalDecrease = principalBefore * aliceWithdraw / expectedValue;
        assertApproxEqRel(
            principalBefore - principalAfter,
            expectedPrincipalDecrease,
            0.01e18,
            "Principal should decrease proportionally"
        );

        // Shares should decrease proportionally
        uint256 expectedSharesDecrease = sharesBefore * aliceWithdraw / expectedValue;
        assertApproxEqRel(
            sharesBefore - sharesAfter, expectedSharesDecrease, 0.01e18, "Shares should decrease proportionally"
        );

        // Remaining value should still show profit for remaining depositors
        assertTrue(adapter.currentValue() > 0, "Should have remaining value");
    }

    /// @notice Scenario: Small loss (5%) - realAssets = currentValue (no insurance in share price)
    function test_scenario_smallLoss() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 2000 ether;
        _allocate(principal);

        // 5% loss
        underlyingVault.setLoss(5);

        uint256 currentValue = adapter.currentValue();
        assertEq(currentValue, 1900 ether, "5% loss should result in 1900");

        // realAssets = currentValue (no insurance baked into share price)
        assertEq(adapter.realAssets(), currentValue, "realAssets should equal currentValue");
        assertEq(adapter.realAssets(), 1900 ether, "realAssets reflects actual loss");

        // Shortfall should be 100 (the actual loss)
        assertEq(adapter.calculateShortfall(), 100 ether, "Shortfall should be actual loss");

        // Test deallocate with currentValue as base
        uint256 withdrawAmount = currentValue / 2; // 950
        uint256 principalBefore = adapter.totalPrincipal();
        uint256 sharesBefore = adapter.underlyingShares();

        _deallocate(withdrawAmount);

        // Principal should decrease proportionally to currentValue
        uint256 expectedPrincipalDecrease = principalBefore * withdrawAmount / currentValue;
        assertApproxEqRel(
            principalBefore - adapter.totalPrincipal(),
            expectedPrincipalDecrease,
            0.01e18,
            "Principal should decrease proportionally"
        );

        // Shares should decrease proportionally to currentValue
        uint256 expectedSharesDecrease = sharesBefore * withdrawAmount / currentValue;
        assertApproxEqRel(
            sharesBefore - adapter.underlyingShares(),
            expectedSharesDecrease,
            0.01e18,
            "Shares should decrease pro-rata"
        );
    }

    /// @notice Scenario: Large loss (30%) - realAssets = currentValue
    function test_scenario_largeLoss30Percent() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 2000 ether;
        _allocate(principal);

        // 30% loss
        underlyingVault.setLoss(30);

        uint256 currentValue = adapter.currentValue();
        assertEq(currentValue, 1400 ether, "30% loss should result in 1400");

        // realAssets = currentValue (insurance paid directly on withdrawal, not in share price)
        assertEq(adapter.realAssets(), currentValue, "realAssets should equal currentValue");
        assertEq(adapter.realAssets(), 1400 ether, "realAssets reflects actual loss");

        // calculateShortfall still reports capped global shortfall
        assertEq(adapter.calculateShortfall(), 200 ether, "Shortfall should be capped at max coverage");

        // Test deallocate
        uint256 withdrawAmount = currentValue / 2; // 700
        uint256 principalBefore = adapter.totalPrincipal();
        uint256 sharesBefore = adapter.underlyingShares();

        _deallocate(withdrawAmount);

        // Principal should decrease proportionally to currentValue
        uint256 expectedPrincipalDecrease = principalBefore * withdrawAmount / currentValue;
        assertApproxEqRel(
            principalBefore - adapter.totalPrincipal(),
            expectedPrincipalDecrease,
            0.01e18,
            "Principal should decrease proportionally"
        );

        // Shares should decrease proportionally
        uint256 expectedSharesDecrease = sharesBefore * withdrawAmount / currentValue;
        assertApproxEqRel(
            sharesBefore - adapter.underlyingShares(),
            expectedSharesDecrease,
            0.01e18,
            "Shares should decrease pro-rata"
        );
    }

    /// @notice Scenario: Edge case - exactly at max coverage threshold (10%)
    function test_scenario_exactlyAtMaxCoverage() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 2000 ether;
        _allocate(principal);

        // Exactly 10% loss
        underlyingVault.setLoss(10);

        uint256 currentValue = adapter.currentValue();
        assertEq(currentValue, 1800 ether, "10% loss should result in 1800");

        // realAssets = currentValue
        assertEq(adapter.realAssets(), currentValue, "realAssets should equal currentValue");
        // calculateShortfall equals max coverage
        assertEq(adapter.calculateShortfall(), 200 ether, "Shortfall equals max coverage");

        // Test deallocate
        uint256 withdrawAmount = currentValue / 2; // 900
        uint256 principalBefore = adapter.totalPrincipal();
        uint256 sharesBefore = adapter.underlyingShares();

        _deallocate(withdrawAmount);

        // Principal should decrease proportionally to currentValue
        uint256 expectedPrincipalDecrease = principalBefore * withdrawAmount / currentValue;
        assertApproxEqRel(
            principalBefore - adapter.totalPrincipal(),
            expectedPrincipalDecrease,
            0.01e18,
            "Principal should decrease proportionally"
        );

        // Shares should decrease proportionally
        uint256 expectedSharesDecrease = sharesBefore * withdrawAmount / currentValue;
        assertApproxEqRel(
            sharesBefore - adapter.underlyingShares(),
            expectedSharesDecrease,
            0.01e18,
            "Shares should decrease pro-rata"
        );
    }

    /// @notice Scenario: Profit then loss (timing matters)
    /// Alice withdraws during profit, Bob withdraws after loss
    function test_scenario_profitThenLoss() public {
        _deployAdapter(1000); // 10% max coverage

        // Initial deposits
        uint256 aliceDeposit = 1000 ether;
        uint256 bobDeposit = 1000 ether;
        _allocate(aliceDeposit + bobDeposit);

        // T1: +20% profit
        underlyingVault.setProfit(20);
        assertEq(adapter.currentValue(), 2400 ether);

        // Alice withdraws during profit - gets her share
        uint256 aliceWithdraw = 1200 ether; // Her 50% with profit
        uint256 principalBefore = adapter.totalPrincipal();
        uint256 currentValue = adapter.currentValue(); // 2400
        _deallocate(aliceWithdraw);
        uint256 principalAfter = adapter.totalPrincipal();

        // Verify proportional principal decrease
        uint256 expectedPrincipalDecrease = principalBefore * aliceWithdraw / currentValue;
        assertApproxEqRel(
            principalBefore - principalAfter,
            expectedPrincipalDecrease,
            0.01e18,
            "Principal should decrease proportionally"
        );

        // Verify state after Alice
        assertTrue(principalAfter < principalBefore, "Principal should decrease after Alice withdraws");
        assertTrue(adapter.currentValue() > 0, "Bob should have remaining value");

        // T2: Loss event
        underlyingVault.setProfit(0);
        underlyingVault.setLoss(33);

        uint256 bobValue = adapter.currentValue();
        uint256 bobRealAssets = adapter.realAssets();
        uint256 bobPrincipal = adapter.totalPrincipal();

        // Bob bears the loss
        assertTrue(bobValue < bobPrincipal, "Bob's value should be less than his principal after loss");

        // realAssets = currentValue (no insurance baked into share price)
        assertEq(bobRealAssets, bobValue, "realAssets should equal currentValue");
    }

    /// @notice Scenario: Multiple users with different deposit sizes
    function test_scenario_unequalDeposits() public {
        _deployAdapter(1000); // 10% max coverage

        // Alice: 1000, Bob: 3000 (75% of pool)
        uint256 aliceDeposit = 1000 ether;
        uint256 bobDeposit = 3000 ether;
        uint256 totalDeposit = aliceDeposit + bobDeposit;

        _allocate(totalDeposit);

        // 15% loss
        underlyingVault.setLoss(15);

        uint256 currentValue = adapter.currentValue();
        assertEq(currentValue, 3400 ether, "15% loss: 4000 * 0.85 = 3400");

        // realAssets = currentValue
        assertEq(adapter.realAssets(), currentValue, "realAssets should equal currentValue");

        // Alice withdraws her 25% share
        uint256 aliceShare = currentValue / 4; // 850
        uint256 principalBefore = adapter.totalPrincipal();

        _deallocate(aliceShare);

        // Principal should decrease proportionally
        uint256 expectedPrincipalDecrease = principalBefore * aliceShare / currentValue;
        assertApproxEqRel(
            principalBefore - adapter.totalPrincipal(),
            expectedPrincipalDecrease,
            0.01e18,
            "Principal should decrease proportionally"
        );

        // Bob should still have his proportion
        assertTrue(adapter.totalPrincipal() > 0, "Bob's principal should remain");
    }

    /// @notice Scenario: Zero principal edge case
    function test_scenario_zeroPrincipal() public {
        _deployAdapter(1000);

        // No deposits
        assertEq(adapter.realAssets(), 0, "No principal: realAssets should be 0");
        assertEq(adapter.calculateShortfall(), 0, "No principal: shortfall should be 0");
        assertEq(adapter.currentValue(), 0, "No principal: currentValue should be 0");
    }

    /// @notice Scenario: Full withdrawal after loss
    function test_scenario_fullWithdrawalAfterLoss() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 1000 ether;
        _allocate(principal);

        // 20% loss
        underlyingVault.setLoss(20);

        uint256 currentValue = adapter.currentValue();
        assertEq(currentValue, 800 ether);

        // realAssets = currentValue
        assertEq(adapter.realAssets(), currentValue, "realAssets should equal currentValue");

        _deallocate(currentValue);

        // All shares should be burned
        assertEq(adapter.underlyingShares(), 0, "All shares should be burned");
        assertEq(adapter.totalPrincipal(), 0, "All principal should be withdrawn");
    }

    /// @notice Scenario: Different maxCoverableLossBps values
    function test_scenario_differentMaxCoverage() public {
        uint256 principal = 1000 ether;

        // Test with 5% max coverage
        _deployAdapter(500); // 5%
        _allocate(principal);
        underlyingVault.setLoss(20);

        // realAssets = currentValue = 800 regardless of coverage level
        assertEq(adapter.realAssets(), 800 ether, "5% coverage: realAssets = currentValue = 800");
        assertEq(adapter.realAssets(), adapter.currentValue(), "realAssets always equals currentValue");

        // Reset and test with 20% max coverage
        setUp();
        _deployAdapter(2000); // 20%
        _allocate(principal);
        underlyingVault.setLoss(20);

        assertEq(adapter.realAssets(), 800 ether, "20% coverage: realAssets = currentValue = 800");
        assertEq(adapter.realAssets(), adapter.currentValue(), "realAssets always equals currentValue");

        // Reset and test with 100% max coverage
        setUp();
        _deployAdapter(10_000); // 100%
        _allocate(principal);
        underlyingVault.setLoss(20);

        assertEq(adapter.realAssets(), 800 ether, "100% coverage: realAssets = currentValue = 800");
        assertEq(adapter.realAssets(), adapter.currentValue(), "realAssets always equals currentValue");
    }

    /*//////////////////////////////////////////////////////////////
                    WITHDRAW-BASED APPROACH TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that pro-rata redeem burns shares based on currentValue
    function test_withdrawBased_sharesBurnedProRata() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 2000 ether;
        _allocate(principal);

        // Initial underlying shares
        uint256 initialShares = adapter.underlyingShares();
        assertEq(initialShares, principal, "1:1 share ratio initially");

        // 30% loss
        underlyingVault.setLoss(30);

        // currentValue = 1400
        uint256 withdrawAmount = 700 ether; // half of currentValue
        uint256 sharesBefore = adapter.underlyingShares();
        uint256 currentValue = adapter.currentValue(); // 1400

        // Track adapter balance (should change by assetsFromUnderlying ≈ withdrawAmount)
        uint256 adapterBalanceBefore = asset.balanceOf(address(adapter));

        _deallocate(withdrawAmount);

        uint256 sharesAfter = adapter.underlyingShares();
        uint256 sharesBurned = sharesBefore - sharesAfter;
        uint256 adapterBalanceAfter = asset.balanceOf(address(adapter));

        // Shares burned proportional to currentValue (not protectedValue)
        uint256 expectedSharesBurned = sharesBefore * withdrawAmount / currentValue;
        assertApproxEqRel(sharesBurned, expectedSharesBurned, 0.01e18, "Shares burned pro-rata based on currentValue");

        // Adapter balance change ≈ withdrawAmount (assetsFromUnderlying ≈ withdrawAmount)
        // Insurance goes directly to allocator, not the adapter
        uint256 adapterReceived = adapterBalanceAfter - adapterBalanceBefore;
        assertApproxEqRel(
            adapterReceived, withdrawAmount, 0.01e18, "Adapter receives assetsFromUnderlying approx withdrawAmount"
        );
    }

    /// @notice Verify principal decreases based on currentValue
    function test_withdrawBased_principalDecreasedByCurrentValue() public {
        _deployAdapter(1000);

        uint256 principal = 2000 ether;
        _allocate(principal);

        // 30% loss
        underlyingVault.setLoss(30);

        // User withdraws 50% of currentValue
        uint256 currentValue = adapter.currentValue(); // 1400
        uint256 withdrawAmount = currentValue / 2; // 700

        uint256 principalBefore = adapter.totalPrincipal();

        _deallocate(withdrawAmount);

        uint256 remainingPrincipal = adapter.totalPrincipal();

        // Principal decreases proportionally to currentValue
        uint256 expectedDecrease = principalBefore * withdrawAmount / currentValue;
        uint256 actualDecrease = principalBefore - remainingPrincipal;

        assertApproxEqRel(actualDecrease, expectedDecrease, 0.01e18, "Principal decreases based on currentValue");
    }

    /// @notice Test user deposit → deallocate → user withdraw scenario
    function test_userDeposit_deallocate_userWithdraw() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 initialDeposit = 1000 ether;

        // Step 1: User deposits (simulated via allocate)
        _allocate(initialDeposit);

        assertEq(adapter.totalPrincipal(), initialDeposit, "Principal should equal deposit");
        assertGt(adapter.underlyingShares(), 0, "Should have underlying shares");

        uint256 sharesBefore = adapter.underlyingShares();

        // Step 2: Allocator deallocates partial amount (e.g., rebalancing)
        uint256 deallocateAmount = 300 ether;
        _deallocate(deallocateAmount);

        uint256 sharesAfterDeallocate = adapter.underlyingShares();
        assertLt(sharesAfterDeallocate, sharesBefore, "Shares should decrease after deallocate");

        // Principal should decrease proportionally
        uint256 principalAfterDeallocate = adapter.totalPrincipal();
        assertLt(principalAfterDeallocate, initialDeposit, "Principal should decrease");

        // Step 3: User withdraws remaining
        uint256 remainingValue = adapter.currentValue();
        _deallocate(remainingValue);

        // All shares should be burned
        assertEq(adapter.underlyingShares(), 0, "All shares should be burned");
        assertEq(adapter.totalPrincipal(), 0, "Principal should be zero");
    }

    /*//////////////////////////////////////////////////////////////
                    PRINCIPAL DRIFT SCENARIO TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice PROBLEM SCENARIO 1: Allocator deallocate creates phantom shortfall
    function test_scenario_allocatorDeallocate_phantomShortfall() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 1000 ether;
        _allocate(principal);

        // Verify initial state
        assertEq(adapter.totalPrincipal(), principal, "Initial principal");
        assertEq(adapter.currentValue(), principal, "Initial currentValue");
        assertEq(adapter.calculateShortfall(), 0, "No initial shortfall");

        // Partial withdrawal with WITHDRAW_SELECTOR -- allocator has tracked shares from _allocate
        uint256 deallocateAmount = 300 ether;
        vm.prank(address(parentVault));
        adapter.deallocate("", deallocateAmount, WITHDRAW_SELECTOR, allocator);

        uint256 principalAfter = adapter.totalPrincipal();
        uint256 shortfallAfter = adapter.calculateShortfall();

        // Principal should decrease by deallocateAmount (allocator has tracked shares)
        assertEq(principalAfter, principal - deallocateAmount, "Principal should decrease on allocator deallocate");

        // No phantom shortfall since value and principal decreased together
        assertEq(shortfallAfter, 0, "No phantom shortfall after rebalance");
    }

    /// @notice PROBLEM SCENARIO 2: Allocator allocate causes under-coverage
    function test_scenario_allocatorAllocate_underCoverage() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 initialDeposit = 1000 ether;
        _allocate(initialDeposit);

        // Additional allocation with DEPOSIT_SELECTOR -- tracks per-user principal
        uint256 additionalAmount = 500 ether;
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), additionalAmount);
        vm.prank(address(parentVault));
        adapter.allocate("", additionalAmount, DEPOSIT_SELECTOR, allocator);

        uint256 principalAfter = adapter.totalPrincipal();

        // Principal should increase by additionalAmount
        assertEq(principalAfter, initialDeposit + additionalAmount, "Principal should increase on allocator allocate");

        // Now simulate 10% loss
        underlyingVault.setLoss(10);

        uint256 actualLoss = (initialDeposit + additionalAmount) * 10 / 100; // 150
        uint256 maxCoverableLoss = principalAfter * 1000 / 10_000; // 10% of principal
        // With correct principal tracking, maxCoverableLoss covers the actual loss
        assertGe(maxCoverableLoss, actualLoss, "Coverage should be sufficient for actual loss");
    }

    /// @notice PROBLEM SCENARIO 3: Insurance triggered on allocator deallocate with loss
    /// @dev With per-user tracking, allocator (who has tracked shares) receives insurance directly
    function test_scenario_allocatorDeallocate_insuranceTriggered() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 1000 ether;
        _allocate(principal);

        // Underlying vault loses 10%
        underlyingVault.setLoss(10);

        uint256 currentValueBefore = adapter.currentValue();
        assertEq(currentValueBefore, 900 ether, "10% loss: currentValue = 900");

        uint256 shortfallBefore = adapter.calculateShortfall();
        assertEq(shortfallBefore, 100 ether, "Raw shortfall = 100");

        // Track adapter and allocator balances before deallocate
        uint256 adapterBalanceBefore = asset.balanceOf(address(adapter));
        uint256 allocatorBalanceBefore = asset.balanceOf(allocator);

        // Full withdrawal with WITHDRAW_SELECTOR -- allocator has tracked shares
        vm.prank(address(parentVault));
        adapter.deallocate("", currentValueBefore, WITHDRAW_SELECTOR, allocator);

        uint256 adapterBalanceAfter = asset.balanceOf(address(adapter));
        uint256 allocatorBalanceAfter = asset.balanceOf(allocator);
        uint256 principalAfter = adapter.totalPrincipal();
        // Principal should be 0 after full deallocate
        assertEq(principalAfter, 0, "Principal should be 0 after full deallocate");

        // Adapter should have received currentValueBefore (assetsFromUnderlying ≈ withdrawAmount)
        assertApproxEqRel(
            adapterBalanceAfter - adapterBalanceBefore,
            currentValueBefore,
            0.01e18,
            "Adapter receives assetsFromUnderlying"
        );

        // Allocator should have received insurance directly (shortfall = 100, effectiveInsurance = 99)
        assertEq(allocatorBalanceAfter - allocatorBalanceBefore, 99 ether, "Allocator receives 99 ether insurance");
    }

    /*//////////////////////////////////////////////////////////////
                    PER-USER DIRECT INSURANCE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify that insurance is paid directly to the user, not through the vault
    /// @dev Full withdrawal scenario: user gets assetsFromUnderlying via vault + insurance directly
    function test_directInsurance_fullWithdraw() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 1000 ether;
        address user = address(0x1234);

        _allocateFor(user, principal);

        // 10% loss
        underlyingVault.setLoss(10);

        uint256 currentValue = adapter.currentValue(); // 900
        assertEq(currentValue, 900 ether, "10% loss");

        uint256 userBalanceBefore = asset.balanceOf(user);
        uint256 adapterBalanceBefore = asset.balanceOf(address(adapter));

        _deallocateFor(user, currentValue); // Withdraw all currentValue

        uint256 userBalanceAfter = asset.balanceOf(user);
        uint256 adapterBalanceAfter = asset.balanceOf(address(adapter));

        // Insurance paid directly to user:
        // shortfall = 1000 - 900 = 100, maxInsurance = 100, effectiveInsurance = 99 (1% deductible)
        uint256 userInsuranceReceived = userBalanceAfter - userBalanceBefore;
        assertEq(userInsuranceReceived, 99 ether, "User receives 99 ether insurance directly");

        // Adapter receives assetsFromUnderlying ≈ currentValue (vault pulls this)
        uint256 adapterReceived = adapterBalanceAfter - adapterBalanceBefore;
        assertApproxEqRel(adapterReceived, currentValue, 0.001e18, "Adapter receives assetsFromUnderlying");
    }

    /// @notice Verify partial withdraw: insurance proportional to user's principal
    function test_directInsurance_partialWithdraw() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 2000 ether;
        address user = address(0x5678);

        _allocateFor(user, principal);

        // 30% loss
        underlyingVault.setLoss(30);

        uint256 currentValue = adapter.currentValue(); // 1400
        assertEq(currentValue, 1400 ether, "30% loss");

        uint256 withdrawAmount = currentValue / 2; // 700
        uint256 userBalanceBefore = asset.balanceOf(user);

        _deallocateFor(user, withdrawAmount);

        uint256 userBalanceAfter = asset.balanceOf(user);
        uint256 userInsuranceReceived = userBalanceAfter - userBalanceBefore;

        // After 50% withdraw:
        // userPrincipalForWithdrawal = 2000 * (1000/2000) = 1000 (half of shares)
        // assetsFromUnderlying ≈ 700
        // shortfall = 1000 - 700 = 300
        // maxInsurance = 1000 * 10% = 100
        // effectiveInsurance = 100 * 99% = 99
        // claimAmount = min(300, 99) = 99
        assertEq(userInsuranceReceived, 99 ether, "User receives capped insurance directly");
    }

    /// @notice Verify NO insurance when user is in profit (value >= principal)
    function test_directInsurance_noInsuranceInProfit() public {
        _deployAdapter(1000); // 10% max coverage

        uint256 principal = 1000 ether;
        address user = address(0x9ABC);

        _allocateFor(user, principal);

        // 20% profit
        underlyingVault.setProfit(20);

        uint256 currentValue = adapter.currentValue(); // 1200
        uint256 withdrawAmount = 600 ether; // Half

        uint256 userBalanceBefore = asset.balanceOf(user);

        _deallocateFor(user, withdrawAmount);

        uint256 userBalanceAfter = asset.balanceOf(user);
        uint256 userInsuranceReceived = userBalanceAfter - userBalanceBefore;

        // No insurance in profit case
        assertEq(userInsuranceReceived, 0, "No insurance when user is in profit");
        assertGt(currentValue, principal, "Verify profit scenario");
    }

    /// @notice Fee recipient with no tracked shares gets no direct insurance
    /// @dev Fee recipient calls deallocate with their address but hasn't deposited via allocate
    function test_scenario_feeRecipientWithdraw_noInsurance() public {
        _deployAdapter(1000); // 10% max coverage

        address feeRecipient = address(0xFEE);
        parentVault.setManagementFeeRecipient(feeRecipient);

        uint256 principal = 1000 ether;
        _allocate(principal); // allocator has tracked shares, feeRecipient does NOT

        // Underlying vault loses 10%
        underlyingVault.setLoss(10);

        uint256 currentVal = adapter.currentValue(); // 900
        uint256 principalBefore = adapter.totalPrincipal();

        uint256 feeAmount = 50 ether;
        uint256 feeRecipientBalanceBefore = asset.balanceOf(feeRecipient);

        // Fee recipient withdraws - they have no tracked shares → fallback path, no insurance
        vm.prank(address(parentVault));
        adapter.deallocate("", feeAmount, WITHDRAW_SELECTOR, feeRecipient);

        uint256 feeRecipientBalanceAfter = asset.balanceOf(feeRecipient);
        uint256 principalAfter = adapter.totalPrincipal();

        // Fee recipient should NOT receive direct insurance (no tracked principal)
        assertEq(feeRecipientBalanceAfter, feeRecipientBalanceBefore, "Fee recipient gets no direct insurance");

        // Principal should decrease via fallback formula: totalPrincipal * feeAmount / currentVal
        uint256 expectedPrincipalDecrease = principalBefore * feeAmount / currentVal;
        assertApproxEqRel(
            principalBefore - principalAfter,
            expectedPrincipalDecrease,
            0.01e18,
            "Fee recipient decreases principal via fallback"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    TWO-USER SCENARIO: ALICE AND BOB
    //////////////////////////////////////////////////////////////*/

    /// @notice Two-user scenario demonstrating per-user insurance benefit
    /// @dev Alice joins early (benefits from yield), Bob joins late (insured against hack)
    ///
    /// Timeline:
    ///   1. Alice deposits 1000 at price 1.00 (1000 shares)
    ///   2. Yield → price 1.50 (50% profit)
    ///   3. Bob deposits 1500 at price 1.50 (1000 shares)
    ///   4. 10% hack → price drops (loss from accumulated state)
    ///   5. Alice withdraws: price > her principal → 0 insurance
    ///   6. Bob withdraws: price < his principal → receives direct insurance
    function test_twoUsers_perUserInsurance() public {
        _deployAdapter(1000); // 10% max coverage

        address alice = address(0xAA11);
        address bob = address(0xBB22);

        // Step 1: Alice deposits 1000 at 1:1 ratio
        _allocateFor(alice, 1000 ether);
        assertEq(adapter.userPrincipal(alice), 1000 ether, "Alice principal = 1000");
        assertEq(adapter.userUnderlyingShares(alice), 1000 ether, "Alice shares = 1000");

        // Step 2: 50% yield accrues
        underlyingVault.setProfit(50);
        // Alice's shares now worth 1500, price = 1.50

        // Step 3: Bob deposits 1500 at price 1.50
        // convertToShares(1500) = 1500 * totalShares / totalAssets() = 1500 * 1000 / 1500 = 1000
        _allocateFor(bob, 1500 ether);
        assertEq(adapter.userPrincipal(bob), 1500 ether, "Bob principal = 1500");
        assertEq(adapter.userUnderlyingShares(bob), 1000 ether, "Bob shares = 1000");

        // Total state: _totalAssets = 2500, _totalShares = 2000
        assertEq(adapter.totalPrincipal(), 2500 ether, "Total principal = 2500");

        // Step 4: 10% hack - loss applied to accumulated assets
        // setLoss clears profit and sets 10% loss
        underlyingVault.setLoss(10);

        // currentValue = 2000 * totalAssets()/totalShares
        // _totalAssets = 2500, totalAssets() = 2500 * 90/100 = 2250
        // adapter.underlyingShares = 2000
        // currentValue = 2000 * 2250/2000 = 2250
        assertEq(adapter.currentValue(), 2250 ether, "currentValue after hack = 2250");

        // Each user owns 1000 of 2000 shares → each worth 1125
        // Alice's share of currentValue: 2250 / 2 = 1125
        // Bob's share of currentValue: 2250 / 2 = 1125

        // Step 5: Alice withdraws her half (1125)
        // Alice's principal = 1000, assetsFromUnderlying = 1125 > principal → NO insurance
        uint256 aliceBalanceBefore = asset.balanceOf(alice);

        _deallocateFor(alice, 1125 ether);

        uint256 aliceInsurance = asset.balanceOf(alice) - aliceBalanceBefore;
        assertEq(aliceInsurance, 0, "Alice has no shortfall, no direct insurance");
        assertEq(adapter.userPrincipal(alice), 0, "Alice principal cleared after full withdrawal");

        // Step 6: Bob withdraws remaining
        // After Alice: _totalAssets = 2500 - 1125 = 1375, _totalShares = 1000
        // totalAssets() = 1375 * 90/100 = 1237, currentValue = 1237
        uint256 bobCurrentValue = adapter.currentValue();

        uint256 bobBalanceBefore = asset.balanceOf(bob);

        _deallocateFor(bob, bobCurrentValue);

        uint256 bobInsurance = asset.balanceOf(bob) - bobBalanceBefore;

        // Bob's shortfall: userPrincipal[Bob] = 1500, assetsFromUnderlying ≈ bobCurrentValue
        // shortfall = 1500 - bobCurrentValue (roughly 263)
        // maxInsurance = 1500 * 10% = 150, effectiveInsurance = 150 * 99% = 148.5
        // claimAmount = min(263, 148.5) = 148.5
        assertGt(bobInsurance, 0, "Bob has a shortfall, receives direct insurance");
        assertEq(bobInsurance, 148.5 ether, "Bob receives 148.5 ether insurance directly");
        assertEq(adapter.userPrincipal(bob), 0, "Bob principal cleared after full withdrawal");
    }
}
