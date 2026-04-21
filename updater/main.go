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

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	credora := newCredoraClient(cfg.CredoraAPIURL, cfg.CredoraAPIKey)

	notifiers := []Notifier{LogNotifier{}}
	if cfg.Webhook != nil && cfg.Webhook.URL != "" {
		notifiers = append(notifiers, newWebhookNotifier(*cfg.Webhook, cfg.webhookTimeout))
		slog.Info("webhook notifier enabled", "url", cfg.Webhook.URL)
	}
	notifier := newMultiNotifier(notifiers...)

	newService(cfg, credora, notifier).run(ctx)
}
