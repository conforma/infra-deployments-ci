// Copyright The Conforma Contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

package kubernetes

import (
	"encoding/json"
	"path/filepath"
	"testing"

	pipeline "github.com/tektoncd/pipeline/pkg/apis/pipeline/v1"

	"github.com/conforma/infra-deployments-ci/acceptance/testenv"
)

const (
	testBundle      = "quay.io/conforma/tekton-task:latest"
	manifestBundle  = "quay.io/conforma/tekton-task@sha256:5555555555555555555555555555555555555555555555555555555555555555"
	manifestPolicy  = "oci::quay.io/conforma/release-policy@sha256:1111111111111111111111111111111111111111111111111111111111111111"
	repoRootForTest = "../.."
)

func releaseFixture(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs("../../spec/fixtures/release.json")
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func bundleParam(t *testing.T, p *pipeline.Pipeline, taskName string) string {
	t.Helper()
	for _, task := range p.Spec.Tasks {
		if task.Name != taskName || task.TaskRef == nil {
			continue
		}
		for _, param := range task.TaskRef.Params {
			if param.Name == "bundle" {
				return param.Value.StringVal
			}
		}
	}
	t.Fatalf("no bundle param found for task %s", taskName)
	return ""
}

func TestLoadPipelineWithBundleKeepsGivenBundleWithoutRelease(t *testing.T) {
	t.Setenv("RELEASE_IMAGES", "")
	pipeline, err := loadPipelineWithBundle(repoRootForTest, "conforma.yaml", testBundle)
	if err != nil {
		t.Fatal(err)
	}
	if got := bundleParam(t, pipeline, "verify"); got != testBundle {
		t.Errorf("bundle param = %q, want %q", got, testBundle)
	}
}

func TestLoadPipelineWithBundlePinsTaskBundleFromRelease(t *testing.T) {
	t.Setenv("RELEASE_IMAGES", releaseFixture(t))
	pipeline, err := loadPipelineWithBundle(repoRootForTest, "conforma.yaml", testBundle)
	if err != nil {
		t.Fatal(err)
	}
	if got := bundleParam(t, pipeline, "verify"); got != manifestBundle {
		t.Errorf("bundle param = %q, want %q", got, manifestBundle)
	}
}

func TestPinPolicySources(t *testing.T) {
	release := &testenv.Release{}
	if err := json.Unmarshal([]byte(`{
		"schemaVersion": 2,
		"policy": [{"image": "quay.io/conforma/release-policy", "digest": "sha256:1111111111111111111111111111111111111111111111111111111111111111"}],
		"components": []
	}`), release); err != nil {
		t.Fatal(err)
	}

	policySpec := map[string]any{}
	if err := json.Unmarshal([]byte(`{
		"sources": [
			{
				"policy": [
					"oci::quay.io/conforma/release-policy:latest",
					"oci::quay.io/other/untouched:latest"
				]
			},
			{"policy": "not-a-list"},
			{}
		]
	}`), &policySpec); err != nil {
		t.Fatal(err)
	}

	pinPolicySources(policySpec, release)

	sources := policySpec["sources"].([]any)
	policies := sources[0].(map[string]any)["policy"].([]any)
	if policies[0] != manifestPolicy {
		t.Errorf("policy ref = %v, want %s", policies[0], manifestPolicy)
	}
	if policies[1] != "oci::quay.io/other/untouched:latest" {
		t.Errorf("unrelated ref was rewritten: %v", policies[1])
	}
}

func TestPinPolicySourcesWithoutSources(t *testing.T) {
	policySpec := map[string]any{"sources": "not-a-list"}
	pinPolicySources(policySpec, &testenv.Release{})
	if policySpec["sources"] != "not-a-list" {
		t.Errorf("unexpected rewrite: %v", policySpec["sources"])
	}
}
