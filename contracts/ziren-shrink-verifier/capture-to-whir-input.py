#!/usr/bin/env python3
"""Convert a Ziren `whir-input.json` capture into the `export-whir.py` input.

The capture is written by the export-only hook in `zkm-pcs` (`ZIREN_WHIR_EXPORT_DIR`).
Field elements are KoalaBear values serialized as Montgomery residues, and
extension elements are four-coefficient lists (basis X^4-3, low coefficient
first). The output holds canonical values, and each extension element is one
integer with its coefficients in 32-bit lanes, low lane first, as the Solidity
harness reads them.

Usage: capture-to-whir-input.py <whir-input.json> <out.json>
"""
import json
import sys
from pathlib import Path


# KoalaBear modulus and the Montgomery radix 2^32. Ziren's field serde writes
# the residue value = a * 2^32 mod p, so each element is converted back to its
# canonical form a = value * 2^-32 mod p before packing.
P = 0x7F000001
R_INV = pow(1 << 32, -1, P)


def base(v):
    assert isinstance(v, int) and 0 <= v < P, f"base field residue is {v!r}"
    return v * R_INV % P


def ext(v):
    # Extension elements serialize as {"_phantom": ..., "value": [c0, c1, c2, c3]}.
    if isinstance(v, dict):
        v = v["value"]
    assert isinstance(v, list) and len(v) == 4, f"extension element is {v!r}"
    return sum(base(c) << (32 * i) for i, c in enumerate(v))


def hash_hex(v):
    assert isinstance(v, list) and len(v) == 32 and all(isinstance(b, int) for b in v), v
    return "0x" + bytes(v).hex()


def roots_of(commitment):
    # Merkle commitments serialize as {"_marker": ..., "cap": [root, ...]}.
    return [hash_hex(r) for r in commitment["cap"]]


def single_root(commitment):
    roots = roots_of(commitment)
    assert len(roots) == 1, f"round commitment has {len(roots)} roots"
    return roots[0]


def leaf(opening):
    values = opening["values"]
    if isinstance(values, dict) and "Uniform" in values:
        width = values["Uniform"]["width"]
        flat = [base(x) for x in values["Uniform"]["values"]]
        rows = [flat[i : i + width] for i in range(0, len(flat), width)]
    elif isinstance(values, dict) and "Ragged" in values:
        rows = [[base(x) for x in row] for row in values["Ragged"]]
    else:
        raise ValueError(f"unrecognized leaf values encoding: {type(values).__name__}")
    return {"values": rows, "path": [hash_hex(h) for h in opening["proof"]]}


def config_of(cfg, stacking_height):
    return {
        "n": stacking_height,
        "startingRate": cfg["starting_log_inv_rate"],
        "batchPow": cfg["batch_pow_bits"],
        "finalQueries": cfg["final_queries"],
        "finalPow": cfg["final_pow_bits"],
        "rounds": [
            {
                "fold": r["folding_factor"],
                "rate": r["log_inv_rate"],
                "queries": r["num_queries"],
                "ood": r["ood_samples"],
                "queryPow": r["queries_pow_bits"],
                "foldPow": r["pow_bits"],
            }
            for r in cfg["round_parameters"]
        ],
    }


def proof_of(stacked):
    whir = stacked["whir_proof"]
    return {
        "batch": [[ext(x) for x in row] for row in stacked["batch_evaluations"]],
        "batchPow": base(stacked["batch_grinding_witness"]),
        "roundPolys": [
            [[ext(c) for c in poly] for poly in rnd] for rnd in whir["round_sumcheck_polys"]
        ],
        "roundOod": [[ext(x) for x in rnd] for rnd in whir["round_ood_answers"]],
        "roots": [single_root(c) for c in whir["round_commitments"]],
        "openings": [
            [leaf(opening) for opening in query["leaves"]]
            for query in whir["round_query_openings"]
        ],
        "finalPoly": [ext(x) for x in whir["final_poly"]],
        "finalPolys": [[ext(c) for c in poly] for poly in whir["final_sumcheck_polys"]],
        "foldPow": [base(w) for w in whir["folding_pow"]],
        "finalPow": base(whir["final_pow"]),
    }


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("Usage: ")[1].strip())
    cap = json.loads(Path(sys.argv[1]).read_text())
    stacking_height = cap["log_stacking_height"]
    areas = cap["areas"]
    for area in areas:
        assert area % (1 << stacking_height) == 0, "area is not aligned to the stacking height"
    out = {
        "config": config_of(cap["config"], stacking_height),
        "entry": cap["entry"],
        # Roots of the stacked commitments, one list entry per commitment cap root.
        "roots": [root for c in cap["commitments"] for root in roots_of(c)],
        # Each area spans area >> stacking_height stripes of 2^stacking_height elements.
        "stripes": [area >> stacking_height for area in areas],
        "point": [ext(x) for x in cap["point"][:stacking_height]],
        "proof": proof_of(cap["stacked_proof"]),
    }
    Path(sys.argv[2]).write_text(json.dumps(out))
    print("wrote", sys.argv[2])


if __name__ == "__main__":
    main()
