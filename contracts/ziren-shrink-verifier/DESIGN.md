# Verifier design

## Approved computation

Ziren's compact shrinker proves verification of the native compressed recursion
proof. The child verifier still computes Poseidon2; the output proof's commitments
and transcript use the selected suite. This backend supports Keccak256.

The trusted `ShrinkVerifierData` binds suite domains, transcript absorb boundary,
parameters, child profile and canonical key geometry. Application key, recursion
root, complete successful execution and every public-output digest byte must
remain bound through native export and on-chain verification. A submitted proof
cannot choose its key, verifier program or approved module addresses.

## Export, encoding and compilation

`zkop_shrink_export::machine::export` verifies an approved reference and emits
`machine.json`, `marker.json` and `marker_shift.json`. The compiler specializes
fixed metadata and AIR while retaining proof values as runtime inputs. Unsupported
AIR or suites reject. Marker values identify inputs; they are not proof witnesses.

The separate `wire::Profile` codec pins shape and canonical field/hash traversal.
Its Raw/Shared/Dag modes preserve the full proof. The generated entry also supports
lossless hash dictionaries and zero-field runs before full verification. Those
transport mode namespaces are different. Full 256-bit hashes and proof equations
are retained. The protocol domain `ziren-keccak-wire-profile-v1` is unchanged by
the directory rename; approved profiles still depend on the key descriptor.

## On-chain execution

The entry validates packet/profile/canonicality, binds the expected output,
executes every authenticated kernel, propagates the live transcript and verifies
the complete WHIR tail: commitments, Merkle paths, grinding, sumchecks, OOD
relations and final polynomial identities. Transport or arithmetic helpers do
not independently establish proof validity.

The reference interpreter refuses to enter the WHIR tail until op 17 has
bound all 32 output-digest bytes, and the native compiler asserts the same of
the approved program at build time; the program hash is not the only guard.

The native outer verifier's jagged-eval sumcheck is replayed into the
transcript only. Its closing identity is computed directly from the opened
values, so those coefficients are transcript inputs rather than checked
relations; re-rolling them still requires clearing the WHIR proof-of-work.

Transport is not canonical on chain. The native entry accepts raw and
dictionary-encoded packets under one profile and never reads some schema
slots, while the Rust decoder accepts exactly one packet per proof.
Verification is over decoded values; key replay protection on the statement,
never on a packet hash.

Kernel, WHIR, math and constructor-created helper code is pinned. Calls use
`STATICCALL`; frame bounds restrict register updates and prevent replacing proof
bytes or the expected statement. Partial installation does not authorize proof
acceptance. The bridge adapter computes the expected digest from its authenticated
statement and accepted predecessor before calling the approved entry.

## Compiler tuning

Register promotion, bounded linear deferral and identity-product branches are
build choices recorded in the external build plan. Optional tuning applies to
one symbolic program. Lazy linear lanes remain bounded below `2*p`, and strict
uses/exported results reduce canonically. Identity-branch intervals cannot select
a lazy-linear kernel. The compiler checks range order, bounds and prerequisites.

A frozen external `native.json` records kernel boundaries, options and tuning.
Reconstruction must match the approved sources/bytecode. Approving a new build
requires its full profile, module hashes, output statement and transaction/code
limits; copying interval numbers does not approve another computation.
