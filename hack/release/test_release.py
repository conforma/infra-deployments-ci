"""Offline regression tests for the release contract and recovery behavior."""
import copy
import hashlib
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from .artifacts import Registry, resource_path
from .integrity import FrozenRegistry
from .manifest import BUNDLE, CLI, POLICIES, STEPS, validate
from .prepare import Preparer

D = 'sha256:' + 'a' * 64
E = 'sha256:' + 'b' * 64


def manifest():
    artifact = lambda image: {'image': image, 'digest': D}
    return {'schemaVersion': 2,
            'policy': [dict(artifact(p), mirrors=[m]) for p, m in POLICIES.items()],
            'components': [artifact(CLI), dict(artifact(BUNDLE), retentionTag='candidate-test')],
            'inputs': {'sourceTaskBundle': artifact(BUNDLE), 'stepActionsBundle': artifact(STEPS),
                       'testInputs': {'configCommit': 'a' * 40, 'comparisonTime': '2026-10-30T00:00:00Z',
                                      'targets': [dict(artifact('quay.io/example/' + n), name=n) for n in ('golden-container', 'golden-rpm')],
                                      'policyData': ['oci::quay.io/example/data@' + D]}},
            'catalog': {'repository': 'conforma/tekton-catalog', 'branch': 'konflux', 'baseCommit': 'b' * 40},
            'baseline': {'images': [{'reference': r + ':konflux', 'digest': E} for r in [*POLICIES, *POLICIES.values(), CLI, BUNDLE]]}}


def task():
    return {'apiVersion': 'tekton.dev/v1', 'kind': 'Task',
            'metadata': {'name': 'test', 'labels': {'app.kubernetes.io/version': '0.1'}},
            'spec': {'params': [{'name': 'POLICY_BUNDLE_DIGEST', 'default': E}],
                     'steps': [{'name': 'test', 'image': CLI + ':latest'}]}}


class ContractTests(unittest.TestCase):
    def test_valid_manifest(self):
        validate(manifest())

    def test_invalid_contracts(self):
        for mutation in (
            lambda m: m.pop('schemaVersion'),
            lambda m: m['baseline']['images'].pop(),
            lambda m: m['components'].append(m['components'][0]),
            lambda m: m['policy'][0].update(mirrors=['quay.io/other/repo']),
            lambda m: m['inputs']['testInputs'].update(configCommit='main'),
            lambda m: m['inputs']['testInputs'].update(comparisonTime='2026-10-30'),
            lambda m: m['components'][1].pop('retentionTag'),
            lambda m: m.update(unexpected=True),
        ):
            m = manifest()
            mutation(m)
            with self.subTest(m=m), self.assertRaises(Exception):
                validate(m)

    def test_frozen_registry_never_resolves_tags(self):
        with patch('release.artifacts.run') as run:
            self.assertEqual(FrozenRegistry().pin(CLI + '@' + D), CLI + '@' + D)
            with self.assertRaises(ValueError):
                FrozenRegistry().pin(CLI + ':latest')
            run.assert_not_called()

    def test_source_resolved_once(self):
        with patch('release.artifacts.run', return_value=D) as run:
            registry = Registry()
            self.assertEqual(registry.pin(CLI + ':latest'), registry.pin(CLI + ':latest'))
            run.assert_called_once()

    def test_preparation_updates_cli_and_policy_and_conditional_images(self):
        obj = task()
        obj['spec']['steps'][0]['when'] = [{'input': 'false', 'operator': 'in', 'values': ['true']}]
        prepared = Preparer(Registry(), CLI + '@' + D, 'quay.io/conforma/release-policy@' + D, 'candidate-test', '.').definition(obj)
        self.assertEqual(prepared['spec']['steps'][0]['image'], CLI + '@' + D)
        self.assertEqual(prepared['spec']['params'][0]['default'], D)

    def test_unsafe_resource_paths(self):
        for value in ('../outside', '', '/absolute', '..'):
            obj = task()
            obj['metadata']['labels']['app.kubernetes.io/version'] = value
            with self.assertRaises(ValueError):
                resource_path(obj)

    def test_extraction_preserves_exact_bytes_and_rejects_duplicates(self):
        raw = b'# preserve comments and trailing newlines\n' + json.dumps(task()).encode() + b'\n\n'
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode='w:gz') as archive:
            info = tarfile.TarInfo('resource.yaml')
            info.size = len(raw)
            archive.addfile(info, io.BytesIO(raw))
        blob = stream.getvalue()
        layer = {'digest': 'sha256:' + hashlib.sha256(blob).hexdigest(),
                 'annotations': {'dev.tekton.image.kind': 'task', 'dev.tekton.image.name': 'test'}}
        with patch('release.artifacts.run', side_effect=[json.dumps({'layers': [layer]}), blob]):
            self.assertEqual(Registry().resources(BUNDLE + '@' + D), {'tasks/test/0.1/test.yaml': raw})
        with patch('release.artifacts.run', side_effect=[json.dumps({'layers': [layer, layer]}), blob, blob]):
            with self.assertRaisesRegex(ValueError, 'Duplicate'):
                Registry().resources(BUNDLE + '@' + D)


if __name__ == '__main__':
    unittest.main()
