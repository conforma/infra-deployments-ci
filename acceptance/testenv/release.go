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
	"fmt"
	"os"
	"regexp"
)

// ReleaseImage is one digest-pinned image recorded in a release manifest.
type ReleaseImage struct {
	Image  string `json:"image"`
	Digest string `json:"digest"`
}

// Ref returns the digest-pinned reference for the image.
func (i ReleaseImage) Ref() string { return i.Image + "@" + i.Digest }

// Release is the subset of a v2 release manifest (images.json) that the
// acceptance suite consumes.
type Release struct {
	SchemaVersion int            `json:"schemaVersion"`
	Policy        []ReleaseImage `json:"policy"`
	Components    []ReleaseImage `json:"components"`
}

var digestPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// LoadRelease reads the release manifest named by RELEASE_IMAGES. It
// returns nil when the variable is unset, so developer runs of the
// acceptance suite keep their normal inputs.
func LoadRelease() (*Release, error) {
	path := os.Getenv("RELEASE_IMAGES")
	if path == "" {
		return nil, nil
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading release manifest: %w", err)
	}
	var release Release
	if err := json.Unmarshal(raw, &release); err != nil {
		return nil, fmt.Errorf("parsing release manifest %s: %w", path, err)
	}
	if release.SchemaVersion != 2 {
		return nil, fmt.Errorf("expected schemaVersion 2 in %s, got %d", path, release.SchemaVersion)
	}
	for _, image := range release.images() {
		if !digestPattern.MatchString(image.Digest) {
			return nil, fmt.Errorf("invalid digest for %s in %s: %s", image.Image, path, image.Digest)
		}
	}
	for _, name := range []string{"cli", "tekton-task", "release-policy", "task-policy", "build-task-policy"} {
		if release.Ref(name) == "" {
			return nil, fmt.Errorf("missing quay.io/conforma/%s in %s", name, path)
		}
	}
	return &release, nil
}

// Ref returns the digest-pinned reference for quay.io/conforma/<name>, or
// an empty string when the manifest has no such entry.
func (r *Release) Ref(name string) string {
	for _, image := range r.images() {
		if image.Image == "quay.io/conforma/"+name {
			return image.Ref()
		}
	}
	return ""
}

func (r *Release) images() []ReleaseImage {
	images := make([]ReleaseImage, 0, len(r.Policy)+len(r.Components))
	images = append(images, r.Policy...)
	images = append(images, r.Components...)
	return images
}
