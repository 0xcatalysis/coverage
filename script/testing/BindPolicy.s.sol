// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {ICoverPool} from "../../src/interfaces/ICoverPool.sol";
import {IPolicyManager} from "../../src/interfaces/IPolicyManager.sol";
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
 *   forge script script/testing/BindPolicy.s.sol:BindPolicy \
 *     --rpc-url $RPC_URL --broadcast --slow -vvvv
 *
 * Required Environment Variables:
 *   - CURATOR_PRIVATE_KEY: Private key of the curator (CoverPool admin)
 *   - QUOTE_SIGNER_PRIVATE_KEY: Private key of the quote signer
 *   - COVER_POOL: CoverPool address
 *   - POLICY_MANAGER: PolicyManager proxy address
 *   - STAKE_MANAGER: StakeManager proxy address from core
 *   - POLICY_ID: Policy ID (from RequestCoverage output)
 *   - SPEC_ADDRESS: ISpec implementation contract for this policy
 *   - VAULTS: Comma-separated vault addresses to bind (e.g. "0x123...,0x456...")
 *   - COVERAGE_LIMIT: Coverage limit in payout token units
 *   - BASE_PREMIUM: Base premium amount
 *   - SPEC_ID: Spec identifier (bytes32 hex)
 *   - TERMS_HASH: Policy terms hash (bytes32 hex)
 *   - START_TIME: Coverage start timestamp
 *   - MATURITY_TIME: Coverage end timestamp
 *   - EXPIRATION_TIME: Quote expiration timestamp
 *
 * Prerequisites:
 *   - Curator must be the CoverPool admin (owner)
 *   - Quote signer must have QUOTE_SIGNER_ROLE on the CoverPool
 *   - Policy draft must exist in PolicyManager (status = Created)
 *   - Sufficient stake must exist in the committee's duration vault (restaker deposits via
 *     StrategyManager.depositIntoStrategy(durationVault, token, amount) independently)
 */
contract BindPolicy is Script {
    bytes32 private constant _QUOTE_TYPEHASH = keccak256(
        "Quote(address pool,uint96 policyId,uint256 coverageLimit,uint256 basePremium,bytes32 specId,bytes32 termsHash,address beneficiary,uint32 startTime,uint32 maturityTime,uint32 expirationTime)"
    );

    /// @notice Curator address (CoverPool admin)
    address public curator;

    /// @notice Curator's private key
    uint256 public curatorPrivateKey;

    /// @notice Quote signer's private key
    uint256 public quoteSignerPrivateKey;

    /// @notice CoverPool address
    address public coverPool;

    /// @notice PolicyManager proxy address
    address public policyManager;

    /// @notice StakeManager proxy address
    address public stakeManager;

    /// @notice Policy ID to bind
    uint96 public policyId;

    /// @notice ISpec implementation address
    address public specAddress;

    /// @notice Vaults to bind to the committee
    address[] public vaults;

    /// @notice Quote parameters
    uint256 public coverageLimit;
    uint256 public basePremium;
    bytes32 public specId;
    bytes32 public termsHash;
    uint32 public startTime;
    uint32 public maturityTime;
    uint32 public expirationTime;

    /// @notice Contract instances
    ICoverPool public poolContract;
    IPolicyManager public policyManagerContract;
    IStakeManager public stakeManagerContract;

    /// @notice Emitted when policy is bound
    event PolicyBound(uint96 indexed policyId, address indexed pool, uint256 coverageLimit, uint256 vaultCount);

    constructor() {
        curatorPrivateKey = vm.envUint("CURATOR_PRIVATE_KEY");
        curator = vm.addr(curatorPrivateKey);
        quoteSignerPrivateKey = vm.envUint("QUOTE_SIGNER_PRIVATE_KEY");

        coverPool = vm.envAddress("COVER_POOL");
        policyManager = vm.envAddress("POLICY_MANAGER");
        stakeManager = vm.envAddress("STAKE_MANAGER");
        policyId = uint96(vm.envUint("POLICY_ID"));
        specAddress = vm.envAddress("SPEC_ADDRESS");

        // Parse vault addresses
        string memory vaultsStr = vm.envString("VAULTS");
        string[] memory vaultAddresses = vm.split(vaultsStr, ",");
        for (uint256 i = 0; i < vaultAddresses.length; i++) {
            vaults.push(vm.parseAddress(vaultAddresses[i]));
        }

        coverageLimit = vm.envUint("COVERAGE_LIMIT");
        basePremium = vm.envUint("BASE_PREMIUM");
        specId = vm.envBytes32("SPEC_ID");
        termsHash = vm.envBytes32("TERMS_HASH");
        startTime = uint32(vm.envUint("START_TIME"));
        maturityTime = uint32(vm.envUint("MATURITY_TIME"));
        expirationTime = uint32(vm.envUint("EXPIRATION_TIME"));

        poolContract = ICoverPool(coverPool);
        policyManagerContract = IPolicyManager(policyManager);
        stakeManagerContract = IStakeManager(stakeManager);
    }

    function run() external {
        console.log("=== FLOW 5: POLICY BINDING ===");
        console.log("Curator:", curator);
        console.log("CoverPool:", coverPool);
        console.log("Policy ID:", policyId);
        console.log("Coverage Limit:", coverageLimit);
        console.log("Number of Vaults:", vaults.length);
        console.log("Start Time:", startTime);
        console.log("Maturity Time:", maturityTime);

        _verifyPrerequisites();

        IPolicyManager.PolicyDraft memory draft = policyManagerContract.getPolicyDraft(policyId);

        ICoverPool.Quote memory quote = ICoverPool.Quote({
            pool: coverPool,
            policyId: policyId,
            coverageLimit: coverageLimit,
            basePremium: basePremium,
            specId: specId,
            termsHash: termsHash,
            beneficiary: draft.beneficiary,
            startTime: startTime,
            maturityTime: maturityTime,
            expirationTime: expirationTime
        });

        bytes memory signature = _signQuote(quote);
        console.log("Quote signed by quote signer");

        require(maturityTime - startTime == draft.duration, "Duration mismatch with draft");
        console.log("Duration matches draft:", draft.duration);

        vm.startBroadcast(curatorPrivateKey);

        poolContract.bindPolicyForRequest(policyId, quote, specAddress, vaults, signature);

        vm.stopBroadcast();

        _verifyBinding();

        console.log("\n=== POLICY BINDING COMPLETED ===");
        console.log("Policy is now active. Coverage window:", startTime, "-", maturityTime);
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
                quote.basePremium,
                quote.specId,
                quote.termsHash,
                quote.beneficiary,
                quote.startTime,
                quote.maturityTime,
                quote.expirationTime
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(quoteSignerPrivateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _verifyBinding() internal view {
        console.log("\n--- Binding Verification ---");

        IPolicyManager.PolicyDraft memory draft = policyManagerContract.getPolicyDraft(policyId);
        console.log("Draft status after binding:", uint8(draft.status));
        require(draft.status == IPolicyManager.PolicyStatus.Bound, "Draft not in Bound status");

        IPolicyManager.PolicyMetadata memory metadata = policyManagerContract.policyMetadata(policyId);
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
