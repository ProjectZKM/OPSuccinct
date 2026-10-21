#!/usr/bin/env python3
"""Build a verifier from a Ziren export, optionally replaying a frozen plan."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
FLAGS = '''path-views fused-base batch-inverse fast-poseidon tower-mulmod assertion-facts
proof-cache bulk-observe dead-arithmetic closing-module fast-sample inplace-tail
calldata-tail fused-dot matrix-cache matrix-left-only fast-whir-transcript
offload-queries matrix-query-folds branchless-products stream-query-folds tensor-query-folds
loop-partial-rounds tracked-partial-sum stack-registers isolate-public-hash
assembly-initial transpose-initial-fold assembly-closing validated-leaf-fields canonical-query-inputs
fixed-whir-profile calldata-closing native-closing-driver vector-proof-cache direct-updates contiguous-results offload-proof-cache
packed-canonical derived-query-inputs shared-power-table zero-run-fields'''.split()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fixtures', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--solc', required=True)
    parser.add_argument('--plan', type=Path, help='optional external native.json for exact frozen boundaries and bytecode checks')
    parser.add_argument('--fresh', action='store_true')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()
    if args.out.resolve().is_relative_to(ROOT):
        parser.error('generated verifier artifacts must be outside the repository')
    command = [sys.executable, str(ROOT/'contracts/ziren-shrink-verifier/native/compile.py'),
               '--fixtures', str(args.fixtures), '--out', str(args.out), '--solc', args.solc,
               '--entry-runs', '10000', '--whir-runs', '2000', '--closing-runs', '10000',
               '--runs', '1', '--optimizer', 'full', '--poseidon-optimizer', 'full',
               '--poseidon-runs', '1', '--compile-timeout', '900',
               '--merkle-unroll', '8', '--base-power-window', '6']
    command.extend('--'+flag for flag in FLAGS)
    # Fresh builds defer one bounded linear layer everywhere; a replayed plan
    # keeps whatever it recorded so its bytecode reproduces exactly.
    if args.plan:
        plan = json.loads(args.plan.read_text())
        if plan.get('lazy_linear_products', False):
            command.append('--lazy-linear-products')
        command.extend(['--plan', str(args.plan)])
    else:
        command.append('--lazy-linear-products')
    if args.fresh:
        command.append('--fresh')
    if args.dry_run:
        import shlex
        print(shlex.join(command))
    else:
        subprocess.run(command, check=True)


if __name__ == '__main__':
    main()
