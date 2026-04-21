package main

import (
	"math"
	"testing"
)

func approxEqual(t *testing.T, name string, got, want, tol float64) {
	t.Helper()
	if math.Abs(got-want) > tol {
		t.Errorf("%s: got %.10f, want %.10f (tol %.1e)", name, got, want, tol)
	}
}

func TestRunUnderwriting_NoLosses(t *testing.T) {
	out, err := runUnderwriting(AlgoInputs{
		NTotalPaths:      100,
		NLossPaths:       0,
		LossArray:        nil,
		Deductible:       0.01,
		Kappa:            0.25,
		ConfidenceLevels: []float64{0.995},
		TVLCovered:       1_000_000,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if out.ExpectedPayout != 0 || out.StdDev != 0 || out.PremiumRateDecimal != 0 {
		t.Errorf("expected all-zero outputs, got E[Y]=%v SD=%v P=%v", out.ExpectedPayout, out.StdDev, out.PremiumRateDecimal)
	}
	if out.AnnualPremiumBps != 0 {
		t.Errorf("expected 0 bps, got %v", out.AnnualPremiumBps)
	}
	if out.PerSecondPremiumWAD != "0" {
		t.Errorf("expected zero perSecondWAD, got %v", out.PerSecondPremiumWAD)
	}
}

func TestRunUnderwriting_AllEqualLosses(t *testing.T) {
	// All 100 paths lose 0.02, deductible 0.01 → y=0.01 each, SD=0, P=E[Y]=0.01.
	N := 100
	loss := make([]float64, N)
	for i := range loss {
		loss[i] = 0.02
	}
	out, err := runUnderwriting(AlgoInputs{
		NTotalPaths:      N,
		NLossPaths:       N,
		LossArray:        loss,
		Deductible:       0.01,
		Kappa:            0.5,
		ConfidenceLevels: []float64{0.995},
		TVLCovered:       1_000_000,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	approxEqual(t, "E[Y]", out.ExpectedPayout, 0.01, 1e-12)
	approxEqual(t, "SD(Y)", out.StdDev, 0, 1e-12)
	approxEqual(t, "P", out.PremiumRateDecimal, 0.01, 1e-12)
	approxEqual(t, "annual_bps", out.AnnualPremiumBps, 100, 1e-9)
	if out.NLossPathsDeductible != N {
		t.Errorf("NLossPathsDeductible: got %d want %d", out.NLossPathsDeductible, N)
	}
	approxEqual(t, "trigger_probability", out.TriggerProbability, 1.0, 1e-12)
}

func TestRunUnderwriting_DeductibleZeroesSubThreshold(t *testing.T) {
	// Two loss samples, one below deductible (l=0.005) and one above (l=0.05).
	out, err := runUnderwriting(AlgoInputs{
		NTotalPaths:      10,
		NLossPaths:       2,
		LossArray:        []float64{0.005, 0.05},
		Deductible:       0.01,
		Kappa:            0,
		ConfidenceLevels: []float64{0.5},
		TVLCovered:       0,
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Only the 0.05 path triggers; y = 0.04, the rest are 0.
	// E[Y] = 0.04 / 10 = 0.004.
	approxEqual(t, "E[Y]", out.ExpectedPayout, 0.004, 1e-12)
	if out.NLossPathsDeductible != 1 {
		t.Errorf("NLossPathsDeductible: got %d want 1", out.NLossPathsDeductible)
	}
	approxEqual(t, "trigger_probability", out.TriggerProbability, 0.1, 1e-12)
}

// TestRunUnderwriting_GauntletShape reproduces the Gauntlet base-case numbers
// from Premium Update Workflow §2.2.2 using a synthetic loss array with the
// right moments: N=100000, M=1822, M_d=655. We construct the 1822 positive-loss
// samples as 655 at the target payout + 1167 at sub-deductible (zero-payout)
// losses, then tune the 655 values so E[Y] and SD(Y) match.
func TestRunUnderwriting_GauntletShape(t *testing.T) {
	N := 100_000
	M := 1822
	Md := 655
	deductible := 0.01

	// Target post-deductible mean and std-dev (decimal form):
	// E[Y] = 0.0002313, SD(Y) = 0.0038415.
	targetEY := 0.0002313
	targetSD := 0.0038415

	// To reach those moments with a clean synthetic, use two-point payouts
	// over the 655 triggering paths: `hiCount` paths at payout `hi`, the
	// remaining `loCount` paths at payout `lo`. Closed-form choices:
	//   sum(y) over M = N * E[Y] = 23.13
	//   sum(y^2) over M = N * (Var + E[Y]^2) ≈ 1.47641...
	// Solve with hi=0.04505, lo = (23.13 - hiCount*hi) / loCount iteratively.
	// Simpler: use all-equal payout per trigger path, which gives the right
	// E[Y] but a smaller SD; then add a single "outlier" path to inflate
	// variance to the target. That yields a well-conditioned construction.
	//
	// Step 1: equal baseline → sum = 23.13, so y_base = 23.13/Md.
	// Step 2: we'll replace one path's payout with a larger value `yTail`
	//         and absorb the resulting mean drift by reducing the others
	//         uniformly. Closed-form:
	//   Let y_other = y0 - delta, yTail = y0 + (Md-1)*delta
	//   sum = Md*y0  → still N*E[Y] ✓
	//   Var_M = ((Md-1)*delta^2 + ((Md-1)*delta)^2) / Md
	//         = (Md-1)*delta^2 * (1 + Md-1) / Md = (Md-1)*delta^2
	//   We want total variance over all N paths:
	//     Var(Y) = (sumSqDiff_nonzero + (N-M)*E[Y]^2) / N = targetSD^2
	//     sumSqDiff_nonzero = N*targetSD^2 - (N-M)*E[Y]^2
	//   Separately, sumSqDiff_nonzero when payouts are (y_base-delta)*(M-1) and yTail once,
	//   around mean E[Y]:
	//     sumSqDiff_nonzero ≈ (Md-1)*(y_base - delta - E[Y])^2
	//                        + (y_base + (Md-1)*delta - E[Y])^2
	//                        + (M - Md)*(0 - E[Y])^2  // sub-deductible loss paths
	//
	// The algebra gets messy — easier: pick delta numerically via a small
	// bisection on total SD until it matches.
	loss := make([]float64, 0, M)
	// 1167 sub-deductible losses (positive gross loss, zero payout).
	subDedLoss := deductible * 0.5
	for i := 0; i < M-Md; i++ {
		loss = append(loss, subDedLoss)
	}
	// Base triggering payout before deductible.
	yBase := targetEY * float64(N) / float64(Md)
	lBase := yBase + deductible

	// Bisection for a "delta" that produces the target total SD.
	lo, hi := 0.0, 0.05
	var best []float64
	for iter := 0; iter < 60; iter++ {
		delta := (lo + hi) / 2
		trial := make([]float64, len(loss), M)
		copy(trial, loss)
		// Md-1 paths at (yBase - delta) + deductible; 1 path at (yBase + (Md-1)*delta) + deductible.
		for i := 0; i < Md-1; i++ {
			trial = append(trial, lBase-delta)
		}
		trial = append(trial, lBase+float64(Md-1)*delta)

		out, err := runUnderwriting(AlgoInputs{
			NTotalPaths:      N,
			NLossPaths:       M,
			LossArray:        trial,
			Deductible:       deductible,
			Kappa:            0.5,
			ConfidenceLevels: []float64{0.995},
			TVLCovered:       0,
		})
		if err != nil {
			t.Fatalf("underwriting failed: %v", err)
		}
		if out.StdDev < targetSD {
			lo = delta
		} else {
			hi = delta
		}
		best = trial
		if math.Abs(out.StdDev-targetSD) < 1e-7 {
			break
		}
	}

	out, err := runUnderwriting(AlgoInputs{
		NTotalPaths:      N,
		NLossPaths:       M,
		LossArray:        best,
		Deductible:       deductible,
		Kappa:            0.5,
		ConfidenceLevels: []float64{0.995},
		TVLCovered:       0,
	})
	if err != nil {
		t.Fatalf("final underwriting failed: %v", err)
	}

	approxEqual(t, "E[Y]", out.ExpectedPayout, targetEY, 1e-7)
	approxEqual(t, "SD(Y)", out.StdDev, targetSD, 1e-5)
	// Trigger probability = Md / N
	approxEqual(t, "trigger_probability", out.TriggerProbability, float64(Md)/float64(N), 1e-12)
	if out.NLossPathsDeductible != Md {
		t.Errorf("NLossPathsDeductible: got %d want %d", out.NLossPathsDeductible, Md)
	}
	// P at kappa=0.5 should be E[Y] + 0.5*SD(Y).
	expectedP := targetEY + 0.5*targetSD
	approxEqual(t, "P(kappa=0.5)", out.PremiumRateDecimal, expectedP, 1e-5)
	// Annual bps around 21.52 at kappa=0.5.
	approxEqual(t, "annual_bps", out.AnnualPremiumBps, expectedP*1e4, 1e-1)
}

func TestAnnualBpsToPerSecondWAD(t *testing.T) {
	// annualBps=100 → perSecond = 100 * 1e18 / (1e4 * 31_536_000)
	//                           = 1e20 / 3.1536e11 ≈ 317_097_919.83...
	// Truncated big.Int quotient.
	got := annualBpsToPerSecondWAD(100)
	wantFloor := int64(317_097_919)
	wantCeil := int64(317_097_920)
	if g := got.Int64(); g != wantFloor && g != wantCeil {
		t.Errorf("perSecondWAD(100bps): got %d, want %d or %d", g, wantFloor, wantCeil)
	}
}

func TestAnnualBpsToPerSecondWAD_Zero(t *testing.T) {
	if g := annualBpsToPerSecondWAD(0); g == nil || g.Sign() != 0 {
		t.Errorf("perSecondWAD(0): got %v, want 0", g)
	}
	if g := annualBpsToPerSecondWAD(math.NaN()); g == nil || g.Sign() != 0 {
		t.Errorf("perSecondWAD(NaN): got %v, want 0", g)
	}
}

