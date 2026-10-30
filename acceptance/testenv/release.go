// Copyright The Conforma Contributors
// SPDX-License-Identifier: Apache-2.0
package testenv

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"sigs.k8s.io/yaml"
)

type Image struct{ Name, Image, Digest string }

func (i Image) Ref() string { return i.Image + "@" + i.Digest }

type Release struct {
	SchemaVersion      int
	Policy, Components []Image
	Inputs             struct {
		TestInputs struct {
			Targets    []Image
			PolicyData []string
		}
	}
}

var EffectiveTime = time.Now().UTC().Format(time.RFC3339)

// RELEASE_IMAGES selects a prepared release. Without it, the existing developer
// acceptance scenarios keep their normal inputs.
func LoadRelease() (*Release, error) {
	path := os.Getenv("RELEASE_IMAGES")
	if path == "" {
		return nil, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var release Release
	if err := json.Unmarshal(raw, &release); err != nil {
		return nil, err
	}
	if release.SchemaVersion != 2 {
		return nil, fmt.Errorf("expected release manifest version 2")
	}
	for _, image := range append(append(release.Policy, release.Components...), release.Inputs.TestInputs.Targets...) {
		if !regexp.MustCompile(`^sha256:[0-9a-f]{64}$`).MatchString(image.Digest) {
			return nil, fmt.Errorf("invalid digest for %s", image.Image)
		}
	}
	for _, name := range []string{"cli", "tekton-task", "release-policy", "task-policy", "build-task-policy"} {
		if release.Ref(name) == "" {
			return nil, fmt.Errorf("missing %s in release", name)
		}
	}
	return &release, nil
}
func (r *Release) Ref(name string) string {
	for _, image := range append(r.Policy, r.Components...) {
		if image.Image == "quay.io/conforma/"+name {
			return image.Ref()
		}
	}
	return ""
}
func (r *Release) Snapshot(value string) (string, error) {
	var snapshot struct {
		Components []map[string]interface{} `json:"components"`
	}
	if err := json.Unmarshal([]byte(value), &snapshot); err != nil {
		return "", err
	}
	for _, component := range snapshot.Components {
		reference, ok := component["containerImage"].(string)
		if !ok {
			return "", fmt.Errorf("missing snapshot image")
		}
		repository := strings.Split(strings.Split(reference, "@")[0], ":")[0]
		found := false
		for _, target := range r.Inputs.TestInputs.Targets {
			if repository == target.Image {
				component["containerImage"] = target.Ref()
				found = true
			}
		}
		if !found {
			return "", fmt.Errorf("snapshot image not recorded in release: %s", reference)
		}
	}
	raw, err := json.Marshal(snapshot)
	return string(raw), err
}

// Use the same template and target collection as the changelog comparison.
func (r *Release) PolicyConfig(root string, rpm bool) (map[string]interface{}, error) {
	raw, err := os.ReadFile(filepath.Join(root, "hack/policy-behavior/golden-policy.yaml"))
	if err != nil {
		return nil, err
	}
	var template struct{ Spec map[string]interface{} }
	if err := yaml.Unmarshal(raw, &template); err != nil {
		return nil, err
	}
	raw, err = os.ReadFile(filepath.Join(root, "hack/policy-behavior/targets.json"))
	if err != nil {
		return nil, err
	}
	var config struct {
		Targets []struct{ Name, Collection string }
	}
	if err := json.Unmarshal(raw, &config); err != nil {
		return nil, err
	}
	name := "golden-container"
	if rpm {
		name = "golden-rpm"
	}
	collection := ""
	for _, target := range config.Targets {
		if target.Name == name {
			collection = target.Collection
		}
	}
	if collection == "" {
		return nil, fmt.Errorf("missing target collection for %s", name)
	}
	for _, item := range template.Spec["sources"].([]interface{}) {
		source := item.(map[string]interface{})
		source["policy"] = []interface{}{"oci::" + r.Ref("release-policy")}
		data := []interface{}{}
		for _, ref := range r.Inputs.TestInputs.PolicyData {
			data = append(data, ref)
		}
		source["data"] = data
		source["config"].(map[string]interface{})["include"] = []interface{}{collection}
	}
	return template.Spec, nil
}
