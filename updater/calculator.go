package main

import "fmt"

// PremiumCalculator converts a LossDistribution into a management fee expressed
// in basis points (1 bps = 0.01%). The returned value is before any min/max clamping.
type PremiumCalculator interface {
	calculate(dist LossDistribution) (uint64, error)
}

// NoOpCalculator is a placeholder that returns a fixed fee in basis points.
// TODO: Replace with a real actuarial formula derived from the loss distribution
// (e.g. expected loss loading, VaR, or CVaR-based pricing).
type NoOpCalculator struct {
	fixedBps uint64
}

func (c *NoOpCalculator) calculate(_ LossDistribution) (uint64, error) {
	if c.fixedBps == 0 {
		return 0, fmt.Errorf("NoOpCalculator: fixedBps is not set")
	}
	return c.fixedBps, nil
}
