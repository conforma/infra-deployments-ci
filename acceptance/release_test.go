// Copyright The Conforma Contributors
// SPDX-License-Identifier: Apache-2.0
package acceptance

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/conforma/infra-deployments-ci/acceptance/testenv"
	"sigs.k8s.io/yaml"
)

// Golden scenarios cover the two verification Tasks. These tests cover the
// auxiliary scripts and policies, using the candidate's actual runtime images.
func TestReleaseResources(t *testing.T) {
	release, err := testenv.LoadRelease()
	must(t, err)
	if release == nil {
		t.Skip("set RELEASE_IMAGES and RELEASE_CATALOG for release acceptance")
	}
	catalog := os.Getenv("RELEASE_CATALOG")
	if catalog == "" {
		t.Fatal("RELEASE_CATALOG is required")
	}
	resources := map[string]releaseScript{}
	must(t, filepath.WalkDir(catalog, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || filepath.Ext(path) != ".yaml" {
			return nil
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var resource struct {
			Kind     string
			Metadata struct{ Name string }
			Spec     releaseScript
		}
		if err := yaml.Unmarshal(raw, &resource); err != nil {
			return err
		}
		key := resource.Kind + "/" + resource.Metadata.Name
		if _, exists := resources[key]; exists {
			return fmt.Errorf("duplicate resource %s", key)
		}
		resources[key] = resource.Spec
		return nil
	}))
	expected := []string{"Task/verify-enterprise-contract", "Task/verify-conforma-konflux-ta", "Task/collect-keyless-params", "StepAction/create-test-result-attestation"}
	if len(resources) != len(expected) {
		t.Fatal("released inventory changed: add acceptance cases")
	}
	for _, name := range expected {
		if _, ok := resources[name]; !ok {
			t.Fatalf("missing resource %s", name)
		}
	}
	t.Run("keyless", func(t *testing.T) { testKeyless(t, resources[expected[2]]) })
	t.Run("attestation", func(t *testing.T) { testAttestation(t, resources[expected[3]]) })
	t.Run("policies", func(t *testing.T) { testPolicies(t, release) })
}

type releaseScript struct {
	Image, Script string
	Env           []struct{ Name, Value string }
	Params        []struct{ Name, Default string }
	Results       []struct{ Name string }
	Steps         []releaseScript
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}
func writeFixture(t *testing.T, path, value string) {
	t.Helper()
	must(t, os.MkdirAll(filepath.Dir(path), 0755))
	must(t, os.WriteFile(path, []byte(value), 0755))
}
func readFixture(t *testing.T, path string) string {
	t.Helper()
	raw, err := os.ReadFile(path)
	must(t, err)
	return string(raw)
}
func container(t *testing.T, image, folder string, options, args []string) ([]byte, error) {
	t.Helper()
	engine := os.Getenv("CONTAINER_ENGINE")
	if engine == "" {
		engine = "docker"
	}
	command := append([]string{"run", "--rm", "--volume", folder + ":/fixture", "--workdir", "/fixture"}, options...)
	command = append(append(command, image), args...)
	cmd := exec.Command(engine, command...)
	cmd.Stderr = os.Stderr
	return cmd.Output()
}
func executeScript(t *testing.T, step releaseScript, params, mocks map[string]string, names []string, fail bool) (string, map[string]string) {
	t.Helper()
	folder := t.TempDir()
	must(t, os.Mkdir(filepath.Join(folder, "results"), 0755))
	expand := func(value string) string {
		for name, replacement := range params {
			value = strings.ReplaceAll(value, "$(params."+name+")", replacement)
		}
		for _, name := range names {
			for _, prefix := range []string{"results.", "step.results."} {
				value = strings.ReplaceAll(value, "$("+prefix+name+".path)", "/fixture/results/"+name)
			}
		}
		for _, prefix := range []string{"$(params.", "$(results.", "$(step.results."} {
			if strings.Contains(value, prefix) {
				t.Fatal("unresolved Tekton substitution")
			}
		}
		return value
	}
	for name, script := range mocks {
		writeFixture(t, filepath.Join(folder, "bin", name), "#!/bin/bash\nset -euo pipefail\n"+script)
	}
	writeFixture(t, filepath.Join(folder, "run.sh"), "#!/bin/bash\nset -euo pipefail\nexport PATH=/fixture/bin:$PATH\n"+expand(step.Script))
	options := []string{"--entrypoint", "/bin/bash"}
	for _, env := range step.Env {
		options = append(options, "--env", env.Name+"="+expand(env.Value))
	}
	raw, err := container(t, step.Image, folder, options, []string{"/fixture/run.sh"})
	t.Log(string(raw))
	if (err != nil) != fail {
		t.Fatalf("expected failure=%v; got %v", fail, err)
	}
	results := map[string]string{}
	for _, name := range names {
		results[name] = readFixture(t, filepath.Join(folder, "results", name))
	}
	return folder, results
}
func testKeyless(t *testing.T, task releaseScript) {
	if len(task.Steps) != 1 {
		t.Fatal("add coverage for new keyless steps")
	}
	names := []string{}
	for _, result := range task.Results {
		names = append(names, result.Name)
	}
	for _, scenario := range []struct{ name, config string }{
		{"absent", ""}, {"disabled", `{"data":{"enableKeylessSigning":"false"}}`},
		{"enabled", `{"data":{"enableKeylessSigning":"true","defaultOIDCIssuer":"https://issuer.example","fulcioInternalUrl":"https://internal.example","fulcioExternalUrl":"https://external.example"}}`},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			mock := "cat <<'JSON'\n" + scenario.config + "\nJSON\n"
			if scenario.name == "absent" {
				mock = "exit 0"
			}
			_, results := executeScript(t, task.Steps[0], map[string]string{"configMapNamespace": "fixture", "configMapName": "fixture"}, map[string]string{"kubectl": mock}, names, false)
			expected := "false"
			if scenario.name == "enabled" {
				expected = "true"
			}
			if results["keylessSigningEnabled"] != expected {
				t.Fatal("wrong keyless flag")
			}
			if expected == "true" {
				if results["defaultOIDCIssuer"] != "https://issuer.example" || results["fulcioUrl"] != "https://internal.example" {
					t.Fatal("issuer or internal URL precedence lost")
				}
			} else {
				for name, value := range results {
					if name != "keylessSigningEnabled" && value != "" {
						t.Fatalf("uncleared result %s", name)
					}
				}
			}
		})
	}
}
func testAttestation(t *testing.T, action releaseScript) {
	digest := "sha256:" + strings.Repeat("a", 64)
	params := map[string]string{}
	for _, param := range action.Params {
		params[param.Name] = param.Default
	}
	params["image-url"], params["image-digest"], params["test-name"] = "registry.example/image", digest, "fixture"
	params["test-output"] = `{"result":"SUCCESS","successes":3,"failures":0,"warnings":1}`
	mocks := map[string]string{"select-oci-auth": `echo '{"auths":{}}'`, "oras": `case "$1" in
 attach) file="${@: -1}"; cp "${file%:application/json}" /fixture/statement.json ;;
 discover) echo '{"referrers":[{"digest":"` + digest + `"}]}' ;;
 *) exit 1 ;;
esac`}
	names := []string{"ARTIFACT_URI", "ARTIFACT_DIGEST"}
	folder, results := executeScript(t, action, params, mocks, names, false)
	var statement struct {
		Subject []struct {
			Name   string
			Digest map[string]string
		}
		Predicate struct {
			Output              json.RawMessage
			Successes, Warnings int
		}
	}
	must(t, json.Unmarshal([]byte(readFixture(t, filepath.Join(folder, "statement.json"))), &statement))
	if len(statement.Subject) != 1 || statement.Subject[0].Name != params["image-url"] || statement.Subject[0].Digest["sha256"] != digest[7:] {
		t.Fatal("wrong subject")
	}
	var actual, expected interface{}
	must(t, json.Unmarshal(statement.Predicate.Output, &actual))
	must(t, json.Unmarshal([]byte(params["test-output"]), &expected))
	if !reflect.DeepEqual(actual, expected) || statement.Predicate.Successes != 3 || statement.Predicate.Warnings != 1 {
		t.Fatal("test output or counts lost")
	}
	if results["ARTIFACT_URI"] != params["image-url"] || results["ARTIFACT_DIGEST"] != digest {
		t.Fatal("wrong StepAction results")
	}
	mocks["oras"] = "exit 17"
	_, results = executeScript(t, action, params, mocks, names, true)
	for name, value := range results {
		if value != "" {
			t.Fatalf("failed registry operation left result %s", name)
		}
	}
}
func testPolicies(t *testing.T, release *testenv.Release) {
	for _, policy := range []struct{ name, rule, good, bad string }{
		{"task-policy", "kind.expected_kind", `{"apiVersion":"tekton.dev/v1","kind":"Task"}`, `{"apiVersion":"tekton.dev/v1","kind":"Pipeline"}`},
		{"build-task-policy", "build_labels.build_type_label_set", `{"metadata":{"labels":{"build.appstudio.redhat.com/build_type":"container"}}}`, `{"metadata":{"labels":{}}}`},
	} {
		for _, valid := range []bool{true, false} {
			t.Run(fmt.Sprintf("%s/valid=%t", policy.name, valid), func(t *testing.T) {
				folder := t.TempDir()
				input := policy.bad
				if valid {
					input = policy.good
				}
				writeFixture(t, filepath.Join(folder, "input.json"), input)
				writeFixture(t, filepath.Join(folder, "policy.json"), fmt.Sprintf(`{"sources":[{"policy":[%q],"config":{"include":[%q]}}]}`, "oci::"+release.Ref(policy.name), policy.rule))
				raw, err := container(t, release.Ref("cli"), folder, nil, []string{"validate", "input", "/fixture/input.json", "--policy", "/fixture/policy.json", "--strict=false", "--info", "--show-successes", "--output", "json", "--effective-time", testenv.EffectiveTime, "--allow-past-effective-time"})
				must(t, err)
				t.Log(string(raw))
				type result struct{ Metadata struct{ Code string } }
				var report struct {
					Success   bool
					Filepaths []struct{ Successes, Violations []result }
				}
				must(t, json.Unmarshal(raw, &report))
				if report.Success != valid || len(report.Filepaths) != 1 {
					t.Fatal("unexpected policy report")
				}
				results := report.Filepaths[0].Violations
				if valid {
					results = report.Filepaths[0].Successes
				}
				for _, result := range results {
					if result.Metadata.Code == policy.rule {
						return
					}
				}
				t.Fatalf("rule %s was not evaluated", policy.rule)
			})
		}
	}
}
