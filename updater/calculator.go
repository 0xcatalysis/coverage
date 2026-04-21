package main

import (
	"fmt"
	"math"
	"math/big"
	"sort"
)

// secondsPerYear is the constant used when converting annual bps to a per-second
// WAD-scaled rate for on-chain storage.
const secondsPerYear = 31_536_000

// AlgoInputs is the full set of parameters consumed by the Catalysis
// underwriting algorithm. Simulation-derived fields come from Credora; the
// remaining fields are per-vault config.
type AlgoInputs struct {
	VaultAddress     string    `json:"vault_address"`
	NTotalPaths      int       `json:"n_total_paths"`
	NLossPaths       int       `json:"n_loss_paths"`
	LossArray        []float64 `json:"-"` // Omit from JSON (not useful in notifications, can be huge)
	Deductible       float64   `json:"deductible"`
	Kappa            float64   `json:"kappa"`
	ConfidenceLevels []float64 `json:"confidence_levels"`
	TVLCovered       float64   `json:"tvl_covered"`
}

// VaRPoint represents a single VaR/ES data point, keyed by confidence level.
// Used for JSON serialization (maps with float64 keys are not JSON-serializable).
type VaRPoint struct {
	ConfidenceLevel float64 `json:"confidence_level"`
	Value           float64 `json:"value"`
}

// AlgoOutputs captures every derived quantity we want to emit in notifications.
// Float values are in decimal form (0.01 == 1%) unless the name says otherwise.
type AlgoOutputs struct {
	NLossPathsDeductible    int         `json:"n_loss_paths_deductible"`
	TriggerProbability      float64     `json:"trigger_probability"`
	ExpectedPayout          float64     `json:"expected_payout"`
	Variance                float64     `json:"variance"`
	StdDev                  float64     `json:"std_dev"`
	PremiumRateDecimal      float64     `json:"premium_rate_decimal"`
	AnnualPremiumBps        float64     `json:"annual_premium_bps"`
	PerSecondPremiumWAD     string      `json:"per_second_premium_wad"` // WAD string (uint256 max safe in JSON)
	MaxPayout               float64     `json:"max_payout"`
	VaR                     []VaRPoint  `json:"var"`
	ES                      []VaRPoint  `json:"es"`
	MinReserveDollars       float64     `json:"min_reserve_dollars"`
	WorstCaseReserveDollars float64     `json:"worst_case_reserve_dollars"`

	// Internal maps for algorithm use (not JSON-serialized)
	varMap                  map[float64]float64 `json:"-"`
	esMap                   map[float64]float64 `json:"-"`
}

// runUnderwriting executes the full algorithm described in Premium Update
// Workflow §2.2.1 for one vault.
func runUnderwriting(in AlgoInputs) (AlgoOutputs, error) {
	if in.NTotalPaths <= 0 {
		return AlgoOutputs{}, fmt.Errorf("n_total_paths must be > 0, got %d", in.NTotalPaths)
	}
	if in.NLossPaths < 0 || in.NLossPaths > in.NTotalPaths {
		return AlgoOutputs{}, fmt.Errorf("n_loss_paths=%d out of range [0,%d]", in.NLossPaths, in.NTotalPaths)
	}
	if len(in.LossArray) != in.NLossPaths {
		return AlgoOutputs{}, fmt.Errorf("len(loss_array)=%d does not match n_loss_paths=%d", len(in.LossArray), in.NLossPaths)
	}
	if in.Deductible < 0 || in.Deductible >= 1 {
		return AlgoOutputs{}, fmt.Errorf("deductible %v must be in [0,1)", in.Deductible)
	}
	if in.Kappa < 0 {
		return AlgoOutputs{}, fmt.Errorf("kappa %v must be >= 0", in.Kappa)
	}

	N := in.NTotalPaths
	M := in.NLossPaths

	// Step 3.1: deductible transform on positive-loss samples.
	yPositive := make([]float64, 0, M)
	Md := 0
	for _, l := range in.LossArray {
		y := l - in.Deductible
		if y < 0 {
			y = 0
		}
		yPositive = append(yPositive, y)
		if y > 0 {
			Md++
		}
	}

	// Step 3.2: full payout distribution Y of length N (M samples + N-M zeros).
	Y := make([]float64, 0, N)
	Y = append(Y, yPositive...)
	for i := 0; i < N-M; i++ {
		Y = append(Y, 0)
	}

	// Step 3.3 trigger probability.
	p := float64(Md) / float64(N)

	// Step 3.4 E[Y] = (1/N) * sum over non-zero entries.
	var sumY float64
	for _, y := range yPositive {
		sumY += y
	}
	EY := sumY / float64(N)

	// Step 3.5 Var(Y) including implicit zeros.
	var sumSqDiffNonzero float64
	for _, y := range yPositive {
		d := y - EY
		sumSqDiffNonzero += d * d
	}
	variance := (sumSqDiffNonzero + float64(N-M)*(EY*EY)) / float64(N)
	if variance < 0 {
		// Numerical guard; Var cannot be negative in exact arithmetic.
		variance = 0
	}
	sd := math.Sqrt(variance)

	// Step 3.7 premium rate.
	P := EY + in.Kappa*sd
	annualBps := P * 10_000

	// Step 3.8 VaR / ES via order statistics.
	sort.Float64s(Y)
	varMap := make(map[float64]float64, len(in.ConfidenceLevels))
	esMap := make(map[float64]float64, len(in.ConfidenceLevels))
	var highestQ float64
	var minReserveDollars float64
	for _, q := range in.ConfidenceLevels {
		if q <= 0 || q >= 1 {
			return AlgoOutputs{}, fmt.Errorf("confidence level %v must be in (0,1)", q)
		}
		k := int(math.Ceil(q * float64(N)))
		if k < 1 {
			k = 1
		}
		if k > N {
			k = N
		}
		varQ := Y[k-1]
		// ES_q: mean of Y[i] for i where Y[i] >= varQ. Using order statistics,
		// that's the tail starting at the first index whose value equals varQ
		// when Y is sorted ascending — equivalently indices k-1..N-1.
		var sumTail float64
		for _, y := range Y[k-1:] {
			sumTail += y
		}
		esQ := sumTail / float64(N-(k-1))
		varMap[q] = varQ
		esMap[q] = esQ
		if q > highestQ {
			highestQ = q
			minReserveDollars = esQ * in.TVLCovered
		}
	}

	maxPayout := Y[N-1]
	worstCaseReserve := maxPayout * in.TVLCovered

	// Step 5 per-second WAD rate, computed in big.Int to avoid float drift.
	perSecondWAD := annualBpsToPerSecondWAD(annualBps)

	// Convert maps to sorted arrays for JSON serialization (maps with float64 keys are not JSON-serializable).
	varArray := make([]VaRPoint, 0, len(varMap))
	esArray := make([]VaRPoint, 0, len(esMap))
	confidences := make([]float64, 0, len(varMap))
	for q := range varMap {
		confidences = append(confidences, q)
	}
	sort.Float64s(confidences)
	for _, q := range confidences {
		varArray = append(varArray, VaRPoint{ConfidenceLevel: q, Value: varMap[q]})
		esArray = append(esArray, VaRPoint{ConfidenceLevel: q, Value: esMap[q]})
	}

	return AlgoOutputs{
		NLossPathsDeductible:    Md,
		TriggerProbability:      p,
		ExpectedPayout:          EY,
		Variance:                variance,
		StdDev:                  sd,
		PremiumRateDecimal:      P,
		AnnualPremiumBps:        annualBps,
		PerSecondPremiumWAD:     perSecondWAD.String(),
		MaxPayout:               maxPayout,
		VaR:                     varArray,
		ES:                      esArray,
		varMap:                  varMap,
		esMap:                   esMap,
		MinReserveDollars:       minReserveDollars,
		WorstCaseReserveDollars: worstCaseReserve,
	}, nil
}

// annualBpsToPerSecondWAD converts an annual premium rate in basis points to
// the WAD-scaled per-second fixed-point value the vault contract expects:
//
//	perSecond = annualBps * 1e18 / (1e4 * SECONDS_PER_YEAR)
//
// annualBps is a float because the algorithm is float-derived; we scale by 1e9
// before the big.Int division so that sub-bps precision is preserved without
// losing determinism.
func annualBpsToPerSecondWAD(annualBps float64) *big.Int {
	if annualBps <= 0 || math.IsNaN(annualBps) || math.IsInf(annualBps, 0) {
		return new(big.Int)
	}
	const scale = 1e9
	scaled := new(big.Int).SetUint64(uint64(math.Round(annualBps * scale)))

	wad := new(big.Int).Exp(big.NewInt(10), big.NewInt(18), nil)
	num := new(big.Int).Mul(scaled, wad)

	denom := new(big.Int).Mul(big.NewInt(10_000), big.NewInt(secondsPerYear))
	denom.Mul(denom, big.NewInt(int64(scale)))

	return new(big.Int).Quo(num, denom)
}

