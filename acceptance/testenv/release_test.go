// Copyright The Conforma Contributors
// SPDX-License-Identifier: Apache-2.0
package testenv

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

func TestReleaseInputs(t *testing.T) {
	path, err := filepath.Abs("../../spec/fixtures/release.json")
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELEASE_IMAGES", path)
	release, err := LoadRelease()
	if err != nil {
		t.Fatal(err)
	}
	snapshot, err := release.Snapshot(`{"components":[{"name":"golden","containerImage":"quay.io/example/golden-container:changed-tag"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(snapshot, release.Inputs.TestInputs.Targets[0].Ref()) || strings.Contains(snapshot, "changed-tag") {
		t.Fatal(snapshot)
	}
	if _, err := release.Snapshot(`{"components":[{"containerImage":"quay.io/unrecorded/image:latest"}]}`); err == nil {
		t.Fatal("unrecorded target accepted")
	}
	for _, rpm := range []bool{false, true} {
		policy, err := release.PolicyConfig("../..", rpm)
		if err != nil {
			t.Fatal(err)
		}
		raw, err := json.Marshal(policy)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(raw), release.Ref("release-policy")) || !strings.Contains(string(raw), release.Inputs.TestInputs.PolicyData[0]) {
			t.Fatal(string(raw))
		}
		if strings.Contains(string(raw), "@redhat_rpms") != rpm {
			t.Fatal("wrong target collection")
		}
	}
	t.Setenv("RELEASE_IMAGES", "")
	if release, err := LoadRelease(); release != nil || err != nil {
		t.Fatal("developer acceptance unexpectedly requires a release")
	}
}
