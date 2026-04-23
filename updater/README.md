# Premium Updater Service

A Go service that computes dynamic insurance premiums for the Catalysis protocol by fetching loss simulation data from Credora's GraphQL API and running a full actuarial underwriting algorithm.

## Overview

The Premium Updater is a **notify-only** service that:

1. **Fetches loss simulation data** from Credora for each configured vault
2. **Runs actuarial calculations** to compute annual insurance premiums using the formula: `P = E[Y] + κ·SD(Y)`
3. **Detects premium changes** by comparing against the last computed value
4. **Emits notifications** via structured JSON logs and optional HTTP webhooks

The service does **not** write to the blockchain. A multisig (off-chain) is responsible for validating computed premiums and submitting them on-chain via `setManagementFee()`.

## Quick Start

### Prerequisites
- Go 1.21+
- Credora API key with access to `https://api.staging.credora.io/graphql/catalysis`

### Build

```bash
cd updater
go build ./...
```

### Configure

Copy and edit `config.example.yaml`:

```bash
cp config.example.yaml config.yaml
```

Edit `config.yaml`:
- Set `credora_api_key` to your Credora API key
- Configure vault addresses, algorithm parameters (kappa, deductible), and confidence levels
- Optionally configure a webhook endpoint for premium notifications

### Run

```bash
./updater
```

The service will:
1. Perform an immediate update cycle
2. Poll every `poll_interval` (default: 6 hours)
3. Log all premium computations and changes

## Configuration

### Example `config.yaml`

```yaml
poll_interval: "6h"

credora_api_url: "https://api.staging.credora.io/graphql/catalysis"
credora_api_key: "your-credora-api-key-here"

# Optional webhook for premium change notifications
webhook:
  url: "https://your-endpoint.com/premiums"
  timeout: "10s"
  headers:
    Authorization: "Bearer your-webhook-token"

# Vault-specific configurations
vaults:
  - name: "Core Vault"             # Human-readable vault name (shown in notifications)
    address: "0xMORPHO_VAULT_ADDRESS"
    kappa: 0.25                    # Risk-aversion multiplier for std dev
    deductible: 0.01               # 1% deductible (applies to loss distribution)
    confidence_levels: [0.995]     # 99.5% confidence for reserve calculations
    tvl_covered: 10000000          # $10M total value locked
    tolerate_older_simulations: false  # Set to true to accept stale Credora data
```

### Configuration Fields

| Field | Type | Description |
|-------|------|-------------|
| `poll_interval` | Duration | How often to fetch and compute premiums (default: "6h") |
| `credora_api_url` | String | Credora GraphQL endpoint |
| `credora_api_key` | String | Credora API authentication key |
| `webhook.url` | String | (Optional) HTTP endpoint to POST premium notifications |
| `webhook.timeout` | Duration | Webhook request timeout (default: "10s") |
| `webhook.headers` | Map | (Optional) Extra HTTP headers (e.g., authorization) |
| `vaults[].name` | String | Human-readable vault identifier (shown in notifications) |
| `vaults[].address` | String | Vault contract address (0x-prefixed hex) |
| `vaults[].kappa` | Float | Risk-aversion parameter (≥ 0). Higher = more conservative premium |
| `vaults[].deductible` | Float | Loss threshold as decimal (0 ≤ deductible < 1). E.g., 0.01 = 1% |
| `vaults[].confidence_levels` | []Float | Risk confidence thresholds (each in 0 < level < 1). E.g., [0.99, 0.995] |
| `vaults[].tvl_covered` | Float | Total value locked in the vault (in dollars) |
| `vaults[].tolerate_older_simulations` | Boolean | If `true`, use Credora data even if older than 7h (default: `false`) |

## Algorithm

### Input: Loss Distribution

Credora provides a loss simulation with:
- `n_total_paths`: Total Monte Carlo paths (e.g., 100,000)
- `n_loss_paths`: Paths where loss > 0 (e.g., 1,822)
- `loss_array`: Array of M sampled loss amounts
- `updated_at`: Timestamp of when simulation was generated

### Processing Steps

1. **Deductible Application**
   ```
   y_j = max(l_j - deductible, 0)  for each loss sample l_j
   ```
   Losses below the deductible threshold are treated as zero.

2. **Distribution Statistics**
   ```
   E[Y] = (1/N) * Σ(y_j)           # Expected payout
   Var(Y) = (1/N) * Σ(y_j - E[Y])² # Variance (includes implicit zeros)
   SD(Y) = sqrt(Var(Y))             # Standard deviation
   ```

3. **Premium Calculation**
   ```
   P = E[Y] + κ·SD(Y)              # Annual premium as decimal (0-1 range)
   Annual BPS = P * 10,000         # Convert to basis points
   ```

4. **Risk Metrics (VaR & ES)**
   ```
   For each confidence_level q:
     VaR_q = loss at q-th percentile        # Value-at-Risk
     ES_q  = average loss beyond VaR_q      # Expected Shortfall
   ```

5. **Reserve Requirements**
   ```
   MinReserve = ES_highest_q * TVL_covered  # Capital reserve needed
   ```

### Example Calculation

**Input:**
- N = 100,000 simulated paths
- M = 1,822 paths with loss > 0
- Loss array: [10, 50, 100, 500, ..., 999,999]
- Deductible = 0.01 (1%)
- Kappa = 0.25
- TVL covered = $10,000,000
- Confidence level = 0.995

**Processing:**
1. Deductible-adjusted losses (losses below 0.01 become 0)
2. E[Y] = 0.0002313 (~0.02313%)
3. SD(Y) = 0.0038415 (~0.38415%)
4. P = 0.0002313 + 0.25 × 0.0038415 = 0.00021768 (~2.18 basis points)
5. Annual BPS = 21.8 bps
6. VaR_99.5 ≈ 0.0086944 (~0.87%)
7. ES_99.5 ≈ 0.0450546 (~4.51%)
8. MinReserve = 0.0450546 × $10M = $450,546

## Output: Notifications

### When Premium Changes

The service emits a `PremiumEvent` notification whenever:
1. **First observation** of a vault (no prior baseline)
2. **Premium changes** (clamped annual BPS differs from last observation)

Notification is **skipped** if the computed premium is identical to the last observed value.

### Log Output (JSON)

```json
{
  "time": "2026-04-21T14:30:00Z",
  "level": "INFO",
  "msg": "premium_change",
  "vault": "0xfA355999c12C63c465c591daf9C462e14ACf470b",
  "chain_id": 1,
  "protocol": "catalysis",
  "vault_name": "Core",
  "rating": "A+",
  "timestamp": "2026-04-21T14:30:00Z",
  "simulation_updated": "2026-04-21T13:00:00Z",
  "raw_annual_bps": 21.8,
  "previous_annual_bps": 20.5,
  "expected_payout": 0.0002313,
  "std_dev": 0.0038415,
  "min_reserve_dollars": 450546,
  "worst_case_reserve_dollars": 9999999
}
```

### Webhook Payload (JSON POST)

Same JSON structure sent to `webhook.url` (if configured):

```bash
POST https://your-endpoint.com/premiums

{
  "vault": "0xfA355999c12C63c465c591daf9C462e14ACf470b",
  "annual_bps": 21.8,
  "previous_annual_bps": 20.5,
  "expected_payout": 0.0002313,
  ...
}
```

Webhook behavior:
- **2xx response**: Success
- **5xx response**: Single retry after 100ms
- **Network error**: Single retry after 100ms
- **Timeout** (10s default): Logged as warning, not retried

## Data Freshness

The service validates that Credora's simulation data is **recent**:

```go
if time.Since(simulation.UpdatedAt) > 7 * time.Hour {
    // Skip vault, log warning (unless tolerate_older_simulations: true)
}
```

Credora refreshes simulation data every 6 hours. The service allows up to 7 hours before rejecting data — the extra hour absorbs propagation delays and minor scheduling jitter on Credora's side.

### Tolerating Older Simulations

If a vault's simulation data is stale (older than 7 hours), set `tolerate_older_simulations: true` in the vault config to accept it anyway:

```yaml
vaults:
  - name: "Legacy Vault"
    address: "0x..."
    tolerate_older_simulations: true  # Use data even if > 7h old
```

**When to use:**
- Vault is inactive or rarely updated by Credora
- Stakeholder explicitly approves using older risk data
- Testing/development environment

**When NOT to use:**
- Production vault with active risk changes
- Regulatory/compliance requirements (use fresh data)

## Error Handling

| Error | Behavior |
|-------|----------|
| **Stale simulation** (> 7h old) | Warn, skip vault (unless `tolerate_older_simulations: true`) |
| **Credora API failure** | Log error, skip vault, retry on next cycle |
| **Invalid configuration** | Fail at startup, exit with error |
| **Webhook POST fails** | Warn, retry once, continue to next vault |
| **Premium unchanged** | Skip notification, continue silently |

## Building and Testing

### Build

```bash
go build ./...
```

### Run Tests

```bash
go test ./...
```

### Test Coverage

- **calculator_test.go**: Underwriting algorithm (deductible, E[Y], SD(Y), VaR, ES, WAD conversion)
- **Unit tests** for:
  - Zero loss scenarios
  - All-equal loss distributions
  - Deductible filtering
  - Gauntlet base case (N=100k, M=1822, M_d=655)
  - Annual BPS to per-second WAD conversion

### Example Test Run

```bash
$ go test -v ./...
=== RUN   TestRunUnderwriting_NoLosses
--- PASS: TestRunUnderwriting_NoLosses (0.00s)
=== RUN   TestRunUnderwriting_AllEqualLosses
--- PASS: TestRunUnderwriting_AllEqualLosses (0.00s)
=== RUN   TestRunUnderwriting_DeductibleZeroesSubThreshold
--- PASS: TestRunUnderwriting_DeductibleZeroesSubThreshold (0.00s)
=== RUN   TestRunUnderwriting_GauntletShape
--- PASS: TestRunUnderwriting_GauntletShape (0.00s)
=== RUN   TestAnnualBpsToPerSecondWAD
--- PASS: TestAnnualBpsToPerSecondWAD (0.00s)
=== RUN   TestAnnualBpsToPerSecondWAD_Zero
--- PASS: TestAnnualBpsToPerSecondWAD_Zero (0.00s)
PASS
ok  	catalysis-coverage/updater	0.05s
```

## Architecture

### Components

```
main.go
├─ Config Loading (YAML)
├─ CredoraClient (GraphQL)
├─ Service (polling + orchestration)
└─ Notifier (log + webhook)

config.go
├─ VaultConfig validation
├─ WebhookConfig parsing
└─ Config struct

credora.go
├─ GraphQL query builder
├─ HTTP client with retry
└─ Response parsing + freshness check

calculator.go
├─ Underwriting algorithm
├─ VaR/ES calculation
└─ WAD conversion

notifier.go
├─ PremiumEvent struct
├─ LogNotifier (slog)
├─ WebhookNotifier (HTTP POST)
└─ MultiNotifier (fan-out)

service.go
├─ Polling loop
├─ Per-vault update logic
├─ Change detection
└─ Notification triggering
```

### Data Flow

```
1. Load config.yaml
   ↓
2. Create Credora client + notifiers
   ↓
3. Service.run() starts polling loop
   ↓
4. For each vault in poll cycle:
   a. Fetch simulation from Credora GraphQL
   b. Check freshness: if > 7h old, skip unless `tolerate_older_simulations: true`
   c. Run underwriting algorithm
   d. Compare against lastBps[address]
   e. If changed: emit PremiumEvent to all notifiers
   f. Update lastBps[address]
   ↓
5. Wait for next poll_interval, repeat
```

## Security Notes

1. **config.yaml** contains the Credora API key → **must be secrets-protected**
   - Add to `.gitignore` (already done)
   - Use environment secrets in CI/CD
   - Restrict file permissions: `chmod 600 config.yaml`

2. **Webhook headers** (e.g., auth tokens) are in config.yaml → same protection applies

3. **No blockchain private key** in this service (notify-only design)
   - Multisig handles on-chain submissions separately

## Troubleshooting

### Premium Always Unchanged
- **Check**: Compare last-observed premium with current computation
- **Action**: Review Credora simulation data freshness via logs
- **Action**: Verify vault address case (keys are lowercased internally)

### Webhook Not Receiving Notifications
- **Check**: Webhook URL and headers in config.yaml
- **Check**: Network connectivity to webhook endpoint
- **Action**: Enable verbose logging (review logs for POST attempts)
- **Action**: Verify webhook endpoint accepts POST and returns 2xx

### Stale Simulation Warnings
- **Check**: Credora API freshness — is the vault's simulation being updated?
- **Quick fix**: Set `tolerate_older_simulations: true` for that vault in config.yaml
- **Long fix**: Contact Credora to re-enable simulations for this vault
- **Advanced**: Edit `maxSimulationAge` in credora.go if you need different tolerance (currently 7h)

### Config Load Fails
- **Check**: YAML syntax (use online YAML validator)
- **Check**: Vault address format (must be 0x-prefixed, 40 hex chars)
- **Check**: Confidence levels are each in (0, 1) range
- **Check**: Deductible is in [0, 1) range

## Files Reference

| File | Purpose |
|------|---------|
| `main.go` | Entry point, wiring |
| `config.go` | Configuration loading and validation |
| `credora.go` | GraphQL client and API integration |
| `calculator.go` | Underwriting algorithm |
| `notifier.go` | Log and webhook notification |
| `service.go` | Polling loop and orchestration |
| `calculator_test.go` | Unit tests for algorithm |
| `config.example.yaml` | Configuration template |
| `.gitignore` | Excludes secrets and binaries |

## Next Steps

1. **Deploy**: Copy binary + config.yaml to production environment
2. **Monitor**: Review logs for `premium_change` events
3. **Integrate**: Configure multisig to consume webhook feed and submit on-chain updates
4. **Validate**: Cross-check computed premiums with on-chain submissions

