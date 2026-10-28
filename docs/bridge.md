# Metis bridge protocol and cost model

This proposal turns Metis into a validity-proven rollup bridge. Raw L2
transactions are published in Ethereum blobs. L1 records each batch's blob
versioned hash at commit and, once a Ziren proof is verified, the latest L2
state root and the L2 withdrawal tree root. Deposits enter an L1 deposit tree
that L2 syncs and verifies before minting. The [cost model](#cost-model)
compares this design with Metis's measured publication costs, and
[optimizations](#optimizations) ranks further savings.

The [output oracle](../contracts/metis-output-oracle/) in this repository
implements the earlier design, which proves batches already appended to Metis's
state commitment chain (SCC). This document supersedes that design. The rollup
contract, bridges, guest and messenger changes below are not yet implemented;
prototype contracts were measured outside the repository on
[real Metis batches](#measurements-on-real-metis-batches).

## Overview

```mermaid
flowchart LR
    D[User deposits on L1] --> DT[L1 deposit tree]
    DT --> S[Sequencer syncs root to L2]
    S --> M[L2 verifies Merkle path and mints]
    T[L2 transactions] --> B[Blob transaction commits batch hash]
    B --> P[On demand: Ziren proof of the range]
    P --> F[L1 stores state root and withdrawal root]
    W[L2 withdrawal appended to withdrawal tree] --> F
    F --> R[Relay withdrawal with Merkle path]
    R --> E[L1 bridge releases escrow once]
```

| Location | State |
| --- | --- |
| Ethereum blobs | Raw L2 transactions of each batch: the data availability |
| L1 rollup contract | Chained batch hash at each commit boundary; per finalized batch, `finalizedStateRoots[i]` and `withdrawRoots[i]`; the last finalized deposit-sync chain |
| L1 bridge | Append-only deposit tree and its root after every deposit; escrow; relayed-withdrawal bitmap |
| L2 bridge | Synced deposit roots, deposit-sync chain and claimed bitmap; append-only withdrawal tree |

The state root is the `l2geth` execution state root of the last block in the
finalized range. Per-block state roots are not published on L1: withdrawals
prove against the withdrawal root, and the next proof starts from the stored
state root.

## Batch commitment

The sequencer publishes each batch in a type-3 transaction that calls
`commitBatches(parentBatchHash, lastBatchHash)`. For every blob `i` carried by
that transaction the contract computes

```text
batchHash = keccak256(0x01 || uint64(batchIndex) || parentBatchHash || BLOBHASH(i))
```

and stores only the last hash. The commit is accepted only if the parent equals
the stored hash and the computed chain equals `lastBatchHash`. Reading
`BLOBHASH` in the transaction that carries the blob shows that Ethereum
published that data; a hash supplied in calldata would not. One Osaka
transaction can carry at most 6 blobs
([EIP-7594](https://eips.ethereum.org/EIPS/eip-7594)).

This replaces three transactions per batch today: the SCC state-root append,
the inbox reference and the separate blob upload. Metis nodes must derive
batches from the commit transaction's blobs instead of the inbox reference, so
the derivation format changes. Unfinalized batches may be reverted by an
authorized party; finalized batches may not.

Metis blobs already use the OP Stack blob encoding (version 0, 127 bytes per 4
field elements), OP channel frames and brotli compression. Each blob in the
sample holds one Metis span batch, whose prefix is the first L2 block number
followed by parent and L1-origin checks
([`span_batch.go`](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/go/op-program/client/derive/span_batch.go)).

## Deposits

1. A user deposits on the L1 bridge. The bridge escrows the asset, appends
   `keccak256(abi.encode(l1ChainId, l1Bridge, index, from, l2Recipient, token,
   amount))` to a depth-32 append-only Merkle tree, and stores the root after
   that deposit as `depositRootAt[index + 1]`.
2. The sequencer syncs a root and its deposit count to the L2 bridge, in
   increasing count order. The L2 bridge extends
   `depositSyncChain = keccak256(abi.encode(depositSyncChain, count, root))`.
3. Anyone claims a deposit on L2 with its index and Merkle path against a
   synced root. The L2 bridge checks the path, marks the index claimed and
   mints the same amount.
4. Finalization takes the synced counts as calldata and rebuilds the chain from
   the L1 root history. The proof must export the L2 chain value, so every root
   L2 accepted is checked against L1, not only the latest. Checking only the
   latest would let a sequencer sync a false root, mint against it and then
   sync the true root before the range ends.

Because the tree is append-only, a root at count `n` commits to every earlier
deposit, and the claimed bitmap prevents a second mint across roots. This
replaces the canonical transaction chain's enqueue path for deposits. Metis
span batches carry queue-origin (L1) transactions, so after activation the
guest must reject them or bind them in the same way. The rollup
must also bound censorship: require that finalization syncs deposits older than
a published deadline, or provide a forced-inclusion path like
[Polygon zkEVM's forced batches](#polygon-zkevm). This rule is not yet
specified.

## Withdrawals

Every L2-to-L1 withdrawal appends
`keccak256(abi.encode(index, l2Sender, l1Recipient, token, amount))` to a
depth-32 append-only tree in the L2 bridge, whose root is kept in L2 state. The
guest exports that root at the end of the proven range, and finalization stores
it as `withdrawRoots[batchIndex]`. The leaf should additionally bind the L2
chain ID and bridge address before deployment.

To relay, anyone supplies the batch index, the withdrawal fields and its
32-node path. The L1 bridge checks the path at the leaf's own index, which
prevents proving an interior node, marks the index relayed and releases escrow.
Because the tree is cumulative, a withdrawal can be relayed against any finalized
batch at or after the one that includes it.

## Proof statement and guest

The proof's public values bind:

| Value | Source on L1 |
| --- | --- |
| L2 chain ID, program key | Rollup configuration |
| Previous batch hash and state root | Stored at the last finalized batch |
| Number of batches and new batch hash | Committed batch-hash chain |
| New state root, withdrawal root | Caller; stored on success |
| Previous and new deposit-sync chain | Stored chain, extended from `depositRootAt` |

The verifier checks the proof against the SHA-256 of these values. The guest
must, in order:

1. Recompute the batch-hash chain from the previous batch hash and each blob's
   versioned hash, and check it against the committed hash.
2. Authenticate each blob: check `0x01 || sha256(commitment)[1:]` equals the
   versioned hash, then verify the blob's KZG proof. The host computes the
   commitment and proof with c-kzg, because the beacon blob API no longer
   serves proofs after Fusaka. Reject non-canonical field elements, a
   duplicated or reordered hash and a short or trailing payload.
3. Decode the blob, frames, channel and span batch, and reproduce Metis
   derivation and `l2geth` execution exactly from the previous state root.
   The derived ending block must equal the committed range.
4. Execute deposit syncs and claims as ordinary L2 transactions, and export the
   final `depositSyncChain` and withdrawal root read from L2 state.

Pin the deployed Andromeda node release, fork rules and decoding first. The
repository's [Go fault-proof program](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/go/op-program/client/program.go)
is candidate code. Its [oracle client](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/go/op-preimage/oracle.go)
returns bytes unchecked, and its host-side
[`WithVerification`](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/go/op-preimage/verifier.go)
passes blob field elements through unverified. Proved execution must check
every preimage, trie witness and blob. Mainnet use of this program has not been
established; differential replay against the pinned production node on real
batches must match every state root. Reconcile its configuration's
`L1ChainId=1088` with Ethereum chain ID 1 before porting it.

### Blob authentication choice

Production rollups bind blob contents in one of three ways
(research date 2026-10-28):

| Family | Projects | L1 cost per proof |
| --- | --- | --- |
| Circuit evaluates the blob at a hash-derived point; L1 calls the point-evaluation precompile per blob | Scroll v1 to v6, zkSync Era, Linea, Starknet | 50,000 gas per blob |
| Guest or circuit verifies the KZG opening itself | Scroll v7, Taiko, ZKsync OS, OP Succinct, Kailua | None |
| Batched equivalence, one precompile call per proof | Aztec | 50,000 gas |

None recomputes the full commitment in a zkVM in production. Use the second
family: per-blob precompile calls would consume the verifier's remaining gas
under the transaction cap as batches accumulate. Ziren provides BLS12-381 G1
add/double/decompress and Fp/Fp2 syscalls but no pairing chip; the patched
[`kzg-rs`](https://github.com/ziren-patches/kzg-rs/tree/35725e54518a1b56ec908d12e77f3fc9891f643d)
and [`bls12_381`](https://github.com/ziren-patches/bls12_381/tree/1bee78db02337751d5334437c1bb3fe244e283d7)
build the pairing from those. The `bls12_381` patch takes `zkm-lib` from Ziren
without a revision; lock it to the approved Ziren revision. With aggregation,
range proofs can commit each blob's opening and the aggregation guest can verify
all of them with one batched pairing check.

## Ziren integration

Ziren produces the shrink proof of the authenticated Metis state transition.
[Ziren #568](https://github.com/ProjectZKM/Ziren/pull/568) supplies the shrinker;
OPSuccinct owns the [exporter](../crates/ziren-shrink-export/) and
[Solidity verifier](../contracts/ziren-shrink-verifier/). The compact shrink is
terminal and commits the root digest, covering the application key, the
committed-value digest, the exit code and the recursion root. The rollup calls
the verifier through `verify(bytes proofPacket, bytes32 expectedOutputDigest)`.

The recorded verification transaction used **13,668,039 gas**, including its
182 KB packet's 2,834,640 calldata gas, for an Ethereum-block guest on a local
Osaka node enforcing the 16,777,216-gas transaction cap. Deployment of all
modules used 141,599,268 gas. Proof geometry does not grow with the number of
batches for a fixed shrink profile; rerun the measurement for every approved
build and the real Metis guest.

## Demand-driven finalization

Commits continue with every batch; finalization need not. If no withdrawal or
other consumer needs newer finalized state, the operator may defer proving and
verification. Waiting never finalizes a batch. When a withdrawal needs batch
`K`, one proof can finalize every committed batch from the last finalized batch
through `K`, because the contract checks only the two chained hashes at the
range ends. There is no per-proof batch limit on L1; proving capacity and guest
memory bound the range instead.

Proof generation can run in the background or on demand. Ethereum keeps blobs
for about 18 days, so the operator must archive blob data, with each blob's
commitment, for any range it may prove later. The
[catch-up costs](#demand-driven-catch-up) cover idle periods. The current SCC
oracle in this repository still accepts at most 64 batches per proof.

## Measurements on real Metis batches

Sample: 40 consecutive Andromeda blobs in Ethereum blocks 26,282,691 to
26,289,347, covering L2 blocks 23,328,412 to 23,332,790 (4,379 blocks, 7,267
transactions, about 23.2 hours) on October 28. Every blob held one span batch,
one blob per transaction; 38 matched SCC batches block for block, and the last
two had not yet been appended. Blobs were on average 32% full, 57% at most, with
109.5 blocks and 182 transactions per batch.

**In-guest blob authentication and decoding.** The guest checked each blob's
versioned hash and KZG proof with the patched crates, then decoded it through
brotli to the span-batch header. Executed on Ziren `82ceeae`:

| Blobs | KZG verification | Decoding | Total instructions |
| --- | --- | --- | --- |
| 1 | 17.9M | 4.9M | 22.8M |
| 8, one at a time | 143.2M | 42.0M | 185.3M |
| 8, batched | 116.9M | 42.0M | 159.0M |
| 40, batched | 534.5M | 257.1M | 791.7M |

Batched verification costs about 13.4M instructions per blob, and the whole
check about 181,000 instructions per L2 block. These are executor instruction
counts: precompile work adds rows to its own chips, so proving time and trace
area remain to be measured. The guest was built with the `zkm` toolchain dated
2026-01-08 because the 2026-09-17 toolchain was unavailable on this machine.

**L1 and L2 gas.** Prototype contracts on a local Osaka node, committing the
exact mainnet blobs and finalizing with the real Metis state roots and a no-op
verifier:

| Path | Gas |
| --- | --- |
| Commit, one blob per transaction | 54,332 (first commit 71,432) |
| Commit, six blobs per transaction | 65,765, about 11,000 per batch |
| Current Metis publication per batch | About 342,300 over three transactions |
| Finalize, excluding the verifier | 74,046 to 117,702, independent of batch count |
| L1 deposit with tree append (mock token) | 104,306 to 153,522 |
| L1 withdrawal relay, 32-node path | 95,804 |
| L2 deposit-root sync | 88,694 |
| L2 deposit claim and mint | 81,422 to 98,518 |
| L2 withdrawal append | 122,240 |

The L2 figures use Ethereum's gas schedule; Metis's own schedule must be checked.
At the sample's 38 batches/day, single-blob commits save about 288,000 gas per
batch, about **$6.5/day at 0.25 gwei**. The blob fee is unchanged. Real Metis
deposits currently use 209,784 to 218,602 gas through a different token and
path, so they are not a like-for-like comparison. The sample contained only
four L1-to-L2 messages and one withdrawal, so per-message costs matter less
than commit and verification costs. The [cost model](#cost-model) prices these.

## Cost model

A production configuration needs a cost budget and a measured
withdrawal-latency target; fitting a proof under the transaction gas cap
establishes neither. Budget the system as:

```text
new_cost = publication + proving + L1_verification + deposits_and_relays
         + additional_operations + amortized_deployment_and_engineering
```

User-paid METIS fees, sequencer rewards and subsidies need separate cash-flow
accounting from ETH expenditure and compute. Faster withdrawals can reduce
capital tied up or third-party fast-bridge charges, but those benefits require
actual withdrawal demand and pricing.

Dollar amounts use a fixed **$2,385.65/ETH**, observed from
[Blockscout's ETH statistics endpoint](https://eth.blockscout.com/api/v2/stats)
on October 23. This is neither a historical execution-time rate nor a forecast.
At 0.25 gwei, one million gas costs about **$0.60**.

### Observed L1 publication costs

This is a historical, one-day sample for Andromeda, chain ID 1088:
**2026-10-22 00:00:00 UTC inclusive to 2026-10-23 00:00:00 UTC exclusive**
(October 22 08:00 to October 23 08:00 in Asia/Ulaanbaatar), Ethereum blocks
**26,244,425 through 26,251,600 inclusive**. The independently checked boundary
block hashes are:

- [26,244,425](https://eth.blockscout.com/block/26244425):
  `0x552fecbcf2a2473c1eff4c2e3909cf8b69c8c590054cebc4c62c23152bf63774`.
- [26,251,600](https://eth.blockscout.com/block/26251600):
  `0x931a7582b743fd6b599f6999210ac488d4c03d24fae67492c36a22e5f31da0ab`.

| Path | Destination | Sender |
| --- | --- | --- |
| SCC state batches | `0xA2FaAAC9120c1Ff75814F0c6DdB119496a12eEA6` | `0xf3CEB4C2ef996CdBc95C4E18c6D0CA988CC09040` |
| Inbox references | `0xFf00000000000000000000000000000000001088` | `0x1A9da0aedA630dDf2748a453BF6d92560762D914` |
| Blob publication | Same inbox | `0xaE4d46bD9117Cb017C5185844699c51107cB28a9` |

| Component | Count | Paid ETH | USD |
| --- | --- | --- | --- |
| SCC execution | 38 transactions | 0.003087289887304141 | $7.37 |
| Inbox-reference execution | 38 transactions | 0.000242373287438100 | $0.58 |
| Blob-transaction execution | 38 transactions | 0.001093722012117000 | $2.61 |
| Blob data | 38 blobs in those same blob transactions | 0.000096186904215552 | $0.23 |
| **Total** | **114 distinct transactions** | **0.004519572091074793** | **$10.78** |

Rounded dollar amounts need not sum to the rounded total. The SCC calldata
contains 4,795 state roots covering L2 blocks 23,303,500 through 23,308,294. The
[L2 explorer's daily chart](https://andromeda-explorer.metis.io/api/v2/stats/charts/transactions)
reported 9,052 transactions for October 22; dividing gives about $0.00119 as a
calendar-day normalization, not a measured per-transaction cost or user fee.

This sample is **not Metis's total operating expense**. It excludes other L1
activity, deposits and relays, node and MPC infrastructure, RPC and archive
services, staffing, incentives and off-chain publication charges. Receipts
establish sender expenditure, not who funds it. One day does not establish a
long-term average.

All 38 blob transactions paid an effective priority fee of 1 gwei, about
**$1.90** of their execution fees; their effective price was 1.37 gwei against
0.254 gwei for the SCC appends.

#### Accounting and reproduction

Discover transactions from the paginated Blockscout lists for the
[SCC](https://eth.blockscout.com/api/v2/addresses/0xA2FaAAC9120c1Ff75814F0c6DdB119496a12eEA6/transactions?filter=to)
and [inbox](https://eth.blockscout.com/api/v2/addresses/0xFf00000000000000000000000000000000001088/transactions?filter=to).
These are live endpoints: start at the latest page and follow
`next_page_params` past the start of the sample. Filter by the half-open UTC
interval, destination and sender, and deduplicate hashes. Use integer wei:

```text
execution_fee_wei = gasUsed * effectiveGasPrice
blob_fee_wei      = blobGasUsed * blobGasPrice     # zero for non-blob transactions
total_ETH         = sum(execution_fee_wei + blob_fee_wei) / 10^18
```

The explorer's `fee.value` contains execution fees only; add blob fees
separately. Do not use `maxFeePerGas` or `maxFeePerBlobGas`, which are caps, and
do not add the priority fee again. All 114 receipts were checked through
`https://ethereum-rpc.publicnode.com` for status, block range, sender,
destination and both fees. For each sender, the transactions immediately before
and after the window differ in nonce by 39, so all 38 are present. Decode SCC
transactions with
`appendStateBatchByChainId(uint256,bytes32[],uint256,string,bytes32,uint256)`
and require chain ID 1088, contiguous start elements and
`lastBatchBlockNumber = shouldStartAtElement + batch.length`. Raw responses and
ledgers stay outside Git.

### Publication under this design

The 60 most recent SCC appends on October 28, ending at block 26,289,198,
averaged **298,068 gas**: 57,435 of calldata (about 530 per root) and execution
of about 143,908 + 697 per root by least squares, with 108.6 roots on average.
Together with the 23,250-gas inbox reference and the 21,000-gas blob
transaction, Metis spends about **342,300 gas per batch**. A
[measured](#measurements-on-real-metis-batches) single-blob commit uses
**54,332 gas** and replaces all three. The blob fee is unchanged: a sampled
blob paid 294.9 gwei at block 26,289,187, about 6,650 gas at that block's base
fee ([EIP-7918](https://eips.ethereum.org/EIPS/eip-7918) ties the blob price
to the execution base fee).

The saving depends on what the commit transaction pays per gas, because it
moves the SCC's execution into the blob uploader's transaction. At a uniform
0.25 gwei, the 288,000 gas saved per batch is about **$6.5/day** at 38
batches/day. Applied to the October 22 sample's actual prices, with 38 commits
and the same blob fees:

| Commit pricing | New publication per day | Against $10.78 |
| --- | --- | --- |
| SCC's 0.254 gwei effective price | $1.48 | Saves $9.30 |
| Uploader's 1.37 gwei effective price (1 gwei tip) | $6.98 | Saves $3.80 |

At the uploader's current 1-gwei tip, about $4.93/day of the new cost is tip.
An adaptive priority-fee policy is worth a controlled inclusion-latency test;
bidding less must not silently stop publication.

### Proof-verification budget

The recorded [verifier measurement](../contracts/ziren-shrink-verifier/README.md)
uses an Ethereum-block guest, not a Metis guest:

| Evidence | Gas | Scope |
| --- | --- | --- |
| Complete verifier transaction | 13,668,039 | Includes its 182 KB calldata; fixed build and packet |
| Prototype finalize overhead | 117,702 | Measured with a no-op verifier, one deposit sync and a withdrawal root |
| Sum | 13,785,741 | Estimate, not a complete transaction measurement |
| All verifier-module deployments | 141,599,268 | One-time total across transactions |

Use **13.8M gas per finalization** as a scenario input. Finalize overhead does
not grow with the number of batches. For `n` finalizations per day at price `p`:

```text
L1_verification_USD_per_day = n * 13,800,000 * p_gwei * 10^-9 * 2,385.65
```

| Periodic scenario | Finalizations/day | At 0.25 gwei | At 1 gwei |
| --- | --- | --- | --- |
| Every batch | 38 | $312.44 | $1,249.74 |
| Every 2 hours | 12 | $98.66 | $394.66 |
| Every 6 hours | 4 | $32.89 | $131.55 |
| Every 24 hours | 1 | $8.22 | $32.89 |

These exclude proving, relays and deployment. The verifier deployment costs
about $84.45 at 0.25 gwei or $337.81 at 1 gwei; the prototype rollup and L1
bridge deployed for about 1.5M gas more. Charge replacement deployments when
approving new builds, not to every proof.

### Demand-driven catch-up

With no pending withdrawal, no finalization is required and its expense is
zero; commits, proving policy and infrastructure continue. When demand arrives,
one finalization covers every committed batch since the last one:

| Demand scenario | Backlog | Finalizations | At 0.25 gwei | At 1 gwei |
| --- | --- | --- | --- | --- |
| No demand | Any | 0 | $0 | $0 |
| Request after one day | 38 batches | 1 | $8.22 | $32.89 |
| Request after seven days | 266 batches | 1 | $8.22 | $32.89 |

Under the current SCC oracle the seven-day case needed at least five
submissions. Proving all intervening batches remains: catch-up shifts cost to
proving capacity and latency, not away from it. The proof must still be
generated within blob retention or from archived blobs, and a very large range
may need several range proofs aggregated before one L1 verification.

The scheduler should coalesce requests with explicit deadlines and a gas-price
budget, finalize at a target that serves them, reuse already proven ranges and
avoid terminal proofs that will immediately be superseded. If waiting for
cheaper gas would violate a deadline, submit within the funded policy or
surface the failure.

### Proving compute budget

The cost model uses **$400/month** for proving ($13.33/day). It covers range
proving, aggregation, shrink, retries and startup on rented GPUs.

For reference, [vast.ai](https://vast.ai) rents an RTX 5090 (32 GB) by the hour:
across 53 verified on-demand single-GPU offers on **2026-10-28**, the median was
$0.828/hour (cheapest $0.476, 25th percentile $0.670), excluding bandwidth. At
the median, $400/month is about 483 GPU-hours, about 16 hours a day.

The measured part of the guest so far is DA authentication and decoding: about
13.4M executor instructions per blob for batched KZG verification and 6.4M for
decoding, or about 181,000 per L2 block. Precompile work adds rows to its own
chips, so these counts are not proving time.

### Monthly scenarios

At October 27 conditions (0.149 gwei effective, $2,354.27/ETH, 42 batches/day,
30 days), with proving at $400/month:

| Scenario | Commits and blobs | Verification | Proving | Total/month |
| --- | --- | --- | --- | --- |
| Metis today: publication only, no validity proofs | $210 | — | — | **$210** |
| One blob per commit, 1-gwei tip kept, native proof finalized daily | $188 | $145 | $400 | **$733** |
| Same with an adaptive low tip | $27 | $145 | $400 | **$572** |
| Low tip, blobs about 90% full, native proof finalized weekly | $10 | $21 | $400 | **$431** |
| Low tip, blobs about 90% full, SNARK proof finalized daily | $10 | $5 to $7 | $400 | **$416** |

The SNARK row assumes 300,000 to 500,000 verification gas and that wrapping
fits in the proving budget; both need measurement. Proving is about 93% of the
optimized total, and the optimized L1 spend (about $15 to $31 a month) is lower
than today's $210. Finalization gas scales with the L1 price: at 1 gwei a daily native
finalization costs about $975/month, the SNARK terminal tens of dollars.

### Deposits and relays

Measured on the prototypes: an L1 deposit with tree append used 104,306 to
153,522 gas with a mock token, an L1 relay 95,804 and an L2 claim 81,422 to
98,518 (L2 figures use Ethereum's schedule). Metis deposits currently use
209,784 to 218,602 gas through a different path. The October 28 sample had
four L1-to-L2 messages and one withdrawal in 23.2 hours, so these costs are
small beside commits and verification at current demand. Who pays them, users
or the operator, is a policy choice.

## Optimizations

Research dates: **2026-10-23** and **2026-10-28**. These are proposals, not
implemented savings.

| Priority | Optimization | Potential benefit | Evidence still needed |
| --- | --- | --- | --- |
| First | Cache range proofs, size ranges by workload, coalesce demand | Avoid duplicate proving and underfilled finalizations | Proposer, durable proof storage, demand and latency measurements |
| First | Compare native shrink with Ziren Groth16/PLONK terminals | Reduce the dominant 13.7M-gas verification | Same Metis workload, full transaction, wrapping compute, setup assessment |
| Next | Profile guest and native verifier; transport | Lower proving cost and per-finalization gas | Representative profiles, correctness and gas comparisons |
| Next | Tune commit tips; pack several batches per commit | Reduce publication cost | Inclusion-latency experiment and latency target |
| Later | Share withdrawal paths; avoid checkpoints | Reduce relay and anchor overhead | Relay demand and full-path measurements |

None of these allows proof-free finality. A pairing-based terminal changes
cryptographic and setup assumptions.

### Reuse proving work

Keep a persistent graph of authenticated range proofs, each with its range,
predecessor and resulting state, batch hashes, configuration, guest key and
recursion profile. When demand arrives, aggregate compatible cached ranges
through the target instead of rerunning execution. Keep constituent proofs
needed for other targets; an aggregate cannot generally be split. Reverting an
unfinalized commit invalidates proofs of it and its descendants. Persist blobs
and witnesses until replacement work can be reproduced. Tune range size
against measured trace area, memory and proving time; block count and EVM gas
are only heuristics. OP Succinct's
[proposer](https://succinctlabs.github.io/op-succinct/validity/proposer.html)
separates range production from externally driven aggregation, a useful
scheduling reference.

### Compare proof terminals

The pinned [Ziren SDK](https://github.com/ProjectZKM/Ziren/blob/82ceeae13222fcf8cd7532e516108a5ab71fe28d/crates/sdk/src/action.rs)
supports compressed, Groth16 and PLONK modes; its
[verifier documentation](https://docs.zkm.io/dev/verifier.html) describes BN254
verifiers. Benchmark native shrink and the SNARK pipeline from the same Metis
aggregation, with an adapter that preserves the guest key, exit code, recursion
allowlist and statement, and the SNARK interface's public-value digest masking:

```text
net_saving_USD_per_finalization =
    (G_native_full - G_snark_full) * p_gwei * 10^-9 * ETH_USD
    - (C_snark_terminal - C_native_terminal)
    - incremental_deployment_and_operations_per_finalization
```

The entire 13,668,039-gas verifier transaction costs about $8.15 at 0.25 gwei,
which bounds the saving. At low gas prices and infrequent finalization,
wrapping compute can outweigh it.

### Profile the guest and native verifier

Profile derivation, blob authentication, decoding, trie access, hashing,
signatures and execution before choosing guest optimizations. Ziren documents
[cycle tracking](https://docs.zkm.io/dev/optimizations.html) and
[precompiles](https://docs.zkm.io/dev/precompiles.html); use pinned patches
that preserve Metis semantics and replay differentially against the production
node. Record trace area, shards, GPU time and memory, not only instructions.

The recorded verifier transaction is 21,000 base gas, 2,834,640 calldata gas
and 10,812,399 execution gas. Several optimizations are
[already implemented](../contracts/ziren-shrink-verifier/README.md); profile by
kernel, WHIR opening, hashing, field arithmetic and module calls before the
next change. Preserve transcript challenges, hash widths and proof equations;
lowering soundness parameters is a separate security decision.

### Calldata and the transaction floor

Calldata is 20.7% of the verifier transaction. A hypothetical 50% cut saves
1,417,320 gas, about $0.85 per finalization at 0.25 gwei. Under
[EIP-7623](https://eips.ethereum.org/EIPS/eip-7623),
`gasUsed = 21,000 + max(4*T + execution, 10*T)` with
`T = zero_bytes + 4 * nonzero_bytes`; the recorded packet implies a
7,107,600-gas floor, which execution optimization alone cannot go below.

The proof packet cannot move to a blob with its hash in calldata. The EVM reads
only a blob's versioned hash and single-point evaluations at 50,000 gas each,
and a proof cannot authenticate its own bytes: an outer proof that checks it is
recursion, which is the terminal comparison above.

### Publication

Commits carry one blob each at about 32% average fill. Packing up to six
batches per commit costs about 11,000 gas per batch instead of 54,332, but at
38 batches/day it delays commitment by up to about 3.8 hours. Larger batches
would fill blobs further at a similar latency cost. Both need the
withdrawal-latency target first.

### Withdrawal paths and anchors

Relays against the same withdrawal root could share Merkle nodes in a bounded
multiproof, preserving per-withdrawal identity, recipient and replay
protection; measure relay demand first. The guest's L1-origin anchor can use
`BLOCKHASH` for recent blocks or
[EIP-2935](https://eips.ethereum.org/EIPS/eip-2935) history within 8,191
blocks where verified, with a checkpoint fallback for older anchors. These
save small overheads, not the dominant verification.

### Measurement gates

1. Complete the Metis guest, aggregation and contracts; reject missing,
   reordered, replaced or cross-chain inputs.
2. Prove representative quiet, withdrawal-heavy and expensive ranges; report
   proving time, trace area, memory, retries and p50/p95 catch-up latency.
3. Measure the complete finalize transaction with the real verifier and Metis
   guest under the transaction cap.
4. Compare native and SNARK terminals on identical statements and prices.
5. Measure withdrawal demand, then choose demand-driven, periodic or combined
   finalization. Keep publication, proving, verification, relays and
   deployment separate; do not sum overlapping savings or extrapolate one day
   into a monthly budget.

## Migration and safety

1. Activate at a batch boundary. Batches before it keep the existing SCC and
   fraud-window rules; snapshot the accepted state and resolve pending disputes
   before activation. Do not globally zero the fraud window.
2. Every post-activation finalization requires a valid proof. Elapsed time
   never finalizes a batch.
3. Proof-only finality halts withdrawals if no approved configuration can prove
   the chain. Governance approves a replacement guest and verifier that
   continues from the finalized state, behind a timelock and public notice.
4. Span batches still reference L1 origin blocks, so the guest authenticates
   those headers against an anchor that is a recent `blockhash` or a
   checkpointed hash. Deposits and DA no longer need it: they are bound by the
   sync chain and `BLOBHASH`.
5. Hash-based proof verification does not make blob KZG, signatures,
   consensus or governance post-quantum safe.

Activation requires the pinned Metis release and configuration, proofs of
authenticated real batches, tests of reverted and reordered commits, invalid
blobs, false deposit roots, double claims and relays, the legacy cutover, and
an end-to-end deposit and withdrawal.

## References

### OP Succinct and SP1

Pinned to OP Succinct `19c6d2d6b122a31c2a9aaedbb3dad76372bb7433` (2026-10-20).
Its [range program](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/utils/client/src/witness/executor.rs)
proves OP derivation and execution; the
[aggregation program](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/programs/aggregation/src/main.rs)
connects ranges under one L1 head. The
[`OPSuccinctL2OutputOracle`](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/contracts/src/validity/OPSuccinctL2OutputOracle.sol)
stores one output root per proof, which contains the state root and the
message-passer storage root. Blobs are not recorded on L1: the guest finds the
batcher's blob transactions under `l1Head` and verifies their KZG proofs with
SP1-accelerated BLS12-381
([`blob_provider.rs`](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/utils/client/src/oracle/blob_provider.rs)).
Its [range-height advisory](https://github.com/succinctlabs/op-succinct/security/advisories/GHSA-5jh4-3p33-85xc)
makes one test mandatory: the derived ending height must equal the claimed one.

### Scroll

Scroll's [`ScrollChain`](https://github.com/scroll-tech/scroll-contracts/blob/dfbd661520ac30505a773881728cc5cfb005978b/src/L1/rollup/ScrollChain.sol)
at `dfbd661` is the closest production match: `commitBatches` chains
`blobhash(i)` into batch hashes, and finalization stores the state root and
withdraw root of a bundle's last batch. Its
[`L1ScrollMessenger`](https://github.com/scroll-tech/scroll-contracts/blob/dfbd661520ac30505a773881728cc5cfb005978b/src/L1/L1ScrollMessenger.sol)
relays withdrawals with a fixed-length Merkle path. Scroll binds L1-to-L2
messages with a rolling queue hash rather than a deposit tree. On mainnet on
October 28 its commits used 65,931 to 67,927 gas with one blob.

### Polygon zkEVM

Research date 2026-10-28, pinned to
[`agglayer-contracts` `110bda5`](https://github.com/agglayer/agglayer-contracts/tree/110bda5a03e70ee7331bc06407a8e79226d3e520)
(the former `zkevm-contracts`) and
[`zkevm-rom` `d17ccaf`](https://github.com/0xPolygonHermez/zkevm-rom/tree/d17ccaf9c920697571fad8224e3922571fbb3d59).
Polygon zkEVM's unified bridge uses the same two-tree structure as this design;
its data availability and commitment differ.

| | Polygon zkEVM | This design |
| --- | --- | --- |
| Data availability | Transactions as L1 calldata, at most 120,000 bytes per batch; a validium variant uses a data committee. No blob path at this revision | Ethereum blobs |
| Batch commitment | `accInputHash = keccak(prev, keccak(transactions), l1InfoRoot, maxSequenceTimestamp, l2Coinbase, forcedBlockHashL1)` per batch, stored per sequence | `keccak(version, index, parent, BLOBHASH(i))`, stored per commit |
| Proof input | `sha256(sender, oldStateRoot, oldAccInputHash, initNumBatch, chainID, forkID, newStateRoot, newAccInputHash, newLocalExitRoot, finalNewBatch)`; FFLONK over BN254 | Ziren shrink over SHA-256 public values; no prover address |
| Stored on verification | `batchNumToStateRoot[finalNewBatch]` and the latest local exit root, folded into a global exit root kept in a history map | `finalizedStateRoots[i]` and `withdrawRoots[i]` |
| Withdrawals | L2 bridge's depth-32 local exit tree; an L1 claim proves the leaf under the local exit root, that root under the rollup exit root, and that the global exit root exists | Depth-32 L2 tree; relay proves the leaf under `withdrawRoots[i]` |
| Deposits | L1 bridge's depth-32 exit tree; each new global exit root becomes a leaf of the L1 info tree with `l1InfoRootMap[count]` | Depth-32 L1 tree with `depositRootAt[count]` |
| Binding synced roots | `sequenceBatches` binds an existing L1 info root into the batch; each L2 block names a leaf index and the ROM verifies its Merkle path before writing the global exit root to L2 storage ([`process-change-l2-block.zkasm`](https://github.com/0xPolygonHermez/zkevm-rom/blob/d17ccaf9c920697571fad8224e3922571fbb3d59/main/process-change-l2-block.zkasm)) | Sync chain rebuilt from `depositRootAt` at finalization |
| L2 claim | Proves the deposit leaf under the mainnet exit root of a known global exit root, then mints | Proves the leaf under a synced root, then mints |
| Censorship resistance | Forced batches: data posted to L1 with a fee, sequenceable by others after a 5-day timeout | Not yet specified |
| Revert | Unverified sequences only, by an admin role | Unfinalized commits only |
| Who verifies | Trusted aggregator role only | Not yet specified |
| Per-call limit | 1,000 batches | None |

Both deposit bindings ensure every root L2 accepts existed on L1, and both are
detected only at proving time. Polygon checks a Merkle path per L2 block
against a root bound at sequencing and stores one L1 info tree leaf per new
global exit root; this design adds nothing per deposit beyond the root history
and reads one stored root per synced count at finalization.

On mainnet, the zkEVM rollup
[`0x519E…0987`](https://eth.blockscout.com/address/0x519E42c24163192Dca44CD3fBDCEBF6be9130987)
last sequenced batches on 2025-12-03; its final sequences carried 38 to 77 KB of
calldata at 874,290 to 1,822,500 gas each. Its forced batches are restricted to
`forceBatchAddress` `0x242daE44F5d8fb54B198D03a94dA45B5a4413e21`, so they are not
permissionless. The rollup manager
[`0x5132…7aB2`](https://eth.blockscout.com/address/0x5132A183E9F3CB7C848b0AAC5Ae0c4f0491B7aB2)
now receives only pessimistic-proof verifications for other Agglayer chains.

Lessons for this design:

1. **Censorship resistance.** Adopt a forced-inclusion path: a user posts a
   transaction or deposit claim on L1, and after a timeout anyone may commit a
   batch containing it. Leave it permissionless, unlike Polygon's mainnet
   setting.
2. **Who may finalize.** Polygon permits only a trusted aggregator. Allow an
   approved prover, and anyone after a timeout as OP Succinct's
   `fallbackTimeout` does, so that a missing prover cannot stall withdrawals.
3. **Prover binding.** Polygon and OP Succinct bind the submitter's address in
   the proof input, which prevents copying a pending proof to claim a reward.
   Add it if finalization is rewarded.
4. **Leaf contents.** Polygon's leaves carry the origin network, origin token
   and a metadata hash so that one bridge can map many tokens. Extend this
   design's deposit and withdrawal leaves the same way if the bridge carries
   more than METIS.

### Pinned Metis observations

Read-only Ethereum snapshot at block **26,238,563**, hash
`0xf824bfc54c98f3492bbdf42cd6503fe6522faa00f72710b9404289a9bb0f0d56`:

| Component | Proxy |
| --- | --- |
| SCC | `0xA2FaAAC9120c1Ff75814F0c6DdB119496a12eEA6`; fraud window 604800 seconds |
| Messenger | `0x081D1101855bD523bA69A9794e0217F0DB6323ff` |
| Standard bridge | `0x3980c9ed79d2c191A89E02Fa3529C60eD6e9c04b` |

Inspected implementations: [SCC](https://eth.blockscout.com/address/0xa738573ec0fd7959bfa60aaa8a23fe7bec6c4bd7?tab=contract),
[messenger](https://eth.blockscout.com/address/0xc1ce5240b42ab158027095f658d530f9989b414f?tab=contract)
and [bridge](https://eth.blockscout.com/address/0xa0cfe8af2ab5c9232714647702dbacf862ea4798?tab=contract).
These are snapshot resolutions, not assertions about future proxy targets.
