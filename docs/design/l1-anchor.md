# L1 anchor: how the proof program confirms L1 block headers

Every Metis L2 block references an L1 block, called the L1 origin. Executing an L2 block uses its block number, timestamp and basefee.
The proof program must therefore confirm that these L1 block headers are really on the L1 canonical chain. This document describes the approach Metis adopts and why it was chosen.

---

## 1. Problem

The proof program runs in a closed environment and cannot know by itself which L1 chain is the real one. It can do only one thing: start from an **L1 block hash that the contract recognizes** and walk back along the parent block hash in each block header; the block headers it passes on the way are all trusted.

The question is **where this recognized hash comes from, who writes it into the contract, and when**. This hash is called the anchor.

## 2. Two schemes

Put simply, checkpoint anchoring is "after the proof is done, the proposer separately finds an L1 block to hang the proof on"; commit anchoring is "when the data goes on chain, the contract binds the current L1 position to the data along the way, and the proof can only use this position".

**A: checkpoint anchoring**

Each range proof picks an L1 block as its own anchor. Before merging, the proposer sends a transaction that makes the contract record the hash of an L1 block not earlier than the anchor of any range, called the checkpoint. The aggregation program then starts from the checkpoint, verifies a run of block headers backward along parent block hashes, and confirms that the anchor hash of every range appears on the walked path.

In detail:

- The anchor is chosen by the proposer after the fact. When proving, each range picks an L1 block as its `l1Head`, writes it into the public values, and proves every origin block header in the range to be its ancestor.
- Before aggregation the proposer takes the safe block at that time and calls the contract method `checkpointBlockHash`, which makes the contract read that block's hash with `blockhash(number)`, revert if it is zero (outside the 256-block window), and otherwise store it in `historicBlockHashes[number]`
- The aggregation guest then walks back along parentHash from this checkpoint to the `l1Head` of each range, and confirms that the anchor hash of every range appears on the walked path.
- At finalize, the contract checks that the checkpoint hash in the public values does exist in `historicBlockHashes`.
- Characteristics: the anchor is unrelated to the L2 data and is chosen independently; it needs one extra transaction, one extra mapping, and a run of block headers in aggregation; the anchor can be re-chosen at any time.

**B: commit anchoring (adopted)**

Each time the sequencer submits data, the contract reads the hash of the previous L1 block along the way, combines it with the batch hash, hashes once more and stores the result. When the proof program recomputes the batch hash it must use the same hash, or the result does not match. This hash is the anchor.

In detail:

- The anchor is produced automatically by the contract at the moment the sequencer submits data. When `commitBatches` executes, it reads `blockhash(block.number - 1)`, keccaks it together with the batch-hash chain value of this commit, and stores the result as `commitHashAt[lastBatch]`.
- The anchor is no longer a separate value; it is folded into the batch hash itself. The range guest must use the same anchor when recomputing the chain value, or the end batch hash it computes (`newBatchHash`) does not match contract storage. The range walks back from the anchor of the last commit in the range to authenticate all origin block headers.
- Aggregation only checks that the batch hashes of adjacent ranges link, and the contract only checks that the end batch hash of the last range equals `commitHashAt[endBatch]`. This one check binds both the data and the anchor.
- Characteristics: zero extra transactions, zero extra storage, and the parent block hash is always readable; once written, the anchor is valid forever, and the proof can be submitted at any time.

## 3. Comparison

| Dimension | A: checkpoint | B: recorded at commit |
| --- | --- | --- |
| Who decides the anchor | The proposer chooses | The contract writes it; nobody can choose |
| Extra L1 transactions | One more before each finalize, about 45,000 gas | None |
| Extra L1 storage | One storage slot per checkpoint | None; the anchor is folded into an existing value |
| Work in aggregation | Must verify a possibly long run of L1 block headers | Does not touch L1 |
| Work for the proposer | Choose the checkpoint, send the transaction, wait for confirmation, and handle two kinds of L1 reorg separately | Only needs to handle one case, a reorged commit |
| Range boundaries | Any batch | Must be commit boundaries |
| Protocol changes | None | None |
| Source of L2 timestamps | Verifiable | Verifiable |

## 4. Decision

**Adopt B.** Reasons:

1. Its security is not weaker than A's, and it removes the degree of freedom of a range choosing its own `l1Head`.
2. Each finalize needs one fewer checkpoint transaction, and the two-step dependency "aggregate only after the checkpoint is on chain" is gone.
3. It deletes the most error-prone piece of logic in the proposer (choosing the checkpoint, sending the transaction, the two kinds of reorg check) and one mapping in the contract (`historicBlockHashes`).
4. Zero protocol changes and zero extra storage.

## 5. Security argument

Let aggregation cover the commit boundaries `b_0 < b_1 < … < b_n`, where `b_0` is the current finalized one and `b_n = endBatch`.
`prevBatchHash` and `newBatchHash` are the field names of the start and end batch hashes in the public values.

- The contract guarantees `prevBatchHash = commitHashAt[b_0]` (from `finalizedAt`) and `newBatchHash = commitHashAt[b_n]`.
- The guest of each range starts from `prevBatchHash` and recomputes up to `newBatchHash` with the blobs and anchors in the witness; aggregation guarantees that the values of adjacent ranges continue one another.
- By the collision resistance of keccak, the inputs of every step of the recomputed chain (the versioned hash of each blob, each anchor) are the same as the inputs when the contract committed.
- Therefore the anchor each range walks back from is the `blockhash` the contract read at the corresponding commit, that is, a block on the L1 canonical chain at that time.
- If L1 later reorgs so that this block is no longer canonical, the commit transaction itself is no longer in its original block either; the value of `commitHashAt` will be different or absent, and the old proof cannot pass the contract's comparison; the proposer's commit reorg detection marks the affected range proofs as invalid and re-plans.

## 6. Cost

The start and end of a range must be commit boundaries. One commit holds at most 6 blobs, so the granularity is fine enough.

In addition, the range program must walk back from the anchor of the last commit in the range to the oldest L1 origin in the range. The more L1 blocks a range covers, the more block headers it must walk, at about 600 bytes plus one hash per block header. This depends only on the span of the range and not on how far finalize lags behind.
