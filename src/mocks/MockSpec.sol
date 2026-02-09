// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISpec} from "../interfaces/ISpec.sol";

/**
 * @title MockSpec
 * @notice Configurable mock Spec implementation for testing claim evaluation.
 * @dev Supports both default behavior and evidence-specific custom results.
 *      Default behavior: approves all claims.
 *      Custom behavior: map specific evidence hashes to specific outcomes.
 */
contract MockSpec is ISpec {
    address public immutable OWNER;
    bool private _defaultIsPayable;
    uint256 private _defaultAmountUsd;
    bytes32 private _defaultNotesHash;

    mapping(bytes32 evidenceHash => EvaluationResult result) private _customResults;
    mapping(bytes32 evidenceHash => bool exists) private _hasCustomResult;

    /**
     * @notice Emitted when the default evaluation result is updated.
     * @param isPayable Whether claims should be approved by default.
     * @param amountUsd Default USD amount (0 = approve full requested amount).
     * @param notesHash Default notes hash for audit trail.
     */
    event DefaultResultUpdated(bool isPayable, uint256 amountUsd, bytes32 notesHash);

    /**
     * @notice Emitted when a custom result is configured for a specific evidence hash.
     * @param evidenceHash The evidence hash that will trigger this custom result.
     * @param isPayable Whether this specific claim should be approved.
     * @param amountUsd USD amount for this claim (0 = use requested amount).
     * @param notesHash Notes hash for this specific claim.
     */
    event CustomResultSet(bytes32 indexed evidenceHash, bool isPayable, uint256 amountUsd, bytes32 notesHash);

    /**
     * @notice Emitted when a custom result mapping is removed.
     * @param evidenceHash The evidence hash for which custom behavior was removed.
     */
    event CustomResultRemoved(bytes32 indexed evidenceHash);

    /**
     * @notice Thrown when caller is not the owner.
     */
    error NotOwner();

    /**
     * @dev Restricts function access to the contract owner.
     */
    modifier onlyOwner() {
        if (msg.sender != OWNER) revert NotOwner();
        _;
    }

    /**
     * @notice Deploys a new MockSpec with auto-approve default behavior.
     * @dev Initializes with default payable result and zero amount (full claim approval).
     */
    constructor() {
        OWNER = msg.sender;
        _defaultIsPayable = true;
        _defaultAmountUsd = 0;
        _defaultNotesHash = keccak256("mock-spec-auto-approve");
    }

    /**
     * @notice Configure the default evaluation behavior for all claims.
     * @param isPayable Whether claims should be approved by default.
     * @param amountUsd Default USD amount (0 = approve full requested amount).
     * @param notesHash Default notes hash for audit trail.
     */
    function setDefaultResult(bool isPayable, uint256 amountUsd, bytes32 notesHash) external onlyOwner {
        _defaultIsPayable = isPayable;
        _defaultAmountUsd = amountUsd;
        _defaultNotesHash = notesHash;
        emit DefaultResultUpdated(isPayable, amountUsd, notesHash);
    }

    /**
     * @notice Configure a custom result for a specific evidence hash.
     * @param evidenceHash The evidence hash that will trigger this custom result.
     * @param isPayable Whether this specific claim should be approved.
     * @param amountUsd USD amount for this claim (0 = use requested amount).
     * @param notesHash Notes hash for this specific claim.
     */
    function setCustomResult(
        bytes32 evidenceHash,
        bool isPayable,
        uint256 amountUsd,
        bytes32 notesHash
    )
        external
        onlyOwner
    {
        _customResults[evidenceHash] =
            EvaluationResult({isPayable: isPayable, amountUsd: amountUsd, notesHash: notesHash});
        _hasCustomResult[evidenceHash] = true;
        emit CustomResultSet(evidenceHash, isPayable, amountUsd, notesHash);
    }

    /**
     * @notice Remove a custom result mapping for a specific evidence hash.
     * @param evidenceHash The evidence hash to remove custom behavior for.
     */
    function removeCustomResult(bytes32 evidenceHash) external onlyOwner {
        delete _customResults[evidenceHash];
        delete _hasCustomResult[evidenceHash];
        emit CustomResultRemoved(evidenceHash);
    }

    /**
     * @inheritdoc ISpec
     * @dev Evaluation logic:
     *      1. Check for custom result matching evidenceHash - return if exists
     *      2. Otherwise return default result
     *      3. If amountUsd is 0, the ClaimManager will use the requested amount
     */
    function evaluate(EvaluationContext calldata context)
        external
        view
        override
        returns (EvaluationResult memory result)
    {
        if (_hasCustomResult[context.evidenceHash]) {
            return _customResults[context.evidenceHash];
        }

        result.isPayable = _defaultIsPayable;
        result.amountUsd = _defaultAmountUsd;
        result.notesHash = _defaultNotesHash;
    }
}
