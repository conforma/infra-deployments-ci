"""OCI and Git reads; bundle extraction preserves resource bytes."""
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile

import yaml

from .manifest import DIGEST, immutable, require


def run(*args, cwd=None, binary=False):
    result = subprocess.run([str(a) for a in args], cwd=cwd, check=True,
                            stdout=subprocess.PIPE)
    return result.stdout if binary else result.stdout.decode().strip()


def repository(reference):
    value = reference.split('@')[0]
    return value.rsplit(':', 1)[0] if ':' in value.rsplit('/', 1)[-1] else value


class Registry:
    def __init__(self):
        self.pins = {}

    def pin(self, reference):
        if immutable(reference):
            return reference
        if reference not in self.pins:
            digest = self.digest(reference)
            self.pins[reference] = repository(reference) + '@' + digest
        return self.pins[reference]

    def digest(self, reference):
        digest = run('crane', 'digest', reference)
        require(re.fullmatch(DIGEST, digest), f'Invalid digest for {reference}')
        return digest

    def resources(self, reference):
        require(immutable(reference), f'Bundle must be pinned: {reference}')
        manifest = json.loads(run('crane', 'manifest', reference))
        resources = {}
        identities = set()
        for layer in manifest['layers']:
            annotations = layer.get('annotations', {})
            kind = annotations.get('dev.tekton.image.kind')
            require(kind in ('task', 'stepaction'), f'Unsupported bundle resource: {kind}')
            blob = run('crane', 'blob', repository(reference) + '@' + layer['digest'], binary=True)
            import hashlib
            require('sha256:' + hashlib.sha256(blob).hexdigest() == layer['digest'], 'Layer digest mismatch')
            with tarfile.open(fileobj=io.BytesIO(blob), mode='r:*') as archive:
                files = [m for m in archive.getmembers() if m.isfile()]
                require(len(files) == 1 and all(m.isfile() or m.isdir() for m in archive.getmembers()), 'Expected one regular resource file per layer')
                raw = archive.extractfile(files[0]).read()
            obj = yaml.safe_load(raw)
            path = resource_path(obj)
            identity = (obj['kind'], obj['metadata']['name'])
            require(identity not in identities, f'Duplicate resource identity: {identity}')
            identities.add(identity)
            require(obj['kind'].lower() == kind and obj['metadata']['name'] == annotations.get('dev.tekton.image.name'), 'Layer metadata disagrees with resource')
            require(path not in resources, f'Duplicate bundle resource: {path}')
            resources[path] = raw
        require(resources, 'Empty bundle')
        return resources


def resource_path(obj):
    require(isinstance(obj, dict) and obj.get('kind') in ('Task', 'StepAction'), 'Expected Task or StepAction')
    meta = obj['metadata']
    name, version = meta['name'], meta.get('labels', {}).get('app.kubernetes.io/version', '')
    for value in (name, version):
        require(isinstance(value, str) and re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*', value), 'Missing or unsafe resource name/version')
    directory = 'tasks' if obj['kind'] == 'Task' else 'stepactions'
    return f'{directory}/{name}/{version}/{name}.yaml'


def write_resources(resources, directory):
    for path, raw in resources.items():
        target = Path(directory) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        require(not target.exists(), f'Resource already exists: {path}')
        target.write_bytes(raw)


def git_file(repo, commit, path):
    # ls-tree distinguishes absence from failure (including a missing commit).
    entry = run('git', 'ls-tree', commit, '--', path, cwd=repo)
    if not entry:
        return None
    require(entry.split()[0] in ('100644', '100755'), f'Git path is not a regular file: {path}')
    return run('git', 'show', f'{commit}:{path}', cwd=repo, binary=True)
