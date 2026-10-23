# Metis optimization research

Research date: **2026-10-23**. This extends the [cost model](costs.md) and
[demand-driven finalization design](bridge.md#demand-driven-finalization).
The recommendations below are proposals, not implemented savings. The current
oracle still stores every proven batch and accepts at most 64 batches per proof;
the Metis guest, application aggregation and withdrawal integration remain
unfinished.

The baseline is the October 22 publication sample and the recorded Ethereum
guest verifier fixture, not a measured Metis proving pipeline. At the cost
model's illustrative 0.25 gwei and $2,385.65/ETH, saving one million gas saves
about **$0.60 per submission**. Prioritize fewer expensive verifier calls and
less repeated proving before small Solidity changes.

## Priorities

| Priority | Optimization | Potential benefit | Work and evidence still needed |
| --- | --- | --- | --- |
| First | Cache range proofs; adapt range sizes; coalesce withdrawal demand | Avoid duplicate execution proofs, unnecessary terminal proofs and underfilled submissions | Proposer, durable input/proof storage, aggregation guest, demand and latency measurements |
| First, architectural | Replace per-batch finality storage, then remove linear canonical-header reads | Lower oracle gas; potentially finalize a long idle backlog with one verifier call | Enforced SCC prefix immutability; authenticated history commitment; new statement and gas measurements |
| First, comparison | Benchmark native shrink against Ziren Groth16/PLONK terminals | Potentially reduce the dominant L1 verifier cost | Same Metis workload, full adapter transaction, wrapping compute and setup/security assessment |
| Next | Profile guest and native verifier; improve data layout and transport | Lower proving expense and the cost of each remaining submission | Representative profiles and complete correctness/gas comparisons |
| Next, operational | Tune publisher tips and batch policy | Reduce part of existing publication expense | Inclusion-latency experiment and deployment-specific publisher constraints |
| Later | Batch withdrawal witnesses; avoid unnecessary block-hash checkpoints | Reduce relay and checkpoint overhead | Messenger changes, historical-hash compatibility and full-path measurements |

Scheduling, caching and semantics-preserving implementation changes can retain
the existing proof assumptions. Changing the finality representation requires
a new protocol argument. A pairing-based terminal also changes cryptographic
and setup assumptions. None of these proposals allows proof-free finality.

## 1. Reuse proving work and size ranges by actual workload

Use a persistent graph of authenticated range proofs. Cache the range boundaries,
predecessor and resulting commitments, chain/configuration identifiers, guest
key, approved recursion profile and authenticated L1/DA context with each proof.
When demand arrives, aggregate compatible cached ranges through the requested
target. Do not rerun old execution merely to generate another terminal proof.
Retain the smaller constituent proofs when they are needed to serve different
target boundaries; an aggregate proof cannot generally be split afterward.

Cache identity must follow the proved statement, not an arbitrary encoding of
the proof. Reorgs, SCC suffix deletion/replacement and configuration changes
require revalidation or invalidation of affected descendants. Persist inputs
or witnesses until replacement work can be reproduced; a hash of unavailable
blob data is insufficient. Recursive aggregation must still enforce adjacent
heights, matching boundary states, complete execution and approved keys.

Tune range size against measured trace area/shards, memory and proving time.
Block count and EVM gas can be initial heuristics, but neither determines zkVM
cost. Larger ranges amortize setup and recursion; overly large ranges increase
memory, retry cost and the time until a reusable proof becomes available.
Compare CPU/GPU configurations by dollars per completed range at the latency
target, including idle capacity and failed jobs.

OP Succinct already separates range production from aggregation scheduling:
its [proposer documentation](https://succinctlabs.github.io/op-succinct/validity/proposer.html)
describes block/gas range limits and an optional externally driven aggregation
mode that continues range production while a coordinator requests aggregation.
This is a useful scheduling reference; it is not an implementation in this
repository and does not establish Metis workload costs.

The scheduler should combine pending requests with explicit deadlines and a
gas-price budget. Stop at a target that serves the selected requests, reuse
already proven batches, and avoid creating terminal proofs that will immediately
be superseded. If waiting for cheaper gas would violate the service deadline,
submit within the funded policy or surface the failure. A gas-price threshold
alone cannot guarantee withdrawal liveness.

## 2. Remove the long-idle catch-up bottleneck

The [current oracle](../contracts/metis-output-oracle/src/MetisOPSuccinctL2OutputOracle.sol)
both reads every SCC header and writes every proven hash. There are two distinct
optimization stages; removing the writes does not remove the reads or the
explicit 64-batch limit.

### Stage A: store a protected finalized prefix

After SCC deletion/truncation protection is enforced, consider storing the
latest proven index and its exact header hash instead of a second copy of every
historical header. Finality checks would combine the activation boundary and
proven index with **exact canonical SCC header membership**. The predecessor
hash remains necessary to bind the next transition. Legacy batches retain the
existing activation rules.

This is safe only while every path that can replace, truncate or repoint the
SCC/container preserves the finalized prefix, including upgrade authority under
the stated governance assumptions. A check of `batchIndex <= latestBatchIndex`
alone is insufficient. In particular, the public `isProvenHash` interface must
not return true for a wrong hash at an otherwise proven index. The current
mapping deliberately retains the original hash when a candidate is replaced;
removing it before enforcing immutability would lose that safeguard.

The base cost of 64 fresh nonzero storage writes is **1.28M gas**, before cold
access and mapping overhead, using [EIP-2200](https://eips.ethereum.org/EIPS/eip-2200)
and [EIP-2929](https://eips.ethereum.org/EIPS/eip-2929). This identifies an
optimization target, not net savings: replacement storage and reads still cost
gas. It is roughly $0.76 at the illustrative price. Stage A alone still needs
linear canonical reads and a newly measured limit before accepting more batches.

An alternative is one stored Merkle commitment per proven range, with an
index-bound membership witness at withdrawal. That changes the messenger API
and shifts work to relays. Compare it against prefix finality rather than
assuming an extra commitment tree is always necessary.

### Stage B: authenticate the entire prefix without reading every batch on L1

For long idle periods, the larger benefit is avoiding repeated terminal
verification. This requires a commitment that binds the complete ordered SCC
history through the target, and a guest that proves its extension from the
accepted predecessor. The present final header does **not** provide that:
[`hashBatchHeader`](../contracts/metis-output-oracle/src/metis/Lib_OVMCodec.sol)
does not even include `batchIndex`, and a batch's state-root Merkle tree does
not commit to preceding SCC batches.

Research an SCC-maintained cumulative commitment or authenticated history tree.
Bind the chain, index, predecessor, header hash and commitment-format version.
At finalization, authenticate the exact candidate prefix, advance its proven
watermark and prevent subsequent mutation of that prefix. Future candidate
appends should not unnecessarily invalidate a proof of an earlier unchanged
prefix; deletion/replacement of that prefix must invalidate it. A historical
storage proof against `l1Head` alone does not establish that the same candidates
remain canonical at submission time.

The [pinned Metis SCC](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/packages/contracts/contracts/MVM/MVM_StateCommitmentChain.sol)
currently appends individual header hashes and can delete a batch and its
suffix. It does not supply this cumulative commitment. The new format therefore
needs SCC/container changes, a migration boundary, updated guest outputs and
checks, and a compatible withdrawal-membership path. Appending and resetting
the new commitment have costs: do not simply move the same per-batch writes
from the oracle to the publisher and count them as eliminated.

Under the current contract, the illustrative seven-day backlog of 266 batches
needs at least five submissions. A redesigned authenticated-prefix protocol
could aim for one, subject to measured limits. Holding the current 15.4M-gas
scenario constant solely to illustrate the value of four avoided calls gives
**$36.74 per such catch-up at 0.25 gwei**. This is not a forecast of the new
transaction's gas or total savings. Proving all intervening execution,
commitment maintenance and relay costs remain. The objective is constant-size
L1 finalization work, not constant proving work or an unlimited service capacity.

## 3. Compare proof terminals on the same statement

The pinned [Ziren SDK](https://github.com/ProjectZKM/Ziren/blob/82ceeae13222fcf8cd7532e516108a5ab71fe28d/crates/sdk/src/action.rs)
supports compressed, Groth16 and PLONK modes. Its
[verifier documentation](https://docs.zkm.io/dev/verifier.html) describes BN254
verifiers and their program-key, public-value-digest and recursion-root binding;
the [prover documentation](https://docs.zkm.io/dev/prover.html) describes the
versioned setup and circuit artifacts. These provide comparison candidates,
not a completed alternative Metis oracle integration.

Benchmark native Keccak shrink and the supported SNARK pipeline from the same
Metis aggregation computation. Do not assume the existing Keccak shrink packet
is directly accepted by the SNARK wrapper. Pin the circuit artifacts and build
an adapter that preserves the approved guest, successful execution, recursion
allowlist and expected statement. Account for the SNARK interface's public-value
digest encoding/masking; it is not a drop-in replacement for the current raw
32-byte digest interface.

Use complete transaction gas, extra terminal-proving cost and deployment
amortization:

```text
net_terminal_saving_USD_per_submission =
    (G_native_full - G_snark_full) * p_gwei * 10^-9 * ETH_USD
    - (C_snark_terminal - C_native_terminal)
    - incremental_deployment_and_operations_per_submission
```

At the illustrative price, the entire recorded **13,668,039-gas verifier
transaction costs about $8.15**. That bounds the saving available from eliminating
that component of this fixture, even before paying for a replacement. At low
gas prices and infrequent demand, wrapping expense can outweigh gas savings.
The real Metis comparison remains unmeasured. BN254 Groth16/PLONK introduces
pairing and setup assumptions; treat selection as a design decision, not a
transparent optimization of the native hash-based terminal.

## 4. Profile the guest and the native verifier separately

For the guest, profile derivation/DA authentication, trie access, hashing,
signatures and execution before selecting optimizations. Ziren documents
[cycle tracking and reduced copying](https://docs.zkm.io/dev/optimizations.html)
and [proved cryptographic precompiles](https://docs.zkm.io/dev/precompiles.html).
Use supported, pinned patches where they preserve Metis semantics; an unchecked
host hint is not a substitute for a proved precompile. Differentially replay
optimized execution against the pinned production node, including fork rules
and invalid inputs.

Record trace area, shards, GPU time and peak memory as well as instruction count.
Ziren's [performance methodology](https://docs.zkm.io/introduction/performance.html)
explains that a precompile call counts as one guest instruction while adding
rows to its own chip. Thus a lower cycle count alone does not quantify the
proving-cost reduction. Its Ethereum benchmarks do not establish Metis costs.

For the native verifier, the recorded transaction decomposes into 21,000 base
gas, 2,834,640 ordinary calldata gas and **10,812,399 execution gas**. Profile the
full entry path by kernel, WHIR query/opening, hash, field arithmetic, memory
movement and module-call overhead before choosing another compiler change.

Several optimizations are [already implemented](../contracts/ziren-shrink-verifier/README.md):
dictionary/zero-run transport, derived sumchecks, a specialized Yul WHIR tail,
register promotion, shared operations, bounded lazy linear arithmetic and a
fraction-tree check with one inversion. Do not count these as new savings.
Further candidates include reducing inter-module copying and comparing padded
aligned layouts against the present jagged layout. Padding may simplify
verification while increasing trace area, proving time or packet size; benchmark
the whole pipeline. Preserve transcript challenges, full hash widths and proof
equations. Lowering soundness parameters is a separate security change.

## 5. Compress calldata, but account for the transaction floor

The recorded calldata component is **20.7%** of verifier transaction gas. A
hypothetical 50% reduction in calldata tokens removes 1,417,320 ordinary calldata
gas before decoder changes, about **$0.85 per verification** at the illustrative
price. This is a sensitivity calculation, not a claim that the already
compressed packet can be halved.

Under [EIP-7623](https://eips.ethereum.org/EIPS/eip-7623), with
`T = zero_bytes + 4 * nonzero_bytes`, a non-creation transaction has:

```text
gasUsed = 21,000 + max(4*T + execution_gas_after_refunds, 10*T)
```

The recorded calldata implies a **7,107,600-gas floor**. Execution optimization
alone cannot push that same transaction below its calldata floor. Measure real
receipts after both decoder and arithmetic changes; do not add the floor to
ordinary calldata gas or add calldata again to the complete transaction figure.

Moving the proof to a blob is not a drop-in encoding change.
[EIP-4844](https://eips.ethereum.org/EIPS/eip-4844) exposes blob commitments and a
KZG point-evaluation precompile, not arbitrary blob bytes to EVM execution.
The current verifier reads the entire packet. A blob-backed proof protocol
would need authenticated access to all data required by verification, different
openings/commitments and a fresh soundness and cost analysis. Blob expiry also
matters for delayed proving and witness reconstruction.

## 6. Reduce retained publication costs where the sample supports it

The [historical sample](costs.md#observed-l1-publication-costs) spent about
$7.37 on SCC transactions, $0.58 on inbox references, $2.61 on blob-transaction
execution and only $0.23 on blob data. Inspect the actual payload encoding and
publisher rules before proposing a compression or batching change; 38 blobs
does not reveal how full they were.

The blob uploader's effective 1-gwei execution tips totalled about **$1.90**.
An adaptive priority-fee policy is worth a controlled inclusion-latency test.
That sum is an upper bound on the tip component in this sample, not guaranteed
recoverable savings. Account for replacement transactions, missed deadlines and
blob/execution fee caps; bidding less must not silently stop publication.

Larger SCC batches could amortize fixed transaction and storage overhead, but
the current API still publishes every per-block state root. They can also delay
candidate availability, lengthen retries and affect dispute and bridge timing.
Measure batch-size/latency constraints against the deployed publisher before
changing them. Do not equate fewer SCC batches with less execution to prove.
Combining the blob and reference publications would additionally require a
compatible derivation format; it is not an ordinary transaction-batching change.

## 7. Share withdrawal witnesses and avoid redundant checkpoints

A validity proof already serves multiple withdrawals. A separate opportunity
is grouping messages under the same proven state root, sharing the messenger
account proof and repeated storage-trie nodes, and verifying a bounded
multiproof once. This requires a messenger/relayer interface change. Preserve
per-message identity, authorized sender, inclusion and replay protection;
define reentrancy, gas limits and partial-failure behavior. Grouping arbitrary
messages from different state roots does not automatically share those witnesses.
Measure relay demand before investing in this path; no relay-cost sample has
been collected here.

The oracle currently requires a stored L1 block-hash checkpoint. A revised
entry could use `BLOCKHASH` for sufficiently recent anchors and retain the
checkpoint fallback for older ones. Where supported and verified on the target
chain, [EIP-2935](https://eips.ethereum.org/EIPS/eip-2935) provides a separate
history contract covering 8,191 ancestor blocks; it does not extend the
256-block `BLOCKHASH` opcode window. Use exact chain/address/code checks and
reject unavailable hashes. Neither mechanism proves Ethereum consensus
finality by itself, and long-idle anchors still need a durable authentication
path. This saves small checkpoint overhead, not the dominant proof verification.

## Implementation and measurement gates

1. Complete the real Metis guest, aggregation and bridge safety integration.
   Pin the production execution/derivation rules and reject missing,
   reordered, replaced or cross-chain inputs.
2. Build demand detection and durable proof reuse; benchmark representative
   quiet, withdrawal-heavy and expensive-execution ranges. Report p50/p95
   catch-up latency, GPU-seconds, storage, retries and L1/relay expenditure.
3. Prototype Stage A and Stage B separately. Compare 1, 38, 64 and 266-batch
   backlogs, including all additional SCC publication and withdrawal costs.
   Test suffix replacement before proving, attempts to rewrite the finalized
   prefix, appends during proving, activation boundaries and upgrades.
4. Compare native and SNARK terminals on identical statements and price
   assumptions. For native changes, validate honest and malformed proofs
   against the reference, and measure the complete cold-storage oracle call
   under the actual transaction and contract-size limits.
5. Adopt measured improvements that meet the funded latency target. Keep
   proving, publication, verification, relays and one-time deployment separate;
   do not sum overlapping savings or multiply a one-day sample into a claimed
   production operating budget. Keep generated research artifacts outside Git.
