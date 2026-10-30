"""Behavior tests using released runtime images; external writes are stubbed.

The Golden scenarios exercise both verification Tasks in Tekton. These cases
exercise the auxiliary Task and StepAction scripts, and positive/negative
policy inputs. A new released resource requires an explicit test here.
"""
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import yaml


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def container(image, folder, arguments, env=None, entrypoint=None):
    command = [os.environ.get('CONTAINER_ENGINE', 'docker'), 'run', '--rm',
               '--volume', f'{folder.resolve()}:/fixture', '--workdir', '/fixture']
    if entrypoint:
        command += ['--entrypoint', entrypoint]
    for key, value in (env or {}).items():
        command += ['--env', f'{key}={value}']
    return subprocess.run(command + [image] + arguments, check=True, stdout=subprocess.PIPE).stdout


def executable(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text('#!/usr/bin/env bash\nset -euo pipefail\n' + text)
    path.chmod(0o755)


def execute_step(step, folder, params, result_names, mocks):
    folder.mkdir(parents=True)
    (folder / 'results').mkdir()
    def expand(text):
        for name, value in params.items():
            text = text.replace('$(params.' + name + ')', value)
        for name in result_names:
            for prefix in ('results.', 'step.results.'):
                text = text.replace('$(' + prefix + name + '.path)', '/fixture/results/' + name)
        check(not re.search(r'\$\((?:params|results|step.results)\.', text), 'Unresolved Tekton substitution')
        return text
    for name, script in mocks.items():
        executable(folder / 'bin' / name, script)
    executable(folder / 'run.sh', 'export PATH=/fixture/bin:$PATH\n' + expand(step['script']))
    env = {e['name']: expand(e['value']) for e in step.get('env', [])}
    container(step['image'], folder, ['/fixture/run.sh'], env, '/bin/bash')
    return {name: (folder / 'results' / name).read_text() for name in result_names}


def keyless(task, output):
    steps = task['spec']['steps']
    check(len(steps) == 1, 'Add tests for new collect-keyless-params steps')
    results = [r['name'] for r in task['spec']['results']]
    for name, config in [('absent', None), ('disabled', {'enableKeylessSigning': 'false'}),
                         ('enabled', {'enableKeylessSigning': 'true', 'defaultOIDCIssuer': 'https://issuer.example',
                                      'fulcioInternalUrl': 'https://internal.example', 'fulcioExternalUrl': 'https://external.example'})]:
        script = 'exit 0\n' if config is None else "cat <<'JSON'\n" + json.dumps({'data': config}) + '\nJSON\n'
        values = execute_step(steps[0], output / name, {'configMapNamespace': 'fixture', 'configMapName': 'fixture'}, results, {'kubectl': script})
        check(values['keylessSigningEnabled'] == ('true' if name == 'enabled' else 'false'), 'Incorrect keyless flag')
        if name == 'enabled':
            check(values['defaultOIDCIssuer'] == 'https://issuer.example', 'Issuer lost')
            check(values['fulcioUrl'] == 'https://internal.example', 'Internal URL must take precedence')
        else:
            check(all(not value for key, value in values.items() if key != 'keylessSigningEnabled'), 'Disabled/missing configuration must clear results')


def attestation(action, output):
    digest = 'sha256:' + 'a' * 64
    test_output = {'result': 'SUCCESS', 'successes': 3, 'failures': 0, 'warnings': 1}
    params = {p['name']: p['default'] for p in action['spec']['params'] if 'default' in p}
    params.update({'image-url': 'registry.example/image', 'image-digest': digest, 'test-name': 'fixture', 'test-output': json.dumps(test_output)})
    mocks = {
        'select-oci-auth': "echo '{\"auths\":{}}'\n",
        'oras': '''case "$1" in
  attach) file="${@: -1}"; cp "${file%:application/json}" /fixture/statement.json ;;
  discover) echo '{"referrers":[{"digest":"''' + digest + '''"}]}' ;;
  *) exit 1 ;;
esac
'''}
    results = execute_step(action['spec'], output, params, ['ARTIFACT_URI', 'ARTIFACT_DIGEST'], mocks)
    statement = json.loads((output / 'statement.json').read_text())
    check(statement['subject'] == [{'name': params['image-url'], 'digest': {'sha256': digest[7:]}}], 'Wrong attestation subject')
    check(statement['predicate']['output'] == test_output, 'Test output lost')
    check(statement['predicate']['successes'] == 3 and statement['predicate']['warnings'] == 1, 'Wrong attestation counts')
    check(results == {'ARTIFACT_URI': params['image-url'], 'ARTIFACT_DIGEST': digest}, 'Wrong StepAction results')
    # An unsuccessful registry operation must fail the step and clear results.
    mocks['oras'] = 'exit 17\n'
    failed = output.with_name(output.name + '-failed')
    try:
        execute_step(action['spec'], failed, params, ['ARTIFACT_URI', 'ARTIFACT_DIGEST'], mocks)
    except subprocess.CalledProcessError:
        check(all(p.read_text() == '' for p in (failed / 'results').iterdir()), 'Failure must clear results')
    else:
        raise AssertionError('Registry failure was ignored')


def policies(manifest, output, timestamp):
    refs = {e['image']: e['image'] + '@' + e['digest'] for e in manifest['policy'] + manifest['components']}
    cli = refs['quay.io/conforma/cli']
    for policy, rule, good, bad in (
        ('task-policy', 'kind.expected_kind', {'apiVersion': 'tekton.dev/v1', 'kind': 'Task'}, {'apiVersion': 'tekton.dev/v1', 'kind': 'Pipeline'}),
        ('build-task-policy', 'build_labels.build_type_label_set', {'metadata': {'labels': {'build.appstudio.redhat.com/build_type': 'container'}}}, {'metadata': {'labels': {}}}),
    ):
        for label, fixture, success in [('valid', good, True), ('invalid', bad, False)]:
            folder = output / (policy + '-' + label)
            folder.mkdir(parents=True)
            (folder / 'input.json').write_text(json.dumps(fixture))
            (folder / 'policy.json').write_text(json.dumps({'sources': [{'policy': ['oci::' + refs['quay.io/conforma/' + policy]], 'config': {'include': [rule]}}]}))
            raw = container(cli, folder, ['validate', 'input', '/fixture/input.json', '--policy', '/fixture/policy.json', '--strict=false', '--info', '--show-successes', '--output', 'json', '--effective-time', timestamp, '--allow-past-effective-time'])
            (folder / 'report.json').write_bytes(raw)
            report = json.loads(raw)
            check(report['success'] is success, f'{policy} {label} returned wrong result')
            check(len(report['filepaths']) == 1, 'Missing input report')
            results = report['filepaths'][0]['successes' if success else 'violations']
            check(any(r.get('metadata', {}).get('code') == rule for r in results), f'{rule} was not evaluated')


def main():
    manifest_path, catalog, timestamp = sys.argv[1:]
    manifest = json.loads(Path(manifest_path).read_text())
    resources = {(obj['kind'], obj['metadata']['name']): obj
                 for path in Path(catalog).rglob('*.yaml') for obj in [yaml.safe_load(path.read_bytes())]}
    check(set(resources) == {('Task', 'verify-enterprise-contract'), ('Task', 'verify-conforma-konflux-ta'),
                             ('Task', 'collect-keyless-params'), ('StepAction', 'create-test-result-attestation')},
          'Released resource inventory changed: add explicit acceptance cases')
    output = Path.cwd() / 'fixtures'
    keyless(resources['Task', 'collect-keyless-params'], output / 'keyless')
    attestation(resources['StepAction', 'create-test-result-attestation'], output / 'attestation')
    policies(manifest, output, timestamp)
    print('Auxiliary Task, StepAction, and policy fixture assertions passed.')


if __name__ == '__main__':
    main()
