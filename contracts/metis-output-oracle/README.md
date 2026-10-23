# Metis OP Succinct output oracle

`MetisOPSuccinctL2OutputOracle` gives Metis SCC batches proof-only finality.
It is modeled on OP Succinct's
[`OPSuccinctL2OutputOracle`](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/contracts/src/validity/OPSuccinctL2OutputOracle.sol)
and built against the current Metis contracts
([mvm `61ef7e9`](https://github.com/MetisProtocol/mvm/tree/61ef7e9a9a1f404505279e1d86f2c26a885bcc86)).

The Metis proposer still appends state batches to `MVM_StateCommitmentChain`
without a proof. A prover then calls `proposeL2Output`, which:

1. requires an approved proposer, or anyone once `fallbackTimeout` passes
   without a proposal;
2. reads the canonical header hashes of batches `latestBatchIndex + 1` through
   `_endBatchIndex` straight from the SCC's storage container, so the caller
   cannot pick the claim (at most 64 batches per proof);
3. builds `MetisAggregationOutputs` from those hashes, the proven predecessor,
   a checkpointed L1 block hash, the configuration and the prover address;
4. calls the approved [Ziren shrink verifier](../ziren-shrink-verifier/) with
   `sha256(abi.encode(outputs))`, and records every batch's header hash as
   proven only if it accepts.

`isProven(header)` and `isProvenHash(index, hash)` are the finality checks for
the messenger.

| OP Succinct | This oracle |
| --- | --- |
| `aggregationVkey` in `OpSuccinctConfig` | `verifier`: the entry pins the guest key, exit code and recursion root |
| Caller supplies `_outputRoot`, `_l2BlockNumber` | Caller supplies `_endBatchIndex`; header hashes come from the SCC |
| `l2Outputs` array | `provenBatches[batchIndex]` = SCC header hash |
| Optimistic mode, dispute game factory | None: elapsed time never finalizes a batch |
| `historicBlockHashes`, `checkpointBlockHash`, `approvedProposers`, `fallbackTimeout` | Same |

## Public values

The guest must commit exactly these nine 32-byte words, in order. The verifier
checks the proof against their SHA-256, which is Ziren's `PublicValues::hash`.

| Word | Field | Meaning |
| --- | --- | --- |
| 0 | `l1Head` | L1 block hash authenticating DA, enqueue and SCC inputs |
| 1 | `l2ChainId` | Metis chain ID in the SCC (1088 on mainnet) |
| 2 | `l2PreBatchHeaderHash` | Accepted batch `start - 1`; the guest starts from its last state root |
| 3 | `startBatchIndex` | First batch proven |
| 4 | `endBatchIndex` | Last batch proven |
| 5 | `batchHeaderHashesCommitment` | `keccak256` of the concatenated header hashes, start to end |
| 6 | `rollupConfigHash` | Metis rollup configuration |
| 7 | `rangeVkeyCommitment` | Range program key accepted by the aggregation guest |
| 8 | `proverAddress` | Left-padded prover address |

Each header hash is `Lib_OVMCodec.hashBatchHeader`: `keccak256(abi.encode(batchRoot,
batchSize, prevTotalElements, extraData))`. The guest derives `batchRoot` (the
`Lib_MerkleTree` root of every per-block state root), `batchSize`,
`prevTotalElements` and, in `extraData`, `lastBatchBlockHash` and
`lastBatchBlockNumber`. The timestamp and proposer in `extraData` are inputs
that the SCC hash binds.

## What Metis still has to change

The oracle changes nothing on its own. Withdrawals depend on it only after:

- **Messenger**: for batches after `startingBatchIndex`,
  `_verifyStateRootProofByChainId` requires `oracle.isProven(header)` together
  with `verifyStateCommitmentByChainId`, instead of the fraud-window and
  `earliestDisputedBlockNumber` checks. Earlier batches keep today's rules.
- **SCC**: `deleteStateBatchByChainId` rejects any batch at or below
  `oracle.latestBatchIndex()`. Until then, a deleted and replaced batch is not
  proven (the oracle keeps the original hash), but the proven chain cannot
  continue past it.

The constructor anchors at a legacy batch that the messenger already treats as
final: canonical, outside the fraud window, not disputed and ending before
`earliestDisputedBlockNumber`.

## Gas and tests

Proving 64 batches costs the oracle 1,575,532 gas beyond verification in the
tests (warm SCC storage; cold mainnet reads add about 2,100 per batch). Comparing
this with the 3,109,177 gas left after the recorded 13,668,039-gas standalone
verification suggests sufficient room under the 16,777,216 transaction cap.
It is a component estimate, not a complete Metis transaction measurement; verify
the real guest, verifier and oracle together. The [cost model](../../docs/costs.md)
states the assumptions used for submission-frequency budgets.

```sh
forge test --root contracts/metis-output-oracle
```

The tests use mainnet batches 47399 and 47400 of chain 1088 to check the header
hash against the SCC's stored hashes, and prove a batch from a mainnet anchor.
`MetisSCCHarness` reproduces the SCC's header construction and finality views;
the verifier is a mock that accepts one digest. An end-to-end run with a real
verifier needs a guest that commits these public values.
