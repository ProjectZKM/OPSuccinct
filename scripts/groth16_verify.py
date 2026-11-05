#!/usr/bin/env python3
"""Deploy the Groth16 verifier and adapter, then verify a proof on a local EVM.

Builds contracts/ziren-groth16-verifier, deploys Groth16Verifier and
ZirenGroth16ProofVerifier, checks that the adapter accepts the proof and
rejects the negative cases, and prints the gas used. The recursion root is
taken from the proof's public inputs.

The output digest is computed from the committed public values: SHA-256 of the
bytes after the 8-byte little-endian length prefix in `public_values.bin`. Its top
three bits are cleared and must equal the proof's `input[1]`.

Usage: python3 scripts/groth16_verify.py --proof <groth16_proof.json> --public-values <public_values.bin>
"""

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from groth16_args import arguments  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "contracts" / "ziren-groth16-verifier"
ANVIL_DEPLOYER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"  # anvil account 0, local node only
VERIFY_SIG = "verify(bytes,bytes32)"


def output_digest(public_values: Path) -> str:
    data = public_values.read_bytes()
    length = int.from_bytes(data[:8], "little")
    if len(data) != 8 + length:
        sys.exit(f"{public_values}: length prefix {length} does not match {len(data) - 8} bytes")
    return "0x" + hashlib.sha256(data[8:]).hexdigest()


def cast(*args: str) -> str:
    result = subprocess.run(["cast", *args], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"cast {args[0]} failed: {result.stderr.strip()}")
    return result.stdout.strip()


def to_int(value) -> int:
    return int(value, 16) if isinstance(value, str) and value.startswith("0x") else int(value)


def deploy(rpc: str, deployer: str, bytecode: str, gas_limit: int) -> tuple[str, int]:
    receipt = json.loads(
        cast("send", "--unlocked", "--from", deployer, "--rpc-url", rpc,
             "--gas-limit", str(gas_limit), "--create", bytecode, "--json")
    )
    if to_int(receipt["status"]) != 1:
        sys.exit(f"deployment reverted: {receipt['transactionHash']}")
    return receipt["contractAddress"], to_int(receipt["gasUsed"])


def bytecode(artifact: str) -> str:
    return json.loads((PROJECT / "out" / artifact).read_text())["bytecode"]["object"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--proof", type=Path, required=True, help="groth16_proof.json from export_groth16")
    parser.add_argument("--public-values", type=Path, required=True,
                        help="public_values.bin of the statement the proof commits to")
    parser.add_argument("--rpc", default="http://127.0.0.1:18602")
    parser.add_argument("--deployer", default=ANVIL_DEPLOYER)
    parser.add_argument("--report", type=Path, help="optional JSON file for the results")
    args = parser.parse_args()

    subprocess.run(["forge", "build", "--silent"], cwd=PROJECT, check=True)
    proof = arguments(json.loads(args.proof.read_text()))
    app_key, committed, root = proof["inputs"]
    digest = output_digest(args.public_values)
    if int(digest, 16) & ((1 << 253) - 1) != int(committed, 16):
        sys.exit(f"output digest {digest} does not match the proof's committed value {committed}")

    verifier, verifier_gas = deploy(
        args.rpc, args.deployer,
        bytecode("Groth16Verifier.sol/Groth16Verifier.json"), 8_000_000,
    )
    ctor = cast("abi-encode", "constructor(address,bytes4,bytes32,uint256)",
                verifier, proof["selector"], app_key, root)
    adapter, adapter_gas = deploy(
        args.rpc, args.deployer,
        bytecode("ZirenGroth16ProofVerifier.sol/ZirenGroth16ProofVerifier.json") + ctor[2:], 5_000_000,
    )

    packet = proof["packet"]
    flipped = digest[:-1] + ("0" if digest[-1] != "0" else "1")
    checks = {
        "direct Groth16Verifier.Verify (no revert)": (
            "0x",
            cast("call", verifier, "Verify(uint256[8],uint256[3])",
                 "[" + ",".join(proof["proof"]) + "]", "[" + ",".join(proof["inputs"]) + "]",
                 "--rpc-url", args.rpc),
        ),
        "adapter verify": (
            "true", cast("call", adapter, f"{VERIFY_SIG}(bool)", packet, digest, "--rpc-url", args.rpc),
        ),
        "tampered last proof byte": (
            "false", cast("call", adapter, f"{VERIFY_SIG}(bool)", packet[:-2] + "00", digest, "--rpc-url", args.rpc),
        ),
        "digest changed": (
            "false", cast("call", adapter, f"{VERIFY_SIG}(bool)", packet, flipped, "--rpc-url", args.rpc),
        ),
        "selector replaced": (
            "false", cast("call", adapter, f"{VERIFY_SIG}(bool)", "0x00000000" + packet[10:], digest, "--rpc-url", args.rpc),
        ),
        "truncated packet": (
            "false", cast("call", adapter, f"{VERIFY_SIG}(bool)", packet[:100], digest, "--rpc-url", args.rpc),
        ),
    }
    receipt = json.loads(
        cast("send", "--unlocked", "--from", args.deployer, "--rpc-url", args.rpc,
             "--gas-limit", "2000000", adapter, VERIFY_SIG, packet, digest, "--json")
    )
    verify_gas = to_int(receipt["gasUsed"])
    verify_status = to_int(receipt["status"]) == 1

    results = {
        "verifier": verifier,
        "adapter": adapter,
        "gas": {
            "verifier_deployment": verifier_gas,
            "adapter_deployment": adapter_gas,
            "verify_transaction": verify_gas,
            "verify_calldata_packet_bytes": (len(packet) - 2) // 2,
        },
        "checks": {name: {"expected": want, "actual": got, "ok": got == want} for name, (want, got) in checks.items()},
    }
    results["checks"]["adapter verify transaction"] = {"expected": "success", "actual": "success" if verify_status else "reverted", "ok": verify_status}

    for name, check in results["checks"].items():
        print(f"{'ok  ' if check['ok'] else 'FAIL'} {name}: {check['actual']}")
    for name, value in results["gas"].items():
        print(f"gas {name}: {value}")
    if args.report:
        args.report.write_text(json.dumps(results, indent=2) + "\n")
    if not all(check["ok"] for check in results["checks"].values()):
        sys.exit(1)


if __name__ == "__main__":
    main()
