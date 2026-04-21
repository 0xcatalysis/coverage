package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// maxSimulationAge is the freshness bound for Credora's simulation.updated_at
// timestamp. Credora refreshes every 6 hours; the extra 1-hour buffer absorbs
// propagation delays and minor scheduling jitter.
const maxSimulationAge = 7 * time.Hour

// ErrStaleSimulation is returned by CredoraClient when the simulation data is
// older than maxSimulationAge.
var ErrStaleSimulation = errors.New("credora simulation data is stale")

// VaultSimulation is the subset of getVaultWithSimulationData we consume.
type VaultSimulation struct {
	Address     string
	Name        string
	ChainID     int
	Protocol    string
	Rating      string
	PSL         float64
	NTotalPaths int
	NLossPaths  int
	LossArray   []float64
	UpdatedAt   time.Time
}

// CredoraClient queries Credora's GraphQL API for vault simulation data.
type CredoraClient struct {
	url        string
	apiKey     string
	httpClient *http.Client
}

func newCredoraClient(url, apiKey string) *CredoraClient {
	return &CredoraClient{
		url:    url,
		apiKey: apiKey,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

const vaultSimulationQuery = `query($address: String!) {
  getVaultWithSimulationData(address: $address) {
    id
    address
    name
    chainId
    protocol
    curator { name }
    Metrics {
      rating
      psl
      publishDate
      SimulationData {
        n_total_paths
        n_loss_paths
        loss_array
        updated_at
      }
    }
  }
}`

type graphqlRequest struct {
	Query     string                 `json:"query"`
	Variables map[string]interface{} `json:"variables"`
}

type graphqlError struct {
	Message string `json:"message"`
}

type graphqlResponse struct {
	Data struct {
		GetVaultWithSimulationData *struct {
			ID       string `json:"id"`
			Address  string `json:"address"`
			Name     string `json:"name"`
			ChainID  int    `json:"chainId"`
			Protocol string `json:"protocol"`
			Metrics  *struct {
				Rating         string  `json:"rating"`
				PSL            float64 `json:"psl"`
				PublishDate    string  `json:"publishDate"`
				SimulationData *struct {
					NTotalPaths int       `json:"n_total_paths"`
					NLossPaths  int       `json:"n_loss_paths"`
					LossArray   []float64 `json:"loss_array"`
					UpdatedAt   string    `json:"updated_at"`
				} `json:"SimulationData"`
			} `json:"Metrics"`
		} `json:"getVaultWithSimulationData"`
	} `json:"data"`
	Errors []graphqlError `json:"errors"`
}

// getVaultSimulation fetches simulation data for one vault by address. Returns
// ErrStaleSimulation if the returned simulation is older than maxSimulationAge.
func (c *CredoraClient) getVaultSimulation(ctx context.Context, address string) (VaultSimulation, error) {
	body, err := json.Marshal(graphqlRequest{
		Query:     vaultSimulationQuery,
		Variables: map[string]interface{}{"address": address},
	})
	if err != nil {
		return VaultSimulation{}, fmt.Errorf("marshal graphql request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.url, bytes.NewReader(body))
	if err != nil {
		return VaultSimulation{}, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("ClientSecret", c.apiKey)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return VaultSimulation{}, fmt.Errorf("credora request: %w", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return VaultSimulation{}, fmt.Errorf("read response body: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		return VaultSimulation{}, fmt.Errorf("credora API http %d: %s", resp.StatusCode, raw)
	}

	var decoded graphqlResponse
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return VaultSimulation{}, fmt.Errorf("decode credora response: %w", err)
	}
	if len(decoded.Errors) > 0 {
		return VaultSimulation{}, fmt.Errorf("credora graphql error: %s", decoded.Errors[0].Message)
	}
	v := decoded.Data.GetVaultWithSimulationData
	if v == nil {
		return VaultSimulation{}, fmt.Errorf("credora returned null for vault %s", address)
	}
	if v.Metrics == nil || v.Metrics.SimulationData == nil {
		return VaultSimulation{}, fmt.Errorf("credora vault %s has no simulation data", address)
	}
	sim := v.Metrics.SimulationData

	updatedAt, err := parseCredoraTimestamp(sim.UpdatedAt)
	if err != nil {
		return VaultSimulation{}, fmt.Errorf("parse simulation.updated_at %q: %w", sim.UpdatedAt, err)
	}

	out := VaultSimulation{
		Address:     v.Address,
		Name:        v.Name,
		ChainID:     v.ChainID,
		Protocol:    v.Protocol,
		Rating:      v.Metrics.Rating,
		PSL:         v.Metrics.PSL,
		NTotalPaths: sim.NTotalPaths,
		NLossPaths:  sim.NLossPaths,
		LossArray:   sim.LossArray,
		UpdatedAt:   updatedAt,
	}

	return out, nil
}

// parseCredoraTimestamp accepts RFC 3339 / ISO 8601 and a few relaxed shapes we
// have seen in the wild. Handles malformed timestamps with both timezone offset
// and trailing Z (e.g., 2026-04-03T10:14:35.159213+00:00Z).
func parseCredoraTimestamp(s string) (time.Time, error) {
	// Handle malformed timestamps with both offset and trailing Z
	// e.g., "2026-04-03T10:14:35.159213+00:00Z" → remove trailing Z
	if len(s) > 0 && s[len(s)-1] == 'Z' {
		// Check if there's a timezone offset before the Z
		if len(s) > 6 && (s[len(s)-7] == '+' || s[len(s)-7] == '-') {
			s = s[:len(s)-1] // Remove trailing Z
		}
	}

	formats := []string{
		time.RFC3339Nano,
		time.RFC3339,
		"2006-01-02T15:04:05.999999",
		"2006-01-02T15:04:05",
	}
	var firstErr error
	for _, f := range formats {
		t, err := time.Parse(f, s)
		if err == nil {
			return t.UTC(), nil
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	return time.Time{}, firstErr
}
