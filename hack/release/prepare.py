"""Select inputs once and assemble the final bundle before acceptance."""
import copy
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import tempfile
import uuid

import yaml

from .artifacts import Registry, git_file, repository, resource_path, run, write_resources
from .manifest import BUNDLE, CLI, COMMIT, POLICIES, ROOT, STEPS, ref, require, validate


def now():
    return datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00', 'Z')


def entry(reference):
    image, digest = reference.split('@')
    return {'image': repository(image), 'digest': digest}


def snapshot(commit, directory):
    require(re.fullmatch(COMMIT, commit), 'Configuration commit must be a full commit ID')
    paths = run('git', 'ls-tree', '-r', '--name-only', commit, '--',
                'acceptance', 'features', 'hack/policy-behavior', 'hack/release/fixtures', cwd=ROOT).splitlines()
    require(paths, 'Missing test configuration')
    for path in paths:
        raw = git_file(ROOT, commit, path)
        target = Path(directory) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)


class Preparer:
    def __init__(self, registry, cli, policy, tag, work):
        self.registry, self.cli, self.policy = registry, cli, policy
        self.tag, self.work = tag, Path(work)
        self.dependencies, self.resolved, self.visiting = [], {}, set()

    def build(self, resources, suffix=''):
        folder = self.work / ('bundle' + suffix)
        write_resources(resources, folder)
        tag = self.tag + suffix
        # Unique UUID-based tags are reserved for preparation; never overwrite one.
        command = ['tkn', 'bundle', 'push', BUNDLE + ':' + tag]
        for path in sorted(resources):
            command += ['-f', str(folder / path)]
        run(*command)
        result = entry(self.registry.pin(BUNDLE + ':' + tag))
        result['retentionTag'] = tag
        # Read the published bundle: its embedded bytes define catalog contents.
        self.registry.resources(ref(result))
        return result

    def git_resource(self, params):
        require(set(params) >= {'url', 'revision', 'pathInRepo'}, 'Git StepAction requires URL, revision, and path')
        url = params['url']
        require(url.startswith('https://') and '$(' not in url, 'Expected static HTTPS Git URL')
        folder = self.work / ('git-' + str(len(self.resolved)))
        run('git', 'init', '--bare', folder)
        run('git', 'fetch', '--depth=1', url, params['revision'], cwd=folder)
        commit = run('git', 'rev-parse', 'FETCH_HEAD', cwd=folder)
        raw = git_file(folder, commit, params['pathInRepo'])
        require(raw is not None, 'Missing remote StepAction')
        params['revision'] = commit
        return yaml.safe_load(raw)

    def remote(self, reference):
        key = json.dumps(reference, sort_keys=True)
        if key in self.resolved:
            return copy.deepcopy(self.resolved[key])
        require(key not in self.visiting, 'Cyclic StepAction dependency')
        self.visiting.add(key)
        params = {p['name']: p['value'] for p in reference.get('params', [])}
        require(len(params) == len(reference.get('params', [])), 'Duplicate resolver parameter')
        resolver = reference.get('resolver')
        if resolver == 'git':
            obj = self.git_resource(params)
        elif resolver == 'bundles':
            params['bundle'] = self.registry.pin(params['bundle'])
            matches = [yaml.safe_load(raw) for raw in self.registry.resources(params['bundle']).values()
                       if yaml.safe_load(raw)['metadata']['name'] == params['name']]
            require(len(matches) == 1, 'Ambiguous or missing remote StepAction')
            obj = matches[0]
        else:
            raise ValueError(f'Unsupported StepAction resolver: {resolver}')
        require(obj['kind'] == 'StepAction', 'Remote ref must select a StepAction')
        prepared = self.definition(copy.deepcopy(obj))
        if prepared != obj:
            dep = self.build({resource_path(prepared): yaml.safe_dump(prepared, sort_keys=False).encode()},
                             '-dep-' + str(len(self.dependencies)))
            self.dependencies.append(dep)
            resolver = 'bundles'
            params = {'bundle': ref(dep), 'name': prepared['metadata']['name'], 'kind': 'stepaction'}
        result = {'resolver': resolver, 'params': [{'name': k, 'value': v} for k, v in params.items()]}
        self.resolved[key] = result
        self.visiting.remove(key)
        return copy.deepcopy(result)

    def definition(self, obj):
        spec = obj['spec']
        for param in spec.get('params', []):
            if param['name'] == 'POLICY_BUNDLE_DIGEST':
                param['default'] = self.policy.split('@')[1]
        steps = [spec] if obj['kind'] == 'StepAction' else [*spec.get('steps', []), *spec.get('sidecars', [])]
        if 'stepTemplate' in spec:
            steps.append(spec['stepTemplate'])
        for step in steps:
            if 'image' in step:
                require('$(' not in step['image'], 'Parameterized execution image cannot be frozen')
                step['image'] = self.cli if repository(step['image']) == CLI else self.registry.pin(step['image'])
            if 'ref' in step:
                step['ref'] = self.remote(step['ref'])
        return obj


def prepare(output):
    output = Path(output)
    require(not output.exists(), f'Release directory already exists: {output}')
    registry = Registry()
    with tempfile.TemporaryDirectory() as work:
        config = run('git', 'rev-parse', 'HEAD', cwd=ROOT)
        snapshot(config, work)
        policies = [dict(entry(registry.pin(repo + ':latest')), mirrors=[mirror]) for repo, mirror in POLICIES.items()]
        cli = entry(registry.pin(CLI + ':latest'))
        source = entry(registry.pin(BUNDLE + ':latest'))
        steps = entry(registry.pin(STEPS + ':snapshot'))
        targets = json.loads((Path(work) / 'hack/policy-behavior/targets.json').read_text())['targets']
        targets = [dict(entry(registry.pin(t['image'])), name=t['name']) for t in targets]
        template = yaml.safe_load((Path(work) / 'hack/policy-behavior/golden-policy.yaml').read_text())
        data = template['spec']['sources'][0]['data']
        # The current configuration uses OCI data. Reject unsupported mutable
        # sources rather than silently carrying them into a release.
        require(all(d.startswith('oci::') for d in data), 'Preparation currently requires OCI policy data sources')
        data = ['oci::' + registry.pin(d[5:]) for d in data]
        baseline = [{'reference': repo + ':konflux', 'digest': registry.digest(repo + ':konflux')}
                    for repo in [*POLICIES, *POLICIES.values(), CLI, BUNDLE]]
        base = run('git', 'ls-remote', 'https://github.com/conforma/tekton-catalog.git', 'refs/heads/konflux').split()[0]
        preparer = Preparer(registry, ref(cli), ref(policies[0]), 'candidate-' + uuid.uuid4().hex, work)
        resources = registry.resources(ref(source))
        for path, raw in registry.resources(ref(steps)).items():
            require(path not in resources, f'Duplicate source resource: {path}')
            resources[path] = raw
        prepared = {}
        for raw in resources.values():
            obj = preparer.definition(yaml.safe_load(raw))
            path = resource_path(obj)
            require(path not in prepared, f'Duplicate prepared resource: {path}')
            prepared[path] = yaml.safe_dump(obj, sort_keys=False).encode()
        bundle = preparer.build(prepared)
        manifest = {'schemaVersion': 2, 'policy': policies, 'components': [cli, bundle],
                    'inputs': {'sourceTaskBundle': source, 'stepActionsBundle': steps,
                               'testInputs': {'configCommit': config, 'targets': targets, 'policyData': data, 'comparisonTime': now()}},
                    'catalog': {'repository': 'conforma/tekton-catalog', 'branch': 'konflux', 'baseCommit': base},
                    'baseline': {'images': baseline}}
        if preparer.dependencies:
            manifest['inputs']['dependencyBundles'] = preparer.dependencies
        validate(manifest)
        output.mkdir(parents=True)
        (output / 'images.json').write_text(json.dumps(manifest, indent=2) + '\n')
