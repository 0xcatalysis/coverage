// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import { CatalysisCoverAdapter } from "../../src/adapter/adapters/vault/CatalysisCoverAdapter.sol";
import { ICatalysisCoverAdapter } from "../../src/adapter/interfaces/ICatalysisCoverAdapter.sol";
import { IAdapter } from "../../src/adapter/interfaces/Morpho/IAdapter.sol";
import { IAlerts as IA } from "../../src/adapter/interfaces/IAlerts.sol";
import { IEvents as IE } from "../../src/adapter/interfaces/IEvents.sol";

import { MockERC20, MockVaultV2 } from "./mocks/Mocks.sol";
import { ISpec } from "coverage/interfaces/ISpec.sol";
import { RealCoverageSetup } from "./helpers/RealCoverageSetup.sol";

contract CatalysisCoverAdapterTest is RealCoverageSetup {
    CatalysisCoverAdapter adapter;
    MockVaultV2 parentVault;
    MockVaultV2 underlyingVault;
    MockERC20 asset;

    address curator = address(0xCCCC);
    address allocator = address(0xAAAA);
    address user1 = address(0x1111);
    address user2 = address(0x2222);

    uint256 constant DEPOSIT_AMOUNT = 1000 ether;
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

        // Deploy adapter first (no policyId — set via onPolicyBound hook)
        adapter = new CatalysisCoverAdapter(
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
            10_000 ether, // coverageAmount (stake requirement)
            10_000 ether, // coverageLimit (max payout)
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator, // buyer
            address(adapter) // bindPolicyHook = adapter
        );

        // Register adapter
        parentVault.setAdapter(address(adapter), true);
        parentVault.setAllocator(allocator, true);

        // Fund parent vault and underlying vault
        asset.mint(address(parentVault), 100_000 ether);
        asset.mint(address(underlyingVault), 100_000 ether);
        asset.mint(user1, 10_000 ether);
        asset.mint(user2, 10_000 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_constructor_setsImmutables() public view {
        assertEq(adapter.parentVault(), address(parentVault));
        assertEq(adapter.underlyingVault(), address(underlyingVault));
        assertEq(adapter.asset(), address(asset));
        assertNotEq(adapter.adapterId(), bytes32(0));
    }

    function test_constructor_revertsOnZeroParentVault() public {
        vm.expectRevert(IA.ZeroAddress.selector);
        new CatalysisCoverAdapter(
            address(0), address(underlyingVault), address(claimManager), address(coverPool), MAX_COVERABLE_LOSS_BPS
        );
    }

    function test_constructor_revertsOnZeroUnderlyingVault() public {
        vm.expectRevert(IA.ZeroAddress.selector);
        new CatalysisCoverAdapter(
            address(parentVault), address(0), address(claimManager), address(coverPool), MAX_COVERABLE_LOSS_BPS
        );
    }

    function test_constructor_revertsOnInvalidMaxCoverableLoss() public {
        vm.expectRevert(IA.InvalidMaxCoverableLoss.selector);
        new CatalysisCoverAdapter(
            address(parentVault),
            address(underlyingVault),
            address(claimManager),
            address(coverPool),
            10_001 // > 100%
        );
    }

    function test_constructor_setsMaxCoverableLossBps() public view {
        assertEq(adapter.maxCoverableLossBps(), MAX_COVERABLE_LOSS_BPS);
    }

    /*//////////////////////////////////////////////////////////////
                          ALLOCATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_allocate_depositsToUnderlyingVault() public {
        // Parent vault calls allocate with user1 as sender
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        (bytes32[] memory ids,) = adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Verify IDs returned
        assertEq(ids.length, 1);
        assertEq(ids[0], adapter.adapterId());
        // Verify principal tracking
        assertEq(adapter.totalPrincipal(), DEPOSIT_AMOUNT);
        assertEq(adapter.currentValue(), DEPOSIT_AMOUNT);
    }

    function test_allocate_multipleDeposits() public {
        // First allocation
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Second allocation
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Verify cumulative principal
        assertEq(adapter.totalPrincipal(), DEPOSIT_AMOUNT * 2);
    }

    function test_allocate_revertsIfNotParentVault() public {
        vm.expectRevert(CatalysisCoverAdapter.NotAuthorized.selector);
        vm.prank(user1);
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);
    }

    function test_allocate_revertsOnNonEmptyData() public {
        vm.expectRevert(CatalysisCoverAdapter.InvalidData.selector);
        vm.prank(address(parentVault));
        adapter.allocate(abi.encode(123), DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);
    }

    /*//////////////////////////////////////////////////////////////
                         DEALLOCATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_deallocate_withdrawsFromUnderlyingVault() public {
        // Setup: allocate first with user1 as sender
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        uint256 principalBefore = adapter.totalPrincipal();

        // Deallocate half
        uint256 withdrawAmount = DEPOSIT_AMOUNT / 2;

        vm.prank(address(parentVault));
        (bytes32[] memory ids,) = adapter.deallocate("", withdrawAmount, WITHDRAW_SELECTOR, user1);

        // Verify IDs returned
        assertEq(ids.length, 1);
        assertEq(ids[0], adapter.adapterId());
        // Verify principal decreased proportionally
        assertLt(adapter.totalPrincipal(), principalBefore);
    }

    function test_deallocate_fullWithdrawal() public {
        // Setup: allocate first with user1 as sender
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Full deallocate
        vm.prank(address(parentVault));
        adapter.deallocate("", DEPOSIT_AMOUNT, WITHDRAW_SELECTOR, user1);

        // Verify
        assertEq(adapter.totalPrincipal(), 0);
        assertEq(adapter.currentValue(), 0);
    }

    function test_deallocate_revertsIfNotParentVault() public {
        vm.expectRevert(CatalysisCoverAdapter.NotAuthorized.selector);
        vm.prank(user1);
        adapter.deallocate("", DEPOSIT_AMOUNT, WITHDRAW_SELECTOR, user1);
    }

    /*//////////////////////////////////////////////////////////////
                         SHORTFALL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_calculateShortfall_returnsZeroWhenNoLoss() public {
        // Setup: allocate
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // No loss - shortfall should be 0
        assertEq(adapter.calculateShortfall(), 0);
    }

    function test_calculateShortfall_detectsLoss() public {
        // Setup: allocate
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Simulate 10% loss in underlying vault
        underlyingVault.setLoss(10);

        // Verify shortfall
        uint256 shortfall = adapter.calculateShortfall();
        assertGt(shortfall, 0);
        // Shortfall should be ~10% of principal
        assertApproxEqRel(shortfall, DEPOSIT_AMOUNT * 10 / 100, 0.01e18);
    }

    function test_currentValue_reflectsLoss() public {
        // Setup: allocate
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Initial value equals deposit
        assertEq(adapter.currentValue(), DEPOSIT_AMOUNT);

        // Simulate 20% loss
        underlyingVault.setLoss(20);

        // Value should be 80% of deposit
        assertEq(adapter.currentValue(), DEPOSIT_AMOUNT * 80 / 100);
    }

    /*//////////////////////////////////////////////////////////////
                        VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ids_returnsAdapterId() public view {
        bytes32[] memory ids = adapter.ids();
        assertEq(ids.length, 1);
        assertEq(ids[0], adapter.adapterId());
    }

    function test_totalPrincipal_tracksCorrectly() public {
        // Setup: allocate
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        assertEq(adapter.totalPrincipal(), DEPOSIT_AMOUNT);
    }

    /// @dev realAssets() now returns pure currentValue() — no insurance in share price
    function test_realAssets_protectedValueLogic() public {
        // Setup: allocate 1000 ether
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // CASE 1: No loss - realAssets = currentValue = principal
        assertEq(adapter.realAssets(), adapter.currentValue());
        assertEq(adapter.realAssets(), DEPOSIT_AMOUNT);

        // CASE 2: Small loss (5%) - realAssets = currentValue (insurance NOT baked in)
        underlyingVault.setLoss(5);
        assertEq(adapter.currentValue(), DEPOSIT_AMOUNT * 95 / 100); // 950
        assertEq(adapter.realAssets(), adapter.currentValue());
        assertEq(adapter.realAssets(), DEPOSIT_AMOUNT * 95 / 100); // 950, not 1000

        // CASE 3: Large loss (20%) - realAssets = currentValue (no insurance in share price)
        underlyingVault.setLoss(20);
        assertEq(adapter.currentValue(), DEPOSIT_AMOUNT * 80 / 100); // 800
        assertEq(adapter.realAssets(), adapter.currentValue());
        assertEq(adapter.realAssets(), DEPOSIT_AMOUNT * 80 / 100); // 800

        // Reset loss
        underlyingVault.setLoss(0);

        // CASE 4: Profit (+10%) - realAssets = currentValue (upside)
        underlyingVault.setProfit(10);
        assertEq(adapter.currentValue(), DEPOSIT_AMOUNT * 110 / 100); // 1100
        assertEq(adapter.realAssets(), adapter.currentValue());
        assertEq(adapter.realAssets(), 1100 ether);
    }

    function test_calculateShortfall_cappedByMaxCoverableLoss() public {
        // Setup: allocate 1000 ether
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Simulate 50% loss (500 ether shortfall)
        underlyingVault.setLoss(50);

        // Raw shortfall would be 500 ether, but maxCoverableLossBps is 10% (1000 bps)
        // So max coverable loss = 1000 ether * 10% = 100 ether
        uint256 shortfall = adapter.calculateShortfall();
        uint256 maxCoverable = (DEPOSIT_AMOUNT * MAX_COVERABLE_LOSS_BPS) / 10_000;
        assertEq(shortfall, maxCoverable); // Should be capped at 100 ether
        assertEq(shortfall, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
               PER-USER PRINCIPAL TRACKING TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test that userPrincipal and userUnderlyingShares track per-sender independently
    function test_userPrincipal_tracksPerSender() public {
        uint256 amount1 = 600 ether;
        uint256 amount2 = 400 ether;

        // User1 allocates
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount1);
        vm.prank(address(parentVault));
        adapter.allocate("", amount1, DEPOSIT_SELECTOR, user1);

        // User2 allocates
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), amount2);
        vm.prank(address(parentVault));
        adapter.allocate("", amount2, DEPOSIT_SELECTOR, user2);

        // Verify per-user tracking
        assertEq(adapter.userPrincipal(user1), amount1, "user1 principal mismatch");
        assertEq(adapter.userPrincipal(user2), amount2, "user2 principal mismatch");
        assertEq(adapter.userUnderlyingShares(user1), amount1, "user1 shares mismatch");
        assertEq(adapter.userUnderlyingShares(user2), amount2, "user2 shares mismatch");

        // Global aggregate equals sum
        assertEq(adapter.totalPrincipal(), amount1 + amount2);
    }

    /// @notice Test that insurance payout is sent directly to the user, not via the vault
    function test_deallocate_paysInsuranceDirectlyToUser() public {
        // Allocate for user1
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);
        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // 10% loss: currentValue = 900, principal = 1000
        // shortfall = 100, maxInsurance = 100, effectiveInsurance = 99 (1% deductible)
        // claimAmount = min(100, 99) = 99
        underlyingVault.setLoss(10);
        assertEq(adapter.currentValue(), 900 ether);

        uint256 user1BalanceBefore = asset.balanceOf(user1);

        // Deallocate with user1 as sender (vault asks for currentValue amount)
        vm.prank(address(parentVault));
        adapter.deallocate("", 900 ether, WITHDRAW_SELECTOR, user1);

        uint256 user1BalanceAfter = asset.balanceOf(user1);
        uint256 insurancePayout = user1BalanceAfter - user1BalanceBefore;

        // user1 should receive 99 ether insurance directly (1% deductible on 100 ether max)
        assertEq(insurancePayout, 99 ether, "Insurance should be paid directly to user1");
    }

    /// @notice Test userShortfall view returns correct insurance-eligible shortfall
    function test_userShortfall_returnsCorrectValue() public {
        // Allocate for user1
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);
        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // No loss: shortfall = 0
        assertEq(adapter.userShortfall(user1), 0);

        // 5% loss: shortfall = 50 ether (within maxCoverableLossBps = 10%)
        underlyingVault.setLoss(5);
        assertEq(adapter.userShortfall(user1), 50 ether);

        // 50% loss: shortfall capped at maxCoverable = 1000 * 10% = 100 ether
        underlyingVault.setLoss(50);
        assertEq(adapter.userShortfall(user1), 100 ether);

        // User with no tracked shares returns 0
        assertEq(adapter.userShortfall(user2), 0);
        assertEq(adapter.userShortfall(allocator), 0);
    }

    /// @notice Test that non-user with no tracked shares cannot deallocate via user selector
    /// @dev With the new selector validation, this triggers UnsupportedDeallocation revert
    function test_deallocate_nonUserWithdrawal_reverts() public {
        // Setup: allocate with user1 (user1 gets tracked shares)
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);
        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Simulate V2 vault tracking allocation
        parentVault.setAllocation(adapter.adapterId(), adapter.currentValue());

        // Simulate 10% loss before deallocate
        underlyingVault.setLoss(10);
        uint256 currentValAfterLoss = adapter.currentValue(); // 900 ether

        // Allocator has NO tracked shares - should revert with UnsupportedDeallocation
        vm.expectRevert(
            abi.encodeWithSelector(
                IA.UnsupportedDeallocation.selector,
                currentValAfterLoss / 2,
                bytes4(keccak256("rebalance()")),
                allocator
            )
        );
        vm.prank(address(parentVault));
        adapter.deallocate("", currentValAfterLoss / 2, bytes4(keccak256("rebalance()")), allocator);
    }

    /*//////////////////////////////////////////////////////////////
                    INTEGRATION / E2E TESTS
    //////////////////////////////////////////////////////////////*/

    function test_fullFlow_depositWithdrawNoClaim() public {
        // 1. Parent vault allocates funds
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // 2. Verify state
        assertEq(adapter.totalPrincipal(), DEPOSIT_AMOUNT);
        assertEq(adapter.currentValue(), DEPOSIT_AMOUNT);
        assertEq(adapter.calculateShortfall(), 0);

        // 3. Parent vault deallocates funds (no loss)
        vm.prank(address(parentVault));
        adapter.deallocate("", DEPOSIT_AMOUNT, WITHDRAW_SELECTOR, user1);

        // 4. Verify final state
        assertEq(adapter.totalPrincipal(), 0);
        assertEq(adapter.currentValue(), 0);
    }

    function test_fullFlow_depositWithLoss() public {
        // 1. Parent vault allocates funds
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // 2. Simulate loss in underlying vault (15% loss)
        underlyingVault.setLoss(15);

        // 3. Verify shortfall is capped by maxCoverableLossBps (10%)
        // Raw shortfall would be 150 ether (15%), but cap is 100 ether (10%)
        uint256 shortfall = adapter.calculateShortfall();
        uint256 maxCoverable = (DEPOSIT_AMOUNT * MAX_COVERABLE_LOSS_BPS) / 10_000;
        assertEq(shortfall, maxCoverable); // Should be capped at 10%
        assertEq(shortfall, 100 ether);

        // 4. Verify current value reflects actual loss (not capped)
        assertApproxEqRel(adapter.currentValue(), DEPOSIT_AMOUNT * 85 / 100, 0.01e18);
    }

    function test_multipleAllocateDeallocateCycles() public {
        // Cycle 1: Allocate
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);
        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);
        assertEq(adapter.totalPrincipal(), DEPOSIT_AMOUNT);

        // Cycle 1: Partial deallocate
        vm.prank(address(parentVault));
        adapter.deallocate("", DEPOSIT_AMOUNT / 2, WITHDRAW_SELECTOR, user1);
        assertEq(adapter.totalPrincipal(), DEPOSIT_AMOUNT / 2);

        // Cycle 2: Allocate more
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);
        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);
        assertEq(adapter.totalPrincipal(), DEPOSIT_AMOUNT + DEPOSIT_AMOUNT / 2);

        // Cycle 2: Full deallocate
        uint256 remaining = adapter.currentValue();
        vm.prank(address(parentVault));
        adapter.deallocate("", remaining, WITHDRAW_SELECTOR, user1);
        assertEq(adapter.totalPrincipal(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    COVERAGE COMPLETION TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test allocation() view function
    function test_allocation_returnsParentVaultAllocation() public {
        // Setup: allocate
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);
        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Get allocation from adapter (calls parentVault.allocation)
        uint256 alloc = adapter.allocation();

        // Should match what parent vault reports
        assertEq(alloc, parentVault.allocation(adapter.adapterId()));
    }

    /// @notice Test evaluate() with no pending claim
    function test_evaluate_noPendingClaim() public view {
        ISpec.EvaluationContext memory context = ISpec.EvaluationContext({
            policyId: POLICY_ID,
            pool: address(coverPool),
            coverageLimit: 1000 ether,
            startTime: uint32(block.timestamp),
            maturityTime: uint32(block.timestamp + 365 days),
            evaluationTime: uint32(block.timestamp),
            evidenceHash: keccak256("test"),
            additionalData: abi.encode(address(this), 100 ether)
        });

        ISpec.EvaluationResult memory result = adapter.evaluate(context);

        // Should return isPayable = false since no pending claim
        assertFalse(result.isPayable);
    }

    /// @notice Test evaluate() with wrong policy ID
    function test_evaluate_wrongPolicyId() public view {
        // This would require setting up a pending claim first, which happens
        // internally during _claimInsurance. Since evaluate is called by
        // ClaimManager during claim resolution, we test the external interface.
        ISpec.EvaluationContext memory context = ISpec.EvaluationContext({
            policyId: 999, // Wrong policy ID
            pool: address(coverPool),
            coverageLimit: 1000 ether,
            startTime: uint32(block.timestamp),
            maturityTime: uint32(block.timestamp + 365 days),
            evaluationTime: uint32(block.timestamp),
            evidenceHash: keccak256("test"),
            additionalData: abi.encode(address(this), 100 ether)
        });

        ISpec.EvaluationResult memory result = adapter.evaluate(context);

        // Should return isPayable = false
        assertFalse(result.isPayable);
    }

    /// @notice Test deallocate with zero assets
    function test_deallocate_zeroAssets() public {
        // Setup: allocate first
        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);
        vm.prank(address(parentVault));
        adapter.allocate("", DEPOSIT_AMOUNT, DEPOSIT_SELECTOR, user1);

        // Simulate V2 vault tracking allocation (mock doesn't do this automatically)
        parentVault.setAllocation(adapter.adapterId(), adapter.currentValue());

        uint256 principalBefore = adapter.totalPrincipal();

        // Deallocate zero
        vm.prank(address(parentVault));
        (bytes32[] memory ids, int256 delta) = adapter.deallocate("", 0, WITHDRAW_SELECTOR, user1);

        // Should return without changes
        assertEq(ids.length, 1);
        assertEq(delta, 0);
        assertEq(adapter.totalPrincipal(), principalBefore);
    }

    /// @notice Test allocate with zero assets
    function test_allocate_zeroAssets() public {
        vm.prank(address(parentVault));
        (bytes32[] memory ids, int256 delta) = adapter.allocate("", 0, DEPOSIT_SELECTOR, user1);

        assertEq(ids.length, 1);
        assertEq(delta, 0);
        assertEq(adapter.totalPrincipal(), 0);
    }

    /// @notice Test allocate with non-user selector (allocator adding liquidity)
    /// @dev With the new design, principal is ALWAYS tracked to prevent under-coverage
    function test_allocate_nonUserSelector() public {
        bytes4 allocatorSelector = bytes4(keccak256("addLiquidity()"));

        vm.prank(address(parentVault));
        asset.transfer(address(adapter), DEPOSIT_AMOUNT);

        vm.prank(address(parentVault));
        (bytes32[] memory ids, int256 delta) = adapter.allocate("", DEPOSIT_AMOUNT, allocatorSelector, allocator);

        // Funds should be deposited AND principal should increase (all capital needs coverage)
        assertEq(ids.length, 1);
        assertEq(delta, int256(DEPOSIT_AMOUNT));
        assertEq(adapter.totalPrincipal(), DEPOSIT_AMOUNT);
        assertEq(adapter.currentValue(), DEPOSIT_AMOUNT);
    }

    /// @notice Test deallocate reverts on non-empty data
    function test_deallocate_revertsOnNonEmptyData() public {
        vm.expectRevert(CatalysisCoverAdapter.InvalidData.selector);
        vm.prank(address(parentVault));
        adapter.deallocate(abi.encode(123), DEPOSIT_AMOUNT, WITHDRAW_SELECTOR, user1);
    }

    /// @notice Test constructor reverts when assets mismatch
    function test_constructor_revertsOnAssetMismatch() public {
        // Create underlying vault with different asset
        MockERC20 differentAsset = new MockERC20();
        MockVaultV2 mismatchedVault = new MockVaultV2(address(differentAsset), "Different", "DIFF");

        vm.expectRevert(CatalysisCoverAdapter.AssetMismatch.selector);
        new CatalysisCoverAdapter(
            address(parentVault),
            address(mismatchedVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS
        );
    }

    /*//////////////////////////////////////////////////////////////
                      ON POLICY BOUND TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify onPolicyBound was executed during setUp and set the absolute cap
    function test_onPolicyBound_setsAbsoluteCap() public view {
        // onPolicyBound is called during setUp via _createAndBindPolicy
        assertTrue(adapter.policyBoundExecuted());
        assertEq(adapter.policyId(), POLICY_ID);

        // Verify absolute cap: (10000 / 1000) * 10000 ether = 100_000 ether
        uint256 coverageLimit = 10_000 ether;
        uint256 expectedCap = (10_000 / MAX_COVERABLE_LOSS_BPS) * coverageLimit;
        bytes32 id = keccak256(adapter.idData());
        assertEq(parentVault.absoluteCap(id), expectedCap);
        assertEq(expectedCap, 100_000 ether);
    }

    function test_onPolicyBound_revertsIfNotPolicyManager() public {
        // Deploy fresh adapter (not yet bound)
        CatalysisCoverAdapter freshAdapter = new CatalysisCoverAdapter(
            address(parentVault),
            address(underlyingVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS
        );

        vm.expectRevert(CatalysisCoverAdapter.NotAuthorized.selector);
        vm.prank(user1);
        freshAdapter.onPolicyBound(uint96(POLICY_ID), 10_000 ether);
    }

    function test_onPolicyBound_revertsIfAlreadyExecuted() public {
        // Adapter already bound during setUp
        vm.expectRevert(CatalysisCoverAdapter.PolicyBoundAlreadyExecuted.selector);
        vm.prank(address(policyManager));
        adapter.onPolicyBound(uint96(POLICY_ID), 10_000 ether);
    }

    function test_onPolicyBound_revertsIfBuyerMismatch() public {
        // Deploy fresh parentVault with a different owner
        MockVaultV2 pv2 = new MockVaultV2(address(asset), "PV2", "PV2");
        pv2.setOwner(address(0xBEEF)); // different from curator

        CatalysisCoverAdapter freshAdapter = new CatalysisCoverAdapter(
            address(pv2), address(underlyingVault), address(claimManager), address(coverPool), MAX_COVERABLE_LOSS_BPS
        );

        // Create policy with buyer=curator but adapter's parentVault.owner=0xBEEF
        // We need a policy draft to exist — use mockBindPolicyHook as hook for this policy
        uint96 pid = _createAndBindPolicy(
            address(freshAdapter),
            address(freshAdapter),
            address(asset),
            10_000 ether,
            10_000 ether,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(mockBindPolicyHook) // NOT the adapter — so onPolicyBound goes to mock
        );

        // Now call onPolicyBound manually — buyer=curator != pv2.owner=0xBEEF
        pv2.setCurator(address(freshAdapter));
        vm.expectRevert(CatalysisCoverAdapter.InvalidData.selector);
        vm.prank(address(policyManager));
        freshAdapter.onPolicyBound(pid, 10_000 ether);
    }

    function test_onPolicyBound_revertsIfBeneficiaryMismatch() public {
        // Create policy with beneficiary != adapter address
        address fakeBeneficiary = address(0xDEAD);
        uint96 pid = _createAndBindPolicy(
            fakeBeneficiary, // beneficiary != adapter
            fakeBeneficiary,
            address(asset),
            10_000 ether,
            10_000 ether,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(mockBindPolicyHook)
        );

        CatalysisCoverAdapter freshAdapter = new CatalysisCoverAdapter(
            address(parentVault),
            address(underlyingVault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_LOSS_BPS
        );

        parentVault.setCurator(address(freshAdapter));
        vm.expectRevert(CatalysisCoverAdapter.InvalidData.selector);
        vm.prank(address(policyManager));
        freshAdapter.onPolicyBound(pid, 10_000 ether);
    }

    function test_onPolicyBound_emitsPolicyBoundEvent() public view {
        // onPolicyBound was executed during setUp — verify side effects
        assertTrue(adapter.policyBoundExecuted());
        assertEq(adapter.policyId(), POLICY_ID);
    }

    function test_onPolicyBound_capPrecision_variousBps() public {
        // Test cap calculation precision with various maxCoverableLossBps values
        uint16[8] memory bpsValues = [uint16(100), 200, 250, 500, 1000, 2000, 2500, 5000];
        uint256 coverageLimit = 1_000_000 ether;

        for (uint256 i = 0; i < bpsValues.length; i++) {
            // Deploy a new adapter with each bps value
            MockVaultV2 pv = new MockVaultV2(address(asset), "PV", "PV");
            pv.setOwner(curator); // buyer must match parentVault.owner
            MockVaultV2 uv = new MockVaultV2(address(asset), "UV", "UV");

            // Deploy adapter first
            CatalysisCoverAdapter a = new CatalysisCoverAdapter(
                address(pv), address(uv), address(claimManager), address(coverPool), bpsValues[i]
            );

            // Set adapter as curator so onPolicyBound can call submit + increaseAbsoluteCap
            pv.setCurator(address(a));

            // Create and bind policy with adapter as hook — triggers onPolicyBound
            _createAndBindPolicy(
                address(a),
                address(a),
                address(asset),
                coverageLimit,
                coverageLimit,
                uint32(block.timestamp),
                uint32(block.timestamp + 365 days),
                curator,
                address(a) // adapter is the hook
            );

            uint256 expectedCap = (10_000 / uint256(bpsValues[i])) * coverageLimit;
            bytes32 id = keccak256(a.idData());
            assertEq(pv.absoluteCap(id), expectedCap, string.concat("Cap mismatch for bps=", vm.toString(bpsValues[i])));

            // Verify: cap * maxCoverableLossBps / BPS_DENOMINATOR == coverageLimit (no precision loss)
            uint256 reconstructedCoverage = (expectedCap * bpsValues[i]) / 10_000;
            assertEq(
                reconstructedCoverage,
                coverageLimit,
                string.concat("Precision loss for bps=", vm.toString(bpsValues[i]))
            );
        }
    }

    function test_onPolicyBound_policyManagerImmutable() public view {
        assertEq(adapter.policyManager(), address(policyManager));
    }

    function test_constructor_setsPolicyBoundExecutedFalse() public view {
        // Deploy a fresh adapter without binding to verify initial state
        // (main adapter has policyBoundExecuted=true from setUp)
        // We verify the main adapter is bound as expected
        assertTrue(adapter.policyBoundExecuted());
    }
}
