// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoveredVaultWrapper} from "../../src/defi/adapters/morpho/CoveredVaultWrapper.sol";
import {MockERC6, MockERC20} from "./mocks/Mocks.sol";
import {ControllableVault} from "./mocks/ControllableVault.sol";
import {RealCoverageSetup} from "./helpers/RealCoverageSetup.sol";

/// @title CoveredVaultWrapperPrecisionTest
/// @notice Tests for the 6-decimal token premium precision fix.
///
///         Certora finding: for 6-decimal tokens (e.g. USDC), the formula
///         `floor(totalPrincipal × rate × elapsed / WAD)` rounds to zero for
///         small principals or short elapsed windows, allowing a repeated-call
///         attack that avoids all premium and skews totalAssets().
///
///         Fix: scale principal to 18-decimal precision before the formula,
///         carry the WAD-scaled fractional remainder across calls in
///         `premiumAccrualRemainder`, and flush whole native units each call.
contract CoveredVaultWrapperPrecisionTest is RealCoverageSetup {
    uint256 constant WAD = 1e18;
    uint256 constant USDC_SCALE = 1e12; // premiumScaleFactor for 6-decimal token

    // Certora finding: rate and principal that each round to 0 per 2-second call
    // 5_000 USDC × 79_264_426 × 2 / 1e18 = 7.926e17 < 1 → floor = 0
    uint256 constant CERTORA_RATE = 79_264_426;
    uint256 constant USDC_DEPOSIT = 5000e6;

    // accruedWad produced per 2-second call with the above params:
    // mulDiv(5_000e18, 79_264_426 × 2, 1e18) = 792_644_260_000
    uint256 constant ACCRUED_WAD_PER_2S = 792_644_260_000;

    MockERC6 usdc;
    MockERC20 weth;
    ControllableVault usdcVault;
    ControllableVault wethVault;

    address curator = address(0xCCCC);
    address user = address(0xBEEF);
    address premiumRecipient = address(0xFEED);

    uint16 constant MAX_COVERABLE_BPS = 1000; // 10 %
    uint16 constant DEDUCTIBLE_BPS = 100; //  1 %

    function setUp() public {
        usdc = new MockERC6();
        weth = new MockERC20(); // 18-decimal
        usdcVault = new ControllableVault(address(usdc));
        wethVault = new ControllableVault(address(weth));

        _deployRealCoverage(curator, curator);

        vm.prank(curator);
        policyManager.setSupportedPayoutToken(address(usdc), true);
        vm.prank(curator);
        policyManager.setSupportedPayoutToken(address(weth), true);
    }

    // ── Helpers
    // ──────────────────────────────────────────────────────────────

    function _deployWrapper(ControllableVault vault, address payoutToken) internal returns (CoveredVaultWrapper w) {
        w = _deployWrapperProxy(
            address(vault),
            address(claimManager),
            address(coverPool),
            MAX_COVERABLE_BPS,
            DEDUCTIBLE_BPS,
            premiumRecipient,
            curator,
            "Precision Vault",
            "pvVault"
        );
        _createAndBindPolicy(
            address(w),
            address(w),
            payoutToken,
            type(uint128).max,
            uint32(block.timestamp),
            uint32(block.timestamp + 365 days),
            curator,
            address(w)
        );
    }

    function _mintAndApprove(MockERC20 token, CoveredVaultWrapper w, address to, uint256 amount) internal {
        token.mint(to, amount);
        vm.prank(to);
        token.approve(address(w), type(uint256).max);
    }

    // ── Scale factor initialisation
    // ───────────────────────────────────────────

    /// @notice premiumScaleFactor must be 1e12 for a 6-decimal vault.
    function test_sixDecimal_scaleFactor() public {
        CoveredVaultWrapper w = _deployWrapper(usdcVault, address(usdc));
        assertEq(w.premiumScaleFactor(), USDC_SCALE, "6-dec: scale factor must be 1e12");
    }

    /// @notice premiumScaleFactor must be 1 for an 18-decimal vault (formula is a no-op).
    function test_eighteenDecimal_scaleFactor() public {
        CoveredVaultWrapper w = _deployWrapper(wethVault, address(weth));
        assertEq(w.premiumScaleFactor(), 1, "18-dec: scale factor must be 1");
    }

    // ── Certora finding: exact rounding-to-zero reproduction ─────────────────

    /// @notice Two consecutive 2-second calls with the Certora finding's exact parameters.
    ///         Old code: both calls produce accrued = 0, premium silently lost forever.
    ///         New code: first call saves the remainder; second call flushes 1 USDC unit.
    function test_sixDecimal_certoraExact_remainderAccumulates() public {
        CoveredVaultWrapper w = _deployWrapper(usdcVault, address(usdc));
        _setPremiumRate(w, CERTORA_RATE, curator);
        _mintAndApprove(MockERC20(address(usdc)), w, user, USDC_DEPOSIT);
        vm.prank(user);
        w.deposit(USDC_DEPOSIT, user);

        // ── Call 1: accruedWad < 1 USDC unit → no state increment, but remainder saved ──
        vm.warp(block.timestamp + 2);
        w.collectPremium();

        assertEq(w.totalPremiumLiability(), 0, "call 1: no full unit yet");
        assertEq(w.premiumAccrualRemainder(), ACCRUED_WAD_PER_2S, "call 1: sub-unit remainder must be saved");

        // ── Call 2: combined remainder crosses 1 USDC unit threshold ──
        vm.warp(block.timestamp + 2);
        w.collectPremium();

        assertEq(w.totalPremiumLiability(), 1, "call 2: exactly 1 USDC unit accrued");
        assertEq(
            w.premiumAccrualRemainder(),
            2 * ACCRUED_WAD_PER_2S - USDC_SCALE,
            "call 2: remainder is (2*wad_per_2s - 1 unit)"
        );
    }

    // ── Drain-attack mitigation
    // ───────────────────────────────────────────────

    /// @notice Attacker calls every 2 seconds for 200 seconds (100 calls).
    ///         Old code: every call gives accrued = 0 → totalPremiumLiability stays 0.
    ///         New code: accumulated remainder eventually flushes whole units; result
    ///         must equal a single 200-second call (within ±1 rounding unit).
    function test_sixDecimal_drainAttack_cannotAvoidPremium() public {
        CoveredVaultWrapper w = _deployWrapper(usdcVault, address(usdc));
        _setPremiumRate(w, CERTORA_RATE, curator);
        _mintAndApprove(MockERC20(address(usdc)), w, user, USDC_DEPOSIT);
        vm.prank(user);
        w.deposit(USDC_DEPOSIT, user);

        for (uint256 i = 0; i < 100; i++) {
            vm.warp(block.timestamp + 2);
            w.collectPremium();
        }

        // One-shot 200-second calculation (ground truth):
        // floor(floor(5_000e18 × CERTORA_RATE × 200 / 1e18) / 1e12)
        //  = floor(79_264_426_000_000 / 1e12) = 79 USDC units
        uint256 expected = (USDC_DEPOSIT * USDC_SCALE) * CERTORA_RATE * 200 / WAD / USDC_SCALE;
        assertEq(expected, 79, "sanity: expected one-shot 200s accrual is 79 units");

        assertEq(w.totalPremiumLiability(), expected, "drain attack: 100 short calls must equal one 200s call");
    }

    // ── Remainder cleared on empty vault
    // ─────────────────────────────────────

    /// @notice After a full redeem totalPrincipal drops to 0.
    ///         The next _accruePremium() must clear premiumAccrualRemainder to prevent
    ///         a stale sub-unit from being applied to a future depositor's epoch.
    function test_sixDecimal_emptyVault_clearsRemainder() public {
        CoveredVaultWrapper w = _deployWrapper(usdcVault, address(usdc));
        _setPremiumRate(w, CERTORA_RATE, curator);
        _mintAndApprove(MockERC20(address(usdc)), w, user, USDC_DEPOSIT);
        vm.prank(user);
        w.deposit(USDC_DEPOSIT, user);

        // Populate the remainder
        vm.warp(block.timestamp + 2);
        w.collectPremium();
        assertGt(w.premiumAccrualRemainder(), 0, "pre-redeem: remainder must be non-zero");

        // Zero totalPrincipal directly (slot 56) to simulate a fully-withdrawn vault.
        // This bypasses the ERC4626 withdrawal machinery and isolates the _accruePremium
        // else-branch (premiumAccrualRemainder = 0 when totalPrincipal == 0).
        vm.store(address(w), bytes32(uint256(56)), bytes32(uint256(0)));
        assertEq(w.totalPrincipal(), 0, "totalPrincipal must be 0 after store");

        // Advance time so activeElapsed > 0; otherwise _accruePremium returns at the
        // "block.timestamp == checkpointTime" guard before reaching the else branch.
        vm.warp(block.timestamp + 2);

        // collectPremium() calls _accruePremium(); the else branch must clear the remainder
        w.collectPremium();
        assertEq(w.premiumAccrualRemainder(), 0, "post-empty: remainder must be cleared for next epoch");
    }

    // ── totalAssets() view reflects accumulated carry
    // ─────────────────────────

    /// @notice The view function _accruedPremiumFor() reads premiumAccrualRemainder from
    ///         storage so that totalAssets() accurately reflects sub-unit carry
    ///         even before the next state-modifying accrual checkpoint.
    function test_sixDecimal_totalAssetsView_reflectsCarry() public {
        CoveredVaultWrapper w = _deployWrapper(usdcVault, address(usdc));
        _setPremiumRate(w, CERTORA_RATE, curator);
        _mintAndApprove(MockERC20(address(usdc)), w, user, USDC_DEPOSIT);
        vm.prank(user);
        w.deposit(USDC_DEPOSIT, user);

        // First checkpoint: populates premiumAccrualRemainder, accrues 0 units
        vm.warp(block.timestamp + 2);
        w.collectPremium();
        assertEq(w.premiumAccrualRemainder(), ACCRUED_WAD_PER_2S);
        uint256 assetsAtCheckpoint = w.totalAssets();

        // Warp another 2s WITHOUT another checkpoint.
        // The view must combine the stored remainder with the new elapsed to read 1 unit.
        vm.warp(block.timestamp + 2);

        assertEq(
            assetsAtCheckpoint - w.totalAssets(), 1, "totalAssets view must reflect 1-unit carry after remainder fills"
        );
    }

    // ── 18-decimal regression
    // ─────────────────────────────────────────────────

    /// @notice With premiumScaleFactor == 1, the formula is mathematically identical
    ///         to the original code. Premium accrual for 18-decimal tokens must be unchanged.
    function test_eighteenDecimal_premiumAccrual_unchanged() public {
        uint256 rate = uint256(1e17) / 365 days; // ~10 %/year WAD-scaled (≈ 3_170_979_198)

        CoveredVaultWrapper w = _deployWrapper(wethVault, address(weth));
        _setPremiumRate(w, rate, curator);

        uint256 depositAmount = 1000 ether;
        _mintAndApprove(weth, w, user, depositAmount);
        vm.prank(user);
        w.deposit(depositAmount, user);

        uint256 elapsed = 365 days - 1; // stay inside policy window
        vm.warp(block.timestamp + elapsed);
        w.collectPremium();

        // Exact expected accrual: same formula the contract uses (no rounding gap)
        uint256 expectedAccrual = depositAmount * rate * elapsed / WAD;
        assertApproxEqAbs(w.totalPremiumLiability(), expectedAccrual, 1, "18-dec: annual accrual at 10%/year");
        assertEq(w.premiumAccrualRemainder(), 0, "18-dec: no fractional remainder (sf = 1 is a no-op)");
    }

    // ── Fuzz: short calls converge to the same total as one long call ─────────

    /// @notice For any valid rate, principal, and elapsed-per-call, N short calls must
    ///         produce the same totalPremiumLiability as a single call of N × elapsedPerCall,
    ///         within ±1 USDC unit (rounding bound from the final per-call flush).
    function testFuzz_sixDecimal_shortCallsMatchLongCall(
        uint256 rate,
        uint256 principal,
        uint256 elapsedPerCall,
        uint8 numCalls
    )
        public
    {
        rate = bound(rate, 1, 15_854_895_991); // [1 wei/s, max 50 %/year]
        principal = bound(principal, 1e6, 1_000_000e6); // [1 USDC, 1M USDC]
        elapsedPerCall = bound(elapsedPerCall, 1, 3600); // [1s, 1h]
        numCalls = uint8(bound(numCalls, 2, 100));

        CoveredVaultWrapper w = _deployWrapper(usdcVault, address(usdc));
        _setPremiumRate(w, rate, curator);
        _mintAndApprove(MockERC20(address(usdc)), w, user, principal);
        vm.prank(user);
        w.deposit(principal, user);

        // N short calls
        for (uint256 i = 0; i < numCalls; i++) {
            vm.warp(block.timestamp + elapsedPerCall);
            w.collectPremium();
        }
        uint256 accrualFromShortCalls = w.totalPremiumLiability();

        // Ground-truth: same arithmetic the contract uses, over totalElapsed in one shot
        uint256 totalElapsed = uint256(numCalls) * elapsedPerCall;
        uint256 expected = principal * rate * totalElapsed / WAD;

        assertApproxEqAbs(
            accrualFromShortCalls, expected, 1, "fuzz: N short calls must equal one long call within 1 unit"
        );
    }
}
