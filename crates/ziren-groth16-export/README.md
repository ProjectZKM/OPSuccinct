# Groth16 export

Export of the Groth16 terminal: native shrink, `wrap_bn254` and
`wrap_groth16_bn254` on Ziren, writing the proof for the on-chain check.
`examples/export_groth16.rs` is the entry point.

## Modes

```sh
export_groth16 prove <guest.elf> <out dir> [u32 input]
export_groth16 replay <dir with shrink.bin> <circuit dir> <out.json>
export_groth16 groth16 <guest.elf> <circuit dir> <out.json> [u32 input]
```

- `prove` runs setup, core proving, compression and native shrink. It writes
  `shrink.bin` and `public_values.bin` to `<out dir>`.
- `replay` loads a saved `shrink.bin` and runs `wrap_bn254` and
  `wrap_groth16_bn254`, so the Groth16 step can be rerun without proving again.
- `groth16` runs `prove` and `replay` in one process. It writes only the proof
  JSON, not `public_values.bin`.

The default input is 10. The Groth16 modes read the circuit artifacts from
`<circuit dir>`, and every mode runs on the CPU.

Each Groth16 mode writes the proof as JSON, which
`scripts/groth16_args.py` and `scripts/groth16_verify.py` read. The
`replay` and `groth16` modes print `GROTH16_OK raw_proof_bytes=... out=...` on success.

The Solidity verifier and adapter live in
[contracts/ziren-groth16-verifier](../../contracts/ziren-groth16-verifier/).
See [groth16-verification](../../docs/groth16-verification.md) for the full steps.
