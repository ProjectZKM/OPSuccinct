# Range program design

This document designs a **range program** (zkVM guest) for the Metis validity bridge.
It proves that, starting from a finalized L2 state, consuming the blobs of several consecutive batches already committed on L1, and rebuilding and executing blocks under the Metis derivation rules, yields the claimed new state root, withdrawal root and deposit-sync chain.

## 1. Design points

**The program trusts no input.** Inputs are prepared off-chain by the proposer and may be wrong or malicious. Every piece of data the program receives must match a commitment stored by the L1 contract; otherwise the program aborts and produces no proof.

| Input the program needs | Committed by the contract |
| --- | --- |
| L2 transaction data | At commit, the contract chains the hash of every blob into one chain; the program recomputes this chain |
| Deposits | Deposit roots are synced to L2 and accumulated into a chain value; the program only exports it, and the contract checks it |
| System configuration | Fixed in the rollup config; the hash of the config is registered in the contract |
| L1 block headers referenced by L2 blocks | Authenticated by walking back from the L1 block the contract recorded at commit |

The program does not treat L1 as a database to traverse and parse. It uses L1 only in the last row, and reads only three fields of the block header. So it has no L1 traversal phase, and its input needs no L1 transactions or receipts.

**Both ends of the range must be commit boundaries.** The contract stores the batch hash only at the end of each commit, so the program's start and end can only fall on these positions.

---

## 2. Public values

The public values are what the proof declares to the outside. The program outputs them unchanged and asserts internally that its computed results match them:

| Public value | Meaning | Who checks it |
| --- | --- | --- |
| L2 chain ID | Which chain the proof belongs to | Contract configuration |
| Rollup config hash | The chain parameters the program uses, for example the activation height of each upgrade | Contract configuration |
| Start batch hash | The chained hash the contract stores at the start commit boundary | Contract storage |
| End batch hash | The chained hash the contract stores at the end commit boundary | Contract storage |
| Start output root | Commitment to the start L2 state | Contract storage |
| End output root | Commitment to the end L2 state | The contract recomputes it from the components submitted by the caller |

Here the output root is the Metis variant of the OP Stack output root, with one more value folded in, the deposit-sync chain:

```
outputRoot = keccak256(abi.encode(version, stateRoot, withdrawRoot, depositSyncChain, blockHash))
```

`version` is initially `bytes32(0)`.

Notes:

- **Why an output root instead of exporting the values separately** 
  
  The four quantities block hash, state root, withdrawal root and deposit-sync chain are all uniquely determined by the end state (the latter three are read from the block header or from the state root through the MPT). The benefits of folding them into one value:
  
  - The public values drop from 13 fields to 6;
  - The aggregation continuity checks drop from three to two;
  - The contract's comparison logic is shorter; it only needs one more keccak to restore the preimage supplied by the caller;
  - It follows the OP Stack output root practice: the caller submits the preimage components and the contract recomputes the hash. But there are five components rather than four, and withdrawals are proven by a Merkle path rather than a storage proof, so OP's off-chain tooling cannot be reused directly;
  - Once folded into one value, the proof's public values contain only one commitment. When components are added or removed later, neither the public values format nor the aggregation program needs to change; only the range program and the one place in the contract that recomputes the output root do.
  
- **Why the output root contains the block hash**

  The next proof continues execution from here and needs to know the previous block's number, timestamp and other fields. A state root alone cannot constrain these; the block hash can.

---

## 3. Inputs

| Input | Content | How it is constrained |
| --- | --- | --- |
| Preimages | State trie nodes, contract bytecode, L2 block headers and L1 block headers, given in the form "hash → content" | The hash of each entry is recomputed; the required hashes in turn come from data already checked |
| blob | Blob content with its KZG commitment and proof | KZG verification, then bound by the recomputation of the batch hash |
| rollup config | Chain parameters | Its hash must equal the config hash in the public values |
| commit anchors | The L1 block hash corresponding to each commit in the range | Folded into the batch hash and checked together with it |
| Start state components | The five constituent values of the start output root | Their hash must equal the start output root in the public values |

No field in the input is "trusted directly".

**How the input is generated.** Which state the program reads during execution is known only by actually executing it. So the proposer first runs the same program on an ordinary machine, lets it fetch data over the network, and records every item it accesses. This record is the preimage input. The later execution inside the zkVM is deterministic and accesses exactly the same data.

---

## 4. Execution flow

| Phase | What it does | What it guarantees |
| --- | --- | --- |
| 1. Check inputs | Verify the preimages, verify the blobs, recompute the batch hash, locate the start | The data in hand is the data the sequencer submitted to L1, and the start is the state the contract recognizes |
| 2. Derive and execute | Decode L2 blocks blob by blob, authenticate the L1 block headers they reference, execute block by block | The end state is indeed computed from this data |
| 3. Wrap up | Confirm all data is used up, read out the withdrawal root and the deposit-sync chain, check the end | It did not stop early, and the output end matches the claimed one |

### 4.1. Check inputs

1. **Verify the preimages.** Recompute the hash of each entry and confirm it matches its key.
2. **Verify the blobs.** Verify the KZG proof of each blob, confirm the content corresponds to the commitment, then compute the blob's hash from the commitment. Also reject blobs that contain non-canonical field elements.
3. **Recompute the batch hash.** Starting from the start chain value, append the hash of each blob in order; at the last blob of each commit, also fold in that commit's L1 anchor. The result must equal the value the contract stores for the end commit. The computation rule is exactly the same as the contract's `commitBatches`.
4. **Locate the start.** Confirm the start state components hash to the start output root, then take the start block header and begin execution from its state root.

Step 3 fixes four things at once: the number, order and content of the blobs, and the L1 anchor of each commit. A duplicated, reordered or missing blob, or a replaced anchor, gives a different result.

If the anchors are not used up exactly, the range stops in the middle of a commit, and the program rejects it.

### 4.2. Derive and execute

**Derivation: from blob to L2 blocks.** Each blob holds exactly one Metis span batch. Decoding has four layers:

1. **blob → bytes.** Restore the bytes under the OP Stack blob encoding. Reject blobs whose length is out of bounds or that have extra trailing data.
2. **bytes → channel.** Assemble the channel under the OP frame format. One blob should close one channel.
3. **channel → span batch.** Decompress with brotli, then parse. The decompressed output has an upper limit, to prevent malicious data from exhausting memory.
4. **span batch → blocks.** The first block number must immediately follow the last executed block, the parent block hash must match, and the referenced L1 blocks must pass the authentication below.

The order of the blobs is already fixed by the batch hash, so derivation is only a deterministic decoder.

**Authenticating L1 block headers.** Each L2 block references an L1 block (called the L1 origin), and execution uses its block number, timestamp and basefee.
The program must confirm these block headers are really on the L1 canonical chain:

- **Start from the anchor.** Take the anchor of the last commit in the range, that is, the parent block hash of the L1 block that contains that commit. It was already checked against contract storage in phase 1 and cannot be forged.
- **Walk back along parent hashes.** Starting from the block header that corresponds to the anchor, take parent block headers one by one until the oldest L1 origin.
- **The L1 origin must be on this path.** The L1 block a batch references is always earlier than the L1 block that submits it, so it must be found; if it is not found, the program fails.

See l1-anchor.md for the scheme.

**Execution.** For each decoded L2 block:

1. **Assemble the block input.** The block number, timestamp, L1 information and transaction list all come from the blob or from authenticated L1 block headers. "Hint" values given separately in the input are not accepted.
2. **Execute the transactions.** The EVM behavior must match the pinned version of the Metis node exactly, including METIS as the gas token, the computation of the L1 data fee, Metis's system contracts and the activation height of each upgrade.
3. **Read and write state.** State trie nodes are fetched by hash from the verified preimages.
4. **Produce the block header.** Compute the new block hash, which becomes the parent of the next block.

Derivation and execution are interleaved block by block.

**L1-enqueued (queue-origin) transactions are always rejected.** Metis's old deposit path puts transactions that claim to come from L1 into batches. The program has no commitment against which to check their authenticity; accepting them would be the same as allowing the sequencer to forge L1 inputs. In the new design, deposit syncs and claims are ordinary L2 transactions and are not affected.

### 4.3. Wrap up

1. **Confirm everything is used up.** All blobs are decoded, all anchors are folded in, and every block is executed. This step prevents the program from executing only part of the data and reporting success.
2. **Read out the two bridge-related values.** Read the L2 bridge's withdrawal root and deposit-sync chain from the end state. Both are read from the state trie; values given directly in the input are not accepted.
3. **Check the end.** Compute the output root from the end state root, withdrawal root, deposit-sync chain and block hash; it must equal the end output root in the public values.
4. **Output the public values.**

---

## 5. Linking with aggregation

The aggregation program verifies several range proofs and checks that each adjacent pair connects end to start: the end batch hash of the earlier one equals the start batch hash of the later one, and likewise for the output root.

It also checks that the chain ID and config hash of all ranges are the same.

The range program itself completes all data verification and execution; aggregation does not re-execute any block.

---

## 6. Security checklist

| Threat | Defense |
| --- | --- |
| Forging or tampering with blob content | KZG verification; the blob's hash enters the batch hash |
| Adding, removing or reordering blobs | The batch hash includes the index and the order; the anchors must be used up exactly |
| Starting from the wrong block | The start block hash is in the start output root |
| Tampering with the end state, withdrawal root or deposit-sync chain | The four components are folded into the end output root and asserted |
| Executing only part and claiming success | The wrap-up confirms all blobs and blocks are used up |
| Tampering with state trie nodes or bytecode | Preimage hash verification, verified layer by layer downward from the state root |
| Forging L1 block headers | Authenticated by walking back along parent hashes from the commit anchor |
| Forging a commit anchor | The anchor is folded into the batch hash, which the contract checks |
| Forging transactions from L1 | L1-enqueued transactions are rejected |
| Forging a deposit root | The program exports the complete deposit-sync chain on L2; the contract rebuilds it from L1 history and checks it |
| Specifying the withdrawal root or the chain value directly | Both can only be read from the end state trie |
| Decompression bomb, overlong channel | A fixed decompression limit and a fixed channel size limit |
| Inconsistent configuration | The config hash enters the public values and is checked by the contract |
| Replay to another chain | The chain ID enters the public values |
