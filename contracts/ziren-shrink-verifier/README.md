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
complete WHIR proof. The shrink AIR constrains only the Poseidon2 digest of its
public values, so the verifier recomputes the root digest (application key,
committed-value digest, exit code and recursion root) that the compact shrink
commits. `KeccakWireReader` only checks transport decoding; it is not
a proof verifier. See [design](DESIGN.md) for the trust boundary.

Deploy all approved immutable modules before approving the entry address.
Deployment can span transactions. Each proof verification supplies the complete
packet in one transaction; partial upload or intermediate verification state is
not part of this design.

Measured on 2026-10-21 for Ethereum block 26240087 (an EthProofs Ziren proof),
on a local Osaka Anvil node that enforces the 16,777,216-gas transaction cap:

| Cost | Gas |
| --- | --- |
| Verification transaction | 13,668,039 |
| of which calldata (182 KB packet) | 2,834,640 |
| Deployment, all modules | 141,599,268 |

The proof geometry does not depend on the guest workload, so these costs apply
to any guest under the same profile. Rerun the measurement for every new build.

Follow [reproduction](../../docs/development.md) to produce a shrink proof with
Ziren, export it with OPSuccinct, compile the Solidity verifier and run verification
on a local EVM. Compiler plans, proof packets and deployment records stay external.
