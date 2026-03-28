# Event Definitions

> Source: grep fallback from src/

## src/defi/interfaces/IEvents.sol (CoveredVaultWrapper events)
- `NavRecorded(address indexed user, uint256 assets, uint256 shares, uint256 totalNav)`
- `NavWithdrawn(address indexed user, address indexed receiver, uint256 navWithdrawn, uint256 sharesBurned, uint256 assetsOut)`
- `InsuranceClaimed(address indexed user, uint96 indexed policyId, uint256 claimAmount, uint256 payout)`
- `PolicyBound(address indexed user, uint96 indexed policyId)`
- `PremiumCollected(address indexed recipient, uint256 amount)`
- `DeductibleBpsProposed(uint16 indexed newBps, uint64 executeAfter)`
- `DeductibleBpsExecuted(uint16 oldBps, uint16 indexed newBps)`
- `MaxCoverableLossBpsProposed(uint16 indexed newBps, uint64 executeAfter)`
- `MaxCoverableLossBpsExecuted(uint16 oldBps, uint16 indexed newBps)`
- `ClaimManagerUnavailable(uint96 indexed policyId)`
- `MorphoRedeemFailed(uint256 redeemShares)`
- `PolicyBoundReset(uint96 indexed oldPolicyId)`
- `UnderlyingRescued(address indexed to, uint256 amount)`
- `PolicyBindingFailed(bytes32 indexed reason)`
- `EmergencyExit(address indexed owner, address indexed receiver, uint256 shares, uint256 assetsOut)`
- `MorphoGateStatusUpdated(bool active)`
- `UpgradeProposed(address indexed implementation, uint64 executeAfter)`
- `UpgradeExecuted(address indexed implementation)`
- `PremiumRateProposed(uint256 newRate, uint64 executeAfter)`
- `PremiumRateExecuted(uint256 oldRate, uint256 newRate)`
- `TokensRescued(address indexed token, address indexed to, uint256 amount)`
- `ProposalSuperseded(bytes32 indexed paramKey)`
- `PremiumRecipientProposed(address indexed newRecipient, uint64 executeAfter)`
- `PremiumRecipientExecuted(address indexed oldRecipient, address indexed newRecipient)`

## src/interfaces/ISpecRegistry.sol
- `CoverPoolFactorySet(address indexed coverPoolFactory)`
- `SpecRegistered(address indexed coverPool, bytes32 indexed specId, address indexed spec)`
- `SpecApproved(address indexed spec)`
- `SpecRevoked(address indexed spec)`

## src/interfaces/IPolicyManager.sol
- `CoverageRequested(...)` - policy draft creation
- `PolicyDraftCancelled(uint96 indexed policyId, address indexed pool)`
- `PolicyBound(...)` - policy binding
- `StakeManagerSet(address indexed stakeManager_)`
- `ClaimManagerSet(address indexed claimManager_)`
- `CoverPoolFactorySet(address indexed coverPoolFactory_)`
- `ChainlinkPriceFeedSet(address indexed chainlinkPriceFeed_)`
- `PayoutTokenSet(address indexed token, bool supported)`
- `PremiumDefaultedSet(uint96 indexed policyId, bool defaulted)`

## src/interfaces/IClaimManager.sol
- `ClaimFiled(...)` - claim submission
- `ClaimApproved(...)` - claim approval
- `ClaimRejected(uint96 indexed policyId, uint256 indexed claimId, string reason, uint256 timestamp)`
- `CollateralSwapped(...)`
- `SpecRegistrySet(address indexed specRegistry)`
- `SlashingManagerSet(address indexed slashingManager)`
- `SwapperSet(address indexed swapper)`
- `PolicyManagerSet(address indexed policyManager)`
- `MaxSwapSlippageBpsSet(uint16 maxSwapSlippageBps)`
- `NextClaimApproved(uint96 indexed policyId, address indexed approver)`
- `TokensRecovered(address indexed token, address indexed to, uint256 amount)`

## src/interfaces/ICoverPool.sol
- `PoolFeeBpsSet(uint16 previousPoolFeeBps, uint16 newPoolFeeBps)`
- `PolicyForRequestBound(uint96 indexed policyId, uint256 vaultCount)`
- `FeeRecipientSet(address indexed previousFeeRecipient, address indexed newFeeRecipient)`

## src/interfaces/IPremiumCollector.sol
- `VaultRegistered(address indexed vault, address indexed underlying, address pool, uint96 policyId)`
- `VaultRemoved(address indexed vault)`
- `VaultUpdated(address indexed vault, address pool, uint96 policyId)`
- `Distributed(address indexed vault, uint256 shares, uint256 assets)`
- `DistributeIntervalSet(uint64 interval)`
- `PremiumManagerSet(address indexed premiumManager_)`
- `CoverPoolFactorySet(address indexed coverPoolFactory_)`

## src/interfaces/ISwapper.sol
- `SwapExecuted(...)` - swap completion
- `SwapRouteSet(address indexed tokenIn, address indexed tokenOut, address swapTarget, bool enabled)`
- `SwapTargetWhitelistSet(address indexed target, bool whitelisted)`
- `NativeWrapperSet(address indexed wrapper)`

## src/interfaces/IPremiumManager.sol
- `PremiumDistributed(address indexed pool, uint96 indexed policyId, uint256 amount)`
- `RewardsManagerSet(address indexed rewardsManager_)`
- `SpenderApproved(address indexed token, address indexed spender, uint256 amount)`
- `PlatformTreasurySet(address indexed platformTreasury_)`
- `PlatformFeeBpsSet(uint16 indexed platformFeeBps_)`

## src/interfaces/ICoverPoolFactory.sol
- `CoverPoolCreated(...)`
- `CoverPoolImplementationSet(address indexed previousImplementation, address indexed newImplementation)`
- `PolicyManagerSet(address indexed previousPolicyManager, address indexed newPolicyManager)`
- `StakeManagerSet(address indexed previousStakeManager, address indexed newStakeManager)`
- `SpecRegistrySet(address indexed previousSpecRegistry, address indexed newSpecRegistry)`

## src/adapters/UniswapV3Adapter.sol
- `AdapterSwapExecuted(...)`
- `PairFeeSet(address indexed tokenIn, address indexed tokenOut, uint24 fee)`

## src/mocks/ (mock events)
- `DefaultSpecSet(address indexed spec)`
- `DefaultResultUpdated(bool isPayable, bytes32 notesHash)`
- `CustomResultSet(bytes32 indexed evidenceHash, bool isPayable, bytes32 notesHash)`
- `CustomResultRemoved(bytes32 indexed evidenceHash)`
