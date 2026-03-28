# Function List (src/ directory)

> Source: grep fallback (SLITHER_AVAILABLE determined below)
> Note: Slither MCP probe was not attempted as this is a fallback recon agent. See static_analysis.md.

## src/mocks/MockSpecRegistry.sol
- `registerSpec(bytes32 specId, ISpec spec)` external whenNotPaused
- `registerSpecForPool(address coverPool, bytes32 specId, address spec)` external onlyOwner whenNotPaused
- `setDefaultSpec(address spec)` external onlyOwner
- `approveSpec(address spec)` external override onlyOwner
- `revokeSpec(address spec)` external override onlyOwner
- `isSpecApproved(address)` external pure override
- `pause()` external override onlyOwner
- `unpause()` external override onlyOwner
- `paused()` external view
- `resolveSpec(address coverPool, bytes32 specId)` external view override

## src/mocks/MockSpec.sol
- `setDefaultResult(bool isPayable, bytes32 notesHash)` external onlyOwner
- `setCustomResult(bytes32 evidenceHash, bool isPayable, bytes32 notesHash)` external onlyOwner
- `removeCustomResult(bytes32 evidenceHash)` external onlyOwner
- `evaluate(EvaluationContext calldata context)` external view

## src/mocks/MockBindPolicyHook.sol
- `supportsInterface(bytes4 interfaceId)` external pure override
- `onPolicyBound(uint96, uint256)` external pure override

## src/mocks/MockERC4626Vault.sol
- constructor(address underlying, ...)

## src/SpecRegistry.sol
- `initialize(address admin_, address coverPoolFactory_)` external initializer
- `setCoverPoolFactory(address coverPoolFactory_)` external onlyRole(DEFAULT_ADMIN_ROLE)
- `pause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `unpause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `approveSpec(address spec)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `revokeSpec(address spec)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `isSpecApproved(address spec)` external view override
- `registerSpec(bytes32 specId, ISpec spec)` external override whenNotPaused
- `resolveSpec(address coverPool, bytes32 specId)` external view override
- `_authorizeUpgrade(address newImplementation)` internal view override onlyRole(DEFAULT_ADMIN_ROLE)

## src/PolicyManager.sol
- `initialize(address admin_, address stakeManager_, address claimManager_, address coverPoolFactory_, address chainlinkPriceFeed_, address[] initialPayoutTokens_)` external
- `pause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `unpause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setStakeManager(address stakeManager_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setClaimManager(address claimManager_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setCoverPoolFactory(address coverPoolFactory_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setChainlinkPriceFeed(address chainlinkPriceFeed_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setSupportedPayoutToken(address token, bool supported)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `requestCoverage(address pool, address beneficiary, address claimer, address payoutToken, uint32 duration, address bindPolicyHook)` external
- `cancelPolicyDraft(uint96 policyId)` external override nonReentrant whenNotPaused
- `bindPolicy(BindPolicyRequest calldata request, ...)` external
- `getPolicyDraft(uint96 policyId)` external view override
- `policyMetadata(uint96 policyId)` external view
- `setPremiumDefaulted(uint96 policyId, bool defaulted)` external override
- `paused()` public view override
- `_authorizeUpgrade(address)` internal view override onlyRole(DEFAULT_ADMIN_ROLE)
- `_validateRequest(BindPolicyRequest calldata request)` private view

## src/PremiumCollector.sol
- `initialize(address admin_, address premiumManager_, address coverPoolFactory_, uint64 distributeInterval_)` external
- `pause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `unpause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `registerVault(address vault, address pool, uint96 policyId)` external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE)
- `removeVault(address vault)` external override nonReentrant onlyRole(DEFAULT_ADMIN_ROLE)
- `updateVault(address vault, address pool, uint96 policyId)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `distributeBatch(address[] calldata vaults)` external override nonReentrant whenNotPaused
- `setDistributeInterval(uint64 interval)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setPremiumManager(address premiumManager_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setCoverPoolFactory(address coverPoolFactory_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `getRegisteredVaults()` external view override
- `getVaultConfig(address vault)` external view override
- `getAccruedShares(address vault)` external view override
- `getDistributableVaults()` external view override
- `paused()` public view override
- `_authorizeUpgrade(address)` internal view override onlyRole(DEFAULT_ADMIN_ROLE)
- `_distribute(address vault)` private

## src/CoverPool.sol
- `initialize(address curator_, address quoteSigner_, address policyManager_, address stakeManager_, address specRegistry_, uint16 poolFeeBps_)` external
- `pause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `unpause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setPoolFeeBps(uint16 poolFeeBps_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setFeeRecipient(address feeRecipient_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setPremiumDefaulted(uint96 policyId, bool defaulted)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `bindPolicyForRequest(uint96 policyId, Quote calldata quote, bytes calldata signature, address spec, address[] calldata vaults)` external
- `quoteDomainSeparator()` external view override
- `getBoundPolicy(uint96 policyId)` external view override
- `hasBoundPolicy(uint96 policyId)` external view override
- `grantRole(bytes32 role, address account)` external override
- `revokeRole(bytes32 role, address account)` external override
- `_validateVaults(address[] calldata vaults)` private pure
- `_recordBoundPolicy(uint96 policyId, bytes32 policyCommit, Quote calldata quote, address spec, address[] calldata vaults)` internal
- `_verifyQuote(Quote calldata quote, bytes calldata signature)` internal view
- `_hashQuote(Quote calldata quote)` private pure

## src/CoverPoolFactory.sol
- `initialize(address admin_, address creator_, address coverPoolImplementation_, address policyManager_, address stakeManager_, address specRegistry_)` external
- `pause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `unpause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `createCoverPool(CreateCoverPoolParams calldata params)` external
- `setCoverPoolImplementation(address implementation_)` external override onlyRole(CREATOR_ROLE)
- `setPolicyManager(address policyManager_)` external override onlyRole(CREATOR_ROLE)
- `setStakeManager(address stakeManager_)` external override onlyRole(CREATOR_ROLE)
- `setSpecRegistry(address specRegistry_)` external override onlyRole(CREATOR_ROLE)
- `coverPoolExists(address pool)` external view override
- `coverPoolAt(uint256 index)` external view override
- `totalCoverPools()` external view override
- `getCoverPools(uint256 offset, uint256 limit)` external view override
- `computeCoverPoolAddress(CreateCoverPoolParams calldata params)` public view override
- `_authorizeUpgrade(address newImplementation)` internal view override onlyRole(DEFAULT_ADMIN_ROLE)
- `_computeSalt(CreateCoverPoolParams calldata params)` private view

## src/ClaimManager.sol
- `initialize(address admin_, address specRegistry_, ...)` external
- `pause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `unpause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setSpecRegistry(address specRegistry_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setSlashingManager(address slashingManager_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setSwapper(address swapper_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setPolicyManager(address policyManager_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setMaxSwapSlippageBps(uint16 maxSwapSlippageBps_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `recoverTokens(address token, address to, uint256 amount)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `approveNextClaim(uint96 policyId)` external override
- `claimApprovalRequired(uint96 policyId)` external view override
- `fileClaim(...)` external
- `claimRecord(uint96 policyId, uint256 claimId)` external view override
- `policyClaim(uint96 policyId)` external view override
- `remainingCoverage(uint96 policyId)` external view override
- `paused()` public view override
- `_authorizeUpgrade(address)` internal view override onlyRole(DEFAULT_ADMIN_ROLE)
- `_fileClaimWithMetadata(...)` internal
- `_capAndExecutePayout(...)` internal
- `_executeSlashingAndPayout(...)` internal
- `_slashAndDistribute(...)` internal
- `_computeVaultSlashes(...)` internal
- `_toPayoutEquivalent(address token, address payoutToken, uint256 stake)` private
- `_resolveNative(address token)` private view
- `_calculateVaultSlash(...)` internal
- `_inflateForSlippage(...)` internal
- `_processCollateral(...)` internal
- `_executeCollateralSwap(...)` internal
- `_transferToken(address token, address to, uint256 amount)` private
- `_approveIfERC20(address token, address spender, uint256 amount)` private
- `_evaluateSpec(...)` internal

## src/adapters/UniswapV3Adapter.sol
- `setPairFee(address tokenIn, address tokenOut, uint24 fee)` external onlyOwner
- `quote(address tokenIn, address tokenOut, uint256 amountIn)` external override
- `swap(...)` external
- `_getFee(address tokenIn, address tokenOut)` private view

## src/Swapper.sol
- `initialize(...)` external
- `pause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `unpause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setSwapTargetWhitelist(address target, bool whitelisted)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setNativeWrapper(address wrapper)` external override onlyRole(DEFAULT_ADMIN_ROLE) whenPaused
- `recoverTokens(address token, address to, uint256 amount)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setSwapRoute(...)` external
- `quoteSwap(...)` external
- `executeSwap(SwapParams calldata params)` external
- `getSwapRoute(address tokenIn, address tokenOut)` external view override
- `paused()` public view override
- `_authorizeUpgrade(address)` internal view override onlyRole(DEFAULT_ADMIN_ROLE)
- `_handleTokenInput(address tokenIn, address actualTokenIn, uint256 amountIn)` private
- `_performSwap(...)` internal
- `_handleTokenOutput(address tokenOut, uint256 amountOut, address recipient)` private
- `_validateAndGetSwapTarget(...)` internal
- `_getRouteKey(address tokenIn, address tokenOut)` private pure

## src/PremiumManager.sol
- `initialize(...)` external
- `pause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `unpause()` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setRewardsManager(address rewardsManager_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `approveSpender(...)` external
- `setPlatformTreasury(address platformTreasury_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `setPlatformFeeBps(uint16 platformFeeBps_)` external override onlyRole(DEFAULT_ADMIN_ROLE)
- `distributePremium(...)` external
- `paused()` public view override
- `getFeeSplits(...)` external view
- `_authorizeUpgrade(address)` internal view override onlyRole(DEFAULT_ADMIN_ROLE)

## src/defi/adapters/morpho/CoveredVaultAccrual.sol
- `_accruePremium()` internal
- `collectPremium()` external override nonReentrant
- `_accruedPremium()` internal view
- `_accruedPremiumFor(uint256 morphoVal)` internal view
- `_activeElapsedFrom(uint256 checkpoint)` internal view
- `_morphoValue()` internal view
- `_isPolicyActive()` internal view
- `_liabilityHeadroom(uint256 morphoVal)` internal view

## src/defi/adapters/morpho/CoveredVaultWrapper.sol
- `initialize(...)` external
- `totalAssets()` public view override
- `_deposit(address caller, address receiver, uint256 assets, uint256 shares)` internal override nonReentrant
- `_settleWithdrawalTransfer(...)` internal
- `_withdraw(...)` internal override
- `redeem(uint256 shares, address receiver, address owner)` external override
- `withdraw(uint256 assets, address receiver, address owner)` external override
- `emergencyRedeem(uint256 shares, address receiver, address owner)` external
- `emergencyWithdraw(uint256 assets, address receiver, address owner)` external
- `_update(address from, address to, uint256 value)` internal override
- `onPolicyBound(...)` external
- `_computeInsurance(...)` internal
- `_claimInsurance(uint256 claimAmount, address user)` internal
- `evaluate(ISpec.EvaluationContext calldata context)` external view
- `calculateShortfall()` external view override
- `userShortfall(address user)` external view override
- `maxWithdraw(address owner)` public view override
- `maxRedeem(address owner)` public view override
- `_decimalsOffset()` internal pure override
- `maxDeposit(address)` public view override
- `maxMint(address receiver)` public view override
- `supportsInterface(bytes4 interfaceId)` external pure
- `_userMorphoValue(address user)` private view
- `_computeOwedAmounts(...)` internal
- `_executeWithdrawal(...)` internal
- `_updateDebtsAfterWithdrawal(...)` internal
- `_validatePolicyBinding(IPolicyManager.PolicyMetadata memory pol)` private
- `_revertBinding(bytes32 code)` private
- `_safeSub(uint256 a, uint256 b)` private pure
- `_calcOwedDebt(uint256 principal, uint256 cumulative, uint256 userDebt)` private pure
- `_capAndApplyDeductible(uint256 shortfall, uint256 basis)` private view
- `_tstore(uint256 slot, uint256 value)` private

## src/defi/adapters/morpho/CoveredVaultAdmin.sol
- (admin setters for timelocked parameters: deductibleBps, maxCoverableLossBps, premiumRate, premiumRecipient, upgrade, morpho gate, rescue functions)

## src/defi/adapters/morpho/CoveredVaultStorage.sol
- (storage layout definitions - no external functions)
