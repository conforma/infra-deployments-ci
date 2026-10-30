"""Run acceptance against the manifest, retaining evidence for publication."""
import json
import copy
import os
from pathlib import Path
import re
import subprocess
import sys

import yaml

from .artifacts import write_resources
from .config import materialize
from .integrity import inspect
from .manifest import BUNDLE, candidates, identity, ref, require
from .prepare import now


def render(manifest, directory, timestamp):
    materialize(manifest, directory)
    root = Path(directory)
    entries = candidates(manifest)
    inputs = manifest['inputs']['testInputs']
    targets = {t['name']: ref(t) for t in inputs['targets']}
    collections = {t['name']: t['collection'] for t in json.loads(
        (root / 'hack/policy-behavior/targets.json').read_text())['targets']}
    template = yaml.safe_load((root / 'hack/policy-behavior/golden-policy.yaml').read_text())['spec']
    # Feature files remain the ordinary, reviewed test cases. Substitute only
    # release inputs; preserve their assertions and scenario structure.
    for feature in (root / 'features').glob('*.feature'):
        content = feature.read_text().replace(BUNDLE + ':latest', ref(entries[BUNDLE]))
        for old, new in (("quay.io/konflux-ci/ec-golden-image:latest", targets['golden-container']),
                         ("quay.io/redhat-user-workloads/rhtap-contract-tenant/golden-rpm/golden-rpm:latest", targets['golden-rpm'])):
            content = content.replace(old, new)
        def policy(match):
            original = json.loads(match.group(1))
            includes = original['sources'][0]['config']['include']
            require(includes in (['@redhat'], ['@redhat_rpms']), 'Add a target mapping for this acceptance scenario')
            target = 'golden-rpm' if includes == ['@redhat_rpms'] else 'golden-container'
            obj = copy.deepcopy(template)
            for source in obj['sources']:
                source['policy'] = ['oci::' + ref(entries['quay.io/conforma/release-policy'])]
                source['data'] = inputs['policyData']
                source.setdefault('config', {})['include'] = [collections[target]]
            return '"""\n' + json.dumps(obj, indent=2) + '\n      """'
        content = re.sub(r'"""\s*(\{.*?\})\s*"""', policy, content, flags=re.S)
        require(':latest' not in content, f'Unpinned acceptance feature: {feature}')
        feature.write_text(content)
    for filename in ('conforma.yaml', 'conforma-ta.yaml'):
        path = root / 'acceptance' / filename
        pipeline = yaml.safe_load(path.read_text())
        verify = next(t for t in pipeline['spec']['tasks'] if t['name'] == 'verify')
        verify['params'] += [{'name': 'EFFECTIVE_TIME', 'value': timestamp},
                             {'name': 'ALLOW_PAST_EFFECTIVE_TIME', 'value': 'true'}]
        if filename == 'conforma-ta.yaml':
            # Exercise the VSA branch and its remote create-trusted-artifact
            # StepAction through the prepared Task, using the test registry.
            verify['params'] += [{'name': 'ENABLE_VSA', 'value': 'true'},
                                 {'name': 'ATTESTATION_FORMAT', 'value': 'predicate'},
                                 {'name': 'ociStorage', 'value': 'local-registry.registry.svc.cluster.local:5000/vsa'}]
            pipeline['spec']['results'] += [
                {'name': 'VSA_GENERATED', 'value': '$(tasks.verify.results.VSA_GENERATED)'},
                {'name': 'sourceDataArtifact', 'value': '$(tasks.verify.results.sourceDataArtifact)'}]
        path.write_text(yaml.safe_dump(pipeline, sort_keys=False))


def acceptance(manifest, manifest_path, output):
    output = Path(output).resolve()
    require(not output.exists(), 'Use a new acceptance output directory')
    output.mkdir(parents=True)
    timestamp = now()
    evidence = {'manifestHash': identity(manifest_path), 'timestamp': timestamp,
                'digests': {e['image']: e['digest'] for e in candidates(manifest).values()}, 'status': 'failed'}
    try:
        resources = inspect(manifest)
        write_resources(resources, output / 'catalog')
        render(manifest, output / 'config', timestamp)
        # Fixtures and their assertions are loaded at the same configCommit.
        fixture_runner = output / 'config/hack/release/fixtures/run.py'
        require(fixture_runner.is_file(), 'Configuration commit lacks release fixture tests')
        for name, command, cwd in (
            ('fixtures', [sys.executable, str(fixture_runner), str(Path(manifest_path).resolve()), str(output / 'catalog'), timestamp], output),
            ('pipelines', ['go', 'test', '-count=1', '-v', '-timeout', '30m', './...'], output / 'config/acceptance'),
        ):
            with (output / (name + '.log')).open('w') as log:
                subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=True,
                               env={**os.environ, 'ACCEPTANCE_REPORT_DIR': str(output / 'reports')})
        evidence['status'] = 'passed'
    except Exception as error:
        evidence['error'] = str(error)
        raise
    finally:
        (output / 'acceptance.json').write_text(json.dumps(evidence, indent=2) + '\n')
