// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/**
 * @title StorageLayoutTest
 * @notice Regression test that pins the storage layout of every upgradeable proxy currently
 *         deployed on Ethereum mainnet (see docs/deployment/Ethereum-Mainnet.md).
 * @dev Forge writes each contract's storage layout to `out/<Contract>.sol/<Contract>.json` because
 *      `extra_output = ["storageLayout"]` is set in foundry.toml. This test reads that JSON for
 *      each deployed UUPS proxy and asserts (label, slot, offset, type) for every storage entry
 *      against a pinned baseline captured from the deployed implementation source.
 *
 *      The test FAILS if any future PR inserts, removes, reorders, or retypes a state variable
 *      in a contract that already has a live proxy. Backward-compatible additions must extend
 *      the contract by appending new variables AND must update the corresponding baseline in
 *      this file in the same commit.
 *
 *      Compiler-generated AST node IDs that appear inside parenthesised type identifiers
 *      (e.g. `t_struct(PolicyDraft)12345_storage`) are stripped before comparison, so unrelated
 *      changes elsewhere in the codebase that shift AST IDs do not produce spurious failures.
 *
 *      The OpenZeppelin v5 upgradeable bases used by these contracts (AccessControlUpgradeable,
 *      PausableUpgradeable, UUPSUpgradeable, etc.) use ERC-7201 namespaced storage, so they do
 *      not occupy slots 0+. The slots pinned below therefore correspond exactly to each child
 *      contract's own declared state variables.
 *
 *      CoverPool is intentionally not pinned: it is deployed as EIP-1167 minimal-proxy clones
 *      via CoverPoolFactory.createCoverPool, and existing clones cannot be upgraded in place.
 *      UniswapV3Adapter is non-upgradeable and is also out of scope.
 */
contract StorageLayoutTest is Test {
    /// @dev Single storage entry as decoded from the Foundry storageLayout JSON.
    /// @dev Field names are chosen so Foundry's JSON struct decoder maps them to the
    ///      JSON keys (`astId`, `contract`, `label`, `offset`, `slot`, `type`).
    struct RawSlot {
        uint256 astId;
        string _contract;
        string label;
        uint256 offset;
        string slot;
        string _type;
    }

    /// @dev Pinned baseline entry. `slot` and `offset` are decoded from strings; `_type` is
    ///      compared after AST IDs are stripped (see `_stripAstIds`).
    struct ExpectedSlot {
        string label;
        uint256 slot;
        uint256 offset;
        string typeName;
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PolicyManager_storageLayoutPinned() public view {
        ExpectedSlot[] memory expected = new ExpectedSlot[](9);
        expected[0] = ExpectedSlot("stakeManager", 0, 0, "t_address");
        expected[1] = ExpectedSlot("claimManager", 1, 0, "t_address");
        expected[2] = ExpectedSlot("coverPoolFactory", 2, 0, "t_address");
        expected[3] = ExpectedSlot("_nextPolicyId", 2, 20, "t_uint96");
        expected[4] = ExpectedSlot("_policyDrafts", 3, 0, "t_mapping(t_uint96,t_struct(PolicyDraft)_storage)");
        expected[5] = ExpectedSlot("_policies", 4, 0, "t_mapping(t_uint96,t_struct(PolicyMetadata)_storage)");
        expected[6] = ExpectedSlot("_registeredPolicyCommits", 5, 0, "t_mapping(t_bytes32,t_bool)");
        expected[7] = ExpectedSlot("supportedPayoutTokens", 6, 0, "t_mapping(t_address,t_bool)");
        expected[8] = ExpectedSlot("chainlinkPriceFeed", 7, 0, "t_address");
        _assertLayout("PolicyManager", expected);
    }

    function test_ClaimManager_storageLayoutPinned() public view {
        ExpectedSlot[] memory expected = new ExpectedSlot[](10);
        expected[0] = ExpectedSlot("specRegistry", 0, 0, "t_address");
        expected[1] = ExpectedSlot("slashingManager", 1, 0, "t_address");
        expected[2] = ExpectedSlot("swapper", 2, 0, "t_address");
        expected[3] = ExpectedSlot("policyManager", 3, 0, "t_address");
        expected[4] = ExpectedSlot("premiumManager", 4, 0, "t_address");
        expected[5] = ExpectedSlot("maxSwapSlippageBps", 4, 20, "t_uint16");
        expected[6] =
            ExpectedSlot("_claims", 5, 0, "t_mapping(t_uint96,t_mapping(t_uint256,t_struct(ClaimRecord)_storage))");
        expected[7] = ExpectedSlot("_policyClaims", 6, 0, "t_mapping(t_uint96,t_struct(PolicyClaim)_storage)");
        expected[8] = ExpectedSlot("_claimApprovalRequired", 7, 0, "t_mapping(t_uint96,t_bool)");
        expected[9] = ExpectedSlot("_usedEvidenceHashes", 8, 0, "t_mapping(t_uint96,t_mapping(t_bytes32,t_bool))");
        _assertLayout("ClaimManager", expected);
    }

    function test_PremiumManager_storageLayoutPinned() public view {
        ExpectedSlot[] memory expected = new ExpectedSlot[](5);
        expected[0] = ExpectedSlot("rewardsManager", 0, 0, "t_address");
        expected[1] = ExpectedSlot("platformTreasury", 1, 0, "t_address");
        expected[2] = ExpectedSlot("platformFeeBps", 1, 20, "t_uint16");
        expected[3] = ExpectedSlot("_approvedPremiumTokens", 2, 0, "t_struct(AddressSet)_storage");
        expected[4] = ExpectedSlot("_distributionNonce", 4, 0, "t_uint256");
        _assertLayout("PremiumManager", expected);
    }

    function test_SpecRegistry_storageLayoutPinned() public view {
        ExpectedSlot[] memory expected = new ExpectedSlot[](3);
        expected[0] = ExpectedSlot("coverPoolFactory", 0, 0, "t_contract(ICoverPoolFactory)");
        expected[1] = ExpectedSlot("_specs", 1, 0, "t_mapping(t_address,t_mapping(t_bytes32,t_contract(ISpec)))");
        expected[2] = ExpectedSlot("_approvedSpecs", 2, 0, "t_mapping(t_address,t_bool)");
        _assertLayout("SpecRegistry", expected);
    }

    function test_Swapper_storageLayoutPinned() public view {
        ExpectedSlot[] memory expected = new ExpectedSlot[](3);
        expected[0] = ExpectedSlot("nativeWrapper", 0, 0, "t_address");
        expected[1] = ExpectedSlot("whitelistedTargets", 1, 0, "t_mapping(t_address,t_bool)");
        expected[2] = ExpectedSlot("_swapRoutes", 2, 0, "t_mapping(t_bytes32,t_struct(SwapRoute)_storage)");
        _assertLayout("Swapper", expected);
    }

    function test_CoverPoolFactory_storageLayoutPinned() public view {
        ExpectedSlot[] memory expected = new ExpectedSlot[](5);
        expected[0] = ExpectedSlot("coverPoolImplementation", 0, 0, "t_address");
        expected[1] = ExpectedSlot("policyManager", 1, 0, "t_address");
        expected[2] = ExpectedSlot("stakeManager", 2, 0, "t_address");
        expected[3] = ExpectedSlot("specRegistry", 3, 0, "t_address");
        expected[4] = ExpectedSlot("_pools", 4, 0, "t_struct(AddressSet)_storage");
        _assertLayout("CoverPoolFactory", expected);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reads `out/<contractName>.sol/<contractName>.json` and asserts every storage
     *         entry matches the pinned baseline.
     * @dev Fails on any of: count mismatch, label mismatch, slot mismatch, offset mismatch,
     *      or type mismatch (after AST-ID stripping).
     */
    function _assertLayout(string memory contractName, ExpectedSlot[] memory expected) private view {
        string memory artifactPath = string.concat("out/", contractName, ".sol/", contractName, ".json");
        string memory json = vm.readFile(artifactPath);

        bytes memory raw = vm.parseJson(json, ".storageLayout.storage");
        RawSlot[] memory actual = abi.decode(raw, (RawSlot[]));

        assertEq(
            actual.length,
            expected.length,
            string.concat(
                contractName,
                ": storage entry count drifted from baseline. Update test/unit/StorageLayout.t.sol",
                " ONLY after confirming the change is upgrade-safe (variables appended at the end)."
            )
        );

        for (uint256 i = 0; i < expected.length; ++i) {
            string memory ctx = string.concat(contractName, "[", vm.toString(i), "]:", expected[i].label);

            assertEq(actual[i].label, expected[i].label, string.concat(ctx, " label"));
            assertEq(vm.parseUint(actual[i].slot), expected[i].slot, string.concat(ctx, " slot"));
            assertEq(actual[i].offset, expected[i].offset, string.concat(ctx, " offset"));
            assertEq(_stripAstIds(actual[i]._type), expected[i].typeName, string.concat(ctx, " type"));
        }
    }

    /**
     * @notice Strips compiler-generated AST node IDs from a Solidity storage type identifier.
     * @dev Foundry/solc embed an AST node ID immediately after the closing paren of struct,
     *      contract, and enum type names (e.g. `t_struct(PolicyDraft)12345_storage`,
     *      `t_contract(ISpec)6789`). The numeric ID is build-dependent and shifts when unrelated
     *      contracts are added or reordered, even when the actual storage layout is unchanged.
     *      Pinning the canonical name without the ID makes the regression test resilient to
     *      cosmetic AST drift while still catching real layout changes.
     *
     *      Digits after `)` are only stripped when the corresponding `(` was preceded by a
     *      named-type keyword — "struct", "contract", "enum", or "userDefinedValueType" —
     *      which are the only contexts where solc emits an AST ID. For `t_array(type)N_storage`
     *      the `N` encodes the array length and must be preserved so that a `uint256[32]` →
     *      `uint256[64]` change is visible. A per-paren-depth boolean stack records the decision
     *      made at each `(`.
     * @param s Original type identifier as emitted by solc.
     * @return Normalised identifier with named-type `(...)<digits>` collapsed to `(...)`.
     */
    function _stripAstIds(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory buf = new bytes(b.length);
        uint256 outLen = 0;

        bool[] memory stripAfterClose = new bool[](32);
        uint256 depth = 0;
        bool skipDigits = false;

        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (skipDigits) {
                if (c >= 0x30 && c <= 0x39) continue;
                skipDigits = false;
            }
            if (c == 0x28) {
                stripAfterClose[depth] = _bufEndsWithNamedType(buf, outLen);
                depth++;
                buf[outLen++] = c;
            } else if (c == 0x29) {
                buf[outLen++] = c;
                if (depth > 0) {
                    depth--;
                    skipDigits = stripAfterClose[depth];
                }
            } else {
                buf[outLen++] = c;
            }
        }

        bytes memory trimmed = new bytes(outLen);
        for (uint256 i = 0; i < outLen; ++i) {
            trimmed[i] = buf[i];
        }
        return string(trimmed);
    }

    /**
     * @dev Returns true when `buf[0..len-1]` ends with a solc named-type keyword whose closing
     *      `)` is followed by an AST node ID: "struct", "contract", "enum", or
     *      "userDefinedValueType" (the last covers `type Foo is uint128` style declarations,
     *      added in Solidity 0.8.8).
     */
    function _bufEndsWithNamedType(bytes memory buf, uint256 len) private pure returns (bool) {
        return _bufEndsWith(buf, len, "struct") || _bufEndsWith(buf, len, "contract") || _bufEndsWith(buf, len, "enum")
            || _bufEndsWith(buf, len, "userDefinedValueType");
    }

    /// @dev Returns true when `buf[0..len-1]` ends with the bytes of `suffix`.
    function _bufEndsWith(bytes memory buf, uint256 len, string memory suffix) private pure returns (bool) {
        bytes memory s = bytes(suffix);
        if (len < s.length) return false;
        for (uint256 i = 0; i < s.length; ++i) {
            if (buf[len - s.length + i] != s[i]) return false;
        }
        return true;
    }
}
