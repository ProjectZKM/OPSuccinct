# Metis cost model

The proposed bridge retains Metis's existing data publication and SCC candidate
submission. Validity proving and L1 proof verification therefore add costs to
those paths when performed. Verification can be demand-driven: no fixed timer
or per-batch submission is required by the oracle. A production configuration
needs both a cost budget and a measured withdrawal-latency target; fitting a
proof under the transaction gas cap does not establish either.

See [optimization research](optimizations.md) for ranked proposals, including
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
