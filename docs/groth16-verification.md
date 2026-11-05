# Verify a Groth16 terminal proof on a local EVM

A Ziren proof is shrunk natively, wrapped to BN254, then wrapped again as a gnark
Groth16 proof. The proof is checked by the Ziren Groth16 verifier, called through
`ZirenGroth16ProofVerifier`, which implements `IZirenProofVerifier`, the interface
`MetisOPSuccinctL2OutputOracle` calls.

The shrink path is documented in [development.md](development.md). This document
covers only the Groth16 terminal.

## What is checked

| Check | Where |
| --- | --- |
| Ziren produces a native shrink and a Groth16 proof that verifies internally | `export_groth16` (step 1) |
| The proof verifies on chain through the Ziren verifier | `groth16_verify.py`, direct `Verify` check (step 2) |
| The adapter maps the packet and output digest to the Groth16 inputs | `groth16_verify.py`, adapter checks (step 2) |
| The adapter rejects a tampered proof, digest, selector or length | `groth16_verify.py`, negative checks (step 2) |
| The adapter's mapping logic in isolation | `forge test` in `contracts/ziren-groth16-verifier` (step 3) |

Not checked here: an end-to-end Metis aggregation, the exit code, and the
recursion root against the release constant. See [Caveats](#caveats).

## Prerequisites

- The Ziren revision pinned by this repository (`Cargo.lock`). The recursion root is not read
  from a file: the prover computes it from its embedded `vk_map.bin`, as the shrink exporter does,
  and the Groth16 proof commits to it as `public_inputs[2]`.
- Rust toolchain, Python 3.11+, solc 0.8.30, Foundry (`anvil`, `cast`, `forge`).
- Groth16 artifacts for the pinned revision. The export example reads them from
  `$CIRC`; in this document `$CIRC` is `~/.zkm/circuits/groth16/v2.0.0`. These files
  are several gigabytes (`groth16_pk.bin` about 11 GB, `groth16_circuit.bin` about
  4.3 GB), so confirm the disk and memory budget first.
- A guest ELF. This document uses the fibonacci guest with input `10`.

Run every command from the OPSuccinct root. Put outputs under `$WORK`, which must be
outside the repository.

```sh
export WORK=/path/outside/repo/zkop-work
export CIRC=$HOME/.zkm/circuits/groth16/v2.0.0
export ELF=/path/to/fibonacci
export CARGO_TARGET_DIR=$WORK/target
export RPC=http://127.0.0.1:18602
mkdir -p $WORK
```

Start the local node in a separate terminal. Its unlocked account 0 (`0xf39F…2266`) is the
deployer that `scripts/groth16_verify.py` uses by default. It is an Anvil test key, so use it on
a local node only:

```sh
anvil --host 127.0.0.1 --port 18602 --hardfork osaka --enable-tx-gas-limit \
  --gas-limit 60000000 --no-request-size-limit --silent
```

## 1. Produce the proof

The export example runs setup, core proving, compression, native shrink, `wrap_bn254` and
`wrap_groth16_bn254` on the CPU. It writes the Groth16 proof as JSON.

```sh
cargo build --release -p ziren-groth16-export --example export_groth16
EXPORT_OUT=$WORK/groth16_proof.json \
  $WORK/target/release/examples/export_groth16 $ELF $CIRC 10
```

The last line of output is `GROTH16_OK raw_proof_bytes=648 out=...`. `wrap_groth16_bn254`
also runs gnark's own verification before returning, so a successful run is already
an internal check.

Stage times from the first export run on the CPU with 24 threads: setup
about 0.3 s, core proving about 10 s, compression about 223 s, native shrink about 18 s,
and `wrap_bn254` plus `wrap_groth16_bn254` about 144 s, of which Groth16 proving is
about 11 s. The whole run takes about 400 s. Times vary with hardware.

The exported JSON has these fields:

- `public_inputs`: `[application key, committed-value digest, recursion root]`, as
  decimal strings.
- `encoded_proof`: 256 bytes, eight big-endian 32-byte words (gnark `MarshalSolidity`).
- `groth16_vkey_hash`: 32 bytes. Its first four bytes are the verifier selector.

## 2. Deploy and verify

`scripts/groth16_verify.py` builds `contracts/ziren-groth16-verifier`, deploys
`Groth16Verifier` and `ZirenGroth16ProofVerifier`, and checks the proof:

```sh
python3 scripts/groth16_verify.py --proof $WORK/groth16_proof.json \
  --public-values $WORK/proof/public_values.bin \
  --rpc $RPC --report $WORK/groth16_report.json
```

The script:

- converts the proof with `scripts/groth16_args.py` (selector, proof words, public inputs, packet);
- deploys the verifier, then the adapter with the selector, application key (`input[0]`)
  and recursion root (`input[2]`) from the proof;
- calls the verifier directly and the adapter with the packet and digest, expecting `true`;
- sends the adapter's `verify` as a transaction for its gas, expecting success;
- expects `false` for a changed last proof byte, a changed digest, a replaced selector and a
  truncated packet.

It prints one line per check and the gas used, writes the same results to `--report`, and
exits non-zero if any check fails. For the fibonacci proof, the packet's selector is
`0xb3e14fe9`, which equals `VERIFIER_HASH()` in `ZKMVerifierGroth16.sol`, and the adapter's
application key is `0x002c7ab6…8c53`.

The recursion root is the value the prover computes for the shrink (`recursion_vk_root`),
carried in the proof as `input[2]`. For the fibonacci run it is
`0x007ad39482c4460fe91d19534ecc20e27d374c3e17c0fe5f44d7cf7cb0fd2349`.

The script computes the output digest from `--public-values`, the statement's `public_values.bin`.
The digest is SHA-256 of the committed public-value bytes: the file stores them with an 8-byte
little-endian length prefix, and the hash covers only the bytes after it. For the fibonacci
fixture this gives `0xd0abd303…2354`, the `output_digest` in its `statement.json`. Ziren computes
it as `PublicValues::hash()` (`crates/primitives/src/io.rs`), which uses SHA-256 unless the
`imm-wrap-vk` mode is set, in which case it uses BLAKE3; the script implements only SHA-256.
The adapter clears the top three bits of the digest to get the 253-bit committed value, which
must equal the proof's `input[1]`; the script exits before deploying if they differ. The
contract does not derive the digest from the proof, so the caller must supply it. In Metis the
output oracle passes `sha256(abi.encode(MetisAggregationOutputs))`. The fibonacci mapping is the
only one checked here; see [Caveats](#caveats).

Use a transaction for
gas, not `cast estimate`: the adapter catches the verifier's revert and returns `false`, so an
estimate does not reflect a valid proof.

The script builds with `contracts/ziren-groth16-verifier/foundry.toml` (solc 0.8.30, optimizer on).
The verifier's deployment figure in section 6 comes from an optimizer-off build, and the same proof
with this script gave 1,135,523 gas for the verifier deployment and 233,498 for the verification
transaction. Gas depends on the build, so use the figures from your own run.

## 3. Unit tests for the adapter

```sh
cd contracts/ziren-groth16-verifier
forge test --match-contract ZirenGroth16ProofVerifierTest
```

These use a mock verifier. They check the packet length and selector, the digest mask,
and the forwarding of the proof and the three public inputs. They do not check the
Groth16 proof itself; section 2 does that.

## 6. Measured values

Measured on 2026-11-05 on a local Osaka Anvil node (`--gas-limit 60000000`), with the
fibonacci proof (input 10) and the verifier compiled with solc 0.8.30.

| Cost | Gas |
| --- | --- |
| Verification transaction | 233,581 |
| of which calldata (260-byte packet) | 5,140 |
| Deployment, Groth16Verifier and adapter | 2,265,168 |

Execution is 207,441 gas of the verification transaction. Deployment is 1,938,397 for
the verifier and 326,771 for the adapter. A direct `Groth16Verifier.Verify` transaction
for the same proof costs 228,228 gas. The figures also appear in
[the shrink verifier README](../contracts/ziren-shrink-verifier/README.md).

## Caveats

- **Recursion root.** The adapter takes the root from the proof's `public_inputs[2]`, computed
  by the prover from its `vk_map.bin` as for the shrink. It is `0x007ad394…2349` for the
  fibonacci run.
- **Exit code.** The Groth16 public inputs do not include the exit code. The recursion
  core circuit asserts `exit_code == 0` (`Ziren/crates/recursion/circuit/src/machine/core_jagged.rs`),
  but this document does not trace the full wrap chain to confirm that the constraint
  holds for every path.
- **Digest mapping.** `input[1]` is the output digest with its top three bits cleared.
  This matches the statement fixture for the fibonacci run (`0xd0ab…` masks to `0x10ab…`),
  but the Metis aggregation outputs have not been run through this path.
- **Verifier pragma.** The copy in `contracts/ziren-groth16-verifier/src/` has pragma `0.8.30`.
