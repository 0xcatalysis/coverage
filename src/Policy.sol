// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPolicy} from "./interfaces/IPolicy.sol";

/**
 * @title Policy
 * @notice Soulbound ERC-721 token that stores canonical metadata for Catalysis coverage policies.
 * @dev Uses AccessControl for role separation and enforces permanent transfer locks so receipts
 *      remain non-transferable.
 */
contract Policy is Initializable, UUPSUpgradeable, AccessControlUpgradeable, ERC721Upgradeable, IPolicy {
    bytes32 public constant override POLICY_MANAGER_ROLE = keccak256("POLICY_MANAGER_ROLE");
    string private constant _NAME = "Catalysis Policy";
    string private constant _SYMBOL = "POLICY";

    mapping(uint256 policyId => PolicyMetadata) private _policies;
    mapping(bytes32 policyCommit => bool registered) private _registeredPolicyCommits;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the Policy contract.
     * @param admin_ Address that receives DEFAULT_ADMIN_ROLE for upgrade control.
     * @param policyManager_ Address granted POLICY_MANAGER_ROLE for minting.
     * @dev Reverts with ZeroAddress when either argument is the zero address.
     */
    function initialize(address admin_, address policyManager_) external initializer {
        require(admin_ != address(0) && policyManager_ != address(0), ZeroAddress());

        __ERC721_init(_NAME, _SYMBOL);
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(POLICY_MANAGER_ROLE, policyManager_);
    }

    /**
     * @notice Mints a new policy receipt and persists the provided metadata.
     * @dev Enforces that all referenced addresses are non-zero and that the policy commit has
     *      not been previously registered. Each policy represents coverage from a single pool.
     *      Emits PolicyMinted on success.
     * @param to Recipient address receiving the soulbound policy token.
     * @param policyId Identifier to assign to the new policy token.
     * @param metadata Full policy metadata snapshot supplied by PolicyManager.
     */
    function mintPolicy(
        address to,
        uint256 policyId,
        PolicyMetadata calldata metadata
    )
        external
        override
        onlyRole(POLICY_MANAGER_ROLE)
    {
        require(
            to != address(0) && metadata.buyer != address(0) && metadata.beneficiary != address(0)
                && metadata.premiumToken != address(0) && metadata.payoutToken != address(0)
                && metadata.pool != address(0) && metadata.payoutReceiver != address(0)
                && metadata.operator != address(0),
            ZeroAddress()
        );
        require(metadata.policyCommit != bytes32(0), InvalidPolicyCommit());
        require(metadata.coverageLimit != 0, InvalidCoverageLimit());
        require(metadata.poolPolicyId != bytes32(0) && metadata.termsHash != bytes32(0), InvalidPolicyMetadata());
        require(
            metadata.startTime < metadata.maturityTime, InvalidCoverageWindow(metadata.startTime, metadata.maturityTime)
        );
        require(_ownerOf(policyId) == address(0), PolicyAlreadyMinted(policyId));
        require(!_registeredPolicyCommits[metadata.policyCommit], PolicyCommitAlreadyRegistered(metadata.policyCommit));

        _registeredPolicyCommits[metadata.policyCommit] = true;
        _policies[policyId] = metadata;

        _safeMint(to, policyId);

        emit PolicyMinted(
            policyId,
            to,
            metadata.pool,
            metadata.startTime,
            metadata.maturityTime,
            metadata.coverageLimit,
            metadata.policyCommit
        );
    }

    /**
     * @notice Returns the full metadata snapshot for a policy.
     * @dev Reverts with PolicyNotFound if the policy has not been minted.
     * @param policyId Identifier of the policy to read.
     * @return metadata Fully populated PolicyMetadata struct.
     */
    function policyMetadata(uint256 policyId) external view override returns (PolicyMetadata memory metadata) {
        metadata = _policies[policyId];
        require(metadata.buyer != address(0), PolicyNotFound(policyId));
    }

    /**
     * @inheritdoc AccessControlUpgradeable
     */
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override (AccessControlUpgradeable, ERC721Upgradeable, IERC165)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Overrides ERC721 hook to block transfers while allowing mint/burn semantics.
     * @param to Recipient address specified in the transfer.
     * @param tokenId Identifier of the policy token being moved.
     * @param auth Caller used by ERC721Upgradeable for authorization checks.
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override (ERC721Upgradeable)
        returns (address)
    {
        address from = _ownerOf(tokenId);
        require(from == address(0) || to == address(0), TransfersLocked(tokenId));

        return super._update(to, tokenId, auth);
    }

    /**
     * @dev Restricts upgrade authorization to DEFAULT_ADMIN_ROLE holders.
     */
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
