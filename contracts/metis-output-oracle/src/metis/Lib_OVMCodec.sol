// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

// Subset of MetisProtocol/mvm 61ef7e9a9a1f404505279e1d86f2c26a885bcc86,
// packages/contracts/contracts/libraries/codec/Lib_OVMCodec.sol: the SCC batch
// header and its hash, unchanged. The hash does not cover `batchIndex`.
library Lib_OVMCodec {
    struct ChainBatchHeader {
        uint256 batchIndex;
        bytes32 batchRoot;
        uint256 batchSize;
        uint256 prevTotalElements;
        bytes extraData;
    }

    function hashBatchHeader(ChainBatchHeader memory _batchHeader) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                _batchHeader.batchRoot, _batchHeader.batchSize, _batchHeader.prevTotalElements, _batchHeader.extraData
            )
        );
    }
}
