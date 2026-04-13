// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
import {ISpecRegistry} from "../../src/interfaces/ISpecRegistry.sol";
import {IStakeManager} from "../../src/interfaces/IStakeManager.sol";

/**
 * @title BindPolicy
 * @notice Binds a policy draft by the curator, signing a quote and associating vaults.
 * @dev Corresponds to Document Flow 5 – Policy Binding:
 *      5a. Once vaults on EigenLayer get enough delegation, CoverPool curator binds the policy
 *          to the specific delegated vaults.
 *      5b. This triggers locking of Duration Vaults and policy activation.
 *      5c. PolicyManager notifies CoveredVault's adapter to increaseAbsoluteCap.
 *
 *      Prerequisites: Flows 1-4 must be completed:
 *      - CoverPool created (Flow 1)
 *      - Coverage requested and committee created (Flows 2-3)
 *      - Restakers delegated to Duration Vaults (Flow 4)
 *
 * Usage:
 *   Testnet (curator == deployer, same keystore):
 *     forge script script/testing/BindPolicy.s.sol:BindPolicy \
 *       --rpc-url $RPC_URL --broadcast --slow -vvvv \
 *       --keystore $KEYSTORE --sender $DEPLOYER_ADDRESS
 *
 *   Mainnet (curator is a multisig — no keystore or broadcast needed):
 *     forge script script/testing/BindPolicy.s.sol:BindPolicy \
 *       --rpc-url $RPC_URL --slow -vvvv
 *     (no --broadcast, no --keystore; copy the printed calldata and submit via Safe UI)
 *
 * Quote signing — two flows depending on whether the deployer and quote signer are the same account:
 *
 *   Same account (DEPLOYER_ADDRESS == QUOTE_SIGNER_ADDRESS):
 *     The script signs the quote inline using the loaded deployer keystore. No additional setup.
 *
 *   Separate accounts (DEPLOYER_ADDRESS != QUOTE_SIGNER_ADDRESS):
 *     1. Run SignQuote.s.sol with the quote signer's keystore first:
 *          forge script script/testing/SignQuote.s.sol \
 *            --rpc-url $RPC_URL \
 *            --keystore $QUOTE_SIGNER_KEYSTORE --sender $QUOTE_SIGNER_ADDRESS -vvvv
 *     2. Copy the printed QUOTE_SIGNATURE value into coverage/.env.
 *     3. Run this script with the deployer keystore — it reads QUOTE_SIGNATURE from env.
 *
 * Required Environment Variables:
 *   - DEPLOYER_ADDRESS:     Public address of the keystore signer (used with --keystore flag).
 *   - QUOTE_SIGNER_ADDRESS: Address that holds QUOTE_SIGNER_ROLE on the CoverPool.
 *                           If equal to DEPLOYER_ADDRESS, signing happens inline.
 *                           If different, set QUOTE_SIGNATURE in env (run SignQuote.s.sol first).
 *
 * Optional Environment Variables:
 *   - CURATOR_ADDRESS:   CoverPool owner identity. Defaults to DEPLOYER_ADDRESS.
 *   - QUOTE_SIGNATURE:   Pre-generated 65-byte hex signature from SignQuote.s.sol.
 *                        Required when DEPLOYER_ADDRESS != QUOTE_SIGNER_ADDRESS.
 *
 * Required Environment Variables:
 *   - COVER_POOL: CoverPool address
 *   - POLICY_MANAGER: PolicyManager proxy address
 *   - STAKE_MANAGER: StakeManager proxy address from core
 *   - POLICY_ID: Policy ID (from RequestCoverage output)
 *   - SPEC_REGISTRY: SpecRegistry proxy address (optional but recommended; enables pre-flight
 *       approval check — if omitted, an unapproved spec only fails at the contract level)
 *   - SPEC_ADDRESS: ISpec implementation contract for this policy
 *   - VAULTS: Comma-separated vault addresses to bind (e.g. "0x123...,0x456...")
 *   - COVERAGE_LIMIT: Coverage limit in payout token units
 *   - SPEC_ID: Spec identifier (bytes32 hex)
 *   - TERMS_HASH: Policy terms hash (bytes32 hex)
 *   - EXPIRATION_TIME: Quote expiration timestamp
 *
 * Prerequisites:
 *   - Curator must hold DEFAULT_ADMIN_ROLE on the CoverPool (set at initialization via curator_ arg)
 *   - Quote signer must have QUOTE_SIGNER_ROLE on the CoverPool
 *   - Policy draft must exist in PolicyManager (status = Created)
 *   - Sufficient stake must exist in the committee's duration vault (restaker deposits via
 *     StrategyManager.depositIntoStrategy(durationVault, token, amount) independently)
 *   - SPEC_ADDRESS must be approved in SpecRegistry via approveSpec() before this script is run;
 *     binding will revert on-chain with SpecNotApproved otherwise
 */
contract BindPolicy is Script {
    bytes32 private constant _QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 expirationTime)"
    );

    /// @notice Address of the keystore signer that broadcasts the transaction.
    address public deployer;

    /// @notice Curator address (CoverPool admin/owner).
    address public curator;

    /// @notice Quote signer address (must hold QUOTE_SIGNER_ROLE on the CoverPool).
    address public quoteSigner;

    /// @notice CoverPool address
    address public coverPool;

    /// @notice PolicyManager proxy address
    address public policyManager;

    /// @notice StakeManager proxy address
    address public stakeManager;

    /// @notice Policy ID to bind
    uint96 public policyId;

    /// @notice SpecRegistry proxy address (optional; enables pre-flight approval check)
    address public specRegistry;

    /// @notice ISpec implementation address
    address public specAddress;

    /// @notice Vaults to bind to the committee
    address[] public vaults;

    /// @notice Quote parameters
    uint256 public coverageLimit;
    bytes32 public specId;
    bytes32 public termsHash;
    uint32 public expirationTime;

    /// @notice Contract instances
    ICoverPool public poolContract;
    IPolicyManager public policyManagerContract;
    IStakeManager public stakeManagerContract;

    /// @notice Emitted when policy is bound
    event PolicyBound(uint96 indexed policyId, address indexed pool, uint256 coverageLimit, uint256 vaultCount);

    constructor() {
        deployer = vm.envAddress("DEPLOYER_ADDRESS");
        // Pool owner: defaults to deployer so existing testnet flows need no change,
        // but on mainnet set CURATOR_ADDRESS to a multisig so the hot signer never
        // owns the pool.
        curator = vm.envOr("CURATOR_ADDRESS", deployer);
        quoteSigner = vm.envAddress("QUOTE_SIGNER_ADDRESS");

        coverPool = vm.envAddress("COVER_POOL");
        policyManager = vm.envAddress("POLICY_MANAGER");
        stakeManager = vm.envAddress("STAKE_MANAGER");
        specRegistry = vm.envOr("SPEC_REGISTRY", address(0));
        policyId = uint96(vm.envUint("POLICY_ID"));
        specAddress = vm.envAddress("SPEC_ADDRESS");

        // Parse vault addresses
        string memory vaultsStr = vm.envString("VAULTS");
        string[] memory vaultAddresses = vm.split(vaultsStr, ",");
        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            vaults.push(vm.parseAddress(vaultAddresses[i]));
        }

        coverageLimit = vm.envUint("COVERAGE_LIMIT");
        specId = vm.envBytes32("SPEC_ID");
        termsHash = vm.envBytes32("TERMS_HASH");
        expirationTime = uint32(vm.envUint("EXPIRATION_TIME"));

        poolContract = ICoverPool(coverPool);
        policyManagerContract = IPolicyManager(policyManager);
        stakeManagerContract = IStakeManager(stakeManager);
    }

    function run() external {
        console.log("=== FLOW 5: POLICY BINDING ===");
        console.log("Deployer (keystore signer):", deployer);
        console.log("Broadcaster (curator / DEFAULT_ADMIN_ROLE):", curator);
        console.log("CoverPool:", coverPool);
        console.log("Policy ID:", policyId);
        console.log("Coverage Limit:", coverageLimit);
        console.log("Number of Vaults:", vaults.length);

        _verifyPrerequisites();

        IPolicyManager.PolicyDraft memory draft = policyManagerContract.getPolicyDraft(policyId);

        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: coverPool,
            policyId: policyId,
            coverageLimit: coverageLimit,
            specId: specId,
            termsHash: termsHash,
            beneficiary: draft.beneficiary,
            expirationTime: expirationTime
        });

        bytes memory signature = _signQuote(quote);
        console.log("Quote signature ready");

        // bindPolicyForRequest requires DEFAULT_ADMIN_ROLE, which is held by curator.
        // On testnet where curator == deployer, the loaded keystore signs for curator.
        // On mainnet with a multisig curator, omit --broadcast and submit via Safe instead.
        vm.startBroadcast(curator);

        poolContract.bindPolicyForRequest(policyId, quote, specAddress, vaults, signature);

        vm.stopBroadcast();

        IPolicyManager.PolicyMetadata memory metadata = _verifyBinding();

        console.log("\n=== POLICY BINDING COMPLETED ===");
        console.log("Policy is now active. On-chain coverage window:", metadata.startTime, "-", metadata.maturityTime);
        emit PolicyBound(policyId, coverPool, coverageLimit, vaults.length);
    }

    function _verifyPrerequisites() internal view {
        console.log("\n--- Prerequisites Check ---");

        address owner = poolContract.owner();
        console.log("Pool owner:", owner);
        require(owner == curator, "Curator is not pool owner");

        IPolicyManager.PolicyDraft memory draft = policyManagerContract.getPolicyDraft(policyId);
        console.log("Draft status:", uint8(draft.status));
        require(draft.status == IPolicyManager.PolicyStatus.Created, "Draft is not in Created status");

        require(draft.pool == coverPool, "Draft pool mismatch");
        console.log("Draft pool matches CoverPool");

        if (specRegistry != address(0)) {
            bool approved = ISpecRegistry(specRegistry).isSpecApproved(specAddress);
            console.log("Spec approved in SpecRegistry:", approved);
            require(approved, "SPEC_ADDRESS is not approved in SpecRegistry -- call approveSpec() first");
        } else {
            console.log("[WARN] SPEC_REGISTRY not set -- skipping spec approval pre-flight check");
        }

        console.log("[OK] Prerequisites verified");
    }

    function _signQuote(ICoverPool.Quote memory quote) internal view returns (bytes memory) {
        bytes32 domainSeparator = poolContract.quoteDomainSeparator();

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

        if (deployer == quoteSigner) {
            // Same account: sign inline using the loaded deployer keystore.
            console.log("Quote signer == deployer: signing inline");
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSigner, digest);
            return abi.encodePacked(r, s, v);
        } else {
            // Separate accounts: read pre-generated signature produced by SignQuote.s.sol.
            console.log("Quote signer != deployer: reading QUOTE_SIGNATURE from env");
            bytes memory sig = vm.envBytes("QUOTE_SIGNATURE");
            require(sig.length == 65, "QUOTE_SIGNATURE must be 65 bytes, run SignQuote.s.sol first");
            return sig;
        }
    }

    function _verifyBinding() internal view returns (IPolicyManager.PolicyMetadata memory metadata) {
        console.log("\n--- Binding Verification ---");

        IPolicyManager.PolicyDraft memory draft = policyManagerContract.getPolicyDraft(policyId);
        console.log("Draft status after binding:", uint8(draft.status));
        require(draft.status == IPolicyManager.PolicyStatus.Bound, "Draft not in Bound status");

        metadata = policyManagerContract.policyMetadata(policyId);
        console.log("Policy buyer:", metadata.buyer);
        console.log("Policy beneficiary:", metadata.beneficiary);
        console.log("Policy coverageLimit:", metadata.coverageLimit);
        console.log("Policy startTime:", metadata.startTime);
        console.log("Policy maturityTime:", metadata.maturityTime);
        require(metadata.buyer != address(0), "Policy metadata not stored");

        ICoverPool.BoundPolicy memory boundPolicy = poolContract.getBoundPolicy(policyId);
        console.log("BoundPolicy commit:", vm.toString(boundPolicy.policyCommit));
        require(boundPolicy.policyId == policyId, "BoundPolicy ID mismatch");

        address[] memory committeeVaults = stakeManagerContract.getCommitteeVaults(policyId);
        console.log("Committee vault count:", committeeVaults.length);
        require(committeeVaults.length > 0, "No vaults in committee");

        console.log("[SUCCESS] Policy binding verified");
    }
}
