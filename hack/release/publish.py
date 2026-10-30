"""Promote tested content with stale-state checks and idempotent recovery."""
import json
import os
from pathlib import Path
import subprocess

from .artifacts import Registry, git_file, run
from .manifest import BUNDLE, baselines, candidates, destinations, identity, ref, require


def action(current, baseline, candidate):
    if current == candidate:
        return 'skip'
    if current == baseline:
        return 'apply'
    raise ValueError('Publication conflict: current value differs from both baseline and candidate')


def catalog_actions(repo, head, base, resources):
    return {path: action(git_file(repo, head, path), git_file(repo, base, path), raw)
            for path, raw in resources.items()}


def fetch_catalog(repo, branch):
    run('git', 'fetch', 'origin', 'refs/heads/' + branch, cwd=repo)
    return run('git', 'rev-parse', 'FETCH_HEAD', cwd=repo)


def update_catalog(repo, manifest, resources, manifest_hash):
    branch, base = manifest['catalog']['branch'], manifest['catalog']['baseCommit']
    require(not run('git', 'status', '--porcelain', cwd=repo), 'Catalog checkout must be clean')
    for attempt in range(3):
        head = fetch_catalog(repo, branch)
        states = catalog_actions(repo, head, base, resources)
        if all(s == 'skip' for s in states.values()):
            return head
        run('git', 'checkout', '--detach', head, cwd=repo)
        for path, state in states.items():
            if state == 'skip':
                continue
            root = Path(repo).resolve()
            target = root / path
            # Reject symlinked parent directories, including outside candidate paths.
            require(all(not p.is_symlink() for p in target.parents if p != root and root in p.parents), 'Symlinked catalog directory')
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(resources[path])
            run('git', 'add', '--', path, cwd=repo)
        run('git', '-c', 'user.name=github-actions[bot]', '-c',
            'user.email=github-actions[bot]@users.noreply.github.com', 'commit',
            '-m', 'Publish tested Conforma definitions', '-m', f'Manifest: {manifest_hash}', cwd=repo)
        try:
            run('git', 'push', 'origin', 'HEAD:refs/heads/' + branch, cwd=repo)
        except subprocess.CalledProcessError:
            # A failed client call can mean the server accepted the push.
            # Re-read actual contents; never force or merge over a conflict.
            continue
    head = fetch_catalog(repo, branch)
    require(all(s == 'skip' for s in catalog_actions(repo, head, base, resources).values()), 'Catalog push did not complete; retry the same manifest')
    return head


def publish(manifest, manifest_path, evidence_path, catalog, result_path):
    manifest_hash = identity(manifest_path)
    evidence = json.loads(Path(evidence_path).read_text())
    require(evidence.get('manifestHash') == manifest_hash and evidence.get('status') == 'passed', 'Successful acceptance for this exact manifest is required')
    registry = Registry()
    baseline, desired = baselines(manifest), destinations(manifest)
    result = {'manifestHash': manifest_hash, 'workflowURL': os.environ.get('WORKFLOW_URL', ''),
              'status': 'failed', 'digests': {}, 'catalogCommit': None}
    try:
        resources = registry.resources(ref(candidates(manifest)[BUNDLE]))
        require(run('git', 'remote', 'get-url', 'origin', cwd=catalog).removesuffix('.git') == 'https://github.com/conforma/tekton-catalog', 'Unexpected catalog remote')
        require(not run('git', 'status', '--porcelain', cwd=catalog), 'Catalog checkout must be clean')
        run('git', 'fetch', 'origin', manifest['catalog']['baseCommit'], cwd=catalog)
        head = fetch_catalog(catalog, manifest['catalog']['branch'])
        # Preflight every destination before any externally visible mutation.
        catalog_actions(catalog, head, manifest['catalog']['baseCommit'], resources)
        for destination, candidate in desired.items():
            action(registry.digest(destination), baseline[destination], candidate.split('@')[1])
        for destination, candidate in desired.items():
            digest = candidate.split('@')[1]
            if action(registry.digest(destination), baseline[destination], digest) == 'apply':
                command = ['skopeo', 'copy', '--all', '--preserve-digests']
                if os.environ.get('REGISTRY_AUTH_FILE'):
                    command += ['--authfile', os.environ['REGISTRY_AUTH_FILE']]
                run(*command, 'docker://' + candidate, 'docker://' + destination)
            observed = registry.digest(destination)
            result['digests'][destination] = observed
            require(observed == digest, f'Promotion changed digest: {destination}')
        result['catalogCommit'] = update_catalog(catalog, manifest, resources, manifest_hash)
        for destination, candidate in desired.items():
            observed = registry.digest(destination)
            result['digests'][destination] = observed
            require(observed == candidate.split('@')[1], f'Destination changed during publication: {destination}')
        head = fetch_catalog(catalog, manifest['catalog']['branch'])
        require(all(s == 'skip' for s in catalog_actions(catalog, head, manifest['catalog']['baseCommit'], resources).values()), 'Catalog changed during publication')
        result['catalogCommit'] = head
        result['status'] = 'published'
    except Exception as error:
        result['error'] = str(error)
        raise
    finally:
        Path(result_path).write_text(json.dumps(result, indent=2) + '\n')
