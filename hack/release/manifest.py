"""The release contract shared by preparation, testing, and publication."""
import hashlib
import json
from pathlib import Path
import re
from datetime import datetime

import jsonschema

ROOT = Path(__file__).resolve().parents[2]
POLICIES = {
    'quay.io/conforma/release-policy': 'quay.io/enterprise-contract/ec-release-policy',
    'quay.io/conforma/task-policy': 'quay.io/enterprise-contract/ec-task-policy',
    'quay.io/conforma/build-task-policy': 'quay.io/enterprise-contract/ec-build_task-policy',
}
CLI = 'quay.io/conforma/cli'
BUNDLE = 'quay.io/conforma/tekton-task'
STEPS = 'quay.io/conforma/step-actions'
DIGEST = r'sha256:[0-9a-f]{64}'
COMMIT = r'[0-9a-f]{40}'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def ref(entry):
    return entry['image'] + '@' + entry['digest']


def candidates(manifest):
    return {e['image']: e for e in manifest['policy'] + manifest['components']}


def destinations(manifest):
    return {repo + ':konflux': ref(e)
            for e in manifest['policy'] + manifest['components']
            for repo in [e['image'], *e.get('mirrors', [])]}


def baselines(manifest):
    return {e['reference']: e['digest'] for e in manifest['baseline']['images']}


def validate(manifest):
    schema = json.loads((ROOT / 'docs/release-manifest.schema.json').read_text())
    jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker()).validate(manifest)
    entries = manifest['policy'] + manifest['components']
    require(len(candidates(manifest)) == len(entries), 'Duplicate candidate repository')
    require({e['image'] for e in manifest['policy']} == set(POLICIES), 'Expected the three Conforma policies')
    require({e['image'] for e in manifest['components']} == {CLI, BUNDLE}, 'Expected CLI and final Task bundle')
    for e in manifest['policy']:
        require(e['mirrors'] == [POLICIES[e['image']]], 'Unexpected policy mirror')
    require('retentionTag' in candidates(manifest)[BUNDLE], 'Final bundle requires retentionTag')
    require(manifest['inputs']['sourceTaskBundle']['image'] == BUNDLE, 'Unexpected source Task repository')
    require(manifest['inputs']['stepActionsBundle']['image'] == STEPS, 'Unexpected StepAction repository')
    require(len(baselines(manifest)) == len(manifest['baseline']['images']), 'Duplicate baseline')
    require(set(baselines(manifest)) == set(destinations(manifest)), 'Baseline must cover all eight destinations')
    targets = manifest['inputs']['testInputs']['targets']
    timestamp = manifest['inputs']['testInputs']['comparisonTime']
    require(re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})', timestamp), 'Comparison time must be RFC3339 with a timezone')
    datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    require(len(targets) == 2 and {t['name'] for t in targets} == {'golden-container', 'golden-rpm'}, 'Expected both Golden targets exactly once')
    dependencies = manifest['inputs'].get('dependencyBundles', [])
    require(len({ref(e) for e in dependencies}) == len(dependencies), 'Duplicate dependency bundle')
    return manifest


def load(path):
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            require(key not in obj, f'Duplicate JSON key: {key}')
            obj[key] = value
        return obj
    return validate(json.loads(Path(path).read_bytes(), object_pairs_hook=unique))


def identity(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def immutable(value):
    return bool(re.fullmatch(r'[^\s@]+@' + DIGEST, value))
