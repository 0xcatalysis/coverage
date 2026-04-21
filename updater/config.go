package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

// VaultConfig holds per-vault algorithm inputs and the on-chain address.
type VaultConfig struct {
	Name                      string    `yaml:"name"`
	Address                   string    `yaml:"address"`
	Kappa                     float64   `yaml:"kappa"`
	Deductible                float64   `yaml:"deductible"`
	ConfidenceLevels          []float64 `yaml:"confidence_levels"`
	TVLCovered                float64   `yaml:"tvl_covered"`
	TolerateOlderSimulations  bool      `yaml:"tolerate_older_simulations,omitempty"`
}

// WebhookConfig configures the optional generic HTTP webhook notifier.
type WebhookConfig struct {
	URL     string            `yaml:"url"`
	Headers map[string]string `yaml:"headers,omitempty"`
	Timeout string            `yaml:"timeout,omitempty"`
}

// Config is the top-level YAML configuration for the updater service.
type Config struct {
	PollInterval  string         `yaml:"poll_interval"`
	CredoraAPIURL string         `yaml:"credora_api_url"`
	CredoraAPIKey string         `yaml:"credora_api_key"`
	Webhook       *WebhookConfig `yaml:"webhook,omitempty"`
	Vaults        []VaultConfig  `yaml:"vaults"`

	pollDuration   time.Duration
	webhookTimeout time.Duration
}

// loadConfig reads a YAML config file and validates the result.
func loadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config file: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

func (c *Config) validate() error {
	if c.CredoraAPIURL == "" {
		return fmt.Errorf("credora_api_url is required")
	}
	if c.CredoraAPIKey == "" {
		return fmt.Errorf("credora_api_key is required")
	}
	if len(c.Vaults) == 0 {
		return fmt.Errorf("at least one vault must be configured")
	}
	seen := map[string]bool{}
	for i, v := range c.Vaults {
		if v.Name == "" {
			return fmt.Errorf("vaults[%d].name is required", i)
		}
		if v.Address == "" {
			return fmt.Errorf("vaults[%d].address is required", i)
		}
		addr := strings.ToLower(v.Address)
		if !strings.HasPrefix(addr, "0x") || len(addr) != 42 {
			return fmt.Errorf("vaults[%d].address %q must be a 0x-prefixed 40-hex-char address", i, v.Address)
		}
		if seen[addr] {
			return fmt.Errorf("vaults[%d].address %s is duplicated", i, v.Address)
		}
		seen[addr] = true
		if v.Kappa < 0 {
			return fmt.Errorf("vaults[%d].kappa must be >= 0", i)
		}
		if v.Deductible < 0 || v.Deductible >= 1 {
			return fmt.Errorf("vaults[%d].deductible must be in [0,1)", i)
		}
		if v.TVLCovered < 0 {
			return fmt.Errorf("vaults[%d].tvl_covered must be >= 0", i)
		}
		if len(v.ConfidenceLevels) == 0 {
			return fmt.Errorf("vaults[%d].confidence_levels must have at least one entry", i)
		}
		for j, q := range v.ConfidenceLevels {
			if q <= 0 || q >= 1 {
				return fmt.Errorf("vaults[%d].confidence_levels[%d]=%v must be in (0,1)", i, j, q)
			}
		}
	}
	interval := c.PollInterval
	if interval == "" {
		interval = "6h"
	}
	d, err := time.ParseDuration(interval)
	if err != nil {
		return fmt.Errorf("poll_interval %q is not a valid duration: %w", interval, err)
	}
	if d <= 0 {
		return fmt.Errorf("poll_interval must be > 0")
	}
	c.pollDuration = d

	if c.Webhook != nil && c.Webhook.Timeout != "" {
		timeoutStr := c.Webhook.Timeout
		if timeoutStr == "" {
			timeoutStr = "10s"
		}
		wt, err := time.ParseDuration(timeoutStr)
		if err != nil {
			return fmt.Errorf("webhook.timeout %q invalid: %w", timeoutStr, err)
		}
		if wt <= 0 {
			return fmt.Errorf("webhook.timeout must be > 0")
		}
		c.webhookTimeout = wt
	}

	return nil
}
