// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Lib_OVMCodec} from "../src/metis/Lib_OVMCodec.sol";
import {IChainStorageContainer, IMVMStateCommitmentChain} from "../src/metis/IMVMStateCommitmentChain.sol";
import {Lib_MerkleTree} from "./metis/Lib_MerkleTree.sol";

/// Storage and finality views of MVM_StateCommitmentChain at mvm 61ef7e9:
/// `append` builds and hashes headers exactly as `_appendBatchByChainId`
/// does; proposer, address-manager and dispute-game plumbing are omitted.
contract MetisSCCHarness is IMVMStateCommitmentChain, IChainStorageContainer {
    uint256 public immutable FRAUD_PROOF_WINDOW;
    mapping(uint256 => mapping(uint256 => bytes32)) internal stored;
    mapping(uint256 => uint256) internal lengths;
    mapping(uint256 => uint256) public totalElements;
    mapping(bytes32 => bool) public disputedBatches;
    uint256 public earliestDisputedBlockNumber;

    constructor(uint256 _fraudProofWindow) {
        FRAUD_PROOF_WINDOW = _fraudProofWindow;
    }

    function append(uint256 _chainId, bytes32[] memory _batch, bytes32 _lastBatchBlockHash)
        external
        returns (Lib_OVMCodec.ChainBatchHeader memory header)
    {
        uint256 prevTotal = totalElements[_chainId];
        header = Lib_OVMCodec.ChainBatchHeader({
            batchIndex: lengths[_chainId],
            batchRoot: Lib_MerkleTree.getMerkleRoot(_batch),
            batchSize: _batch.length,
            prevTotalElements: prevTotal,
            extraData: abi.encode(block.timestamp, msg.sender, _lastBatchBlockHash, prevTotal + _batch.length)
        });
        stored[_chainId][header.batchIndex] = Lib_OVMCodec.hashBatchHeader(header);
        lengths[_chainId] = header.batchIndex + 1;
        totalElements[_chainId] = prevTotal + header.batchSize;
    }

    /// Places an existing header hash, such as a mainnet batch, at its index.
    function seed(uint256 _chainId, uint256 _index, bytes32 _headerHash) external {
        stored[_chainId][_index] = _headerHash;
        if (_index >= lengths[_chainId]) lengths[_chainId] = _index + 1;
    }

    /// `deleteElementsAfterInclusiveByChainId`, as the fraud verifier triggers it.
    function deleteFrom(uint256 _chainId, uint256 _index, uint256 _prevTotalElements) external {
        for (uint256 i = _index; i < lengths[_chainId]; ++i) {
            delete stored[_chainId][i];
        }
        lengths[_chainId] = _index;
        totalElements[_chainId] = _prevTotalElements;
    }

    function setDisputed(bytes32 _headerHash, uint256 _blockNumber) external {
        disputedBatches[_headerHash] = true;
        earliestDisputedBlockNumber = _blockNumber;
    }

    function batches() external view returns (IChainStorageContainer) {
        return this;
    }

    function lengthByChainId(uint256 _chainId) external view returns (uint256) {
        return lengths[_chainId];
    }

    function getByChainId(uint256 _chainId, uint256 _index) external view returns (bytes32) {
        require(_index < lengths[_chainId], "Index out of bounds.");
        return stored[_chainId][_index];
    }

    function insideFraudProofWindow(Lib_OVMCodec.ChainBatchHeader memory _batchHeader) external view returns (bool) {
        uint256 timestamp;
        if (_batchHeader.extraData.length == 0x40) {
            (timestamp,) = abi.decode(_batchHeader.extraData, (uint256, address));
        } else if (_batchHeader.extraData.length == 0x80) {
            (timestamp,,,) = abi.decode(_batchHeader.extraData, (uint256, address, bytes32, uint256));
        } else {
            revert("Invalid extra data length");
        }
        require(timestamp != 0, "Batch header timestamp cannot be zero");
        return timestamp + FRAUD_PROOF_WINDOW > block.timestamp;
    }

    function isDisputedBatch(bytes32 _headerHash) external view returns (bool) {
        return disputedBatches[_headerHash];
    }
}
