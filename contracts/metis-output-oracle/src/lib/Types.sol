// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @notice Public values of the Metis aggregation guest. The guest commits
///         exactly `abi.encode(outputs)`, so the Ziren output digest is
///         `sha256(abi.encode(outputs))` (Ziren `PublicValues::hash`).
/// @dev Counterpart of OP Succinct's `AggregationOutputs`. Metis finality is
///      per SCC batch, so the claim is a contiguous batch range instead of an
///      output root and block number.
struct MetisAggregationOutputs {
    /// L1 block hash that authenticates every L1 input (DA, enqueues, SCC).
    bytes32 l1Head;
    /// Metis chain ID in the SCC, such as 1088.
    uint256 l2ChainId;
    /// Header hash of the accepted batch `startBatchIndex - 1`. The guest
    /// starts from its last state root.
    bytes32 l2PreBatchHeaderHash;
    uint256 startBatchIndex;
    uint256 endBatchIndex;
    /// keccak256(abi.encodePacked(h[start], ..., h[end])) over SCC header
    /// hashes, each `Lib_OVMCodec.hashBatchHeader` of a derived header.
    bytes32 batchHeaderHashesCommitment;
    bytes32 rollupConfigHash;
    bytes32 rangeVkeyCommitment;
    address proverAddress;
}
