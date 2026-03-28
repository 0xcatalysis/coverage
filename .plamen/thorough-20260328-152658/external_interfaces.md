# External Interfaces

> Source: grep from src/interfaces/ and src/defi/interfaces/

## src/interfaces/ (Core Protocol Interfaces)

### IChainlinkPriceFeed.sol
- `getUSDValue(address token, uint256 amount) external view returns (uint256)` - USD value (8 decimals)
- `getTokenAmount(address token, uint256 usdValue) external view returns (uint256)` - token amount from USD

### ISpecRegistry.sol
- `approveSpec(address spec) external`
- `revokeSpec(address spec) external`
- `isSpecApproved(address spec) external view returns (bool)`
- `registerSpec(bytes32 specId, ISpec spec) external`
- `resolveSpec(address coverPool, bytes32 specId) external view returns (ISpec spec)`
- `setCoverPoolFactory(address coverPoolFactory_) external`
- `pause() / unpause() external`

### IPolicyManager.sol
- `requestCoverage(...)` - creates a policy draft
- `cancelPolicyDraft(uint96 policyId) external`
- `bindPolicy(BindPolicyRequest calldata request, ...) external`
- `getPolicyDraft(uint96 policyId) external view returns (PolicyDraft)`
- `policyMetadata(uint96 policyId) external view returns (PolicyMetadata)`
- `setPremiumDefaulted(uint96 policyId, bool defaulted) external`
- `stakeManager() / claimManager() / coverPoolFactory()` - public state vars

### ICoverPool.sol
- `bindPolicyForRequest(uint96 policyId, Quote calldata quote, bytes calldata signature, address spec, address[] calldata vaults) external`
- `getBoundPolicy(uint96 policyId) external view returns (BoundPolicy)`
- `hasBoundPolicy(uint96 policyId) external view returns (bool)`
- `quoteDomainSeparator() external view returns (bytes32)`
- `setPoolFeeBps(uint16) / setFeeRecipient(address) / setPremiumDefaulted(...)` - admin setters
- `poolFeeBps() / feeRecipient() / policyManager() / stakeManager() / specRegistry()` - public getters

### ICoverPoolFactory.sol
- `createCoverPool(CreateCoverPoolParams calldata params) external returns (address)`
- `coverPoolExists(address pool) external view returns (bool)`
- `coverPoolAt(uint256 index) external view returns (address)`
- `totalCoverPools() external view returns (uint256)`
- `getCoverPools(uint256 offset, uint256 limit) external view returns (address[])`
- `computeCoverPoolAddress(CreateCoverPoolParams calldata params) external view returns (address)`
- Various setters: `setCoverPoolImplementation`, `setPolicyManager`, `setStakeManager`, `setSpecRegistry`

### IClaimManager.sol
- `fileClaim(...)` external - file an insurance claim
- `claimRecord(uint96 policyId, uint256 claimId) external view returns (ClaimRecord)`
- `policyClaim(uint96 policyId) external view returns (PolicyClaim)`
- `remainingCoverage(uint96 policyId) external view returns (uint256)`
- `claimApprovalRequired(uint96 policyId) external view returns (bool)`
- `approveNextClaim(uint96 policyId) external`
- Various setters: `setSpecRegistry`, `setSlashingManager`, `setSwapper`, `setPolicyManager`
- `recoverTokens(address token, address to, uint256 amount) external`

### IPremiumCollector.sol
- `registerVault(address vault, address pool, uint96 policyId) external`
- `removeVault(address vault) external`
- `updateVault(address vault, address pool, uint96 policyId) external`
- `distributeBatch(address[] calldata vaults) external`
- `getRegisteredVaults() external view returns (address[])`
- `getVaultConfig(address vault) external view returns (VaultConfig)`
- `getAccruedShares(address vault) external view returns (uint256)`
- `getDistributableVaults() external view returns (address[])`

### IPremiumManager.sol
- `distributePremium(address pool, uint96 policyId, address token, uint256 amount, uint16 poolFeeBps, address feeRecipient, uint256 committeeId) external`
- `approveSpender(address token, address spender, uint256 amount) external`
- `getFeeSplits(...) external view`

### ISwapper.sol
- `quoteSwap(SwapParams calldata params) external returns (uint256 amountOut)`
- `executeSwap(SwapParams calldata params) external returns (uint256 amountOut)`
- `setSwapRoute(...) external`
- `getSwapRoute(address tokenIn, address tokenOut) external view returns (SwapRoute)`
- `setSwapTargetWhitelist(address target, bool whitelisted) external`
- `setNativeWrapper(address wrapper) external`

### IStakeManager.sol
- (stake-related interface - called by ClaimManager for slashing)

### ISlashingManager.sol
- (slashing execution interface - called by ClaimManager)
  - `slash(...)` - taskId-gated to prevent replay attacks

### IRewardsManager.sol
- (rewards distribution interface - taskId-gated)

### IBindPolicyHook.sol
- `supportsInterface(bytes4 interfaceId) external pure returns (bool)`
- `onPolicyBound(uint96 policyId, uint256 stakingAmount) external` - hook called during policy binding

### ISpec.sol
- `evaluate(EvaluationContext calldata context) external view returns (EvaluationResult)`

### IQuoterV2.sol
- Uniswap V2 quoter interface

### IWETH.sol
- `deposit() external payable`
- `withdraw(uint256 amount) external`

### IQuotableAdapter.sol
- `quote(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut)`
- `swap(...) external`

## src/defi/interfaces/ (DeFi Adapter Interfaces)

### ICoveredVaultWrapper.sol
- `collectPremium() external` - collect accrued premium
- `emergencyRedeem(uint256 shares, address receiver, address owner) external returns (uint256)`
- `emergencyWithdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares)`
- `calculateShortfall() external view returns (uint256)`
- `userShortfall(address user) external view returns (uint256)`
- `onPolicyBound(...) external` - called by PolicyManager
- `evaluate(ISpec.EvaluationContext calldata context) external view returns (ISpec.EvaluationResult)`
- Various view getters for storage variables

### IEvents.sol
- (event definitions - see event_definitions.md)

### IAlerts.sol
- (alert/error definitions)

### Morpho/IVaultV2.sol
- Morpho ERC4626 vault interface (underlying vault)
  - Standard ERC4626: `deposit`, `withdraw`, `redeem`, `mint`, `totalAssets`, etc.
  - `balanceOf(address) external view returns (uint256)` - Morpho shares

### Morpho/IAdapter.sol
- Morpho adapter interface
