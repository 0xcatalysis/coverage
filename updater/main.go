package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
)

func main() {
	configPath := flag.String("config", "config.yaml", "path to YAML config file")
	flag.Parse()

	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: slog.LevelInfo,
	})))

	cfg, err := loadConfig(*configPath)
	if err != nil {
		slog.Error("failed to load config", "err", err)
		os.Exit(1)
	}

	if err := parseVaultABI(); err != nil {
		slog.Error("failed to parse vault ABI", "err", err)
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	chain, err := newChainClient(ctx, cfg.RPCURL, cfg.PrivateKey)
	if err != nil {
		slog.Error("failed to connect to RPC", "err", err)
		os.Exit(1)
	}
	defer chain.close()

	slog.Info("connected to chain", "chain_id", chain.chainID, "sender", chain.from)

	credora := newCredoraClient(cfg.CredoraAPIURL, cfg.CredoraAPIKey)

	// NoOpCalculator is used until a real actuarial formula is implemented.
	// TODO: Replace with a production PremiumCalculator implementation.
	calculator := &NoOpCalculator{fixedBps: cfg.MinFeeBps}

	newService(cfg, credora, calculator, chain).run(ctx)
}
