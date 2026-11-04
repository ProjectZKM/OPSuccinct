#!/usr/bin/env python3
"""Check that all Ziren dependencies share one repository and one rev or branch, and that Cargo.lock resolves them to one commit."""
from pathlib import Path
import tomllib
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
REF_KEYS = ('rev', 'branch', 'tag')


def git_ref(dep):
    for key in REF_KEYS:
        if key in dep:
            return key, dep[key]
    return None, None


def check_pin(root=ROOT):
    manifest = tomllib.loads((root / 'Cargo.toml').read_text())
    dependencies = manifest['workspace']['dependencies']
    reference = dependencies['zkm-prover']
    repository = reference['git']
    expected = {
        'zkm-pcs', 'zkm-prover', 'zkm-core-machine', 'zkm-core-executor',
        'zkm-recursion-core', 'zkm-primitives',
    }
    actual = {name for name, dep in dependencies.items()
              if isinstance(dep, dict) and dep.get('git') == repository}
    if not expected.issubset(actual):
        raise ValueError('shared Ziren workspace dependencies are missing or use another repository')
    refs = {name: git_ref(dependencies[name]) for name in actual}
    if len(set(refs.values())) != 1:
        raise ValueError(f'shared Ziren dependencies disagree on rev/branch: {refs}')
    key, value = next(iter(refs.values()))
    if key == 'rev' and (len(value) != 40 or any(c not in '0123456789abcdef' for c in value)):
        raise ValueError('Ziren revision must be a full lowercase Git commit ID')
    resolved = tomllib.loads((root / 'Cargo.lock').read_text())
    commits = {}
    for package in resolved['package']:
        source = package.get('source', '')
        if source.startswith('git+' + repository + '?'):
            parsed = urlsplit(source[4:])
            commits.setdefault(parsed.fragment, []).append(package['name'])
    if len(commits) != 1:
        raise ValueError(f'Cargo.lock resolves shared Ziren dependencies to several commits: {sorted(commits)}')
    commit = next(iter(commits))
    if key == 'rev' and commit != value:
        raise ValueError('Cargo.lock differs from the shared Ziren rev')
    if not actual.issubset(commits[commit]):
        raise ValueError('Cargo.lock does not resolve all shared Ziren dependencies')
    return f'{key}={value} (lock commit {commit})'


if __name__ == '__main__':
    print(f'Shared Ziren dependency pin verified: {check_pin()}')
