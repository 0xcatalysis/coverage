# External Production Behavior — Catalysis Coverage

## Deployment Status

- **Sepolia**: Fully deployed with all Coverage and Core contracts. Addresses documented in `docs/deployment/Sepolia-Testnet.md`.
- **Ethereum Mainnet**: Template exists (`docs/deployment/Ethereum-Mainnet.md`) but all address fields are **empty** — not yet deployed to mainnet.
- **CoveredVaultWrapper**: No production deployment found. Deployment script exists at `script/adapter/DeployCoveredVaultWrapper.s.sol` but uses env-var-based configuration (no hardcoded addresses).

---

## External Dependency 1: Morpho V2 Vault (IVaultV2)

### Production Addresses
- No hardcoded Morpho V2 vault address in the codebase. The vault is deployed fresh per-wrapper via `IVaultV2Factory.createVaultV2()` in the deployment script.
- The `VAULT_V2_FACTORY` and `MORPHO_ADAPTER_FACTORY` addresses are loaded from env vars at deploy time.

### Functions Called by CoveredVaultWrapper
| Function | Where Called | Purpose |
|----------|-------------|---------|
| `deposit(assets, address(this))` | `_deposit()` | Deposit underlying assets into Morpho, wrapper as receiver |
| `redeem(shares, address(this), address(this))` | `_executeWithdrawal()` | Redeem Morpho shares for underlying on user withdrawal |
| `convertToAssets(shares)` | `_morphoValue()`, `_userMorphoValue()` | Convert Morpho shares to underlying asset value |
| `balanceOf(address(this))` | `_morphoValue()`, `_executeWithdrawal()`, `_userMorphoValue()` | Get wrapper's Morpho share balance |
| `asset()` | `initialize()` | Get underlying asset address at init time |

### Mock vs Production Behavior Differences
1. **Gate mechanism**: Production Morpho V2 vaults have `sendAssetsGate` and `receiveAssetsGate` that can block deposits/redemptions. Test mocks likely don't implement gating — the wrapper handles this via try/catch + `lastKnownMorphoValue` fallback + `MorphoRedeemReverted()` error.
2. **`convertToAssets()` precision**: Production Morpho may have different rounding behavior than simple mocks. The wrapper uses the value directly (no additional rounding).
3. **Fee configuration**: Deployment script explicitly sets `managementFee(0)` and `performanceFee(0)` on the Morpho vault. If these were non-zero in production, the wrapper's accounting would be incorrect (premium model assumes fee-free Morpho).
4. **Adapter abidcation**: The deployment script abdicates `addAdapter`, `removeAdapter`, and `setPerformanceFeeRecipient` — making these immutable after deployment. Mocks don't enforce this.
5. **Sole depositor assumption**: The wrapper assumes it is the sole depositor in the Morpho vault. If other depositors exist, the `convertToAssets(balanceOf(wrapper))` calculation is still correct (it returns the wrapper's proportional share), but the `lastKnownMorphoValue` cache would reflect only the wrapper's portion.

### Resilience Patterns
- `_morphoValue()`: try/catch on `convertToAssets(balanceOf(this))` — falls back to `lastKnownMorphoValue`
- `_userMorphoValue()`: try/catch on `convertToAssets(userShares)` — falls back to pro-rata of `lastKnownMorphoValue`
- `_executeWithdrawal()`: try/catch on `redeem()` — emits `MorphoRedeemFailed` and reverts with `MorphoRedeemReverted()` (no silent zero)

---

## External Dependency 2: UniswapV3 (via Swapper + UniswapV3Adapter)

### Production Addresses
| Component | Sepolia | Mainnet |
|-----------|---------|---------|
| SwapRouter02 | `0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E` | `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` |
| Swapper (proxy) | `0xcE22Aa500df3E94A5cdBdBD0a97795ff99948C10` | Not deployed |
| WETH (Sepolia) | `0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9` | Standard WETH9 |

UniswapV3Adapter is deployed per-deployment via `script/DeployUniswapV3Adapter.s.sol`. No hardcoded production address found — the adapter address is registered as a whitelisted target in Swapper.

### Functions Called
| Function | Where Called | Purpose |
|----------|-------------|---------|
| `UniswapV3Adapter.swap(tokenIn, tokenOut, fee, amountOutMinimum)` | Swapper `_performSwap()` via stored calldata | Execute collateral conversion swap |
| `UniswapV3Adapter.quote(tokenIn, tokenOut, amountIn)` | Swapper `quoteSwap()` | Get DEX price quote for slippage calculation |
| `QuoterV2.quoteExactInputSingle(...)` | UniswapV3Adapter `quote()` | Underlying Uniswap V3 quote |
| `IV3SwapRouter.exactInputSingle(...)` | UniswapV3Adapter `swap()` | Underlying Uniswap V3 swap execution |

### Mock vs Production Behavior Differences
1. **Liquidity**: Production Uniswap V3 pools have variable liquidity; large claims may experience significant slippage. The system has `maxSwapSlippageBps` (default 2%, max 100%) to cap slippage inflation on slash amounts.
2. **Quote accuracy**: `quoteExactInputSingle` simulates the swap via internal revert — not a view function. Production quotes may differ from actual swap output due to MEV, block-level state changes. ClaimManager handles this via `amountOutMin` enforcement.
3. **Pool existence**: If no Uniswap V3 pool exists for a token pair, `quoteSwap` returns 0 (try/catch), and the vault is excluded from slash distribution. In production, this silently excludes collateral that can't be converted.
4. **Fee tier**: UniswapV3Adapter uses `DEFAULT_FEE = 3000` (0.3%) with per-pair overrides. If the optimal pool is at a different fee tier, quotes and swaps may be suboptimal.

### Slippage Protection Layers
1. **ClaimManager `_inflateForSlippage()`**: inflates base slash amount so beneficiary receives target amount after swap. Capped at `maxSwapSlippageBps` above base.
2. **ClaimManager `_executeCollateralSwap()`**: sets `amountOutMin` from `quoteSwap * (1 - maxSwapSlippageBps)`, floor of 1.
3. **Swapper `executeSwap()`**: enforces `amountOut >= amountOutMin`.
4. **UniswapV3Adapter**: forwards `amountOutMinimum` directly to Uniswap V3 router for router-level enforcement.

---

## External Dependency 3: Chainlink Price Feed

### Production Addresses
| Component | Sepolia | Mainnet |
|-----------|---------|---------|
| ChainlinkPriceFeed (proxy) | `0x2c0334283E06839Eb9Ab01f091Dca4A98443d120` | Not deployed |
| ETH/USD aggregator (Sepolia) | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | Standard Chainlink ETH/USD |

### Usage in Protocol
ChainlinkPriceFeed is used **only** in `PolicyManager.bindPolicy()` for stake sufficiency check at bind time:
```solidity
totalStakeUSD += IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(tokens[i], tokenStakes[i]);
coverageLimitUSD = IChainlinkPriceFeed(chainlinkPriceFeed).getUSDValue(request.payoutToken, boundPolicy.coverageLimit);
require(totalStakeUSD >= coverageLimitUSD, InsufficientStake(...));
```

### Mock vs Production Behavior Differences
1. **Staleness**: The `IChainlinkPriceFeed` interface wraps Chainlink aggregators. Stale or missing feeds cause `bindPolicy()` to revert. This is a **one-time check at bind** — prices are NOT used during claims or premium accrual.
2. **Decimal handling**: ChainlinkPriceFeed returns 8-decimal USD values. The protocol's price feed wrapper handles decimal normalization.
3. **Feed availability**: If no price feed is registered for a collateral or payout token, the bind-time check fails (documented as `PriceFeedNotFound` in failure modes).

### Impact Scope
- ChainlinkPriceFeed has **no runtime impact** on claims, premium accrual, or withdrawals. It only gates policy binding.
- If the price feed returns an incorrect value at bind time, the policy may be bound with insufficient (or excessive) collateral backing.

---

## External Dependency 4: Catalysis Core Contracts

### Production Addresses (Sepolia)
| Component | Address |
|-----------|---------|
| StakeManager | `0x3dB3ca70f23CeF23c7fEDB36dF6019B5ECB5Cb0c` |
| RewardsManager | `0xF4cdFcD4bb8c1ABa3F79AFF9303429cAf79052a9` |
| SlashingManager | `0x4609a19E40f8262b3E42dEC45AACf18961fd4143` |
| SSPRouter | `0xc2F3906Bb57c8Db7DF2DddF0f2CEc521fE6834f8` |
| EigenAdapter | `0xA28871e253C972A96003D3f432CA4170f4ae2A78` |
| SymbioticAdapter | `0x533115b15C3c41e42652c35694a20eb6F7b2cbD2` |

### Functions Called by Coverage
| Core Contract | Function | Coverage Caller | Purpose |
|--------------|----------|----------------|---------|
| StakeManager | `createCommittee(policyId, pool, duration)` | PolicyManager | Create policy-scoped committee |
| StakeManager | `addOperatorToCommittee(curator, policyId)` | PolicyManager | Assign curator as committee operator |
| StakeManager | `removeOperatorFromCommittee(curator, policyId)` | PolicyManager | Release committee on draft cancel |
| StakeManager | `setCommitteeVaults(policyId, vaults[], coverageLimit)` | CoverPool | Bind vaults to committee |
| StakeManager | `getCommitteeVaults(policyId)` | PolicyManager | Verify vault backing exists |
| StakeManager | `getCommitteeTokenStakes(policyId)` | PolicyManager | Get per-vault stake for USD check |
| SlashingManager | `previewSlashing(policyId, operator)` | ClaimManager | Get per-vault slashable stake data |
| SlashingManager | `executeSlashing(policyId, operator, vaultSlashes[], taskId)` | ClaimManager | Execute slashing and get collateral |
| RewardsManager | `distributeRewards(policyId, operator, amount, token, taskId)` | PremiumManager | Trigger reward fan-out to restakers |

### Assumptions About Core
- Committee state and stake reads are correct and timely
- Reward/slash execution either succeeds or reverts atomically
- Token arrays returned from slashing are valid and aligned with vault order
- Duration vaults act as EigenLayer operators (auto-deployed by `SSPRouter.createCommittee`)

### Failure Patterns
| Failure | Impact |
|---------|--------|
| Core stake insufficient at bind | Policy bind reverts (`InsufficientStake`) |
| Slashing returns empty/zero arrays | Claim payout reverts (`NoCollateralSlashed`) |
| `ChainlinkPriceFeed` unset/stale | Bind-time sufficiency check fails |
| `SSPRouter safeTransferFrom` reverts | Premium distribution fails (needs `approveSpender` setup) |

---

## External Dependency 5: EigenLayer

### Production Addresses (Sepolia)
| Component | Address |
|-----------|---------|
| AllocationManager | `0x42583067658071247ec8CE0A516A58f682002d07` |
| DelegationManager | `0xD4A7E1Bd8015057293f0D0A557088c286942e84b` |
| StrategyManager | `0x2E3D6c0744b10eb0A4e6F679F71554a39Ec47a5D` |
| WETH Strategy | `0x424246ef71b01ee33aa33ac590fd9a0855f5efbc` |

### Integration Model
- Coverage does NOT interact directly with EigenLayer contracts
- All EigenLayer interactions go through Core (StakeManager -> SSPRouter -> EigenAdapter)
- Duration vaults (`DurationVaultStrategy`) are auto-deployed by `EigenAdapter.deployDurationVaultStrategy` during committee creation
- Restaker deposit is a direct EigenLayer call (not orchestrated by Coverage)

---

## Summary of Mock/Production Risk Areas

| Area | Risk | Mitigation |
|------|------|-----------|
| Morpho gate blocking redemptions | Withdrawals revert if Morpho gate is active | `MorphoRedeemReverted()` error; `emergencyRedeem` still blocked by Morpho gate; owner can activate `morphoGateActive` to pause premium accrual |
| Morpho `convertToAssets` revert | View functions return incorrect cached values | `lastKnownMorphoValue` fallback; updated on every deposit and successful redeem |
| Uniswap V3 pool liquidity | Large claims may fail or suffer high slippage | Multi-layer slippage protection; `maxSwapSlippageBps` cap; `amountOutMin` enforcement |
| Chainlink feed staleness | Could bind policy with insufficient collateral | One-time check only; does not affect runtime claim/premium operations |
| Core contract availability | Slashing failure blocks claim payouts | ClaimManager wrapped in try/catch from wrapper perspective; `emergencyRedeem` available |
| Morpho fee assumption | Non-zero Morpho fees would break accounting | Deployment script sets fees to 0 and abdicates fee setters |
