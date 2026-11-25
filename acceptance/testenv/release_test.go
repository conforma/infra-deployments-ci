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

package testenv

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixturePath(t *testing.T) string {
	t.Helper()
	path, err := filepath.Abs("../../spec/fixtures/release.json")
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func writeManifest(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "images.json")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestLoadReleaseUnsetKeepsDeveloperInputs(t *testing.T) {
	t.Setenv("RELEASE_IMAGES", "")
	release, err := LoadRelease()
	if err != nil {
		t.Fatal(err)
	}
	if release != nil {
		t.Fatalf("expected no release without RELEASE_IMAGES, got %+v", release)
	}
}

func TestLoadReleasePinsRequiredImages(t *testing.T) {
	t.Setenv("RELEASE_IMAGES", fixturePath(t))
	release, err := LoadRelease()
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string]string{
		"cli":               "quay.io/conforma/cli@sha256:4444444444444444444444444444444444444444444444444444444444444444",
		"tekton-task":       "quay.io/conforma/tekton-task@sha256:5555555555555555555555555555555555555555555555555555555555555555",
		"release-policy":    "quay.io/conforma/release-policy@sha256:1111111111111111111111111111111111111111111111111111111111111111",
		"task-policy":       "quay.io/conforma/task-policy@sha256:2222222222222222222222222222222222222222222222222222222222222222",
		"build-task-policy": "quay.io/conforma/build-task-policy@sha256:3333333333333333333333333333333333333333333333333333333333333333",
	}
	for name, ref := range expected {
		if got := release.Ref(name); got != ref {
			t.Errorf("Ref(%q) = %q, want %q", name, got, ref)
		}
	}
	if got := release.Ref("unknown"); got != "" {
		t.Errorf("Ref(unknown) = %q, want empty", got)
	}
}

func TestLoadReleaseMissingFile(t *testing.T) {
	t.Setenv("RELEASE_IMAGES", filepath.Join(t.TempDir(), "missing.json"))
	if _, err := LoadRelease(); err == nil {
		t.Fatal("expected an error for a missing manifest")
	}
}

func TestLoadReleaseRejectsV1Manifest(t *testing.T) {
	raw, err := os.ReadFile(fixturePath(t))
	if err != nil {
		t.Fatal(err)
	}
	manifest := strings.Replace(string(raw), `"schemaVersion": 2`, `"schemaVersion": 1`, 1)
	t.Setenv("RELEASE_IMAGES", writeManifest(t, manifest))
	if _, err := LoadRelease(); err == nil {
		t.Fatal("expected an error for a v1 manifest")
	}
}

func TestLoadReleaseMissingComponent(t *testing.T) {
	for _, image := range []string{"quay.io/conforma/cli", "quay.io/conforma/tekton-task"} {
		raw, err := os.ReadFile(fixturePath(t))
		if err != nil {
			t.Fatal(err)
		}
		var manifest map[string]any
		if err := json.Unmarshal(raw, &manifest); err != nil {
			t.Fatal(err)
		}
		components := []any{}
		for _, component := range manifest["components"].([]any) {
			if component.(map[string]any)["image"] != image {
				components = append(components, component)
			}
		}
		manifest["components"] = components
		filtered, err := json.Marshal(manifest)
		if err != nil {
			t.Fatal(err)
		}
		t.Setenv("RELEASE_IMAGES", writeManifest(t, string(filtered)))
		if _, err := LoadRelease(); err == nil || !strings.Contains(err.Error(), image) {
			t.Errorf("expected a missing %s error, got %v", image, err)
		}
	}
}

func TestLoadReleaseRejectsBadDigest(t *testing.T) {
	raw, err := os.ReadFile(fixturePath(t))
	if err != nil {
		t.Fatal(err)
	}
	manifest := strings.Replace(string(raw),
		"sha256:4444444444444444444444444444444444444444444444444444444444444444", "sha256:short", 1)
	t.Setenv("RELEASE_IMAGES", writeManifest(t, manifest))
	if _, err := LoadRelease(); err == nil {
		t.Fatal("expected an error for a malformed digest")
	}
}
