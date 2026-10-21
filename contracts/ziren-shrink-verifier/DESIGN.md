# Verifier design

## Approved computation

Ziren's compact shrinker proves verification of the native compressed recursion
proof. The child verifier still computes Poseidon2; the output proof's commitments
and transcript use the selected suite. This backend supports Keccak256.

The trusted `ShrinkVerifierData` binds suite domains, transcript absorb boundary,
parameters, child profile and canonical key geometry. Application key, recursion
root, complete successful execution and every public-output digest byte must
remain bound through native export and on-chain verification. The shrink AIR's
public-values chip constrains only the eight Poseidon2 digest elements; every
other public value is bound to the proof solely by recomputing that digest. The
compact shrink is terminal, so its wrap program commits the root digest, as the
Groth16/PLONK wrap does: Poseidon2 over the application key, committed-value
digest, exit code and recursion root (49 elements, 7 permutations instead of
28 for the full reduce digest). The circuit still checks the child's full
digest and completeness, including the execution-shard flag. The verifier
recomputes the root digest, as Ziren's `verify_shrink_with` does; the recursion
circuit has no byte-hash gadget, so the suite hash cannot replace it. A submitted proof
cannot choose its key, verifier program or approved module addresses.

## Export, encoding and compilation

`opsuccinct_shrink_export::machine::export` verifies an approved reference and emits
`machine.json`, `marker.json` and `marker_shift.json`. The compiler specializes
fixed metadata and AIR while retaining proof values as runtime inputs. Unsupported
AIR or suites reject. Marker values identify inputs; they are not proof witnesses.
The metadata lists the root-digest input positions (`digest_inputs`); the
Poseidon2 program operation carries that explicit field list rather than a
contiguous range.

The separate `wire::Profile` codec pins shape and canonical field/hash traversal.
Its Raw/Shared/Dag modes preserve the full proof. The generated entry also supports
lossless hash dictionaries and zero-field runs before full verification. Those
transport mode namespaces are different. Full 256-bit hashes and proof equations
are retained. The protocol domain `ziren-keccak-wire-profile-v1` is unchanged by
the directory rename; approved profiles still depend on the key descriptor.

## On-chain execution

The entry validates packet/profile/canonicality, binds the expected output,
recomputes the root public-values digest and compares it with the committed one,
executes every authenticated kernel, propagates the live transcript and verifies
the complete WHIR tail: commitments, Merkle paths, grinding, sumchecks, OOD
relations and final polynomial identities. Transport or arithmetic helpers do
not independently establish proof validity.

The reference interpreter refuses to enter the WHIR tail until op 17 has
bound all 32 output-digest bytes, and the native compiler asserts the same of
the approved program at build time; the program hash is not the only guard.

Ziren's host verifier evaluates the jagged weight in closed form, one
branching program per column, and only replays the jagged-eval sumcheck.
Current Ziren leaves chip heights unpadded, which makes every column interval
unaligned, so the compiler instead verifies that sumcheck as Ziren's recursion
verifier does. It checks every round, then checks one branching program and
the equality terms of each column's prefix sums at the final point. The
claimed sum then becomes the bound weight. Prefix-sum products share their
common bits through the compiler's operation cache. Padded, power-of-two
layouts keep the cheaper closed form with a transcript-only replay.

The LogUp-GKR output check `Σ n_i/d_i = 0` is evaluated as a fraction tree. The
combined numerator must vanish and the combined denominator must be invertible,
which rejects any zero denominator as the native verifier does, with one
inversion instead of one per fraction. The chip-height masks use the height
bits as constants, because the program separately asserts that the opened
degree bits equal them.

With `derived_sumchecks`, the wire omits each sumcheck polynomial's linear
coefficient and final evaluation. The verifier reconstructs the linear
coefficient from `p(0) + p(1) = claim`, which replaces that equality check,
and carries the final evaluation forward as the reduced claim. The jagged PCS
evaluation claims (`y_per_chip`) are omitted too: each equals a zerocheck
opening already on the wire, or zero for a padding column. The decoder
restores them and the encoder rejects a proof where they differ, so the
on-chain verifier checks exactly the native proof that decoding produces.

Transport is not canonical on chain. The native entry accepts raw and
dictionary-encoded packets under one profile and never reads some schema
slots, while the Rust decoder accepts exactly one packet per proof.
Verification is over decoded values; key replay protection on the statement,
never on a packet hash.

Fresh builds generate the WHIR tail as straight-line Yul (`--aot-whir-tail`).
It is a port of the patched `StackedWhir.verify` path with every shape fixed by
the authenticated program tail: rounds, query counts, leaf geometry, path
heights and packet offsets are constants, while proof values are read from the
context calldata. It keeps the Solidity tail's ABI, checks, error stages and
calls into the pinned query and closing module. `native/differential.py`
compares a candidate build against the Solidity tail on the honest proof and
on random mutations of every proof section. A small set of proof fields
(per-chip cumulative sums and the original-commitment digests) is read by
neither the on-chain verifier nor Ziren's native verifier.

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
