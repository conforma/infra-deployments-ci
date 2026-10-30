"""Materialize the recorded configuration without resolving source tags."""
import copy
import difflib
import json
from pathlib import Path
import tempfile

import yaml

from .artifacts import Registry, git_file, run
from .manifest import BUNDLE, baselines, candidates, ref
from .prepare import snapshot


def materialize(manifest, directory):
    directory = Path(directory)
    inputs = manifest['inputs']['testInputs']
    snapshot(inputs['configCommit'], directory)
    targets_path = directory / 'hack/policy-behavior/targets.json'
    targets = json.loads(targets_path.read_text())
    pins = {t['name']: ref(t) for t in inputs['targets']}
    for target in targets['targets']:
        target['image'] = pins[target['name']]
    targets_path.write_text(json.dumps(targets, indent=2) + '\n')
    template_path = directory / 'hack/policy-behavior/golden-policy.yaml'
    template = yaml.safe_load(template_path.read_text())
    for source in template['spec']['sources']:
        source['data'] = inputs['policyData']
    template_path.write_text(yaml.safe_dump(template, sort_keys=False))
    before = copy.deepcopy(manifest)
    for item in before['policy'] + before['components']:
        item['digest'] = baselines(manifest)[item['image'] + ':konflux']
    (directory / 'before.json').write_text(json.dumps(before))


def catalog_changelog(manifest):
    resources = Registry().resources(ref(candidates(manifest)[BUNDLE]))
    print('\n## Task and StepAction definitions\n')
    for key in ('sourceTaskBundle', 'stepActionsBundle'):
        print(f'- {key}: `{ref(manifest["inputs"][key])}`')
    for dep in manifest['inputs'].get('dependencyBundles', []):
        print(f'- Prepared dependency: `{ref(dep)}`')
    print('\nThe following diffs include execution reference and policy-default changes.\n')
    with tempfile.TemporaryDirectory() as folder:
        run('git', 'init', '--bare', folder)
        run('git', 'fetch', '--depth=1', 'https://github.com/conforma/tekton-catalog.git', manifest['catalog']['baseCommit'], cwd=folder)
        for path, raw in sorted(resources.items()):
            before = git_file(folder, manifest['catalog']['baseCommit'], path)
            print(f'### `{path}`\n')
            if before == raw:
                print('No changes.\n')
            else:
                # Four-backtick fences also safely contain YAML script fences.
                print('````diff')
                print(''.join(difflib.unified_diff((before or b'').decode().splitlines(keepends=True), raw.decode().splitlines(keepends=True), fromfile=path + ' (baseline)', tofile=path + ' (candidate)')), end='')
                print('\n````\n')
