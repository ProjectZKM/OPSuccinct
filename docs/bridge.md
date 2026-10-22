# Metis bridge protocol proposal

This proposal adds proof-based finality to the canonical Metis bridge.
The [output oracle](../contracts/metis-output-oracle/) is implemented; the
guest and the SCC and messenger upgrades below remain to be implemented.

## Proof and withdrawal flow

```mermaid
flowchart LR
    A[Withdrawal recorded on Metis] --> B[Canonical candidate batch published]
    B --> C[Submit batch statement and Ziren shrink proof]
    C --> D[Output oracle verifies and finalizes batch]
    D --> E[Relay withdrawal with message inclusion proof]
    E --> F[Bridge releases escrow once]
```

The prover supplies a Ziren shrink proof for the candidate batch's state
transition. The output oracle checks the canonical batch and accepted
predecessor, verifies the proof against the expected statement, then marks the
batch finalized. Candidate publication alone does not establish finality;
post-activation batches require a valid proof regardless of elapsed time.

A relayer then proves the withdrawal message under the finalized state root.
The messenger checks inclusion, sender authentication and replay protection
before the existing bridge releases escrow. The batch validity proof and the
withdrawal message proof serve separate checks.

## Statement and guest

The public statement is the oracle's
[`MetisAggregationOutputs`](../contracts/metis-output-oracle/README.md#public-values).
It must bind:

| Commitment | Required fields | Bound by |
| --- | --- | --- |
| Deployment | Guest/rules/configuration version, L1/L2 chains | Verifier entry (guest key), `rollupConfigHash`, `l2ChainId`, `l1Head` |
| Predecessor | Accepted parent claim and starting state | `l2PreBatchHeaderHash`; the guest proves its start root is that batch's last element |
| Range | Start/end heights, exact count and the ordered per-block state roots as the `Lib_MerkleTree` batch root | `prevTotalElements`, `batchSize` and `batchRoot` inside each header hash |
| Canonical batch | Chain ID, batch index and SCC header hash | `startBatchIndex`, `endBatchIndex`, `batchHeaderHashesCommitment` |
| Inputs | Approved Ethereum anchor, ordered DA/batch data and enqueue commitments | `l1Head`; the guest authenticates the rest against it |

The messenger proves each withdrawal against one state-root element of the
batch, so the statement must commit to every root in order, not only the final
one. The SCC header's `extraData` carries a proposer-supplied timestamp,
submitter, `lastBatchBlockHash` and `lastBatchBlockNumber` that the SCC never
checks; the guest must derive them: the end height equals
`prevTotalElements + batchSize` and the last block hash equals the hash of the
last derived block.

The guest must authenticate these inputs and reproduce Metis derivation and
execution exactly. First pin the deployed Andromeda node release, fork rules,
`l2geth` execution and DTL/batch-decoding behavior. The
[official repository](https://github.com/MetisProtocol/mvm/tree/61ef7e9a9a1f404505279e1d86f2c26a885bcc86)
distinguishes `l2geth` as its execution client from `op-program` as a fault-proof
program; [node deployment](https://github.com/MetisProtocol/metis-ansible)
documentation does not establish activation of that exact fault-proof program.

The repository's [Go fault-proof program](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/go/op-program/client/program.go)
and [SCC claim validator](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/go/op-program/client/claim/validate.go)
are candidate code for adaptation. Mainnet use of this exact program/revision
has not been established here. Reuse requires differential replay against the
pinned production node on real mainnet batches, matching every state root and
SCC commitment. Rebuild for Ziren's runtime rather than reusing its existing
big-endian MIPS binary.

If this candidate is used, its [oracle client](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/go/op-preimage/oracle.go)
returns bytes unchecked; the host-side
[`WithVerification`](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/go/op-preimage/verifier.go)
wrapper checks keccak and sha preimages, passes blob field elements through
unverified, and runs outside the proof. Proved execution must check typed
preimages, trie witnesses, blob commitments and precompile results. Missing data,
wrong enqueue order, unsupported forks and a derived height different from the
claimed ending height must reject. Reconcile the candidate configuration's
`L1ChainId=1088` with Ethereum transaction chain ID 1 before porting it; this
source discrepancy is not evidence of production behavior or a deployed exploit.

## Ziren integration

Ziren produces the shrink proof establishing the authenticated Metis state
transition and public statement. The output oracle selects independently
approved guest/verifier configurations and recursion keys, derives the expected
output digest from the statement, and requires proof verification before
finalizing the candidate batch.

Ziren is pinned directly in [Cargo.toml](../Cargo.toml) and [Cargo.lock](../Cargo.lock).
[Ziren #568](https://github.com/ProjectZKM/Ziren/pull/568) supplies the shrinker;
OPSuccinct owns the [exporter](../crates/ziren-shrink-export/) and
[Solidity verifier](../contracts/ziren-shrink-verifier/). Proof encoding,
hash-suite and deployment details are documented with the verifier.

The shrink AIR constrains only the Poseidon2 digest of its public values. The
compact shrink is terminal and commits the root digest, as Ziren's Groth16/PLONK
wrap does: it covers the application key, the committed-value digest, the exit
code and the recursion root. The on-chain verifier recomputes it, so the expected
output digest the output oracle supplies is bound through it.

The output oracle calls the generated verifier entry, a subclass of
[`NativeTerminalVerifier`](../contracts/ziren-shrink-verifier/src/NativeTerminalVerifier.sol),
through `verify(bytes proofPacket, bytes32 expectedOutputDigest)`. Measured
[verifier costs](../contracts/ziren-shrink-verifier/README.md) on 2026-10-21 for
Ethereum block 26240087, on a local Osaka Anvil node that enforces the
16,777,216-gas transaction cap:

| Cost | Gas |
| --- | --- |
| Verification transaction | 13,668,039 |
| of which calldata (182 KB packet) | 2,834,640 |
| Deployment, all modules (one-time, across transactions) | 141,599,268 |

The proof geometry does not depend on the Metis batch, so verification cost is
per proof, not per block. The output oracle's statement checks and proven-batch
writes must fit in the remaining 3,109,177 gas under the cap, because the proof
is verified in the same transaction that records the batches as proven. Proving
the maximum 64 batches costs the oracle about 1.6M gas in its tests. Rerun the
measurement for every approved build.

## Ethereum finalization and bridge changes

The inspected [SCC](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/packages/contracts/contracts/MVM/MVM_StateCommitmentChain.sol)
commits batches of state roots. The [messenger](https://github.com/MetisProtocol/mvm/blob/61ef7e9a9a1f404505279e1d86f2c26a885bcc86/packages/contracts/contracts/L1/messaging/L1CrossDomainMessenger.sol)
currently combines SCC membership, fraud-window/dispute gates and a separate
message-passer account/storage proof. The proposal changes state finality while
preserving message proofs, sender authentication, escrow and replay protection.

1. [`MetisOPSuccinctL2OutputOracle`](../contracts/metis-output-oracle/src/MetisOPSuccinctL2OutputOracle.sol),
   named after OP Succinct's `OPSuccinctL2OutputOracle`, reads the canonical
   header hashes from the SCC and checks the approved L1 anchor, configuration,
   contiguous range and accepted predecessor.
   The anchor must be an ancestor of the verifying block: `blockhash` within
   the 256-block window, or a hash checkpointed earlier on L1 as OP Succinct's
   `checkpointBlockHash` does. A proof against any other anchor is rejected.
2. It computes the expected output digest, calls the approved complete verifier
   and atomically records each batch's header hash by index, in an oracle bound
   to one chain ID. The SCC header hash alone does not bind chain ID and batch
   index.
3. The messenger requires `isProven(header)` with SCC membership for batches
   after the oracle's `startingBatchIndex`, together with the existing message
   proof and relay checks (not yet implemented). Preserve other chains' behavior
   explicitly.
4. Legacy batches keep their existing rules. Snapshot the accepted prefix and
   resolve pending/disputed ancestors before activation; do not globally zero the
   fraud window or permit time-only acceptance of new batches.
5. Proven batches and their ancestors cannot be deleted or truncated: the SCC's
   `deleteStateBatchByChainId` must reject indexes at or below the oracle's
   `latestBatchIndex` (not yet implemented). An authorized
   invalid-candidate reset must preserve the proven prefix and prevent descendants
   from finalizing across a gap.
6. Proof-only finality halts every withdrawal when no approved configuration can
   prove the chain: a Metis fork, a Ziren defect or a prover outage. Define the
   recovery before activation: governance approves a replacement guest/verifier
   configuration that continues from the proven prefix, behind a timelock and
   public notice. OP Succinct's `fallbackTimeout` shows the permissionless
   proposer mechanism; its proof-free optimistic mode is not adopted, and no
   time-only acceptance of unproven batches is permitted.

This needs coordinated SCC/finality and messenger upgrades plus proposer/relayer
integration. Deploying a verifier alone does not change withdrawal authority.
A proof-before-append variant can be considered later; it requires redesigning
the guest's dependence on an existing SCC event.

## Activation gates

Pin and replay the real Metis release/configuration; prove authenticated real
batches; test continuity, replay, invalid data, disputed ancestors, legacy cutover
and storage-compatible upgrades; approve the guest/verifier configuration; then
validate the complete proof-finalization and withdrawal flow end to end.

Hash-based proof verification does not make Ethereum blob KZG, account signatures,
consensus or governance post-quantum safe. DA authentication and L1 reorg/finality
policy remain explicit assumptions. See [SP1 + OP research](#sp1-and-op-succinct-reference)
for the architectural reference and pinned Metis inspection.

## SP1 and OP Succinct reference

Research snapshot: 2026-10-21. Sources are pinned to inspected OP Succinct
revision `19c6d2d6b122a31c2a9aaedbb3dad76372bb7433` and Metis revision
`61ef7e9a9a1f404505279e1d86f2c26a885bcc86`; this is not a live deployment inventory.
OP Succinct's [v4.9.2 release](https://github.com/succinctlabs/op-succinct/releases/tag/v4.9.2)
and development main must be distinguished.

### What the validity path does

| Stage | OP Succinct behavior | OPSuccinct application |
| --- | --- | --- |
| Range proof | Authenticate inputs and run OP derivation/execution | Prove Metis's own rules and authenticated witnesses |
| Aggregation | Verify range proofs, connect roots/configuration and authenticate L1 ancestry | Enforce contiguous Metis batches and one approved L1 anchor |
| L1 acceptance | Reconstruct the statement from trusted configuration and accepted state; verify before accepting output | Bind canonical SCC candidate and advance a proven prefix |
| Proof backend | Normally PLONK/Groth16 wrapping | Verify the Ziren shrink proof on Ethereum |

The [range executor](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/utils/client/src/witness/executor.rs)
and [aggregation guest](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/programs/aggregation/src/main.rs)
implement the first two stages. The
[output oracle](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/contracts/src/validity/OPSuccinctL2OutputOracle.sol)
binds L1 head, previous/new output roots, ending height, rollup configuration,
range-program key and prover identity before accepting an output.

The [validity dispute game](https://github.com/succinctlabs/op-succinct/blob/19c6d2d6b122a31c2a9aaedbb3dad76372bb7433/contracts/src/validity/OPSuccinctDisputeGame.sol)
verifies before resolution for Portal2 compatibility. It is distinct from Lite's
challenge-based acceptance. Metis need not copy that game abstraction, a
proof-free optimistic mode or stock OP contracts to obtain proof-only finality.

The [range-height advisory](https://github.com/succinctlabs/op-succinct/security/advisories/GHSA-5jh4-3p33-85xc)
makes one test mandatory: the actually derived ending height must equal the
claimed height, including when witness data ends early.

### Pinned Metis observations

The earlier read-only Ethereum snapshot used block **26,238,563**, hash
`0xf824bfc54c98f3492bbdf42cd6503fe6522faa00f72710b9404289a9bb0f0d56`.

| Component | Proxy / observation |
| --- | --- |
| SCC | `0xA2FaAAC9120c1Ff75814F0c6DdB119496a12eEA6`; fraud window 604800 seconds |
| Messenger | `0x081D1101855bD523bA69A9794e0217F0DB6323ff` |
| Standard bridge | `0x3980c9ed79d2c191A89E02Fa3529C60eD6e9c04b` |

Inspected implementations: [SCC](https://eth.blockscout.com/address/0xa738573ec0fd7959bfa60aaa8a23fe7bec6c4bd7?tab=contract),
[messenger](https://eth.blockscout.com/address/0xc1ce5240b42ab158027095f658d530f9989b414f?tab=contract)
and [bridge](https://eth.blockscout.com/address/0xa0cfe8af2ab5c9232714647702dbacf862ea4798?tab=contract).
These are snapshot resolutions, not assertions about future proxy targets.
A sampled [inbox transaction](https://etherscan.io/tx/0xffc2f0f69ea8b726c8c6190fab7687c0dc59b6f6841aaafe1c3fc65a71fd0686)
references an Ethereum [blob transaction](https://etherscan.io/tx/0x6f8c9d70e31cdc4f5b01ce9bc8f1de7a39336c965d0f6667e1abbf7a58530388);
that establishes blob use for that sample, not replay of every DA mode.

Apply the authenticated ranges, aggregation and proof-gated acceptance pattern.
Keep Metis execution, SCC batch format and messenger/message-proof semantics.
