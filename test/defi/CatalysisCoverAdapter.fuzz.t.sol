// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CatalysisCoverAdapter} from "../../src/defi/adapters/morpho/CatalysisCoverAdapter.sol";
import {ICatalysisCoverAdapter} from "../../src/defi/interfaces/ICatalysisCoverAdapter.sol";
import {IAdapter} from "../../src/defi/interfaces/Morpho/IAdapter.sol";
import {IAlerts as IA} from "../../src/defi/interfaces/IAlerts.sol";
import {IEvents as IE} from "../../src/defi/interfaces/IEvents.sol";

import {MockERC20, MockVaultV2} from "./mocks/Mocks.sol";
import {ISpec} from "coverage/interfaces/ISpec.sol";
import {RealCoverageSetup} from "./helpers/RealCoverageSetup.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// @title CatalysisCoverAdapterFuzzTest
/// @notice Fuzz tests for CatalysisCoverAdapter to verify invariants and edge cases
contract CatalysisCoverAdapterFuzzTest is RealCoverageSetup {
    CatalysisCoverAdapter adapter;
    MockVaultV2 parentVault;
    MockVaultV2 underlyingVault;
    MockERC20 asset;

    address curator = address(0xCCCC);
    address allocator = address(0xAAAA);
    address user1 = address(0x1111);

    uint96 POLICY_ID; // set in setUp (auto-assigned by real PolicyManager)
    uint16 constant MAX_COVERABLE_LOSS_BPS = 1000; // 10% max coverage

    // ERC4626 selectors (user operations — triggers per-user principal tracking)
    bytes4 constant DEPOSIT_SELECTOR = 0x6e553f65; // deposit(uint256,address)
    bytes4 constant MINT_SELECTOR = 0x94bf804d; // mint(uint256,address)
    bytes4 constant WITHDRAW_SELECTOR = 0xb460af94; // withdraw(uint256,address,address)
    bytes4 constant REDEEM_SELECTOR = 0xba087652; // redeem(uint256,address,address)

    // V2 vault selectors (allocator operations — no per-user tracking)
    bytes4 constant ALLOCATE_SELECTOR = 0x5c9ce04d; // allocate(address,bytes,uint256)
    bytes4 constant DEALLOCATE_SELECTOR = 0x4b219d16; // deallocate(address,bytes,uint256)
    bytes4 constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8; // forceDeallocate(address,bytes,uint256,address)

    function setUp() public {
        // Deploy mock vaults and asset
        asset = new MockERC20();
        parentVault = new MockVaultV2(address(asset), "Covered Vault", "cvMORPHO");
        underlyingVault = new MockVaultV2(address(asset), "Underlying Vault", "uvMORPHO");

        // Set curator and owner
        parentVault.setCurator(curator);
        parentVault.setOwner(curator);

        // Deploy real PolicyManager + CoverPool + peripheral mocks
        _deployRealCoverage(curator, curator);

        // Deploy adapter behind UUPS proxy (no policyId — set via onPolicyBound hook)
        adapter = _deployAdapterProxy(
            address(parentVault),
            address(underlyingVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS
        );

        // Set adapter as curator so onPolicyBound can call submit + increaseAbsoluteCap
        parentVault.setCurator(address(adapter));

        // Create and bind policy through real PM + CoverPool flow
        // This triggers adapter.onPolicyBound which sets policyId + absoluteCap
        POLICY_ID = _createAndBindPolicy(
            address(adapter), // beneficiary = adapter
            address(adapter), // claimer = adapter
            address(asset), // payoutToken
            type(uint128).max, // coverageAmount (stake requirement)
            type(uint128).max, // coverageLimit (max payout)
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator, // buyer
            address(adapter) // bindPolicyHook = adapter
        );

        // Register adapter
        parentVault.setAdapter(address(adapter), true);
        parentVault.setAllocator(allocator, true);

        // Fund vaults with large amounts for fuzz testing
        asset.mint(address(parentVault), type(uint128).max);
        asset.mint(address(underlyingVault), type(uint128).max);
    }

    /*//////////////////////////////////////////////////////////////
                      ALLOCATE FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: allocate should always increase principal for user deposits
    function testFuzz_allocate_increasesPrincipal(uint256 amount) public {
        // Bound to reasonable amounts (avoid overflow and zero)
        amount = bound(amount, 1, type(uint128).max / 2);

        uint256 principalBefore = adapter.totalPrincipal();

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount);

        vm.prank(address(parentVault));
        (bytes32[] memory ids, int256 delta) = adapter.allocate("", amount, DEPOSIT_SELECTOR, user1);

        // Verify invariants
        assertEq(ids.length, 1);
        assertEq(ids[0], adapter.adapterId());
        assertEq(delta, int256(amount));
        assertEq(adapter.totalPrincipal(), principalBefore + amount);
    }

    /// @notice Fuzz test: allocate tracks per-user principal correctly
    function testFuzz_userPrincipal_tracksDeposit(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max / 2);

        uint256 userPrincipalBefore = adapter.userPrincipal(user1);
        uint256 userSharesBefore = adapter.userUnderlyingShares(user1);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount);

        vm.prank(address(parentVault));
        adapter.allocate("", amount, DEPOSIT_SELECTOR, user1);

        // Per-user tracking
        assertEq(adapter.userPrincipal(user1), userPrincipalBefore + amount, "userPrincipal should increase by deposit");
        assertGt(adapter.userUnderlyingShares(user1), userSharesBefore, "userUnderlyingShares should increase");
    }

    /// @notice Fuzz test: allocate with mint selector should increase principal
    function testFuzz_allocate_mintSelector(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max / 2);

        uint256 principalBefore = adapter.totalPrincipal();

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount);

        vm.prank(address(parentVault));
        adapter.allocate("", amount, MINT_SELECTOR, user1);

        assertEq(adapter.totalPrincipal(), principalBefore + amount);
    }

    /// @notice Fuzz test: allocate with non-user selector SHOULD increase principal
    /// @dev All allocated capital needs insurance coverage
    function testFuzz_allocate_nonUserSelector(uint256 amount, bytes4 selector) public {
        amount = bound(amount, 1, type(uint128).max / 2);

        // Ensure selector is not a user selector (doesn't matter anymore)
        vm.assume(selector != DEPOSIT_SELECTOR && selector != MINT_SELECTOR);

        uint256 principalBefore = adapter.totalPrincipal();

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount);

        vm.prank(address(parentVault));
        adapter.allocate("", amount, selector, allocator);

        // Principal SHOULD increase for all allocations (capital needs coverage)
        assertEq(adapter.totalPrincipal(), principalBefore + amount);
        // Value should increase
        assertEq(adapter.currentValue(), principalBefore + amount);
    }

    /// @notice Fuzz test: multiple allocations should accumulate principal correctly
    function testFuzz_allocate_multiple(uint256 amount1, uint256 amount2, uint256 amount3) public {
        amount1 = bound(amount1, 1, type(uint128).max / 4);
        amount2 = bound(amount2, 1, type(uint128).max / 4);
        amount3 = bound(amount3, 1, type(uint128).max / 4);

        uint256 totalAllocated = 0;
        uint256[3] memory amounts = [amount1, amount2, amount3];

        for (uint256 i = 0; i < amounts.length; i++) {
            totalAllocated += amounts[i];

            vm.prank(address(parentVault));
            asset.transfer(address(adapter), amounts[i]);

            vm.prank(address(parentVault));
            adapter.allocate("", amounts[i], DEPOSIT_SELECTOR, user1);
        }

        assertEq(adapter.totalPrincipal(), totalAllocated);
        assertEq(adapter.userPrincipal(user1), totalAllocated, "userPrincipal should equal total deposited");
    }

    /*//////////////////////////////////////////////////////////////
                     DEALLOCATE FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: deallocate should decrease principal proportionally
    function testFuzz_deallocate_decreasesPrincipal(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint128).max / 2);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Setup: allocate first with user1
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        // Simulate V2 vault tracking allocation
        parentVault.setAllocation(adapter.adapterId(), adapter.currentValue());

        uint256 withdrawAmount = (depositAmount * withdrawPercent) / 100;
        uint256 principalBefore = adapter.totalPrincipal();

        vm.prank(address(parentVault));
        (bytes32[] memory ids, int256 delta) = adapter.deallocate("", withdrawAmount, WITHDRAW_SELECTOR, user1);

        // Verify invariants
        assertEq(ids.length, 1);
        assertEq(ids[0], adapter.adapterId());
        assertTrue(delta <= 0, "Delta should be non-positive after deallocate");
        assertLe(adapter.totalPrincipal(), principalBefore);
    }

    /// @notice Fuzz test: deallocate with redeem selector should work correctly
    function testFuzz_deallocate_redeemSelector(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint128).max / 2);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Setup: allocate first with user1
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        uint256 withdrawAmount = (depositAmount * withdrawPercent) / 100;
        uint256 principalBefore = adapter.totalPrincipal();

        vm.prank(address(parentVault));
        adapter.deallocate("", withdrawAmount, REDEEM_SELECTOR, user1);

        assertLe(adapter.totalPrincipal(), principalBefore);
    }

    /// @notice Fuzz test: non-user deallocate SHOULD decrease principal
    /// @dev All withdrawals reduce insured capital
    function testFuzz_deallocate_nonUserSelector(
        uint256 depositAmount,
        uint256 withdrawPercent,
        bytes4 selector
    )
        public
    {
        depositAmount = bound(depositAmount, 1 ether, type(uint128).max / 2);
        withdrawPercent = bound(withdrawPercent, 1, 100);

        // Ensure selector is not a user selector (doesn't matter anymore)
        vm.assume(selector != WITHDRAW_SELECTOR && selector != REDEEM_SELECTOR);

        // Setup: allocate first with user1
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        uint256 withdrawAmount = (depositAmount * withdrawPercent) / 100;
        uint256 principalBefore = adapter.totalPrincipal();

        vm.prank(address(parentVault));
        adapter.deallocate("", withdrawAmount, selector, user1);

        // Principal SHOULD decrease for all withdrawals (reduces insured capital)
        assertEq(adapter.totalPrincipal(), principalBefore - withdrawAmount);
    }

    /*//////////////////////////////////////////////////////////////
                      SHORTFALL FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: shortfall calculation should be capped by maxCoverableLossBps
    function testFuzz_calculateShortfall_cappedByMax(uint256 depositAmount, uint256 lossPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint128).max / 2);
        lossPercent = bound(lossPercent, 1, 99);

        // Setup: allocate
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        // Simulate loss
        underlyingVault.setLoss(lossPercent);

        uint256 shortfall = adapter.calculateShortfall();
        uint256 maxCoverable = (depositAmount * MAX_COVERABLE_LOSS_BPS) / 10_000;

        // Shortfall should never exceed maxCoverable
        assertLe(shortfall, maxCoverable);

        // Shortfall should be 0 or positive
        assertGe(shortfall, 0);
    }

    /// @notice Fuzz test: shortfall is 0 when no loss
    function testFuzz_calculateShortfall_zeroWhenNoLoss(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint128).max / 2);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        assertEq(adapter.calculateShortfall(), 0);
    }

    /// @notice Fuzz test: shortfall equals raw loss when loss <= maxCoverable
    function testFuzz_calculateShortfall_equalsRawLossWhenSmall(uint256 depositAmount, uint256 lossPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint128).max / 2);
        // Keep loss within maxCoverableLossBps (10%)
        lossPercent = bound(lossPercent, 1, MAX_COVERABLE_LOSS_BPS / 100);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        underlyingVault.setLoss(lossPercent);

        uint256 shortfall = adapter.calculateShortfall();
        uint256 expectedShortfall = (depositAmount * lossPercent) / 100;

        // Should be approximately equal (allowing for rounding)
        assertApproxEqRel(shortfall, expectedShortfall, 0.01e18);
    }

    /*//////////////////////////////////////////////////////////////
                     CURRENT VALUE FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: currentValue reflects deposits and losses accurately
    function testFuzz_currentValue_reflectsState(uint256 depositAmount, uint256 lossPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint128).max / 2);
        lossPercent = bound(lossPercent, 0, 99);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        // Initially value equals deposit
        assertEq(adapter.currentValue(), depositAmount);

        // Apply loss
        underlyingVault.setLoss(lossPercent);

        uint256 expectedValue = (depositAmount * (100 - lossPercent)) / 100;
        assertEq(adapter.currentValue(), expectedValue);
    }

    /// @notice Fuzz test: currentValue reflects profits
    function testFuzz_currentValue_reflectsProfit(uint256 depositAmount, uint256 profitPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint64).max);
        profitPercent = bound(profitPercent, 1, 100);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        // Apply profit
        underlyingVault.setProfit(profitPercent);

        uint256 expectedValue = (depositAmount * (100 + profitPercent)) / 100;
        assertEq(adapter.currentValue(), expectedValue);
    }

    /*//////////////////////////////////////////////////////////////
                      REAL ASSETS FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: realAssets() always equals currentValue() regardless of loss
    function testFuzz_realAssets_alwaysEqualsCurrentValue(uint256 depositAmount, uint256 lossPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint64).max);
        lossPercent = bound(lossPercent, 0, 99);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        underlyingVault.setLoss(lossPercent);

        uint256 realAssets = adapter.realAssets();
        uint256 currentVal = adapter.currentValue();

        // realAssets always equals currentValue — insurance is NOT baked in
        assertEq(realAssets, currentVal, "realAssets should always equal currentValue");
    }

    /// @notice Fuzz test: realAssets >= currentValue when in profit (trivially true)
    function testFuzz_realAssets_inProfit(uint256 depositAmount, uint256 profitPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint64).max);
        profitPercent = bound(profitPercent, 1, 100);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        underlyingVault.setProfit(profitPercent);

        uint256 realAssets = adapter.realAssets();
        uint256 currentVal = adapter.currentValue();

        // In profit: realAssets == currentValue (they are always equal)
        assertEq(realAssets, currentVal);
        assertGe(realAssets, depositAmount);
    }

    /// @notice Fuzz test: direct insurance payout is bounded by userPrincipal * maxCoverableLossBps
    function testFuzz_directInsurance_boundedByPrincipal(uint256 depositAmount, uint256 lossPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint64).max);
        lossPercent = bound(lossPercent, 1, 99);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        underlyingVault.setLoss(lossPercent);

        uint256 currentVal = adapter.currentValue();
        if (currentVal == 0) return; // Skip edge case

        uint256 user1BalanceBefore = asset.balanceOf(user1);

        // Withdraw entire currentValue
        vm.prank(address(parentVault));
        adapter.deallocate("", currentVal, WITHDRAW_SELECTOR, user1);

        uint256 insurancePayout = asset.balanceOf(user1) - user1BalanceBefore;

        // Insurance payout must be bounded by maxCoverableLossBps of principal (with deductible)
        uint256 maxInsurance = (depositAmount * MAX_COVERABLE_LOSS_BPS) / 10_000;
        assertLe(insurancePayout, maxInsurance, "Insurance payout bounded by maxCoverableLoss");
    }

    /*//////////////////////////////////////////////////////////////
                   CONSTRUCTOR FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: initialize validates maxCoverableLossBps
    function testFuzz_initialize_validatesMaxCoverableLoss(uint16 maxLossBps) public {
        // Deploy uninitialized proxy to test initialize revert paths
        CatalysisCoverAdapter impl = new CatalysisCoverAdapter();
        CatalysisCoverAdapter proxy = CatalysisCoverAdapter(address(new ERC1967Proxy(address(impl), "")));
        // Valid range: 1 - 10000
        if (maxLossBps == 0 || maxLossBps > 10_000) {
            vm.expectRevert(IA.InvalidMaxCoverableLoss.selector);
        }

        proxy.initialize(
            address(parentVault), address(underlyingVault), address(claimManager), address(coverPool), maxLossBps
        );
    }

    /// @notice Fuzz test: different maxCoverableLossBps values affect shortfall cap
    function testFuzz_maxCoverableLoss_affectsShortfallCap(
        uint16 maxLossBps,
        uint256 depositAmount,
        uint256 lossPercent
    )
        public
    {
        maxLossBps = uint16(bound(maxLossBps, 1, 10_000));
        depositAmount = bound(depositAmount, 1 ether, type(uint64).max);
        lossPercent = bound(lossPercent, 50, 99); // Ensure loss > maxLossBps in most cases

        // Deploy adapter behind UUPS proxy with custom maxLossBps
        CatalysisCoverAdapter customAdapter = _deployAdapterProxy(
            address(parentVault), address(underlyingVault), address(claimManager), address(coverPool), maxLossBps
        );

        // Set adapter as curator and bind policy
        parentVault.setCurator(address(customAdapter));
        _createAndBindPolicy(
            address(customAdapter),
            address(customAdapter),
            address(asset),
            type(uint128).max,
            type(uint128).max,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(customAdapter)
        );

        parentVault.setAdapter(address(customAdapter), true);

        vm.prank(address(parentVault));
        asset.transfer(address(customAdapter), depositAmount);

        vm.prank(address(parentVault));
        customAdapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        underlyingVault.setLoss(lossPercent);

        uint256 shortfall = customAdapter.calculateShortfall();
        uint256 maxCoverable = (depositAmount * maxLossBps) / 10_000;

        // Shortfall should be capped
        assertLe(shortfall, maxCoverable);
    }

    /*//////////////////////////////////////////////////////////////
                    INVARIANT-STYLE FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: principal never exceeds total deposited
    function testFuzz_invariant_principalNeverExceedsDeposited(
        uint256 deposit1,
        uint256 deposit2,
        uint256 withdrawPercent1,
        uint256 withdrawPercent2
    )
        public
    {
        deposit1 = bound(deposit1, 0.1 ether, type(uint64).max);
        deposit2 = bound(deposit2, 0.1 ether, type(uint64).max);
        withdrawPercent1 = bound(withdrawPercent1, 0, 50);
        withdrawPercent2 = bound(withdrawPercent2, 0, 50);

        uint256 totalDeposited = 0;

        // First deposit
        totalDeposited += deposit1;
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), deposit1);
        vm.prank(address(parentVault));
        adapter.allocate("", deposit1, DEPOSIT_SELECTOR, user1);

        // First withdrawal
        if (withdrawPercent1 > 0) {
            uint256 currentVal = adapter.currentValue();
            uint256 withdrawAmt = (currentVal * withdrawPercent1) / 100;
            if (withdrawAmt > 0) {
                vm.prank(address(parentVault));
                adapter.deallocate("", withdrawAmt, WITHDRAW_SELECTOR, user1);
            }
        }

        // Invariant check
        assertLe(adapter.totalPrincipal(), totalDeposited);

        // Second deposit
        totalDeposited += deposit2;
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), deposit2);
        vm.prank(address(parentVault));
        adapter.allocate("", deposit2, DEPOSIT_SELECTOR, user1);

        // Second withdrawal
        if (withdrawPercent2 > 0) {
            uint256 currentVal = adapter.currentValue();
            uint256 withdrawAmt = (currentVal * withdrawPercent2) / 100;
            if (withdrawAmt > 0) {
                vm.prank(address(parentVault));
                adapter.deallocate("", withdrawAmt, WITHDRAW_SELECTOR, user1);
            }
        }

        // Final invariant check
        assertLe(adapter.totalPrincipal(), totalDeposited);
    }

    /// @notice Fuzz test: currentValue >= 0 always
    function testFuzz_invariant_currentValueNonNegative(uint256 depositAmount, uint256 lossPercent) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint64).max);
        lossPercent = bound(lossPercent, 0, 99);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        underlyingVault.setLoss(lossPercent);

        assertGe(adapter.currentValue(), 0);
    }

    /// @notice Fuzz test: shares tracking consistency
    function testFuzz_invariant_sharesConsistency(uint256 depositAmount) public {
        depositAmount = bound(depositAmount, 1 ether, type(uint64).max);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), depositAmount);

        vm.prank(address(parentVault));
        adapter.allocate("", depositAmount, DEPOSIT_SELECTOR, user1);

        uint256 underlyingSharesTotal = adapter.underlyingShares();
        uint256 currentValue = adapter.currentValue();

        // Shares should be positive after deposit
        assertGt(underlyingSharesTotal, 0);
        // Current value should equal deposit (no loss yet)
        assertEq(currentValue, depositAmount);
        // userUnderlyingShares should equal total shares (single depositor)
        assertEq(adapter.userUnderlyingShares(user1), underlyingSharesTotal, "User shares == total shares");
    }

    /// @notice Fuzz test: userPrincipal sum <= totalPrincipal after multi-user deposits
    function testFuzz_invariant_userPrincipalConsistency(uint256 amount1, uint256 amount2) public {
        address user2 = address(0x2222);
        amount1 = bound(amount1, 1 ether, type(uint64).max / 2);
        amount2 = bound(amount2, 1 ether, type(uint64).max / 2);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount1);
        vm.prank(address(parentVault));
        adapter.allocate("", amount1, DEPOSIT_SELECTOR, user1);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount2);
        vm.prank(address(parentVault));
        adapter.allocate("", amount2, DEPOSIT_SELECTOR, user2);

        // Sum of per-user principals = totalPrincipal
        assertEq(
            adapter.userPrincipal(user1) + adapter.userPrincipal(user2),
            adapter.totalPrincipal(),
            "Sum of user principals should equal totalPrincipal"
        );
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: very small amounts
    function testFuzz_edge_smallAmounts(uint256 amount) public {
        amount = bound(amount, 1, 1000); // wei amounts

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount);

        vm.prank(address(parentVault));
        adapter.allocate("", amount, DEPOSIT_SELECTOR, user1);

        assertEq(adapter.totalPrincipal(), amount);
        assertEq(adapter.currentValue(), amount);
    }

    /// @notice Fuzz test: allocate then immediately deallocate full amount
    function testFuzz_edge_fullCycle(uint256 amount) public {
        amount = bound(amount, 1 ether, type(uint64).max);

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount);

        vm.prank(address(parentVault));
        adapter.allocate("", amount, DEPOSIT_SELECTOR, user1);

        assertEq(adapter.totalPrincipal(), amount);

        vm.prank(address(parentVault));
        adapter.deallocate("", amount, WITHDRAW_SELECTOR, user1);

        assertEq(adapter.totalPrincipal(), 0);
        assertEq(adapter.currentValue(), 0);
    }

    /// @notice Fuzz test: evaluate returns not payable when no pending claim
    function testFuzz_evaluate_noPendingClaim(
        uint256 policyIdInput,
        uint256 coverageLimit,
        uint256 claimAmount
    )
        public
        view
    {
        policyIdInput = bound(policyIdInput, 1, type(uint96).max);
        coverageLimit = bound(coverageLimit, 1 ether, type(uint128).max);
        claimAmount = bound(claimAmount, 1, coverageLimit);

        ISpec.EvaluationContext memory context = ISpec.EvaluationContext({
            policyId: uint96(policyIdInput),
            pool: address(coverPool),
            coverageLimit: coverageLimit,
            startTime: uint32(block.timestamp),
            maturityTime: uint32(block.timestamp + 365 days),
            evaluationTime: uint32(block.timestamp),
            evidenceHash: keccak256(abi.encodePacked("test")),
            additionalData: abi.encode(address(this), claimAmount)
        });

        ISpec.EvaluationResult memory result = adapter.evaluate(context);

        // Should always return not payable when no pending claim
        assertFalse(result.isPayable);
    }

    /*//////////////////////////////////////////////////////////////
                  ON POLICY BOUND PRECISION FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Fuzz test: onPolicyBound cap calculation has no precision loss for clean bps values
    function testFuzz_onPolicyBound_capPrecision(uint256 coverageLimit) public {
        // Bound coverage limit to reasonable range
        coverageLimit = bound(coverageLimit, 1 ether, type(uint128).max);

        // Use clean bps values that evenly divide 10000
        uint16[8] memory cleanBps = [uint16(100), 200, 250, 500, 1000, 2000, 2500, 5000];

        for (uint256 i = 0; i < cleanBps.length; i++) {
            uint256 multiplier = 10_000 / uint256(cleanBps[i]);
            uint256 cap = multiplier * coverageLimit;

            // Verify: cap * bps / 10000 == coverageLimit (exact roundtrip)
            uint256 reconstructed = (cap * cleanBps[i]) / 10_000;
            assertEq(reconstructed, coverageLimit, "Precision loss in cap calculation");
        }
    }

    /// @notice Fuzz test: onPolicyBound reverts for non-policyManager callers
    function testFuzz_onPolicyBound_revertsIfNotPolicyManager(address caller) public {
        vm.assume(caller != address(policyManager));

        // Deploy fresh adapter behind UUPS proxy (not yet bound)
        CatalysisCoverAdapter freshAdapter = _deployAdapterProxy(
            address(parentVault),
            address(underlyingVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS
        );

        vm.expectRevert(CatalysisCoverAdapter.NotAuthorized.selector);
        vm.prank(caller);
        freshAdapter.onPolicyBound(uint96(POLICY_ID), 10_000 ether);
    }

    /// @notice Fuzz test: onPolicyBound reverts when already executed
    function testFuzz_onPolicyBound_revertsIfAlreadyExecuted(uint96 anyPolicyId) public {
        // Adapter already bound during setUp
        vm.expectRevert(CatalysisCoverAdapter.PolicyBoundAlreadyExecuted.selector);
        vm.prank(address(policyManager));
        adapter.onPolicyBound(anyPolicyId, 10_000 ether);
    }
}
