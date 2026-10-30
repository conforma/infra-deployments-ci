"""Exercise retries against a real local Git remote and simulated registry."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from .artifacts import run
from .manifest import BUNDLE, candidates, destinations, identity
from .publish import action, catalog_actions, publish, update_catalog
from .test_release import D, E, manifest


class PublicationTests(unittest.TestCase):
    def test_state_rule(self):
        self.assertEqual(action(D, E, D), 'skip')
        self.assertEqual(action(E, E, D), 'apply')
        self.assertEqual(action(None, None, b'new'), 'apply')
        self.assertEqual(action(b'new', None, b'new'), 'skip')
        for current in ('unexpected', None):
            with self.assertRaises(ValueError):
                action(current, E, D)

    def test_catalog_retry_and_unrelated_changes(self):
        with tempfile.TemporaryDirectory() as folder:
            remote, checkout = Path(folder) / 'remote', Path(folder) / 'checkout'
            run('git', 'init', '--bare', remote)
            run('git', 'clone', remote, checkout)
            run('git', 'config', 'user.name', 'test', cwd=checkout)
            run('git', 'config', 'user.email', 'test@example.com', cwd=checkout)
            (checkout / 'unrelated').write_text('preserve me')
            run('git', 'add', '.', cwd=checkout)
            run('git', 'commit', '-m', 'baseline', cwd=checkout)
            run('git', 'push', 'origin', 'HEAD:konflux', cwd=checkout)
            base = run('git', 'rev-parse', 'HEAD', cwd=checkout)
            m = manifest()
            m['catalog']['baseCommit'] = base
            resources = {'tasks/test/0.1/test.yaml': b'candidate\n\n'}
            # Simulate a lost acknowledgement after a successful server push.
            real_run = run
            pushed = []
            def ambiguous(*args, **kwargs):
                result = real_run(*args, **kwargs)
                if args[:2] == ('git', 'push') and not pushed:
                    pushed.append(True)
                    raise subprocess.CalledProcessError(1, args)
                return result
            with patch('release.publish.run', side_effect=ambiguous):
                first = update_catalog(checkout, m, resources, 'hash')
            self.assertEqual(update_catalog(checkout, m, resources, 'hash'), first)
            self.assertEqual((checkout / 'unrelated').read_text(), 'preserve me')
            self.assertEqual((checkout / next(iter(resources))).read_bytes(), b'candidate\n\n')
            (checkout / 'unrelated').write_text('another independent change')
            run('git', 'add', '.', cwd=checkout)
            run('git', 'commit', '-m', 'independent', cwd=checkout)
            run('git', 'push', 'origin', 'HEAD:konflux', cwd=checkout)
            self.assertNotEqual(update_catalog(checkout, m, resources, 'hash'), first)
            (checkout / next(iter(resources))).write_text('conflicting edit')
            run('git', 'add', '.', cwd=checkout)
            run('git', 'commit', '-m', 'conflict', cwd=checkout)
            run('git', 'push', 'origin', 'HEAD:konflux', cwd=checkout)
            with self.assertRaises(ValueError):
                update_catalog(checkout, m, resources, 'hash')

    def test_registry_partial_retry_and_stale_release(self):
        for stale in (False, True):
            with self.subTest(stale=stale), tempfile.TemporaryDirectory() as folder:
                m = manifest()
                path = Path(folder) / 'images.json'
                path.write_text(json.dumps(m))
                evidence = Path(folder) / 'acceptance.json'
                evidence.write_text(json.dumps({'status': 'passed', 'manifestHash': identity(path)}))
                desired = destinations(m)
                state = {target: E for target in desired}
                first = next(iter(state))
                state[first] = D  # already applied by a previous attempt
                if stale:
                    state[list(state)[-1]] = 'sha256:' + 'c' * 64
                copies = []
                def command(*args, **kwargs):
                    if args[0] == 'skopeo':
                        target = args[-1].removeprefix('docker://')
                        state[target] = D
                        copies.append(target)
                    return 'https://github.com/conforma/tekton-catalog.git'
                result = Path(folder) / 'result.json'
                with patch('release.publish.Registry') as registry, patch('release.publish.run', side_effect=command), patch('release.publish.fetch_catalog', return_value='head'), patch('release.publish.catalog_actions', return_value={'file': 'skip'}), patch('release.publish.update_catalog', return_value='head'):
                    registry.return_value.digest.side_effect = lambda r: state[r]
                    registry.return_value.resources.return_value = {'file': b'candidate'}
                    if stale:
                        with self.assertRaises(ValueError):
                            publish(m, path, evidence, folder, result)
                        self.assertEqual(copies, [])
                        self.assertEqual(json.loads(result.read_text())['status'], 'failed')
                    else:
                        publish(m, path, evidence, folder, result)
                        self.assertEqual(len(copies), 7)
                        self.assertNotIn(first, copies)
                        self.assertEqual(json.loads(result.read_text())['status'], 'published')
