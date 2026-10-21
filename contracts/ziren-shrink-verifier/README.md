# Ziren shrink Solidity verifier

This component verifies `CompactShrink<Keccak256Suite>` proofs directly on an
EVM chain. Ziren owns the Rust shrinker; OPSuccinct owns the Solidity backend, codec,
trusted machine exporter and Python/Yul generator.

| Part | Role |
| --- | --- |
| `src/` | Solidity verifier, WHIR, transcript, arithmetic and transport libraries |
| `compile-machine.py` | Compile independently approved machine metadata to verifier IR |
| `native/compile.py` | Generate immutable Yul kernels and the complete Solidity entry |
| `parameters/` | WHIR model inputs; not runtime Ziren configuration |

The complete generated entry exposes
`verify(bytes proofPacket, bytes32 expectedOutputDigest)`. It checks the approved
profile, canonical fields, application/output binding, AIR/GKR reductions and
complete WHIR proof. `KeccakWireReader` only checks transport decoding; it is not
a proof verifier. See [design](DESIGN.md) for the trust boundary.

Deploy all approved immutable modules before approving the entry address.
Deployment can span transactions. Each proof verification supplies the complete
packet in one transaction; partial upload or intermediate verification state is
not part of this design.

Follow [reproduction](../../docs/development.md) to produce a shrink proof with
Ziren, export it with OPSuccinct, compile the Solidity verifier and run verification
on a local EVM. Compiler plans, proof packets and deployment records stay external.
