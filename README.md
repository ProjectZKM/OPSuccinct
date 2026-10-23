# OPSuccinct

OPSuccinct contains the proposed Metis validity bridge and the Solidity verifier for
Ziren compact shrink proofs. Ziren supplies the proof system through a pinned
Cargo dependency; OPSuccinct supplies the exporter, on-chain verifier and bridge design.

| Read | Purpose |
| --- | --- |
| [Bridge protocol](docs/bridge.md) | Metis statement, Ziren integration, SP1 + OP reference and withdrawal gates |
| [Cost model](docs/costs.md) | Historical Metis publication costs, proof budgets and measurements still needed |
| [Solidity verifier](contracts/ziren-shrink-verifier/) | Proof verification, encoding and deployment |
| [Output oracle](contracts/metis-output-oracle/) | Proof-only finality for Metis SCC batches |
| [Reproduction](docs/development.md) | Generate a Ziren proof, export, build and verify on a local EVM |

The Solidity backend verifies `CompactShrink<Keccak256Suite>` proofs.
The output oracle is built against the current Metis contracts; the Metis guest
and the SCC and messenger upgrades remain proposals. Cargo defines the
Ziren revision; all generated proofs, verifier builds and measurements stay
outside the repository.

Derived code retains [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE) licensing.
