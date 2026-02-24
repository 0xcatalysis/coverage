package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// LossDistribution holds the loss data returned by the Credora API for a given entity.
// Fields are populated from the actual Credora response; RawResponse preserves the
// full payload so that a future calculator implementation can access any field.
type LossDistribution struct {
	// Percentiles maps probability level (0–1) to annualized loss fraction (0–1).
	// Example: {0.50: 0.005, 0.95: 0.02, 0.99: 0.05}
	Percentiles map[float64]float64

	// ExpectedLoss is the mean annualized loss as a fraction (0–1).
	ExpectedLoss float64

	// RawResponse is the raw JSON body from the Credora API.
	RawResponse json.RawMessage
}

// credoraResponse is the wire format of the Credora loss distribution endpoint.
// Adjust field names to match the actual Credora API schema once available.
type credoraResponse struct {
	EntityID     string             `json:"entity_id"`
	ExpectedLoss float64            `json:"expected_loss"`
	Percentiles  map[string]float64 `json:"percentiles"`
}

// CredoraClient fetches loss distributions from the Credora API.
type CredoraClient struct {
	baseURL    string
	apiKey     string
	httpClient *http.Client
}

// newCredoraClient creates a new CredoraClient with a sensible timeout.
func newCredoraClient(baseURL, apiKey string) *CredoraClient {
	return &CredoraClient{
		baseURL: baseURL,
		apiKey:  apiKey,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// getLossDistribution fetches the loss distribution for the given entity ID.
func (c *CredoraClient) getLossDistribution(ctx context.Context, entityID string) (LossDistribution, error) {
	url := fmt.Sprintf("%s/loss-distribution/%s", c.baseURL, entityID)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return LossDistribution{}, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.apiKey)
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return LossDistribution{}, fmt.Errorf("credora request: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return LossDistribution{}, fmt.Errorf("read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return LossDistribution{}, fmt.Errorf("credora API error (status %d): %s", resp.StatusCode, body)
	}

	var raw credoraResponse
	if err := json.Unmarshal(body, &raw); err != nil {
		return LossDistribution{}, fmt.Errorf("decode credora response: %w", err)
	}

	percentiles := make(map[float64]float64, len(raw.Percentiles))
	for k, v := range raw.Percentiles {
		var p float64
		if _, err := fmt.Sscanf(k, "%f", &p); err != nil {
			continue
		}
		percentiles[p] = v
	}

	return LossDistribution{
		ExpectedLoss: raw.ExpectedLoss,
		Percentiles:  percentiles,
		RawResponse:  json.RawMessage(body),
	}, nil
}
