#!/usr/bin/env python3
"""Check that all Ziren dependencies resolve to the exact Cargo.toml revision."""
from pathlib import Path
import tomllib
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]


def check_pin(root=ROOT):
    manifest = tomllib.loads((root / 'Cargo.toml').read_text())
    reference = manifest['workspace']['dependencies']['zkm-prover']
    repository, revision = reference['git'], reference['rev']
    if len(revision) != 40 or any(c not in '0123456789abcdef' for c in revision):
        raise ValueError('Ziren revision must be a full lowercase Git commit ID')
    dependencies = manifest['workspace']['dependencies']
    expected = {
        'zkm-pcs', 'zkm-prover', 'zkm-core-machine', 'zkm-core-executor',
        'zkm-recursion-core', 'zkm-primitives',
    }
    actual = {name for name, dep in dependencies.items()
              if isinstance(dep, dict) and dep.get('git') == repository}
    if not expected.issubset(actual):
        raise ValueError('shared Ziren workspace dependencies are missing or use another repository')
    for name in actual:
        if dependencies[name].get('rev') != revision:
            raise ValueError(f'{name}: Cargo.toml differs from the shared Ziren pin')
    resolved = tomllib.loads((root / 'Cargo.lock').read_text())
    packages = []
    for package in resolved['package']:
        source = package.get('source', '')
        if source.startswith('git+' + repository + '?'):
            parsed = urlsplit(source[4:])
            if parse_qs(parsed.query).get('rev') != [revision] or parsed.fragment != revision:
                raise ValueError(f'{package["name"]}: Cargo.lock differs from the shared Ziren pin')
            packages.append(package['name'])
    if not actual.issubset(packages):
        raise ValueError('Cargo.lock does not resolve all shared Ziren dependencies')
    return revision


if __name__ == '__main__':
    print(f'Shared Ziren dependency pin verified: {check_pin()}')
