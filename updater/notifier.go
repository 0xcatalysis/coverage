package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"
)

// PremiumEvent is the payload delivered to every Notifier when a vault's
// computed premium changes versus the last value seen by this process.
type PremiumEvent struct {
	Vault                   string      `json:"vault"`
	ChainID                 int         `json:"chain_id"`
	Protocol                string      `json:"protocol"`
	Name                    string      `json:"name"`
	Rating                  string      `json:"rating"`
	Timestamp               time.Time   `json:"timestamp"`
	SimulationUpdated       time.Time   `json:"simulation_updated"`
	AnnualBps               float64     `json:"annual_bps"`
	PreviousBps             *float64    `json:"previous_bps,omitempty"`
	PerSecondWAD            string      `json:"per_second_premium_wad"`
	TriggerProbability      float64     `json:"trigger_probability"`
	ExpectedPayout          float64     `json:"expected_payout"`
	StdDev                  float64     `json:"std_dev"`
	MaxPayout               float64     `json:"max_payout"`
	MinReserveDollars       float64     `json:"min_reserve_dollars"`
	WorstCaseReserveDollars float64     `json:"worst_case_reserve_dollars"`
	NLossPathsDeductible    int         `json:"n_loss_paths_deductible"`
	Inputs                  AlgoInputs  `json:"inputs"`
	Outputs                 AlgoOutputs `json:"outputs"`
}

// Notifier delivers a PremiumEvent somewhere. Implementations must be
// concurrency-safe; the service calls Notify from a single goroutine today but
// that may change.
type Notifier interface {
	Notify(ctx context.Context, e PremiumEvent) error
}

// LogNotifier writes the event as a single structured JSON log record.
type LogNotifier struct{}

func (LogNotifier) Notify(_ context.Context, e PremiumEvent) error {
	var prev any
	if e.PreviousBps != nil {
		prev = *e.PreviousBps
	}
	slog.Info("premium_change",
		"vault", e.Vault,
		"chain_id", e.ChainID,
		"annual_bps", e.AnnualBps,
		"previous_bps", prev,
		"per_second_wad", e.PerSecondWAD,
		"trigger_probability", e.TriggerProbability,
		"expected_payout", e.ExpectedPayout,
		"std_dev", e.StdDev,
		"max_payout", e.MaxPayout,
		"min_reserve_dollars", e.MinReserveDollars,
		"worst_case_reserve_dollars", e.WorstCaseReserveDollars,
		"simulation_updated", e.SimulationUpdated,
	)
	return nil
}

// WebhookNotifier POSTs the event as JSON to a configured URL. It applies
// optional static headers, respects a per-request timeout, and retries once on
// 5xx or transport errors.
type WebhookNotifier struct {
	url        string
	headers    map[string]string
	httpClient *http.Client
}

func newWebhookNotifier(cfg WebhookConfig, timeout time.Duration) *WebhookNotifier {
	return &WebhookNotifier{
		url:     cfg.URL,
		headers: cfg.Headers,
		httpClient: &http.Client{
			Timeout: timeout,
		},
	}
}

func (w *WebhookNotifier) Notify(ctx context.Context, e PremiumEvent) error {
	body, err := json.Marshal(e)
	if err != nil {
		return fmt.Errorf("marshal event: %w", err)
	}

	var lastErr error
	for attempt := 0; attempt < 2; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.url, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("build webhook request: %w", err)
		}
		req.Header.Set("Content-Type", "application/json")
		for k, v := range w.headers {
			req.Header.Set(k, v)
		}

		resp, err := w.httpClient.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("webhook POST: %w", err)
			slog.Warn("webhook attempt failed", "attempt", attempt+1, "err", err)
			if attempt < 1 {
				time.Sleep(100 * time.Millisecond)
			}
			continue
		}
		respBody, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return nil
		}

		lastErr = fmt.Errorf("webhook POST http %d: %s", resp.StatusCode, truncate(respBody, 256))
		if resp.StatusCode < 500 {
			// Don't retry on client errors.
			slog.Warn("webhook non-2xx response", "status", resp.StatusCode, "body", string(truncate(respBody, 256)))
			return lastErr
		}
		slog.Warn("webhook 5xx, retrying", "status", resp.StatusCode)
		if attempt < 1 {
			time.Sleep(100 * time.Millisecond)
		}
	}
	return lastErr
}

// MultiNotifier fans out to multiple notifiers. Every child is called; errors
// are joined but never abort siblings.
type MultiNotifier struct {
	children []Notifier
}

func newMultiNotifier(children ...Notifier) *MultiNotifier {
	return &MultiNotifier{children: children}
}

func (m *MultiNotifier) Notify(ctx context.Context, e PremiumEvent) error {
	var errs []error
	var successCount int
	for _, n := range m.children {
		if err := n.Notify(ctx, e); err != nil {
			errs = append(errs, err)
		} else {
			successCount++
		}
	}

	// Log partial failures but only return error if ALL notifiers failed.
	// This allows state to advance even if optional notifiers (e.g., webhook) fail,
	// preventing log duplication from retry loops on the same premium value.
	if len(errs) > 0 && successCount == 0 {
		// All notifiers failed
		return errors.Join(errs...)
	}
	if len(errs) > 0 {
		// Some notifiers failed, but at least one succeeded - log and continue
		slog.Warn("partial notifier failure",
			"failed", len(errs),
			"succeeded", successCount,
			"errors", errs)
	}
	return nil
}

func truncate(b []byte, max int) []byte {
	if len(b) <= max {
		return b
	}
	return b[:max]
}
