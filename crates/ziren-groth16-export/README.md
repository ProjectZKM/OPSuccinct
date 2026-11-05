# Groth16 export

Export of the Groth16 terminal: native shrink, `wrap_bn254` and
`wrap_groth16_bn254` on Ziren, writing the proof for the on-chain check.
`examples/export_groth16.rs` is the entry point.

## Modes

```sh
export_groth16 prove <guest.elf> <circuit dir> <out dir> [u32 input]
export_groth16 groth16 <compressed proof.bin> <circuit dir> <out.json>
export_groth16 replay <prove out dir>
```

- `prove` runs core proving, compression, native shrink, `wrap_bn254` and
  `wrap_groth16_bn254`. It writes `compressed.bin`, `public_values.bin` and
  `groth16_proof.json` to `<out dir>`. `public_values.bin` is the input to
  `scripts/groth16_verify.py`.
- `groth16` takes a saved compressed proof, either `compressed.bin` or an SDK
  compressed proof, and runs the native shrink and both wraps without proving
  the guest again. It writes the Groth16 proof to `<out.json>`.
- `replay` reads `groth16_proof.json` from a `prove` output directory and checks
  its layout: the encoded proof is 256 bytes, and it prints the verifier selector,
  the number of public inputs and the raw proof size. It runs no proving and no wrap,
  and it does not verify the proof cryptographically.

The default input is 10. Every mode runs on the CPU. `prove` and `groth16` read the Groth16
circuit artifacts from `<circuit dir>`.

`prove` and `groth16` write the proof as JSON, which `scripts/groth16_args.py` and
`scripts/groth16_verify.py` read. A successful `prove` or `groth16` run prints
`GROTH16_OK raw_proof_bytes=... out=...`; `replay` prints `REPLAY_OK ...`.

The Solidity verifier and adapter live in
[contracts/ziren-groth16-verifier](../../contracts/ziren-groth16-verifier/).
See [groth16-verification](../../docs/groth16-verification.md) for the full steps.
