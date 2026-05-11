# Mainnet Upgrade Runbook — PAUSER_ROLE

## Overview

This runbook upgrades the six Coverage UUPS proxies on Ethereum mainnet to introduce
`PAUSER_ROLE`, separating the pause capability from `DEFAULT_ADMIN_ROLE` so that an
automation bot can pause contracts instantly without going through the multisig.

**Contracts upgraded:** PolicyManager · ClaimManager · PremiumManager · SpecRegistry ·
Swapper · CoverPoolFactory

**Storage safety:** `PAUSER_ROLE` is a `constant` and does not occupy any storage slot.
All six `StorageLayout` pinned baselines pass unchanged. No reinitializer is required.

**Exception — ClaimManager:** The base `UpgradeClaimManager` script encodes `initializeV2`
into `upgradeCalldata`. `UpgradeClaimManagerEthereum` overrides this to return empty bytes
because `initializeV2` (`reinitializer(2)`) was already executed on mainnet and would revert
if called again.

---

## Addresses

| Contract | Proxy |
|----------|-------|
| PolicyManager | `0xfb771BE75365D2a1D32be198e03ce8a2125e2699` |
| ClaimManager | `0x3ceE181C3E78fB9968f0Fb0935d2db0723B9Cb45` |
| PremiumManager | `0xEc7322D6754709d5001B710ec4fB2547a89B3aD1` |
| CoverPoolFactory | `0x4f3DbB70cD85bcb63303FBa8610Cb163aDDA4E66` |
| SpecRegistry | `0x90EfF742958dd4c54ede3ED365375a14077D0A58` |
| Swapper | `0x148Bfe2330cEe4f227addb47736a105DB427dc31` |
| TimelockController | `0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7` |
| Catalysis Master Admin (multisig) | `0xd2d03377Fa96687e9C11380DA9956AcC5F307e2c` |

**PAUSER_ROLE hash:** `0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a`

Verify:
```bash
cast keccak "PAUSER_ROLE"
# 0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a
```

---

## Why the upgrade script alone is not sufficient

The upgrade script (`UpgradeBase`) only produces a single-call `schedule` / `execute`
for `upgradeToAndCall(newImpl, "")`. After that call executes, `pause()` on every upgraded
proxy immediately requires `PAUSER_ROLE` — which no address holds yet, including the
TimelockController.

The fix is to issue a single `scheduleBatch` that atomically upgrades each proxy **and**
grants `PAUSER_ROLE` to the designated pauser in the same timelock operation. There is then
no window where the contracts are upgraded but unpaused by anyone.

---

## Prerequisites

1. **Confirm timelock min delay** — the deploy script defaults to 2 days but verify on-chain:
   ```bash
   cast call 0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7 "getMinDelay()(uint256)" \
     --rpc-url $ETHEREUM_RPC_URL
   ```

2. **Choose a pauser address** — an automation bot EOA or dedicated hot-wallet. Set as
   `PAUSER` throughout this runbook.

3. **Deployer EOA** — must have ETH for gas; does NOT need any on-chain role (the script
   only deploys implementation contracts, not the proxy upgrade).

4. **Verify existing implementations** (optional sanity check):
   ```bash
   cast storage 0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
     0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
     --rpc-url $ETHEREUM_RPC_URL
   ```

---

## Step 1 — Deploy the 6 new implementations

Run each script with `TIMELOCK` set. The script **broadcasts only the implementation
deployment** from the deployer EOA and then prints single-call `schedule` / `execute`
calldata to the console. **Ignore those printed calldatas** — they do not include
`grantRole` and must not be submitted. You will build a combined `scheduleBatch` in Step 3.
Collect the six new implementation addresses from the script output.

```bash
# Set common env
export ETHEREUM_RPC_URL=...
export TIMELOCK=0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7
export DEPLOYER_ADDRESS=<your-deployer-address>

# PolicyManager
POLICY_MANAGER_PROXY=0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
  forge script script/UpgradePolicyManagerEthereum.s.sol \
  --rpc-url $ETHEREUM_RPC_URL --keystore $KEYSTORE --broadcast

# ClaimManager (note: upgradeCalldata is empty — initializeV2 already applied)
CLAIM_MANAGER_PROXY=0x3ceE181C3E78fB9968f0Fb0935d2db0723B9Cb45 \
  forge script script/UpgradeClaimManagerEthereum.s.sol \
  --rpc-url $ETHEREUM_RPC_URL --keystore $KEYSTORE --broadcast

# PremiumManager
PREMIUM_MANAGER_PROXY=0xEc7322D6754709d5001B710ec4fB2547a89B3aD1 \
  forge script script/UpgradePremiumManagerEthereum.s.sol \
  --rpc-url $ETHEREUM_RPC_URL --keystore $KEYSTORE --broadcast

# CoverPoolFactory
COVER_POOL_FACTORY_PROXY=0x4f3DbB70cD85bcb63303FBa8610Cb163aDDA4E66 \
  forge script script/UpgradeCoverPoolFactoryEthereum.s.sol \
  --rpc-url $ETHEREUM_RPC_URL --keystore $KEYSTORE --broadcast

# SpecRegistry
SPEC_REGISTRY_PROXY=0x90EfF742958dd4c54ede3ED365375a14077D0A58 \
  forge script script/UpgradeSpecRegistryEthereum.s.sol \
  --rpc-url $ETHEREUM_RPC_URL --keystore $KEYSTORE --broadcast

# Swapper
SWAPPER_PROXY=0x148Bfe2330cEe4f227addb47736a105DB427dc31 \
  forge script script/UpgradeSwapperEthereum.s.sol \
  --rpc-url $ETHEREUM_RPC_URL --keystore $KEYSTORE --broadcast
```

Record the six new implementation addresses from the script output:

| Contract | New Implementation |
|----------|--------------------|
| PolicyManager | `0x...` |
| ClaimManager | `0x...` |
| PremiumManager | `0x...` |
| CoverPoolFactory | `0x...` |
| SpecRegistry | `0x...` |
| Swapper | `0x...` |

---

## Step 2 — Encode the 12 calldata payloads

For each proxy, two calls are needed: `upgradeToAndCall` and `grantRole`. Replace
`<IMPL_*>` with the addresses recorded in Step 1 and `<PAUSER>` with the chosen pauser.

```bash
export PAUSER=<your-pauser-address>
export PAUSER_ROLE=0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a

# --- PolicyManager ---
PM_UPGRADE=$(cast calldata "upgradeToAndCall(address,bytes)" <IMPL_PM> "0x")
PM_GRANT=$(cast calldata "grantRole(bytes32,address)" $PAUSER_ROLE $PAUSER)

# --- ClaimManager ---
CM_UPGRADE=$(cast calldata "upgradeToAndCall(address,bytes)" <IMPL_CM> "0x")
CM_GRANT=$(cast calldata "grantRole(bytes32,address)" $PAUSER_ROLE $PAUSER)

# --- PremiumManager ---
PREMM_UPGRADE=$(cast calldata "upgradeToAndCall(address,bytes)" <IMPL_PREMM> "0x")
PREMM_GRANT=$(cast calldata "grantRole(bytes32,address)" $PAUSER_ROLE $PAUSER)

# --- CoverPoolFactory ---
CPF_UPGRADE=$(cast calldata "upgradeToAndCall(address,bytes)" <IMPL_CPF> "0x")
CPF_GRANT=$(cast calldata "grantRole(bytes32,address)" $PAUSER_ROLE $PAUSER)

# --- SpecRegistry ---
SR_UPGRADE=$(cast calldata "upgradeToAndCall(address,bytes)" <IMPL_SR> "0x")
SR_GRANT=$(cast calldata "grantRole(bytes32,address)" $PAUSER_ROLE $PAUSER)

# --- Swapper ---
SW_UPGRADE=$(cast calldata "upgradeToAndCall(address,bytes)" <IMPL_SW> "0x")
SW_GRANT=$(cast calldata "grantRole(bytes32,address)" $PAUSER_ROLE $PAUSER)
```

All `grantRole` payloads are identical across proxies (same role, same recipient) and look
like:
```
0x2f2ff15d
65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a
000000000000000000000000<PAUSER-zero-padded>
```

---

## Step 3 — Build and submit `scheduleBatch` via Safe TX Builder

In Gnosis Safe TX Builder, create a transaction to the TimelockController
(`0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7`) calling `scheduleBatch`.

**Targets (12 entries, in order):**

```
0xfb771BE75365D2a1D32be198e03ce8a2125e2699   ← PolicyManager    (upgrade)
0xfb771BE75365D2a1D32be198e03ce8a2125e2699   ← PolicyManager    (grantRole)
0x3ceE181C3E78fB9968f0Fb0935d2db0723B9Cb45   ← ClaimManager     (upgrade)
0x3ceE181C3E78fB9968f0Fb0935d2db0723B9Cb45   ← ClaimManager     (grantRole)
0xEc7322D6754709d5001B710ec4fB2547a89B3aD1   ← PremiumManager   (upgrade)
0xEc7322D6754709d5001B710ec4fB2547a89B3aD1   ← PremiumManager   (grantRole)
0x4f3DbB70cD85bcb63303FBa8610Cb163aDDA4E66   ← CoverPoolFactory (upgrade)
0x4f3DbB70cD85bcb63303FBa8610Cb163aDDA4E66   ← CoverPoolFactory (grantRole)
0x90EfF742958dd4c54ede3ED365375a14077D0A58   ← SpecRegistry     (upgrade)
0x90EfF742958dd4c54ede3ED365375a14077D0A58   ← SpecRegistry     (grantRole)
0x148Bfe2330cEe4f227addb47736a105DB427dc31   ← Swapper          (upgrade)
0x148Bfe2330cEe4f227addb47736a105DB427dc31   ← Swapper          (grantRole)
```

**Values:** all `0`

**Payloads (matching order):**

```
$PM_UPGRADE   $PM_GRANT
$CM_UPGRADE   $CM_GRANT
$PREMM_UPGRADE  $PREMM_GRANT
$CPF_UPGRADE  $CPF_GRANT
$SR_UPGRADE   $SR_GRANT
$SW_UPGRADE   $SW_GRANT
```

**Predecessor:** `0x0000000000000000000000000000000000000000000000000000000000000000`

**Salt:** `0x0000000000000000000000000000000000000000000000000000000000000000`

**Delay:** output of `cast call ... "getMinDelay()(uint256)"` from Prerequisites step 1

Collect 5-of-7 signatures and submit.

Note the **operation ID** from the emitted `CallScheduled` events for use in Step 5. It can
also be computed locally:
```bash
cast keccak $(cast abi-encode \
  "(address[],uint256[],bytes[],bytes32,bytes32)" \
  "[<targets-array>]" "[0,0,0,0,0,0,0,0,0,0,0,0]" "[<payloads-array>]" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000)
```

---

## Step 4 — Wait for the timelock delay

No action required. Track the earliest execution time:

```bash
cast call 0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7 \
  "getTimestamp(bytes32)(uint256)" <OPERATION_ID> \
  --rpc-url $ETHEREUM_RPC_URL
```

---

## Step 5 — Execute the batch

After the delay has passed, submit a second Safe TX Builder transaction to the
TimelockController calling `executeBatch` with **identical** targets, values, payloads,
predecessor, and salt (no delay argument).

Verify it has not already been executed:

```bash
cast call 0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7 \
  "isOperationDone(bytes32)(bool)" <OPERATION_ID> \
  --rpc-url $ETHEREUM_RPC_URL
# must return false before submitting
```

---

## Step 6 — Verify post-upgrade state

Run all checks against mainnet:

```bash
# 1. Confirm new implementations are live
cast storage 0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
  0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc \
  --rpc-url $ETHEREUM_RPC_URL
# Repeat for each proxy

# 2. Confirm PAUSER_ROLE is granted to <PAUSER> on all six proxies
for PROXY in \
  0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
  0x3ceE181C3E78fB9968f0Fb0935d2db0723B9Cb45 \
  0xEc7322D6754709d5001B710ec4fB2547a89B3aD1 \
  0x4f3DbB70cD85bcb63303FBa8610Cb163aDDA4E66 \
  0x90EfF742958dd4c54ede3ED365375a14077D0A58 \
  0x148Bfe2330cEe4f227addb47736a105DB427dc31; do
  cast call $PROXY \
    "hasRole(bytes32,address)(bool)" \
    0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a \
    $PAUSER \
    --rpc-url $ETHEREUM_RPC_URL
done
# All must return true

# 3. Confirm DEFAULT_ADMIN_ROLE is still on the TimelockController (not disturbed)
cast call 0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
  "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x776Ab5890b6c62544dF06471A3705Ed83BeEA2f7 \
  --rpc-url $ETHEREUM_RPC_URL
# Must return true

# 4. Confirm pauser can pause (simulate — do not broadcast on mainnet without approval)
cast call 0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
  "pause()" --from $PAUSER --rpc-url $ETHEREUM_RPC_URL
# Must not revert

# 5. Confirm admin alone cannot pause (expected revert)
cast call 0xfb771BE75365D2a1D32be198e03ce8a2125e2699 \
  "pause()" --from 0xd2d03377Fa96687e9C11380DA9956AcC5F307e2c \
  --rpc-url $ETHEREUM_RPC_URL
# Must revert with AccessControlUnauthorizedAccount
```

---

## Operational notes post-upgrade

### Pausing contracts

Only the `PAUSER_ROLE` holder can call `pause()` or `unpause()`. The TimelockController
does NOT hold `PAUSER_ROLE` after this upgrade. This is intentional: the purpose of the
role is to enable **instant** pausing by an automation bot without any timelock delay.

If governance ever needs to pause via timelock (e.g. because the bot is compromised), the
path is: (1) schedule `grantRole(PAUSER_ROLE, timelockAddress)` → wait min-delay → execute;
(2) schedule `pause()` → wait min-delay → execute. This takes 2× the timelock delay and is
not suited for emergencies — always keep a trusted PAUSER_ROLE holder active.

### Swapper.setNativeWrapper

`setNativeWrapper` requires `whenPaused` in addition to `DEFAULT_ADMIN_ROLE`. After this
upgrade, the workflow to call it is:

1. `PAUSER` calls `swapper.pause()`
2. `ADMIN` (via timelock) calls `swapper.setNativeWrapper(newWrapper)`
3. `PAUSER` calls `swapper.unpause()`

### Granting PAUSER_ROLE to additional addresses

The TimelockController holds `DEFAULT_ADMIN_ROLE` which is the role-admin for `PAUSER_ROLE`.
To grant the role to a new address, schedule a `grantRole(PAUSER_ROLE, newAddress)` call
on the desired proxy through the normal Safe TX Builder → TimelockController flow.

---

## Checklist

- [ ] Timelock min delay confirmed on-chain
- [ ] Pauser address decided and documented
- [ ] 6 new implementation contracts deployed (addresses recorded above)
- [ ] 12 calldata payloads encoded and verified
- [ ] `scheduleBatch` submitted and signed by 5-of-7
- [ ] Operation ID recorded
- [ ] Delay elapsed
- [ ] `executeBatch` submitted and signed by 5-of-7
- [ ] New implementations verified on-chain for all 6 proxies
- [ ] `hasRole(PAUSER_ROLE, pauser)` returns `true` on all 6 proxies
- [ ] `hasRole(DEFAULT_ADMIN_ROLE, timelock)` still returns `true` on all 6 proxies
- [ ] `pause()` simulation from pauser succeeds on all 6 proxies
- [ ] `pause()` simulation from admin alone reverts on all 6 proxies
- [ ] `docs/deployment/Ethereum-Mainnet.md` updated with new implementation addresses
