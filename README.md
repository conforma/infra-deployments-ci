# infra-deployments-ci

Prepare, test, and publish Conforma releases, and maintain the separate
infra-deployments update workflow.

See the [release workflow guide](docs/RELEASE_WORKFLOW.md) for preparation,
review, acceptance, publication, and recovery. The [annotated manifest
reference](docs/RELEASE_WORKFLOW_V2_DESIGN.md#release-manifest) explains every
field; [release-manifest.schema.json](docs/release-manifest.schema.json)
provides machine-readable validation.

A release pins inputs once and builds its final Task/StepAction bundle before
review. Testing and publication consume the same completed `images.json`.

To reproduce a prepared release's changelog:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r hack/release/requirements.txt
./hack/generate-changelog.sh releases/<id>/images.json
```

Run the local regression checks:

```bash
PYTHONPATH=hack python3 -m unittest discover -s hack/release -t hack -p 'test_*.py' -v
bash hack/check-release-lead-time_test.sh
shellspec
(cd acceptance && go test ./... -run '^TestValidateTestOutput$')
(cd hack/policy-rule-diff && go test ./...)
```

The legacy extraction shell tests require GNU coreutils. On macOS with
Homebrew, prepend `/opt/homebrew/opt/coreutils/libexec/gnubin` to `PATH`.
