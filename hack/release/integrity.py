"""Read-only verification of the complete candidate and executable dependencies."""
import re
import tempfile

import yaml

from .artifacts import Registry
from .manifest import BUNDLE, CLI, COMMIT, candidates, immutable, ref, require
from .prepare import Preparer


class FrozenRegistry(Registry):
    def pin(self, reference):
        require(immutable(reference), f'Mutable execution reference: {reference}')
        return reference


class Inspector(Preparer):
    def build(self, resources, suffix=''):
        raise ValueError('Candidate contains an unprepared executable dependency')

    def git_resource(self, params):
        require(re.fullmatch(COMMIT, params.get('revision', '')), 'Mutable Git StepAction revision')
        return super().git_resource(params)


def inspect(manifest):
    registry = FrozenRegistry()
    entries = candidates(manifest)
    for e in [*entries.values(), *manifest['inputs'].get('dependencyBundles', [])]:
        require(registry.digest(ref(e)) == e['digest'], 'Candidate digest mismatch')
        if 'retentionTag' in e:
            require(registry.digest(e['image'] + ':' + e['retentionTag']) == e['digest'], 'Retention tag mismatch')
    resources = registry.resources(ref(entries[BUNDLE]))
    with tempfile.TemporaryDirectory() as work:
        inspector = Inspector(registry, ref(entries[CLI]), ref(entries['quay.io/conforma/release-policy']), '', work)
        for raw in resources.values():
            obj = yaml.safe_load(raw)
            import copy
            require(inspector.definition(copy.deepcopy(obj)) == obj,
                    f'Candidate definition is not fully pinned: {obj["metadata"]["name"]}')
    return resources
