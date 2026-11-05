"""Convert an exported Groth16 proof JSON into verifier arguments.

Prints the selector, the uint256[8] proof, the uint256[3] public inputs and the
packet (selector followed by the 256-byte proof) that ZirenGroth16ProofVerifier expects.

Usage: python3 scripts/groth16_args.py <groth16_proof.json>
"""

import json
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Arguments:
    selector: str
    proof: list[str]
    inputs: list[str]
    packet: str


def arguments(proof: dict) -> Arguments:
    encoded = bytes.fromhex(proof["encoded_proof"])
    assert len(encoded) == 256, len(encoded)
    selector = "0x" + bytes(proof["groth16_vkey_hash"][:4]).hex()
    return Arguments(
        selector=selector,
        proof=["0x" + encoded[i : i + 32].hex() for i in range(0, 256, 32)],
        inputs=["0x" + format(int(x), "064x") for x in proof["public_inputs"]],
        packet=selector + encoded.hex(),
    )


def main() -> None:
    args = arguments(json.loads(Path(sys.argv[1]).read_text()))
    print("selector", args.selector)
    print("proof", "[" + ",".join(args.proof) + "]")
    print("input", "[" + ",".join(args.inputs) + "]")
    print("packet", args.packet)


if __name__ == "__main__":
    main()
