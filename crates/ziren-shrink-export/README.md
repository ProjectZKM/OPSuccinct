# Shrink export

OPSuccinct-owned codec and trusted verifier-data exporter for
`CompactShrink<Keccak256Suite>`. Cargo pins Ziren directly; PCS/prover have no
exporter dependency.

`wire::Profile` encodes/decodes complete proofs under an independently approved
shape/key. Decoding must be followed by full native verification. With the
`machine` feature, `machine::export` first verifies the reference against approved
`ShrinkVerifierData`, application key and public values, then emits fixed machine
metadata and markers, including the public-value positions of the root digest
that the compact shrink commits. Unsupported AIR fails export. A submission cannot authorize
its own verifier key, geometry or program.

The Solidity backend and compiler live in [ziren-shrink-verifier](../../contracts/ziren-shrink-verifier/).
See [development](../../docs/development.md) for checks and full proving gates,
and [the bridge protocol](../../docs/bridge.md) for integration.
