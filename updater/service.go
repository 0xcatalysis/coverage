package main

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"
)

// Service orchestrates the premium update loop. For each configured vault it
// fetches fresh simulation data from Credora, runs the underwriting algorithm,
// and emits a notification whenever the clamped premium differs from the last
// value this process observed. On-chain writes are explicitly out of scope —
// the Catalysis team pushes the actual on-chain update via multisig.
type Service struct {
	cfg      *Config
	credora  *CredoraClient
	notifier Notifier

	// lastBps tracks the last clamped premium (bps) per lowercased vault
	// address. A miss means "not observed this process run" → always notify.
	lastBps map[string]float64
}

func newService(cfg *Config, credora *CredoraClient, notifier Notifier) *Service {
	return &Service{
		cfg:      cfg,
		credora:  credora,
		notifier: notifier,
		lastBps:  make(map[string]float64, len(cfg.Vaults)),
	}
}

// run starts the poll loop. It performs one immediate pass on startup and then
// ticks every cfg.pollDuration. Blocks until ctx is cancelled.
func (s *Service) run(ctx context.Context) {
	slog.Info("starting premium updater",
		"poll_interval", s.cfg.pollDuration,
		"vaults", len(s.cfg.Vaults),
		"webhook_enabled", s.cfg.Webhook != nil,
	)

	s.updateAll(ctx)

	ticker := time.NewTicker(s.cfg.pollDuration)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("shutting down premium updater")
			return
		case <-ticker.C:
			s.updateAll(ctx)
		}
	}
}

// updateAll runs one full cycle across every configured vault. Per-vault
// failures are logged and do not abort the cycle.
func (s *Service) updateAll(ctx context.Context) {
	for _, v := range s.cfg.Vaults {
		if ctx.Err() != nil {
			return
		}
		if err := s.updateVault(ctx, v); err != nil {
			slog.Error("vault update failed", "vault", v.Address, "err", err)
		}
	}
}

func (s *Service) updateVault(ctx context.Context, v VaultConfig) error {
	logger := slog.With("vault", v.Address)

	sim, err := s.credora.getVaultSimulation(ctx, v.Address)
	if err != nil {
		return fmt.Errorf("fetch simulation: %w", err)
	}

	// Check simulation freshness unless tolerance is enabled
	age := time.Since(sim.UpdatedAt)
	if age > maxSimulationAge && !v.TolerateOlderSimulations {
		logger.Warn("skipping stale simulation",
			"age", age.Truncate(time.Second),
			"max_age", maxSimulationAge,
			"tip", "set tolerate_older_simulations: true to use older data")
		return nil
	}
	if age > maxSimulationAge && v.TolerateOlderSimulations {
		logger.Info("using older simulation (tolerance enabled)",
			"age", age.Truncate(time.Second),
			"max_age", maxSimulationAge)
	}

	logger.Info("fetched simulation",
		"n_total_paths", sim.NTotalPaths,
		"n_loss_paths", sim.NLossPaths,
		"updated_at", sim.UpdatedAt,
	)

	inputs := AlgoInputs{
		VaultAddress:     v.Address,
		NTotalPaths:      sim.NTotalPaths,
		NLossPaths:       sim.NLossPaths,
		LossArray:        sim.LossArray,
		Deductible:       v.Deductible,
		Kappa:            v.Kappa,
		ConfidenceLevels: v.ConfidenceLevels,
		TVLCovered:       v.TVLCovered,
	}

	out, err := runUnderwriting(inputs)
	if err != nil {
		return fmt.Errorf("run underwriting: %w", err)
	}

	annualBps := out.AnnualPremiumBps

	key := strings.ToLower(v.Address)
	prev, hadPrev := s.lastBps[key]
	if hadPrev && prev == annualBps {
		logger.Info("premium unchanged, skipping notify", "bps", annualBps)
		return nil
	}

	event := PremiumEvent{
		Vault:                   v.Address,
		ChainID:                 sim.ChainID,
		Protocol:                sim.Protocol,
		Name:                    v.Name,
		Rating:                  sim.Rating,
		Timestamp:               time.Now().UTC(),
		SimulationUpdated:       sim.UpdatedAt,
		AnnualBps:               annualBps,
		PerSecondWAD:            out.PerSecondPremiumWAD.String(),
		TriggerProbability:      out.TriggerProbability,
		ExpectedPayout:          out.ExpectedPayout,
		StdDev:                  out.StdDev,
		MaxPayout:               out.MaxPayout,
		MinReserveDollars:       out.MinReserveDollars,
		WorstCaseReserveDollars: out.WorstCaseReserveDollars,
		NLossPathsDeductible:    out.NLossPathsDeductible,
		Inputs:                  inputs,
		Outputs:                 out,
	}
	if hadPrev {
		p := prev
		event.PreviousBps = &p
	}

	if err := s.notifier.Notify(ctx, event); err != nil {
		// Don't update lastBps on full notify failure so we retry next tick.
		return fmt.Errorf("notify: %w", err)
	}

	s.lastBps[key] = annualBps
	return nil
}
