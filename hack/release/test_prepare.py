import copy
import tempfile
import unittest
from unittest.mock import patch

from .artifacts import Registry
from .prepare import Preparer, pin_data
from .test_release import BUNDLE, CLI, D, task


class PreparationTests(unittest.TestCase):
    def test_git_policy_data_uses_one_commit_for_all_paths(self):
        with tempfile.TemporaryDirectory() as folder, patch('release.prepare.run', return_value='b' * 40) as run:
            values = pin_data(['git::github.com/example/data//first?ref=main',
                               'git::github.com/example/data//second?ref=main'], Registry(), folder)
            self.assertTrue(all(v.endswith('?ref=' + 'b' * 40) for v in values))
            self.assertEqual(len([c for c in run.call_args_list if c.args[1] == 'fetch']), 1)

    def remote(self):
        return {'resolver': 'git', 'params': [
            {'name': 'url', 'value': 'https://github.com/example/catalog'},
            {'name': 'revision', 'value': 'development'},
            {'name': 'pathInRepo', 'value': 'step.yaml'}]}

    def action(self, image):
        return {'apiVersion': 'tekton.dev/v1beta1', 'kind': 'StepAction',
                'metadata': {'name': 'remote'}, 'spec': {'image': image}}

    def test_mutable_remote_runtime_built_before_final_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            preparer = Preparer(Registry(), CLI + '@' + D, 'policy@' + D, 'candidate-test', folder)
            with patch.object(preparer, 'git_resource', return_value=self.action('quay.io/example/runtime:latest')), patch.object(preparer.registry, 'pin', return_value='quay.io/example/runtime@' + D), patch.object(preparer, 'build', return_value={'image': BUNDLE, 'digest': D, 'retentionTag': 'candidate-dep'}) as build:
                reference = preparer.remote(self.remote())
                self.assertEqual(reference['resolver'], 'bundles')
                self.assertEqual(reference['params'][0]['value'], BUNDLE + '@' + D)
                self.assertEqual(len(preparer.dependencies), 1)
                build.assert_called_once()
                # The original external StepAction had no version label.
                self.assertIn('stepactions/remote/candidate-test/remote.yaml', build.call_args.args[0])
                self.assertEqual(preparer.remote(self.remote()), reference)
                build.assert_called_once()

    def test_pinned_remote_runtime_needs_no_extra_bundle(self):
        with tempfile.TemporaryDirectory() as folder:
            preparer = Preparer(Registry(), CLI + '@' + D, 'policy@' + D, 'candidate-test', folder)
            def resolve(params):
                params['revision'] = 'b' * 40
                return self.action('quay.io/example/runtime@' + D)
            with patch.object(preparer, 'git_resource', side_effect=resolve), patch.object(preparer, 'build') as build:
                reference = preparer.remote(self.remote())
                self.assertEqual(reference['resolver'], 'git')
                self.assertEqual(reference['params'][1]['value'], 'b' * 40)
                build.assert_not_called()

    def test_git_revision_resolved_once_across_resource_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            preparer = Preparer(Registry(), CLI + '@' + D, 'policy@' + D, 'candidate-test', folder)
            calls = []
            def command(*args, **kwargs):
                calls.append(args)
                return 'b' * 40 if args[1] == 'rev-parse' else ''
            params = {p['name']: p['value'] for p in self.remote()['params']}
            with patch('release.prepare.run', side_effect=command), patch('release.prepare.git_file', return_value=b'kind: StepAction'):
                preparer.git_resource(copy.deepcopy(params))
                params['pathInRepo'] = 'other.yaml'
                preparer.git_resource(params)
            self.assertEqual(len([c for c in calls if c[1] == 'fetch']), 1)

    def test_parameterized_images_fail_preparation(self):
        obj = task()
        obj['spec']['steps'][0]['image'] = '$(params.runtime)'
        with self.assertRaisesRegex(ValueError, 'Parameterized'):
            Preparer(Registry(), CLI + '@' + D, 'policy@' + D, '', '.').definition(obj)
