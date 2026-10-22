# Reproduce with Ziren and the Solidity verifier

The steps below prove a guest with the pinned Ziren, export the shrink proof,
build the Solidity verifier, then deploy and verify it on a local EVM.

You need Python 3.11+, solc 0.8.30, Foundry (`anvil`) and the Rust toolchain of
the pinned Ziren revision. Run every command from the OPSuccinct root. All
outputs go under `$WORK`, which must be outside the repository.

```sh
export WORK=/path/outside/repo/zkop-work
export SOLC=/path/to/solc-0.8.30
export CARGO_TARGET_DIR=$WORK/target
export PYTHONDONTWRITEBYTECODE=1
```

## 1. Set up

```sh
python3 -m venv $WORK/venv && . $WORK/venv/bin/activate
python3 -m pip install -r contracts/ziren-shrink-verifier/native/requirements.in
python3 scripts/check-dependencies.py
cargo test --locked -p ziren-shrink-export --lib
```

## 2. Make a shrink proof

Pick one source. Both write `machine/`, `raw.bin` and `statement.json` to
`$WORK/proof` and run Ziren's native verifier first.

**A small guest** (proves from scratch; `10` is the guest's `u32` input):

```sh
cargo run --release -p ziren-shrink-export --features machine --example export_fixture -- \
  prove /path/to/guest.elf $WORK/proof 10 --derived
```

**A real Ethereum block**: start from a compressed block proof, such as an
EthProofs worker output, with its `proof.bin`, `public_values.bin` and the
`program.elf` it was proven with. Only the compact shrink runs:

```sh
cargo run --release -p ziren-shrink-export --features machine --example export_fixture -- \
  shrink /path/to/proof.bin /path/to/program.elf /path/to/public_values.bin \
  $WORK/proof --derived
```

The example derives the verifier data from the proof's own key. That is fine for
local reproduction only; production uses the independently approved key.

## 3. Build the verifier

```sh
python3 contracts/ziren-shrink-verifier/compile-machine.py $WORK/proof/machine $WORK/proof/compiled
cp $WORK/proof/statement.json $WORK/proof/compiled/
python3 scripts/build-native.py --fixtures $WORK/proof --out $WORK/build --solc $SOLC
```

## 4. Deploy and verify

Start a local Osaka node that enforces the 16,777,216-gas transaction cap:

```sh
anvil --host 127.0.0.1 --port 18601 --hardfork osaka --enable-tx-gas-limit \
  --gas-limit 60000000 --no-request-size-limit --silent
```

In a second terminal, with the same environment variables and venv:

```sh
python3 contracts/ziren-shrink-verifier/native/measure.py \
  --build $WORK/build --fixtures $WORK/proof \
  --rpc http://127.0.0.1:18601 --capped-osaka --skip-checkpoints \
  --out $WORK/verification.json
```

This deploys every module and submits the complete proof in one transaction.
Success means `complete_verification_succeeded: true` in the printed report,
with `transaction_gas_used` and `total_deployment_gas`. Because the proof
geometry does not depend on the guest, every guest costs the same; compare with
the [measured costs](../contracts/ziren-shrink-verifier/README.md).
`--skip-checkpoints` only skips optional intermediate-vector comparisons.

## Notes

- **`--derived`** omits each sumcheck polynomial's linear coefficient and final
  evaluation, and jagged PCS claims that repeat zerocheck openings. The verifier
  reconstructs them. It is the cheaper encoding; use it consistently.
- **After the Ziren pin changes**, run `shrink` again from the compressed proof.
  A shrink proof embeds its Ziren revision's wrap program, so `replay` of an
  older `shrink.bin` fails native verification.
- **Rebuilding exactly**: pass `--plan $WORK/build/native.json --fresh` to
  `build-native.py` to reproduce a previous build's boundaries and bytecode.
- **Comparing acceptance**: `export_fixture verify-packet <fixture> <packet> --derived`
  runs Ziren's native verifier on any profile packet, for example a modified one.

## Export from your own host

Enable the `machine` feature of `ziren-shrink-export` and call it after
`shrink_with`. The verifier data, application key and public values must come
from your approved setup and statement.

```rust,ignore
use zkm_prover::{CompactShrink, Keccak256Suite};
use ziren_shrink_export::{machine, wire::{Mode, Profile}};

let shrink = prover.shrink_with::<CompactShrink<Keccak256Suite>>(compressed, opts)?;
let work = std::path::Path::new("/path/outside/repo/zkop-work/proof");
machine::export(
    &work.join("machine"), &prover, &shrink, &application_vk,
    &approved_verifier_data, &public_values, derived,
)?;
let profile = Profile::from_trusted_proof(&shrink.vk, &shrink.proof, Mode::Raw, derived)?;
std::fs::write(work.join("raw.bin"), profile.encode(&shrink.proof)?)?;
let statement = serde_json::json!({
    "output_digest": format!("0x{}", hex::encode(public_values.hash()))
});
std::fs::write(work.join("statement.json"), serde_json::to_vec(&statement)?)?;
```

`machine::export` fully verifies the proof before writing metadata. Then
continue from step 3.

## Optional Foundry fixture tests

`ShrinkReferenceVerifierTest` and `OptimizedKernelsTest` read the proof and
build. The committed `foundry.toml` grants no file access, so run them from a
scratch root that can read `$WORK`:

```sh
V=$PWD/contracts/ziren-shrink-verifier
mkdir -p $WORK/forge && cd $WORK/forge
ln -sf $V/src src && ln -sf $V/test test
sed "s#fs_permissions = \[\]#fs_permissions = [{ access = \"read\", path = \"$WORK\" }]#" \
  $V/foundry.toml > foundry.toml
WIRE_FIXTURE=$WORK/proof NATIVE_BUILD=$WORK/build \
  forge test --root . --match-contract 'ShrinkReferenceVerifierTest|OptimizedKernelsTest'
```

For more differential checks against independent checkpoint vectors, run
`contracts/ziren-shrink-verifier/native/run-tests.py` and drop `--skip-checkpoints`.

The bridge integration is described in [bridge.md](bridge.md).
