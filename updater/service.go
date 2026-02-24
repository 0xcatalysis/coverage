package main

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/ethereum/go-ethereum/common"
)

// Service orchestrates the premium update loop: for each configured vault it
// fetches a loss distribution from Credora, computes a fee in basis points,
// and updates the vault's management fee on-chain if the value has changed.
type Service struct {
	cfg        *Config
	credora    *CredoraClient
	calculator PremiumCalculator
	chain      *ChainClient
}

// newService constructs a Service from already-initialised dependencies.
func newService(cfg *Config, credora *CredoraClient, calculator PremiumCalculator, chain *ChainClient) *Service {
	return &Service{
		cfg:        cfg,
		credora:    credora,
		calculator: calculator,
		chain:      chain,
	}
}

// run starts the 24-hour poll loop. It performs one immediate update cycle on
// startup and then ticks every cfg.pollDuration. Blocks until ctx is cancelled.
func (s *Service) run(ctx context.Context) {
	slog.Info("starting premium updater", "poll_interval", s.cfg.pollDuration, "vaults", len(s.cfg.Vaults))

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

// updateAll runs one update cycle across all configured vaults.
func (s *Service) updateAll(ctx context.Context) {
	for _, v := range s.cfg.Vaults {
		if err := s.updateVault(ctx, v); err != nil {
			slog.Error("failed to update vault", "vault", v.Address, "entity", v.CredoraEntityID, "err", err)
		}
	}
}

// updateVault performs a single update for one vault:
//  1. Fetch loss distribution from Credora.
//  2. Calculate fee in bps via the pluggable calculator.
//  3. Clamp to [min_fee_bps, max_fee_bps].
//  4. Convert to WAD and compare with on-chain fee; skip if unchanged.
//  5. Send multicall(submit + setManagementFee) to the vault.
func (s *Service) updateVault(ctx context.Context, v VaultConfig) error {
	logger := slog.With("vault", v.Address, "entity", v.CredoraEntityID)

	dist, err := s.credora.getLossDistribution(ctx, v.CredoraEntityID)
	if err != nil {
		return fmt.Errorf("fetch loss distribution: %w", err)
	}
	logger.Info("fetched loss distribution", "expected_loss", dist.ExpectedLoss)

	rawBps, err := s.calculator.calculate(dist)
	if err != nil {
		return fmt.Errorf("calculate premium: %w", err)
	}

	feeBps := clamp(rawBps, s.cfg.MinFeeBps, s.cfg.MaxFeeBps)
	if feeBps != rawBps {
		logger.Info("fee bps clamped", "raw_bps", rawBps, "clamped_bps", feeBps,
			"min", s.cfg.MinFeeBps, "max", s.cfg.MaxFeeBps)
	}

	feeWAD := bpsToWAD(feeBps)
	vaultAddr := common.HexToAddress(v.Address)

	currentFeeWAD, err := s.chain.readManagementFee(ctx, vaultAddr)
	if err != nil {
		return fmt.Errorf("read current management fee: %w", err)
	}

	if currentFeeWAD.Cmp(feeWAD) == 0 {
		logger.Info("management fee unchanged, skipping update", "fee_bps", feeBps)
		return nil
	}

	logger.Info("updating management fee",
		"current_bps", wadToBps(currentFeeWAD),
		"new_bps", feeBps,
	)

	calldata, err := buildSubmitAndSetFeeMulticall(vaultAddr, feeWAD)
	if err != nil {
		return fmt.Errorf("build multicall: %w", err)
	}

	receipt, err := s.chain.sendMulticall(ctx, vaultAddr, calldata)
	if err != nil {
		return fmt.Errorf("send multicall: %w", err)
	}

	logger.Info("management fee updated",
		"tx", receipt.TxHash.Hex(),
		"block", receipt.BlockNumber,
		"fee_bps", feeBps,
	)
	return nil
}

// clamp returns v clamped to [lo, hi].
func clamp(v, lo, hi uint64) uint64 {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}
