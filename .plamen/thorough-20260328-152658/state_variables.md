# State Variables

> Source: grep fallback from src/

## src/defi/adapters/morpho/CoveredVaultStorage.sol (inherited by CoveredVaultWrapper)

### Constants
- `BPS_DENOMINATOR = 10_000` (uint256 internal constant)
- `PENDING_CLAIM_AMOUNT_SLOT` = keccak256-derived transient storage slot
- `ACTUAL_OUT_SLOT` = keccak256-derived transient storage slot
- `SKIP_INSURANCE_SLOT` = keccak256-derived transient storage slot
- `WAD = 1e18` (uint256 internal constant)
- `MAX_PREMIUM_RATE_PER_SECOND = 15_854_895_991` (uint256 internal constant) - max ~50% APR
- `UPGRADE_DELAY = 7 days`
- `STANDARD_DELAY = 2 days`
- `OPERATIONAL_DELAY = 2 hours`

### Storage Variables
- `morphoVault` (address public) - the underlying Morpho ERC4626 vault
- `maxCoverableLossBps` (uint16 public) - max loss percentage coverable
- `deductibleBps` (uint16 public) - deductible percentage applied to claims
- `policyId` (uint96 public) - the bound insurance policy ID
- `policyBoundExecuted` (bool public) - whether policy binding has been executed
- `userPrincipal` (mapping(address => uint256) public) - per-user deposited principal
- `totalPrincipal` (uint256 public) - total deposited principal across all users
- `premiumRatePerSecond` (uint256 public) - premium rate per second (WAD precision)
- `lastPremiumAccrualTime` (uint256 public) - timestamp of last premium accrual
- `premiumRecipient` (address public) - recipient of collected premiums
- `depositCap` (uint256 public) - max total deposits allowed
- `pendingPremium` (uint256 public) - accrued but not yet paid premium
- `coverageLimit` (uint256 public) - maximum claimable coverage
- `cumulativePremiumPerUnit` (uint256 public) - cumulative premium per unit of principal
- `userPremiumDebt` (mapping(address => uint256) public) - per-user premium debt checkpoint
- `totalPremiumLiability` (uint256 public) - total outstanding premium liability
- `userMorphoShares` (mapping(address => uint256) public) - per-user Morpho vault shares
- `pendingDeductibleBps` (uint16 public) - proposed new deductibleBps (timelocked)
- `pendingDeductibleTimestamp` (uint64 public) - timelock timestamp for deductible change
- `pendingMaxCoverableLossBps` (uint16 public) - proposed new maxCoverableLossBps (timelocked)
- `pendingMaxCoverableLossTimestamp` (uint64 public) - timelock timestamp
- `lastKnownMorphoValue` (uint256 public) - last known total assets in Morpho vault
- `morphoGateActive` (bool public) - whether emergency morpho gate is active
- `pendingImplementation` (address public) - proposed new implementation (timelocked upgrade)
- `pendingUpgradeTimestamp` (uint64 public) - timelock timestamp for upgrade
- `pendingPremiumRate` (uint256 public) - proposed new premium rate
- `pendingPremiumRateTimestamp` (uint64 public) - timelock timestamp for rate change
- `pendingPremiumRecipient` (address public) - proposed new premium recipient
- `pendingPremiumRecipientTimestamp` (uint64 public) - timelock timestamp
- `gateActivatedAt` (uint256 public) - timestamp when morpho gate was activated
- `gateGracePeriod` (uint256 public) - grace period duration after gate activation

### Transient Storage (EIP-1153)
- PENDING_CLAIM_AMOUNT_SLOT - amount of pending claim in current tx
- ACTUAL_OUT_SLOT - actual assets out in current tx
- SKIP_INSURANCE_SLOT - flag to skip insurance check in current tx

### Structs
- `WithdrawalAmounts { uncappedPremium, totalOwedPremium, ... }` - used during withdrawal computation

## src/SpecRegistry.sol
- `coverPoolFactory` (ICoverPoolFactory public)
- `_specs` (mapping(address coverPool => mapping(bytes32 specId => ISpec spec)) private)
- `_approvedSpecs` (mapping(address spec => bool approved) private)

## src/PolicyManager.sol
- `stakeManager` (address public override)
- `claimManager` (address public override)
- `coverPoolFactory` (address public override)
- `chainlinkPriceFeed` (address public override)
- `_nextPolicyId` (uint96 private)
- `_policyDrafts` (mapping(uint96 policyId => PolicyDraft draft) private)
- `_policies` (mapping(uint96 policyId => IPolicyManager.PolicyMetadata) private)
- `_registeredPolicyCommits` (mapping(bytes32 policyCommit => bool registered) private)
- `supportedPayoutTokens` (mapping(address token => bool supported) public override)

## src/PremiumCollector.sol
- `_vaultConfigs` (mapping(address vault => VaultConfig) private)
- `_registeredVaults` (address[] private)
- `_vaultIndex` (mapping(address vault => uint256 index) private)
- `premiumManager` (address public override)
- `distributeInterval` (uint64 public override)
- `coverPoolFactory` (address public override)

## src/CoverPool.sol
- `QUOTE_SIGNER_ROLE` = keccak256("QUOTE_SIGNER_ROLE") (bytes32 constant override)
- `policyManager` (address public override)
- `stakeManager` (address public override)
- `specRegistry` (address public override)
- `feeRecipient` (address public override)
- `poolFeeBps` (uint16 public override)
- `boundPolicyCommits` (mapping(bytes32 policyCommit => bool bound) public override)
- `boundPolicies` (mapping(uint96 policyId => BoundPolicy policy) private)

## src/CoverPoolFactory.sol
- `CREATOR_ROLE` = keccak256("CREATOR_ROLE") (bytes32 constant override)
- `coverPoolImplementation` (address public override)
- `policyManager` (address public override)
- `stakeManager` (address public override)
- `specRegistry` (address public override)
- `_pools` (EnumerableSet.AddressSet private)

## src/ClaimManager.sol
- `_MAX_SLIPPAGE_BPS = 10_000` (uint16 private constant)
- `_NATIVE_ETH = 0xEeee...EEEeE` (address private constant)
- `specRegistry` (address public override)
- `slashingManager` (address public override)
- `swapper` (address public override)
- `policyManager` (address public override)
- `maxSwapSlippageBps` (uint16 public override)
- `_claims` (mapping(uint96 policyId => mapping(uint256 claimId => ClaimRecord)) private)
- `_policyClaims` (mapping(uint96 policyId => PolicyClaim) private)
- `_claimApprovalRequired` (mapping(uint96 policyId => bool) private)
- `_usedEvidenceHashes` (mapping(uint96 policyId => mapping(bytes32 evidenceHash => bool used)) private)

## src/PremiumManager.sol
- `rewardsManager` (address public override)
- `platformTreasury` (address public override)
- `platformFeeBps` (uint16 public override)
- (token approvals managed via OpenZeppelin SafeERC20)
