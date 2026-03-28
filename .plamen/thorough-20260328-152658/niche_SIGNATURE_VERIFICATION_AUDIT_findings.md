# Signature Verification Audit Findings

**Agent**: Niche — SIGNATURE_VERIFICATION_AUDIT
**Scope**: CoverPool EIP-712 quote signing system
**Key Files**: `src/CoverPool.sol`, `src/PolicyManager.sol`, `src/interfaces/ICoverPool.sol`
**Exclusions**: OZ-4 (basePremium hash truncation — already REFUTED) excluded per instructions.

---

## Finding [SIG-1]: basePremium Field Signed But Not Persisted or Enforced Post-Binding

**Verdict**: CONFIRMED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✓, R13:✓]
**Depth Evidence**: [TRACE: _hashQuote includes basePremium → _recordBoundPolicy creates BoundPolicy without basePremium → PolicyMetadata does not store basePremium], [VARIATION: basePremium=0 vs basePremium=1e18 produce different policyCommits but identical BoundPolicy and PolicyMetadata on-chain]
**Severity**: Informational
**Location**: `CoverPool.sol:L33-34` (QUOTE_TYPEHASH), `CoverPool.sol:L329-343` (_hashQuote), `CoverPool.sol:L270-299` (_recordBoundPolicy), `interfaces/ICoverPool.sol:L30`, `interfaces/ICoverPool.sol:L49-66` (BoundPolicy)
**Description**: The EIP-712 `Quote` typehash includes a `basePremium` field, and `_hashQuote` incorporates it into the policyCommit. However, `basePremium` is never stored in `BoundPolicy` or in `PolicyManager.PolicyMetadata`. After binding, there is no on-chain record of what premium amount was agreed upon in the signed quote. The field exists solely as a signature commitment that prevents post-hoc alteration of the agreed premium, but it has zero enforceability once the policyCommit is recorded.

The `_recordBoundPolicy` creates a `BoundPolicy` with fields `{policyId, policyCommit, specId, termsHash, coverageLimit, beneficiary, startTime, maturityTime}`. The `basePremium` field from the quote is silently dropped. `PolicyManager.PolicyMetadata` mirrors the same omission.

**Impact**:
- No direct funds-at-risk: the curator cannot forge a different basePremium because the ECDSA signature would not verify. The QUOTE_SIGNER_ROLE holder controls what basePremium is committed to.
- Off-chain reliance: Any system querying on-chain state to verify the agreed premium (e.g., premium accrual reconciliation, dispute resolution) cannot do so from chain state alone — it must reprocess the original signed quote bytes or event logs.
- Future code paths: Any contract upgrade that introduces `basePremium`-dependent logic (e.g., on-chain premium schedule enforcement) would have no source of truth in storage.

**Evidence**:

```solidity
// CoverPool.sol — typehash includes basePremium
bytes32 private constant _QUOTE_TYPEHASH = keccak256(
    "Quote(address pool,uint96 policyId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 startTime,uint32 maturityTime,uint32 expirationTime)"
);

// CoverPool.sol — _hashQuote includes basePremium (v4 in position)
function _hashQuote(Quote calldata quote) private pure returns (bytes32) {
    return EfficientHashLib.hash(
        uint256(_QUOTE_TYPEHASH),
        uint256(uint160(quote.pool)),
        uint256(quote.policyId),
        quote.coverageLimit,
        quote.basePremium,        // ← hashed but never stored
        uint256(quote.specId),
        uint256(quote.termsHash),
        uint256(uint160(quote.beneficiary)),
        uint256(quote.startTime),
        uint256(quote.maturityTime),
        uint256(quote.expirationTime)
    );
}

// ICoverPool.sol — BoundPolicy does NOT include basePremium
struct BoundPolicy {
    uint96 policyId;
    bytes32 policyCommit;
    bytes32 specId;
    bytes32 termsHash;
    uint256 coverageLimit;
    address beneficiary;
    uint32 startTime;
    uint32 maturityTime;
    // basePremium absent
}
```

---

## Finding [SIG-2]: Quote Signer Role Revocation Does Not Invalidate Prior Signature — Intended Design, No Exploit Path

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✓, R8:✗(single-step), R10:✓, R12:✗(no dangerous precondition)]
**Depth Evidence**: [TRACE: revoke QUOTE_SIGNER_ROLE → existing signed quotes with expirationTime in future are still usable IF curator calls bindPolicyForRequest before expiration → however curator is onlyRole(DEFAULT_ADMIN_ROLE) so curator must deliberately choose to submit the stale signer's quote]
**Severity**: Informational
**Location**: `CoverPool.sol:L321` (_verifyQuote — hasRole check at bind time), `CoverPool.sol:L164` (onlyRole(DEFAULT_ADMIN_ROLE))
**Description**: When a QUOTE_SIGNER_ROLE holder is revoked, any signed quotes they issued that have not yet expired (`expirationTime > block.timestamp`) remain cryptographically valid as signatures. The `_verifyQuote` function checks `hasRole(QUOTE_SIGNER_ROLE, signer)` at bind time, so a revoked signer's quotes are correctly rejected. This is sound.

However, the concern would be: can a malicious curator delay revoking a compromised signer, use their signature, then revoke? The answer is yes — but the curator is the one calling `bindPolicyForRequest` (gated by `onlyRole(DEFAULT_ADMIN_ROLE)`). The curator is SEMI_TRUSTED per the project's trust table (bounds: pool-scoped operations). This is within the curator's declared authority.

**Evidence**:

```solidity
function _verifyQuote(Quote calldata quote, bytes calldata signature)
    private view validateQuote(quote) whenNotPaused returns (bytes32 policyCommit)
{
    policyCommit = _hashQuote(quote);
    bytes32 digest = _hashTypedDataV4(policyCommit);
    address signer = ECDSA.recover(digest, signature);
    require(hasRole(QUOTE_SIGNER_ROLE, signer), InvalidQuoteSignature()); // ← live role check
}
```

---

## Finding [SIG-3]: EIP-712 Domain Separator Correctly Constructed — Positive Confirmation

**Verdict**: CONFIRMED (positive)
**Step Execution**: ✓1,2,3
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single state)]
**Severity**: Informational
**Location**: `CoverPool.sol:L94` (__EIP712_init), `lib/openzeppelin-contracts-upgradeable/contracts/utils/cryptography/EIP712Upgradeable.sol:L88-90`
**Description**: The domain separator is correctly constructed by OZ's `EIP712Upgradeable._buildDomainSeparator()`:

```solidity
keccak256(abi.encode(TYPE_HASH, _EIP712NameHash(), _EIP712VersionHash(), block.chainid, address(this)))
```

Where `TYPE_HASH = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")`.

Key properties verified:
1. `chainId` uses `block.chainid` (live, not cached) — protects against cross-chain replay after forks.
2. `verifyingContract` = `address(this)` = the specific CoverPool clone address — protects against cross-pool replay.
3. The upgradeable variant does NOT cache the domain separator in immutable storage — it recomputes each call, which is correct for proxy deployments where `address(this)` is meaningful.
4. `__EIP712_init("Catalysis Cover Pool", "1")` is called in the initializer, so `_hashedName = 0` and `_hashedVersion = 0` (reset in `__EIP712_init_unchained`), meaning `_EIP712NameHash()` returns `keccak256("Catalysis Cover Pool")` via the string-path branch (non-empty string).

Test at `test/unit/CoverPool.t.sol:L758-769` independently verifies the domain separator composition.

---

## Finding [SIG-4]: ECDSA Signature Malleability — Not Vulnerable

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single state)]
**Severity**: Informational
**Location**: `CoverPool.sol:L320` (ECDSA.recover call), `lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol:L185-186`
**Description**: OpenZeppelin ECDSA v5.5.0 `tryRecover()` rejects high-s values (s > secp256k1n/2) per EIP-2, returning `RecoverError.InvalidSignatureS`. The `ECDSA.recover()` wrapper reverts on this condition. Malleable signatures cannot produce a valid alternative signature that passes verification for the same message, because the high-s variant would be rejected before `ecrecover` is invoked.

Additionally, since quotes are single-use (tracked by `boundPolicyCommits[policyCommit]`), even if malleability were possible, a second use of the same quote data would revert with `PolicyAlreadyBound`. There is no scenario where a malleable signature could produce exploitable behavior.

---

## Finding [SIG-5]: Cross-Pool Replay of Signed Quotes — Doubly Protected

**Verdict**: REFUTED
**Step Execution**: ✓1,2,3,4
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✗(single-step), R10:✗(single state)]
**Severity**: Informational
**Location**: `CoverPool.sol:L52`, `CoverPool.sol:L318`
**Description**: A signed quote for Pool A cannot be replayed on Pool B due to two independent protections:

1. **Domain separator**: `verifyingContract = address(poolA)` differs from `address(poolB)`. The EIP-712 digest computed on Pool B will differ from that on Pool A for the same struct hash. ECDSA recovery would return a different address (or an invalid address), causing `hasRole(QUOTE_SIGNER_ROLE, recovered)` to fail on Pool B.

2. **Struct-level protection**: `quote.pool` is included in `_hashQuote` (first field after typehash). The `validateQuote` modifier enforces `require(quote.pool == address(this))`. Even if an attacker submitted the Pool A quote struct to Pool B unchanged, this check would revert with `PoolAddressMismatch`.

Both protections must be overcome simultaneously — which is cryptographically infeasible.

---

## Finding [SIG-6]: Nonce-Free Quote System — Replay Protection Analysis

**Verdict**: CONFIRMED (design review — adequate, with noted limitation)
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R13:✓]
**Depth Evidence**: [TRACE: same quote → _hashQuote → policyCommit → boundPolicyCommits[policyCommit] = true → second use reverts PolicyAlreadyBound], [VARIATION: quote with different expirationTime → different policyCommit → not blocked by replay guard → attacker could use second valid signature if signer signed two quotes for same policyId with different expiry]
**Severity**: Informational
**Location**: `CoverPool.sol:L283-285` (_recordBoundPolicy replay guard), `PolicyManager.sol:L278` (_registeredPolicyCommits)
**Description**: Quote replay protection relies on `boundPolicyCommits[policyCommit]` (CoverPool) and `_registeredPolicyCommits[policyCommit]` (PolicyManager), both keyed on the struct hash of the quote. This is adequate for the single-binding model.

**Design limitation identified**: If a QUOTE_SIGNER_ROLE holder signs two quotes for the same `policyId` but with different `expirationTime` values (or any other field), both would produce distinct policyCommits. If the first is successfully bound, the second is blocked only because the policy draft's status advances to `Bound` (PolicyManager.bindPolicy checks `draft.status == PolicyStatus.Created`). The second signature's policyCommit is not in `boundPolicyCommits`, but the draft status check prevents a second binding.

This multi-layer defense is adequate. The absence of nonces is not a vulnerability given:
- `policyId` is unique and single-use (draft → bound is a one-way transition)
- `expirationTime` bounds the validity window
- `quote.pool` and domain separator prevent cross-pool use
- Curator must actively call `bindPolicyForRequest`

**Note**: The OZ ECDSA v5 documentation notes "Developers SHOULD NOT use signatures as unique identifiers; use hash invalidation or nonces for replay protection." The protocol correctly follows this by using `policyCommit` hash invalidation rather than treating the signature as unique.

---

## Finding [SIG-7]: buyer Identity Excluded from Signed Quote — Reliance on Draft Binding

**Verdict**: CONFIRMED (design review — adequate)
**Step Execution**: ✓1,2,3,4,5
**Rules Applied**: [R4:✗(clear), R5:✗(single entity), R6:✗(no role), R8:✓, R10:✓, R13:✓]
**Depth Evidence**: [TRACE: Quote struct fields → does not include buyer → PolicyManager.bindPolicy checks draft.buyer == request.buyer → draft was created by buyer themselves in requestCoverage → buyer identity protected by draft, not signature]
**Severity**: Informational
**Location**: `interfaces/ICoverPool.sol:L22-43` (Quote struct), `PolicyManager.sol:L244-247` (buyer match check)
**Description**: The EIP-712 `Quote` typehash does not include the `buyer` address. The buyer's identity is protected by the `PolicyDraft` storage record (created when buyer called `requestCoverage`) rather than by the signature.

**Protection analysis**:
- `PolicyManager.requestCoverage` creates `_policyDrafts[policyId]` with `buyer = msg.sender`.
- `PolicyManager.bindPolicy` checks `request.buyer == draft.buyer` (L244).
- `CoverPool.bindPolicyForRequest` sets `buyer: draft.buyer` in the `BindPolicyRequest` (L189).
- The curator cannot substitute a different buyer because they must pass `draft.buyer` from storage.

The signed quote covers `policyId` which is 1:1 with a draft. Since the draft was created by the buyer, and the `policyId` is unique, the buyer is transitively covered by the signature through the policyId binding. No exploit path exists.

**Design note**: Adding `buyer` to the typehash would provide defense-in-depth but is not required given the draft-binding model.

---

## Chain Summary

| Finding ID | Title | Severity | Verdict | Postconditions Created | Preconditions Blocked |
|-----------|-------|----------|---------|----------------------|----------------------|
| SIG-1 | basePremium signed but not persisted post-binding | Informational | CONFIRMED | None (no funds at risk) | N/A |
| SIG-2 | Role revocation does not invalidate prior signatures | Informational | REFUTED | None | Live role check at bind time |
| SIG-3 | EIP-712 domain separator correct (positive) | Informational | CONFIRMED (positive) | N/A | N/A |
| SIG-4 | ECDSA malleability | Informational | REFUTED | None | OZ high-s rejection |
| SIG-5 | Cross-pool quote replay | Informational | REFUTED | None | Domain separator + pool field |
| SIG-6 | Nonce-free system — replay analysis | Informational | CONFIRMED (design adequate) | None | policyCommit invalidation + draft status |
| SIG-7 | buyer excluded from signed quote | Informational | CONFIRMED (design adequate) | None | Draft storage binding |

**Summary**: No critical, high, medium, or low signature security vulnerabilities found. The EIP-712 implementation is correctly constructed using OpenZeppelin's EIP712Upgradeable with live `block.chainid` (no caching), per-clone `verifyingContract`, and OZ ECDSA v5 with high-s rejection. Replay protection via policyCommit hash invalidation is adequate for the single-binding model. One informational finding (SIG-1) identifies that `basePremium` is a signed commitment with no on-chain persistence after binding, which may affect off-chain auditability and future upgrade paths.
