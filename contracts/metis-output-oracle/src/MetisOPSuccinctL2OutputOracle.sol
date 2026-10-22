// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IZirenShrinkVerifier} from "./interfaces/IZirenShrinkVerifier.sol";
import {MetisAggregationOutputs} from "./lib/Types.sol";
import {IChainStorageContainer, IMVMStateCommitmentChain} from "./metis/IMVMStateCommitmentChain.sol";
import {Lib_OVMCodec} from "./metis/Lib_OVMCodec.sol";

/// @title MetisOPSuccinctL2OutputOracle
/// @notice Proof-only finality for Metis SCC batches, modeled on OP Succinct's
///         `OPSuccinctL2OutputOracle`. The Metis proposer still appends state
///         batches to `MVM_StateCommitmentChain`; this contract marks a
///         contiguous range of those canonical batches proven once a Ziren
///         shrink proof of their derivation and execution verifies.
/// @dev Differences from OP Succinct: the claim is read from the SCC instead
///      of supplied by the caller, `OpSuccinctConfig.verifier` replaces
///      `aggregationVkey` because the verifier entry pins the guest key, and
///      there is no optimistic mode: elapsed time never finalizes a batch.
contract MetisOPSuccinctL2OutputOracle {
    /// @notice Configuration parameters for OP Succinct verification.
    struct OpSuccinctConfig {
        /// @notice Approved Ziren shrink verifier entry for the aggregation guest.
        address verifier;
        /// @notice Commitment to the range program key the aggregation guest accepts.
        bytes32 rangeVkeyCommitment;
        /// @notice Hash of the Metis rollup configuration, preventing cross-chain replay.
        bytes32 rollupConfigHash;
    }

    /// @notice Parameters to construct the oracle.
    struct InitParams {
        address owner;
        address proposer;
        IMVMStateCommitmentChain scc;
        uint256 l2ChainId;
        /// @notice A legacy batch already final under the fraud-window rules.
        Lib_OVMCodec.ChainBatchHeader startingBatchHeader;
        uint256 fallbackTimeout;
        OpSuccinctConfig genesisConfig;
    }

    /// @notice Most batches one proof may finalize, keeping the oracle's
    ///         reads and writes well inside the transaction gas cap.
    uint256 public constant MAX_BATCHES_PER_PROOF = 64;

    bytes32 public constant GENESIS_CONFIG_NAME = keccak256("opsuccinct_genesis");

    string public constant version = "v1.0.0";

    IMVMStateCommitmentChain public immutable scc;
    uint256 public immutable l2ChainId;
    uint256 public immutable startingBatchIndex;
    /// @notice After this many seconds without a proposal, anyone may prove.
    uint256 public immutable fallbackTimeout;

    address public owner;
    mapping(address => bool) public approvedProposers;
    mapping(bytes32 => OpSuccinctConfig) public opSuccinctConfigs;
    /// @notice A trusted mapping of L1 block numbers to block hashes.
    mapping(uint256 => bytes32) public historicBlockHashes;
    /// @notice SCC header hash of every proven batch, by batch index.
    mapping(uint256 => bytes32) public provenBatches;
    uint256 public latestBatchIndex;
    uint256 public lastProposalTimestamp;

    event OutputProposed(
        uint256 indexed startBatchIndex,
        uint256 indexed endBatchIndex,
        bytes32 endBatchHeaderHash,
        bytes32 indexed configName,
        address proverAddress
    );
    event OpSuccinctConfigUpdated(
        bytes32 indexed configName, address verifier, bytes32 rangeVkeyCommitment, bytes32 rollupConfigHash
    );
    event OpSuccinctConfigDeleted(bytes32 indexed configName);
    event ProposerUpdated(address indexed proposer, bool added);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error NotApprovedProposer();
    error InvalidConfig();
    error ConfigExists();
    error L1BlockHashNotAvailable();
    error L1BlockHashNotCheckpointed();
    error InvalidBatchRange();
    error BatchNotCanonical(uint256 batchIndex);
    error BatchNotFinal();
    error InvalidProof();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(InitParams memory _params) {
        IChainStorageContainer container = _params.scc.batches();
        Lib_OVMCodec.ChainBatchHeader memory header = _params.startingBatchHeader;
        bytes32 headerHash = Lib_OVMCodec.hashBatchHeader(header);
        if (
            header.batchIndex >= container.lengthByChainId(_params.l2ChainId)
                || container.getByChainId(_params.l2ChainId, header.batchIndex) != headerHash
        ) revert BatchNotCanonical(header.batchIndex);
        // The same finality test the messenger applies before relaying today.
        uint256 earliestDisputed = _params.scc.earliestDisputedBlockNumber();
        if (
            _params.scc.insideFraudProofWindow(header) || _params.scc.isDisputedBatch(headerHash)
                || (earliestDisputed != 0 && header.prevTotalElements + header.batchSize >= earliestDisputed)
        ) revert BatchNotFinal();

        scc = _params.scc;
        l2ChainId = _params.l2ChainId;
        startingBatchIndex = header.batchIndex;
        fallbackTimeout = _params.fallbackTimeout;
        provenBatches[header.batchIndex] = headerHash;
        latestBatchIndex = header.batchIndex;
        lastProposalTimestamp = block.timestamp;

        owner = _params.owner;
        emit OwnershipTransferred(address(0), _params.owner);
        approvedProposers[_params.proposer] = true;
        emit ProposerUpdated(_params.proposer, true);
        _addOpSuccinctConfig(GENESIS_CONFIG_NAME, _params.genesisConfig);
    }

    /// @notice Proves SCC batches `latestBatchIndex + 1` through `_endBatchIndex`.
    /// @param _configName Approved configuration to verify under.
    /// @param _endBatchIndex Last batch the proof covers; it must already be in the SCC.
    /// @param _l1BlockNumber Checkpointed L1 block whose hash the guest used as its L1 head.
    /// @param _proof Ziren shrink proof packet for the verifier entry.
    /// @param _proverAddress Prover bound into the public values.
    function proposeL2Output(
        bytes32 _configName,
        uint256 _endBatchIndex,
        uint256 _l1BlockNumber,
        bytes calldata _proof,
        address _proverAddress
    ) external {
        if (
            !approvedProposers[msg.sender] && !approvedProposers[address(0)]
                && block.timestamp - lastProposalTimestamp <= fallbackTimeout
        ) revert NotApprovedProposer();

        OpSuccinctConfig memory config = opSuccinctConfigs[_configName];
        if (config.verifier == address(0)) revert InvalidConfig();

        bytes32 l1BlockHash = historicBlockHashes[_l1BlockNumber];
        if (l1BlockHash == bytes32(0)) revert L1BlockHashNotCheckpointed();

        uint256 start = latestBatchIndex + 1;
        if (_endBatchIndex < start || _endBatchIndex - start >= MAX_BATCHES_PER_PROOF) revert InvalidBatchRange();
        IChainStorageContainer container = scc.batches();
        if (_endBatchIndex >= container.lengthByChainId(l2ChainId)) revert BatchNotCanonical(_endBatchIndex);

        bytes32[] memory hashes = new bytes32[](_endBatchIndex - start + 1);
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = container.getByChainId(l2ChainId, start + i);
            if (hashes[i] == bytes32(0)) revert BatchNotCanonical(start + i);
        }

        MetisAggregationOutputs memory publicValues = MetisAggregationOutputs({
            l1Head: l1BlockHash,
            l2ChainId: l2ChainId,
            l2PreBatchHeaderHash: provenBatches[start - 1],
            startBatchIndex: start,
            endBatchIndex: _endBatchIndex,
            batchHeaderHashesCommitment: keccak256(abi.encodePacked(hashes)),
            rollupConfigHash: config.rollupConfigHash,
            rangeVkeyCommitment: config.rangeVkeyCommitment,
            proverAddress: _proverAddress
        });
        if (!IZirenShrinkVerifier(config.verifier).verify(_proof, sha256(abi.encode(publicValues)))) {
            revert InvalidProof();
        }

        for (uint256 i; i < hashes.length; ++i) {
            provenBatches[start + i] = hashes[i];
        }
        latestBatchIndex = _endBatchIndex;
        lastProposalTimestamp = block.timestamp;
        emit OutputProposed(start, _endBatchIndex, hashes[hashes.length - 1], _configName, _proverAddress);
    }

    /// @notice Checkpoints a block hash at a given block number.
    function checkpointBlockHash(uint256 _blockNumber) external {
        bytes32 blockHash = blockhash(_blockNumber);
        if (blockHash == bytes32(0)) revert L1BlockHashNotAvailable();
        historicBlockHashes[_blockNumber] = blockHash;
    }

    /// @notice Whether this exact SCC batch header is proven. The messenger
    ///         checks this, together with SCC inclusion, for batches after
    ///         `startingBatchIndex`.
    function isProven(Lib_OVMCodec.ChainBatchHeader memory _batchHeader) external view returns (bool) {
        return isProvenHash(_batchHeader.batchIndex, Lib_OVMCodec.hashBatchHeader(_batchHeader));
    }

    function isProvenHash(uint256 _batchIndex, bytes32 _batchHeaderHash) public view returns (bool) {
        return _batchHeaderHash != bytes32(0) && provenBatches[_batchIndex] == _batchHeaderHash;
    }

    function addOpSuccinctConfig(bytes32 _configName, OpSuccinctConfig memory _config) external onlyOwner {
        _addOpSuccinctConfig(_configName, _config);
    }

    function deleteOpSuccinctConfig(bytes32 _configName) external onlyOwner {
        delete opSuccinctConfigs[_configName];
        emit OpSuccinctConfigDeleted(_configName);
    }

    function addProposer(address _proposer) external onlyOwner {
        approvedProposers[_proposer] = true;
        emit ProposerUpdated(_proposer, true);
    }

    function removeProposer(address _proposer) external onlyOwner {
        approvedProposers[_proposer] = false;
        emit ProposerUpdated(_proposer, false);
    }

    function transferOwnership(address _owner) external onlyOwner {
        emit OwnershipTransferred(owner, _owner);
        owner = _owner;
    }

    function _addOpSuccinctConfig(bytes32 _configName, OpSuccinctConfig memory _config) internal {
        if (_configName == bytes32(0) || _config.verifier.code.length == 0) revert InvalidConfig();
        if (opSuccinctConfigs[_configName].verifier != address(0)) revert ConfigExists();
        opSuccinctConfigs[_configName] = _config;
        emit OpSuccinctConfigUpdated(
            _configName, _config.verifier, _config.rangeVkeyCommitment, _config.rollupConfigHash
        );
    }
}
