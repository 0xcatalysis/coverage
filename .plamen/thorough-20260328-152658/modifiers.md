# Modifiers

> Source: grep fallback from src/

## src/mocks/MockSpecRegistry.sol
- `onlyOwner()` - checks `msg.sender == OWNER`
- `whenNotPaused()` - checks `!_paused`

## src/mocks/MockSpec.sol
- `onlyOwner()` - checks `msg.sender == OWNER`

## src/CoverPool.sol
- `validateQuote(Quote calldata quote)` - validates quote timestamps:
  - `block.timestamp < quote.expirationTime` (quote not expired)
  - `block.timestamp >= quote.startTime` (policy has started)
  - `block.timestamp < quote.maturityTime` (policy not matured)

## OpenZeppelin Inherited Modifiers (used throughout src/)
- `onlyRole(bytes32 role)` - from AccessControlUpgradeable (SpecRegistry, PolicyManager, PremiumCollector, CoverPool, CoverPoolFactory, ClaimManager, Swapper, PremiumManager)
- `whenNotPaused()` - from PausableUpgradeable
- `nonReentrant()` - from ReentrancyGuardUpgradeable (CoveredVaultWrapper, PremiumCollector, ClaimManager, Swapper)
- `initializer` - from Initializable

## Notable Modifier Usage in CoveredVaultWrapper
- `nonReentrant` on `_deposit()`, `collectPremium()`, `redeem()`, `withdraw()`, `emergencyRedeem()`, `emergencyWithdraw()`
- Various slither-disable comments indicate known reentrancy patterns that are intentional/benign
