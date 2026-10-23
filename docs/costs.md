# Metis cost model and optimizations

The proposed bridge retains Metis's existing data publication and SCC candidate
submission. Validity proving and L1 proof verification therefore add costs to
those paths when performed. Verification can be demand-driven: no fixed timer
or per-batch submission is required by the oracle. A production configuration
needs both a cost budget and a measured withdrawal-latency target; fitting a
proof under the transaction gas cap does not establish either.

See [optimization research](#optimization-research) for ranked proposals, including
proof reuse, authenticated-prefix finality, terminal comparisons and publication
tuning. Their potential savings are separate from the measured baseline here.

## Observed L1 publication costs

This is a historical, one-day sample for Andromeda, chain ID 1088:
**2026-10-22 00:00:00 UTC inclusive to 2026-10-23 00:00:00 UTC exclusive**
(October 22 08:00 to October 23 08:00 in Asia/Ulaanbaatar). The corresponding
Ethereum blocks are **26,244,425 through 26,251,600 inclusive**.
The independently checked boundary block hashes are:

- [26,244,425](https://eth.blockscout.com/block/26244425):
  `0x552fecbcf2a2473c1eff4c2e3909cf8b69c8c590054cebc4c62c23152bf63774`.
- [26,251,600](https://eth.blockscout.com/block/26251600):
  `0x931a7582b743fd6b599f6999210ac488d4c03d24fae67492c36a22e5f31da0ab`.

The sample covers these publication paths and observed senders:

| Path | Destination | Sender |
| --- | --- | --- |
| SCC state batches | `0xA2FaAAC9120c1Ff75814F0c6DdB119496a12eEA6` | `0xf3CEB4C2ef996CdBc95C4E18c6D0CA988CC09040` |
| Inbox references | `0xFf00000000000000000000000000000000001088` | `0x1A9da0aedA630dDf2748a453BF6d92560762D914` |
| Blob publication | Same inbox | `0xaE4d46bD9117Cb017C5185844699c51107cB28a9` |

| Component | Count | Paid ETH | USD at the fixed conversion below |
| --- | --- | --- | --- |
| SCC execution | 38 transactions | 0.003087289887304141 | $7.37 |
| Inbox-reference execution | 38 transactions | 0.000242373287438100 | $0.58 |
| Blob-transaction execution | 38 transactions | 0.001093722012117000 | $2.61 |
| Blob data | 38 blobs in those same blob transactions | 0.000096186904215552 | $0.23 |
| **Total** | **114 distinct transactions** | **0.004519572091074793** | **$10.78** |

Dollar amounts use a fixed **$2,385.65/ETH** conversion, observed from
[Blockscout's ETH statistics endpoint](https://eth.blockscout.com/api/v2/stats)
during collection on October 23. This is neither a historical execution-time
exchange rate nor a forecast. Rounded component dollar amounts need not sum to
the rounded total. Reproduce the ETH totals first; apply a separately stated
exchange-rate assumption for budgeting.

The SCC calldata contains 4,795 state-root entries, with contiguous claimed L2
coverage from block 23,303,500 through 23,308,294. This checks submitted coverage,
not execution correctness. The
[L2 explorer's daily chart](https://andromeda-explorer.metis.io/api/v2/stats/charts/transactions)
reported 9,052 transactions for October 22. Its calendar-day transaction count
is not an exact cohort match for the L2 blocks published to L1 that day and has
not been filtered to exclude system transactions. Dividing $10.78 by 9,052 gives
about $0.00119 as a calendar-day normalization, not a measured user-transaction
cost or a fee charged to users.

This sample is **not Metis's total operating expense**. It excludes other L1
activity, deposits and withdrawal relays, node and MPC infrastructure, RPC and
archive services, staffing, incentives, and any off-chain publication-service
charges. The receipts establish sender expenditure, not who ultimately funds
or reimburses it. One day does not establish a long-term average or monthly bill.

### Accounting and reproduction

Discovery uses the paginated Blockscout transaction lists for the
[SCC](https://eth.blockscout.com/api/v2/addresses/0xA2FaAAC9120c1Ff75814F0c6DdB119496a12eEA6/transactions?filter=to)
and [inbox](https://eth.blockscout.com/api/v2/addresses/0xFf00000000000000000000000000000000001088/transactions?filter=to).
These are live endpoints, so start at the latest page and follow
`next_page_params` until crossing the beginning of the sample. Filter by the
half-open UTC interval, destination and sender above, and deduplicate hashes.

For each transaction, use integer wei arithmetic:

```text
execution_fee_wei = gasUsed * effectiveGasPrice
blob_fee_wei      = blobGasUsed * blobGasPrice     # zero for non-blob transactions
total_ETH        = sum(execution_fee_wei + blob_fee_wei) / 10^18
```

The explorer's transaction `fee.value` in this sample contains execution fees;
blob fees must be added separately. Do not multiply by `maxFeePerGas` or
`maxFeePerBlobGas`: those are caps, not the prices actually paid. Do not add the
priority fee again; it is already included in `effectiveGasPrice`.

Cross-check the discovered hashes using Ethereum JSON-RPC
`eth_getTransactionReceipt`; all 114 sampled receipts were independently
checked through `https://ethereum-rpc.publicnode.com`. Verify successful status,
block range, sender, destination and both fee components. Check the block
timestamps on either side of the interval. For each sender, the canonical
transaction immediately before the window and the one immediately after it
have a nonce difference of 39: the 38 intervening transactions are all present
in the sample. This completeness check applies to these three senders, not to
all Metis-related accounts.

Decode the SCC transactions with
`appendStateBatchByChainId(uint256,bytes32[],uint256,string,bytes32,uint256)`.
Require chain ID 1088, the expected method selector, contiguous start elements,
and `lastBatchBlockNumber = shouldStartAtElement + batch.length`. Raw API
responses, receipts, transaction ledgers and diagnostic output stay outside Git.

All 38 blob transactions paid an effective execution priority fee of 1 gwei,
totalling **0.000798 ETH**, or about **$1.90** at the fixed conversion. This is a
subset of their execution fees, not an additional charge. It suggests checking
the uploader's fee policy against its inclusion-latency requirements; it does
not establish that the entire tip could be removed without affecting delivery.

## Incremental proof-verification budget

The existing [verifier measurement](../contracts/ziren-shrink-verifier/README.md)
uses an Ethereum-block guest on local Osaka Anvil, not a Metis guest:

| Evidence | Gas | Scope |
| --- | --- | --- |
| Complete verifier transaction | 13,668,039 | Includes its calldata; fixed recorded build and packet |
| Oracle overhead at 64 batches | 1,575,532 | Foundry harness with warm storage and a mock verifier |
| Approximate extra cold SCC reads at 64 batches | 134,400 | Estimate: 64 times 2,100 gas |
| Component sum | 15,377,971 | Estimate, not a complete transaction measurement |
| All verifier-module deployments | 141,599,268 | Recorded one-time total across transactions |

Use **15.4M gas per proof submission** as a rounded scenario input. Applying the
64-batch budget to smaller ranges is deliberately coarse. It is not a proven
upper bound: the real call path, storage accesses, proof packet, approved build
and guest must be measured together. The separate measurements do not establish
that a real Metis proof plus oracle fits under the 16,777,216-gas transaction
cap. Calldata is already included in the verifier measurement; do not add its
2,834,640 gas a second time.

For a fixed assumed effective execution price `p` in gwei and `n` submissions
per day:

```text
incremental_L1_ETH_per_day = n * 15,400,000 * p * 10^-9
incremental_L1_USD_per_day = incremental_L1_ETH_per_day * 2,385.65
```

The following periodic policies are comparison scenarios, not protocol
requirements. A demand-driven policy is described next.

| Periodic submission scenario | Proofs/day | Mean batches/proof at 38 batches/day | Added USD/day at 0.25 gwei | At 1 gwei |
| --- | --- | --- | --- | --- |
| Every SCC batch | 38 | 1 | $349.02 | $1,396.08 |
| Every 2 hours | 12 | 3.17 | $110.22 | $440.87 |
| Every 6 hours | 4 | 9.5 | $36.74 | $146.96 |
| Every 24 hours | 1 | 38 | $9.18 | $36.74 |

These are added verification costs, excluding proving, checkpoints, relays,
deployment and operations. They assume sufficient eligible batches and
successful proving/submission at each interval; fractional batch counts are
daily averages. The 0.25-gwei scenario approximates the sample's SCC gas-weighted
effective price of 0.25417 gwei, not an available future price. At 10 gwei,
multiply the 1-gwei column by ten. Real costs use the price of each submission,
which may correlate with its timing and workload.

The recorded verifier deployment would cost approximately $84.45 at 0.25 gwei
or $337.81 at 1 gwei under the same USD conversion. This excludes other bridge
contracts and development costs. Account for replacement deployments when
approving new verifier builds; do not charge this entire amount to every proof.

## Demand-driven verification

The operator can wait to submit proofs until a pending L2-to-L1 withdrawal or
another consumer needs a newer proven prefix. With no such demand, no proof
verification transaction is required and the operator's scheduled verification
expense can be zero. Existing publication, infrastructure and any background
proving costs continue. The oracle still accepts submissions from callers with
permission, including permission opened by `fallbackTimeout`; demand-driven
scheduling is an operator policy, not a new on-chain restriction.

Let `P` be the last proven batch and `K` the batch needed for the selected
withdrawals. The current oracle requires:

```text
D = max(0, K - P)
minimum_catch_up_submissions = ceil(D / 64)
catch_up_L1_USD_estimate = submissions * 15,400,000 * p_gwei * 10^-9 * 2,385.65
```

If `D = 0`, use the existing finalization; only the message proof and relay are
needed. Otherwise every intervening batch must be covered, even those without
withdrawals. A single range finalization can serve many withdrawal messages.
The proof need not extend past the chosen target to the latest published batch.
The submission count is a lower bound assuming the full 64-batch capacity can
be used, all predecessor batches are canonical and provable, and no retry is
needed. It counts validity-proof submissions, not withdrawal transactions.

Using the sample's rate of 38 batches/day solely as a scenario assumption:

| Demand scenario | Backlog to requested target | Minimum submissions | Added verification budget at 0.25 gwei | At 1 gwei |
| --- | --- | --- | --- | --- |
| No demand for newer finality | Any | 0 required while idle | $0 | $0 |
| Request after one day, target at end of that day's batches | 38 | 1 | $9.18 | $36.74 |
| Request after seven days, target at end of that period | 266 | 5 | $45.92 | $183.70 |

The last two rows are catch-up costs **when the request is serviced**, not daily
charges. The seven-day case would cost about $6.56/day at 0.25 gwei if amortized
over that illustrative cycle, before proving and other expenses. A long idle
period defers expenditure and can reduce the number of small submissions, but
does not remove the eventual cost of covering its backlog. The 64-batch cap
means one aggregate proof cannot finalize an arbitrarily long idle period under
the current contract. Supporting that would require a different finality
representation and/or revised limits with a measured gas budget.

Separate generation from verification policy:

| Policy | Idle-period expense | Effect when demand arrives |
| --- | --- | --- |
| Background range proving; demand-driven aggregation/submission | Witness collection and range proving continue; L1 proof submissions can wait | Reuse compatible proofs of canonical ranges, then aggregate and finalize the needed prefix |
| Demand-driven generation and submission | Publication, required infrastructure and input retention continue; proving can wait | Generate the missing proofs before finalizing, increasing catch-up latency |

Both policies must preserve the DA data, state witnesses or compatible proofs
needed to establish the requested prefix later. Do not assume historical inputs
will remain retrievable from a live endpoint indefinitely. Configuration changes
and candidate resets must also be handled before reusing earlier work.

The proposer/relayer needs demand detection, coalescing of requests, a withdrawal
latency target and a funding policy for catch-up work. These are not implemented
by the oracle. Measure actual withdrawal demand to choose between demand-driven,
periodic and combined scheduling; SCC batch frequency alone does not determine
the required number of L1 verifications.

## Design implications and missing measurements

The current [oracle](../contracts/metis-output-oracle/README.md) permits up to 64
batches per proof. At the sample's rate of 38 batches/day, accumulating 64 batches
represents roughly 40 hours of production. The cap is a limit, not a target to
wait for. Withdrawal latency also depends on candidate publication, proof
generation, L1 confirmation/finality policy and relay. Work can overlap, so
measure the full path instead of treating the submission interval as a latency
guarantee.

Less frequent aggregation reduces the number of L1 verifications. It does not
eliminate the need to prove the underlying execution and derivation of all
covered blocks. Aggregation and terminal-proof work can change with batching;
their compute cost needs separate measurement.

Budget the system as:

```text
new_cost = retained_existing_cost
         + proving + L1_verification + additional_operations
         + amortized_deployment_and_engineering
         - independently_demonstrated_savings
```

The retained costs include current DA and SCC publication and the required
sequencer/node services. User-paid METIS fees, sequencer rewards and protocol
subsidies need separate cash-flow accounting from ETH expenditure and physical
compute costs. Faster withdrawals can reduce capital tied up or third-party
fast-bridge charges, but those benefits require actual withdrawal demand and
pricing; they are not automatic reductions of the operator's L1 bill.

Before selecting the production interval and proof terminal:

1. Prove representative real Metis ranges, including expensive execution and DA
   authentication. Measure cycles, witness size, CPU/GPU time, memory, retries
   and end-to-end latency. Hardware prices or prover quotes must be explicit.
2. Measure the complete oracle transaction with the approved Metis guest and
   verifier, realistic cold storage and representative range sizes. Verify the
   transaction cap rather than relying on the component sum above.
3. Compare direct shrink verification and a supported SNARK-wrapped terminal on
   the same workload and latency target, including extra wrapping compute and
   L1 verification. No end-to-end cost winner has been established here.
4. Measure withdrawal demand and compare demand-driven catch-up with the 6-hour
   and 24-hour periodic scenarios. State whether proving runs in the background,
   how requests are coalesced and funded, and the resulting withdrawal latency.
   Extend sampling across idle, active and congested periods before setting an
   operating budget.

The Metis guest and complete withdrawal integration remain unimplemented, so
this document cannot yet quote a total production proving cost or withdrawal SLA.

## Optimization research

Research date: **2026-10-23**. These proposals extend the cost analysis above
and the [demand-driven finalization design](bridge.md#demand-driven-finalization).
The recommendations below are proposals, not implemented savings. The current
oracle still stores every proven batch and accepts at most 64 batches per proof;
the Metis guest, application aggregation and withdrawal integration remain
unfinished.

The baseline is the October 22 publication sample and the recorded Ethereum
guest verifier fixture, not a measured Metis proving pipeline. At the cost
model's illustrative 0.25 gwei and $2,385.65/ETH, saving one million gas saves
about **$0.60 per submission**. Prioritize fewer expensive verifier calls and
less repeated proving before small Solidity changes.

### Priorities

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

### 1. Reuse proving work and size ranges by actual workload

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

### 2. Remove the long-idle catch-up bottleneck

The [current oracle](../contracts/metis-output-oracle/src/MetisOPSuccinctL2OutputOracle.sol)
both reads every SCC header and writes every proven hash. There are two distinct
optimization stages; removing the writes does not remove the reads or the
explicit 64-batch limit.

#### Stage A: store a protected finalized prefix

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

#### Stage B: authenticate the entire prefix without reading every batch on L1

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

### 3. Compare proof terminals on the same statement

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

### 4. Profile the guest and the native verifier separately

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

### 5. Compress calldata, but account for the transaction floor

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

### 6. Reduce retained publication costs where the sample supports it

The [historical sample](#observed-l1-publication-costs) spent about
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

### 7. Share withdrawal witnesses and avoid redundant checkpoints

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

### Implementation and measurement gates

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
