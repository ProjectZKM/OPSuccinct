# Groth16 export

Export of the Groth16 terminal: native shrink, `wrap_bn254` and
`wrap_groth16_bn254` on Ziren, writing the proof for the on-chain check.
`examples/export_groth16.rs` is the entry point.

The Solidity verifier and adapter live in
[contracts/ziren-groth16-verifier](../../contracts/ziren-groth16-verifier/).
See [groth16-verification](../../docs/groth16-verification.md) for the full steps.
