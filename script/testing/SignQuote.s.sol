// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";

/**
 * @title SignQuote
 * @notice Generates an EIP-712 quote signature for use in BindPolicy when the quote signer
 *         is a separate account from the deployer/curator.
 *
 * @dev Run this script with the QUOTE SIGNER's keystore BEFORE running BindPolicy.s.sol.
 *      The printed QUOTE_SIGNATURE value should be added to coverage/.env.
 *      BindPolicy will then read it from env instead of signing inline.
 *
 *      This script makes no on-chain transactions — omit --broadcast.
 *
 * Usage:
 *   forge script script/testing/SignQuote.s.sol:SignQuote \
 *     --rpc-url $RPC_URL \
 *     --keystore $QUOTE_SIGNER_KEYSTORE \
 *     --sender $QUOTE_SIGNER_ADDRESS \
 *     -vvvv
 *
 *   Then add to coverage/.env:
 *     QUOTE_SIGNATURE=<printed value>
 *
 *   Then run BindPolicy.s.sol with the deployer keystore.
 *
 * Required Environment Variables (shared with BindPolicy):
 *   - QUOTE_SIGNER_ADDRESS: Address of the quote signer (must match --sender / loaded keystore)
 *   - COVER_POOL:           CoverPool address
 *   - POLICY_MANAGER:       PolicyManager proxy address
 *   - POLICY_ID:            Policy ID (from RequestCoverage output)
 *   - COVERAGE_LIMIT:       Max coverage payout in payout token raw units
 *   - SPEC_ID:              Spec identifier (bytes32 hex)
 *   - TERMS_HASH:           Policy terms hash (bytes32 hex)
 *   - EXPIRATION_TIME:      Quote expiration unix timestamp (must be in the future when BindPolicy runs)
 *                           macOS: $(date -v +1H +%s)   Linux: $(date -d '+1 hour' +%s)
 */
contract SignQuote is Script {
    bytes32 private constant _QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 expirationTime)"
    );

    function run() external view {
        address quoteSigner = vm.envAddress("QUOTE_SIGNER_ADDRESS");
        address coverPool = vm.envAddress("COVER_POOL");
        address policyManagerAddr = vm.envAddress("POLICY_MANAGER");
        uint96 policyId = uint96(vm.envUint("POLICY_ID"));
        uint256 coverageLimit = vm.envUint("COVERAGE_LIMIT");
        bytes32 specId = vm.envBytes32("SPEC_ID");
        bytes32 termsHash = vm.envBytes32("TERMS_HASH");
        uint32 expirationTime = uint32(vm.envUint("EXPIRATION_TIME"));

        // Fetch beneficiary from the on-chain policy draft — must match what BindPolicy will use.
        IPolicyManager.PolicyDraft memory draft = IPolicyManager(policyManagerAddr).getPolicyDraft(policyId);
        address beneficiary = draft.beneficiary;

        console.log("=== QUOTE SIGNING ===");
        console.log("Quote signer:    ", quoteSigner);
        console.log("CoverPool:       ", coverPool);
        console.log("Policy ID:       ", policyId);
        console.log("Beneficiary:     ", beneficiary);
        console.log("Coverage limit:  ", coverageLimit);
        console.log("Spec ID:         ", vm.toString(specId));
        console.log("Terms hash:      ", vm.toString(termsHash));
        console.log("Expiration time: ", expirationTime);

        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: coverPool,
            policyId: policyId,
            coverageLimit: coverageLimit,
            specId: specId,
            termsHash: termsHash,
            beneficiary: beneficiary,
            expirationTime: expirationTime
        });

        bytes32 domainSeparator = ICoverPool(coverPool).quoteDomainSeparator();

        bytes32 structHash = keccak256(
            abi.encode(
                _QUOTE_TYPEHASH,
                quote.pool,
                quote.policyId,
                quote.coverageLimit,
                quote.specId,
                quote.termsHash,
                quote.beneficiary,
                quote.expirationTime
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSigner, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        console.log("\n=== OUTPUT ===");
        console.log("Add to coverage/.env:");
        console.log(string.concat("QUOTE_SIGNATURE=", vm.toString(signature)));
        console.log("\nThen run BindPolicy.s.sol with --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS");
    }
}
