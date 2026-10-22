// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import {Lib_OVMCodec} from "./Lib_OVMCodec.sol";

// The functions the oracle reads from MetisProtocol/mvm
// 61ef7e9a9a1f404505279e1d86f2c26a885bcc86 IChainStorageContainer and
// IMVMStateCommitmentChain, with the same signatures.
interface IChainStorageContainer {
    function lengthByChainId(uint256 _chainId) external view returns (uint256);
    function getByChainId(uint256 _chainId, uint256 _index) external view returns (bytes32);
}

interface IMVMStateCommitmentChain {
    function batches() external view returns (IChainStorageContainer);
    function insideFraudProofWindow(Lib_OVMCodec.ChainBatchHeader memory _batchHeader)
        external
        view
        returns (bool _inside);
    function isDisputedBatch(bytes32 stateHeaderHash) external view returns (bool _disputed);
    function earliestDisputedBlockNumber() external view returns (uint256 _earliestDisputedBlockNumber);
}
