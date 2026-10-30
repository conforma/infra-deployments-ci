import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import yaml

from .acceptance import acceptance, render
from .manifest import ROOT
from .test_release import D, manifest


class AcceptanceTests(unittest.TestCase):
    def test_rendered_suite_uses_all_recorded_inputs(self):
        def snapshot(commit, directory):
            for name in ('features', 'acceptance', 'hack/policy-behavior'):
                shutil.copytree(ROOT / name, Path(directory) / name)
        with tempfile.TemporaryDirectory() as folder, patch('release.config.snapshot', side_effect=snapshot):
            m = manifest()
            timestamp = '2026-10-30T01:02:03Z'
            render(m, folder, timestamp)
            for feature in (Path(folder) / 'features').glob('*.feature'):
                text = feature.read_text()
                self.assertNotIn(':latest', text)
                self.assertIn(m['inputs']['testInputs']['policyData'][0], text)
                self.assertIn('quay.io/conforma/tekton-task@' + D, text)
            pipeline = yaml.safe_load((Path(folder) / 'acceptance/conforma-ta.yaml').read_text())
            params = {p['name']: p['value'] for p in pipeline['spec']['tasks'][-1]['params']}
            self.assertEqual(params['EFFECTIVE_TIME'], timestamp)
            self.assertEqual(params['ENABLE_VSA'], 'true')
            self.assertTrue(params['ociStorage'])
            baseline = json.loads((Path(folder) / 'before.json').read_text())
            self.assertEqual(baseline['components'][0]['digest'], m['baseline']['images'][0]['digest'])

    def test_failed_acceptance_never_writes_success_evidence(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'images.json'
            path.write_text(json.dumps(manifest()))
            out = Path(folder) / 'results'
            with patch('release.acceptance.inspect', side_effect=ValueError('mutable StepAction')):
                with self.assertRaises(ValueError):
                    acceptance(manifest(), path, out)
            result = json.loads((out / 'acceptance.json').read_text())
            self.assertEqual(result['status'], 'failed')
            self.assertIn('mutable', result['error'])
