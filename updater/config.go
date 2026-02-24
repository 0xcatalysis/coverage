package main

import (
	"fmt"
	"os"
	"regexp"
	"time"

	"gopkg.in/yaml.v3"
)

// VaultConfig holds per-vault configuration.
type VaultConfig struct {
	Address         string `yaml:"address"`
	CredoraEntityID string `yaml:"credora_entity_id"`
}

// Config is the top-level configuration for the updater service.
type Config struct {
	RPCURL        string        `yaml:"rpc_url"`
	PrivateKey    string        `yaml:"private_key"`
	PollInterval  string        `yaml:"poll_interval"`
	CredoraAPIURL string        `yaml:"credora_api_url"`
	CredoraAPIKey string        `yaml:"credora_api_key"`
	MinFeeBps     uint64        `yaml:"min_fee_bps"`
	MaxFeeBps     uint64        `yaml:"max_fee_bps"`
	Vaults        []VaultConfig `yaml:"vaults"`

	pollDuration time.Duration
}

var envVarRe = regexp.MustCompile(`\$\{([^}]+)\}`)

// expandEnv replaces ${VAR} placeholders with their environment variable values.
func expandEnv(s string) string {
	return envVarRe.ReplaceAllStringFunc(s, func(match string) string {
		name := envVarRe.FindStringSubmatch(match)[1]
		return os.Getenv(name)
	})
}

// loadConfig reads a YAML config file, expands env vars, and validates the result.
func loadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config file: %w", err)
	}

	var cfg Config
	if err := yaml.Unmarshal([]byte(expandEnv(string(raw))), &cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}

	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	return &cfg, nil
}

func (c *Config) validate() error {
	if c.RPCURL == "" {
		return fmt.Errorf("rpc_url is required")
	}
	if c.PrivateKey == "" {
		return fmt.Errorf("private_key is required")
	}
	if c.CredoraAPIURL == "" {
		return fmt.Errorf("credora_api_url is required")
	}
	if c.CredoraAPIKey == "" {
		return fmt.Errorf("credora_api_key is required")
	}
	if len(c.Vaults) == 0 {
		return fmt.Errorf("at least one vault must be configured")
	}
	for i, v := range c.Vaults {
		if v.Address == "" {
			return fmt.Errorf("vaults[%d].address is required", i)
		}
		if v.CredoraEntityID == "" {
			return fmt.Errorf("vaults[%d].credora_entity_id is required", i)
		}
	}
	if c.MinFeeBps > c.MaxFeeBps {
		return fmt.Errorf("min_fee_bps (%d) must be <= max_fee_bps (%d)", c.MinFeeBps, c.MaxFeeBps)
	}

	interval := c.PollInterval
	if interval == "" {
		interval = "24h"
	}
	d, err := time.ParseDuration(interval)
	if err != nil {
		return fmt.Errorf("poll_interval %q is not a valid duration: %w", interval, err)
	}
	c.pollDuration = d

	return nil
}
