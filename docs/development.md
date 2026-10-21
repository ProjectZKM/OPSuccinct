# Reproduce with Ziren and the Solidity verifier

Use Python 3.11+, solc 0.8.30, Foundry and the Rust/guest toolchains required by
the pinned Ziren revision. Run commands from OPSuccinct. Keep proof, build and deployment
outputs outside the repository.

## Setup

```sh
python3 -m venv /outside/repos/opsuccinct-venv
. /outside/repos/opsuccinct-venv/bin/activate
python3 -m pip install -r contracts/ziren-shrink-verifier/native/requirements.in
export PYTHONDONTWRITEBYTECODE=1
export CARGO_TARGET_DIR=/outside/repos/opsuccinct-target
python3 scripts/check-dependencies.py
cargo test --locked -p opsuccinct-shrink-export --lib
cargo check --locked -p opsuccinct-shrink-export --features machine --tests
```

Cargo supplies Ziren directly. The guest/bridge integration is described in
[bridge.md](bridge.md).

## Prove and export

Execute your guest and compress its proof with Ziren. In the guest host, enable
`opsuccinct-shrink-export`'s `machine` feature and export the shrink proof:

```rust,ignore
use zkm_prover::{CompactShrink, Keccak256Suite};
use opsuccinct_shrink_export::{machine, wire::{Mode, Profile}};

let shrink = prover.shrink_with::<CompactShrink<Keccak256Suite>>(compressed, opts)?;
let work = std::path::Path::new("/outside/repos/shrink-proof");
machine::export(
    &work.join("machine"), &prover, &shrink, &application_vk,
    &approved_verifier_data, &public_values,
)?;
let profile = Profile::from_trusted_proof(&shrink.vk, &shrink.proof, Mode::Raw, false)?;
std::fs::write(work.join("raw.bin"), profile.encode(&shrink.proof)?)?;
let statement = serde_json::json!({
    "output_digest": format!("0x{}", hex::encode(public_values.hash()))
});
std::fs::write(work.join("statement.json"), serde_json::to_vec(&statement)?)?;
```

The verifier data, application key and public values must come from your approved
setup/statement. Machine export fully verifies the reference before emitting its
metadata and markers. `Mode::Raw` with `derived_sumchecks=false` matches that export.

## Compile and verify

```sh
export WIRE_FIXTURE=/outside/repos/shrink-proof
python3 contracts/ziren-shrink-verifier/compile-machine.py \
  "$WIRE_FIXTURE/machine" "$WIRE_FIXTURE/compiled"
cp "$WIRE_FIXTURE/statement.json" "$WIRE_FIXTURE/compiled/statement.json"
python3 scripts/build-native.py --fixtures "$WIRE_FIXTURE" \
  --out /outside/repos/verifier-build --solc /path/to/solc-0.8.30
```

This builds from the exported computation without workload-specific presets.
The output includes an external `native.json`. On a later build, add
`--plan /path/to/native.json --fresh` to reproduce its exact boundaries and bytecode.

Start a dedicated local Anvil node:

```sh
anvil --host 127.0.0.1 --port 18601 --hardfork osaka --enable-tx-gas-limit \
  --gas-limit 60000000 --no-request-size-limit --silent
```

In another terminal with the same virtual environment and fixture variable:

```sh
python3 contracts/ziren-shrink-verifier/native/measure.py \
  --build /outside/repos/verifier-build --fixtures "$WIRE_FIXTURE" \
  --rpc http://127.0.0.1:18601 --skip-checkpoints --capped-osaka \
  --out /outside/repos/verification.json
```

The helper deploys the modules and submits the complete proof. `--skip-checkpoints`
omits optional intermediate-vector comparisons; the full on-chain proof check
still runs. Accept a successful receipt and verifier result; this command does
not promise every proof configuration fits Ethereum's limits. With independent
component/checkpoint vectors, run `native/run-tests.py` and omit that diagnostic
flag for additional differential checks.
