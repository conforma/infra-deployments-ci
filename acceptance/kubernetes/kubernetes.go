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
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/cucumber/godog"
	pipeline "github.com/tektoncd/pipeline/pkg/apis/pipeline/v1"
	tekton "github.com/tektoncd/pipeline/pkg/client/clientset/versioned/typed/pipeline/v1"
	corev1 "k8s.io/api/core/v1"
	rbacv1 "k8s.io/api/rbac/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/yaml"

	"github.com/conforma/infra-deployments-ci/acceptance/kubernetes/kind"
	"github.com/conforma/infra-deployments-ci/acceptance/log"
	"github.com/conforma/infra-deployments-ci/acceptance/testenv"
)

// testState holds state for a single test scenario
type testState struct {
	namespace       string
	policyName      string
	pipelineRunName string
	pipelineResult  bool
	testOutput      string
}

type testStateKey struct{}

func (t testState) Key() any {
	return testStateKey{}
}

type pipelineKey struct{}

// AddStepsTo adds cluster-related steps to the scenario context
func AddStepsTo(sc *godog.ScenarioContext) {
	// Cluster setup
	sc.Step(`^a cluster running$`, startCluster)
	sc.Step(`^the conforma pipeline using task bundle "([^"]*)"$`, installPipelineWithBundle)
	sc.Step(`^a working namespace$`, createNamespace)
	sc.Step(`^a policy configuration with content:$`, createPolicy)
	sc.Step(`^the conforma pipeline is run with:$`, runPipeline)
	sc.Step(`^the pipeline should succeed$`, pipelineShouldSucceed)
	sc.Step(`^the pipeline should fail$`, pipelineShouldFail)

	// Cleanup after scenario
	sc.After(func(ctx context.Context, sc *godog.Scenario, err error) (context.Context, error) {
		// Release cluster consumer - must be called if Start() was successful
		clusterState := testenv.FetchState[kind.ClusterState](ctx)
		if clusterState != nil {
			clusterState.Stop()
		}
		return ctx, nil
	})
}

// InitializeSuite sets up suite-level hooks
func InitializeSuite(ctx context.Context, tsc *godog.TestSuiteContext) {
	tsc.AfterSuite(func() {
		kind.Destroy(ctx)
	})
}

func startCluster(ctx context.Context) (context.Context, error) {
	return kind.Start(ctx)
}

func installPipelineWithBundle(ctx context.Context, taskBundle string) (context.Context, error) {
	logger, ctx := log.LoggerFor(ctx)
	logger.Log("Installing conforma pipeline with task bundle: %s", taskBundle)

	// Read the pipeline definition
	repoRoot := testenv.RepoRoot(ctx)
	pipelineYaml, err := os.ReadFile(filepath.Join(repoRoot, "acceptance", "conforma.yaml"))
	if err != nil {
		return ctx, fmt.Errorf("reading pipeline file: %w", err)
	}

	// Parse the pipeline
	var pipelineObj pipeline.Pipeline
	if err := yaml.Unmarshal(pipelineYaml, &pipelineObj); err != nil {
		return ctx, fmt.Errorf("parsing pipeline: %w", err)
	}

	// Update the task bundle reference in taskRef resolver params
	for i := range pipelineObj.Spec.Tasks {
		task := &pipelineObj.Spec.Tasks[i]
		if task.TaskRef != nil && task.TaskRef.Resolver == "bundles" {
			for j := range task.TaskRef.Params {
				if task.TaskRef.Params[j].Name == "bundle" {
					task.TaskRef.Params[j].Value = pipeline.ParamValue{
						Type:      pipeline.ParamTypeString,
						StringVal: taskBundle,
					}
				}
			}
		}
	}

	// Store pipeline for later use in namespace creation
	ctx = context.WithValue(ctx, pipelineKey{}, &pipelineObj)

	logger.Log("Pipeline loaded: %s", pipelineObj.Name)
	return ctx, nil
}

func createNamespace(ctx context.Context) (context.Context, error) {
	logger, ctx := log.LoggerFor(ctx)

	clusterState := testenv.FetchState[kind.ClusterState](ctx)
	if clusterState == nil {
		return ctx, errors.New("cluster not initialized")
	}

	kubeconfig, err := clusterState.KubeConfig()
	if err != nil {
		return ctx, fmt.Errorf("getting kubeconfig: %w", err)
	}

	config, err := clientcmd.RESTConfigFromKubeConfig([]byte(kubeconfig))
	if err != nil {
		return ctx, fmt.Errorf("parsing kubeconfig: %w", err)
	}

	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return ctx, fmt.Errorf("creating client: %w", err)
	}

	// Create namespace
	ns, err := client.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: "acceptance-",
		},
	}, metav1.CreateOptions{})
	if err != nil {
		return ctx, fmt.Errorf("creating namespace: %w", err)
	}

	state := testState{namespace: ns.Name}
	ctx, _ = testenv.SetupState(ctx, &state)

	logger.Log("Created namespace: %s", ns.Name)

	// Create RBAC for default service account to read EnterpriseContractPolicy
	_, err = client.RbacV1().Roles(ns.Name).Create(ctx, &rbacv1.Role{
		ObjectMeta: metav1.ObjectMeta{
			Name: "ec-policy-reader",
		},
		Rules: []rbacv1.PolicyRule{
			{
				APIGroups: []string{"appstudio.redhat.com"},
				Resources: []string{"enterprisecontractpolicies"},
				Verbs:     []string{"get", "list", "watch"},
			},
			{
				APIGroups: []string{""},
				Resources: []string{"secrets"},
				Verbs:     []string{"get"},
			},
		},
	}, metav1.CreateOptions{})
	if err != nil {
		return ctx, fmt.Errorf("creating role: %w", err)
	}

	_, err = client.RbacV1().RoleBindings(ns.Name).Create(ctx, &rbacv1.RoleBinding{
		ObjectMeta: metav1.ObjectMeta{
			Name: "ec-policy-reader-binding",
		},
		RoleRef: rbacv1.RoleRef{
			APIGroup: "rbac.authorization.k8s.io",
			Kind:     "Role",
			Name:     "ec-policy-reader",
		},
		Subjects: []rbacv1.Subject{
			{
				Kind:      "ServiceAccount",
				Name:      "default",
				Namespace: ns.Name,
			},
		},
	}, metav1.CreateOptions{})
	if err != nil {
		return ctx, fmt.Errorf("creating rolebinding: %w", err)
	}

	logger.Log("Created RBAC for EC policy access")

	// Create secret with public key for signature verification
	pubKeyData, err := os.ReadFile(filepath.Join(testenv.RepoRoot(ctx), "acceptance", "pub.key"))
	if err != nil {
		return ctx, fmt.Errorf("reading public key: %w", err)
	}

	_, err = client.CoreV1().Secrets(ns.Name).Create(ctx, &corev1.Secret{
		ObjectMeta: metav1.ObjectMeta{
			Name: "public-key",
		},
		Data: map[string][]byte{
			"cosign.pub": pubKeyData,
		},
	}, metav1.CreateOptions{})
	if err != nil {
		return ctx, fmt.Errorf("creating public key secret: %w", err)
	}

	logger.Log("Created public key secret")

	// Install pipeline in namespace
	pipelineObj := ctx.Value(pipelineKey{}).(*pipeline.Pipeline)
	if pipelineObj != nil {
		tektonClient, err := tekton.NewForConfig(config)
		if err != nil {
			return ctx, fmt.Errorf("creating tekton client: %w", err)
		}

		pipelineObj.Namespace = ns.Name
		_, err = tektonClient.Pipelines(ns.Name).Create(ctx, pipelineObj, metav1.CreateOptions{})
		if err != nil {
			return ctx, fmt.Errorf("creating pipeline: %w", err)
		}
		logger.Log("Pipeline installed in namespace: %s", ns.Name)
	}

	return ctx, nil
}

func createPolicy(ctx context.Context, content *godog.DocString) (context.Context, error) {
	logger, ctx := log.LoggerFor(ctx)

	state := testenv.FetchState[testState](ctx)
	if state == nil {
		return ctx, errors.New("test state not initialized")
	}

	clusterState := testenv.FetchState[kind.ClusterState](ctx)
	if clusterState == nil {
		return ctx, errors.New("cluster not initialized")
	}

	kubeconfig, err := clusterState.KubeConfig()
	if err != nil {
		return ctx, fmt.Errorf("getting kubeconfig: %w", err)
	}

	config, err := clientcmd.RESTConfigFromKubeConfig([]byte(kubeconfig))
	if err != nil {
		return ctx, fmt.Errorf("parsing kubeconfig: %w", err)
	}

	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return ctx, fmt.Errorf("creating dynamic client: %w", err)
	}

	// Parse the policy spec from JSON
	var policySpec map[string]interface{}
	if err := json.Unmarshal([]byte(content.Content), &policySpec); err != nil {
		return ctx, fmt.Errorf("parsing policy spec: %w", err)
	}

	// Create EnterpriseContractPolicy CR
	policyName := "test-policy"
	policy := &unstructured.Unstructured{
		Object: map[string]interface{}{
			"apiVersion": "appstudio.redhat.com/v1alpha1",
			"kind":       "EnterpriseContractPolicy",
			"metadata": map[string]interface{}{
				"name":      policyName,
				"namespace": state.namespace,
			},
			"spec": policySpec,
		},
	}

	gvr := schema.GroupVersionResource{
		Group:    "appstudio.redhat.com",
		Version:  "v1alpha1",
		Resource: "enterprisecontractpolicies",
	}

	_, err = dynamicClient.Resource(gvr).Namespace(state.namespace).Create(ctx, policy, metav1.CreateOptions{})
	if err != nil {
		return ctx, fmt.Errorf("creating policy: %w", err)
	}

	state.policyName = policyName
	// Store updated state back into context
	ctx = context.WithValue(ctx, testStateKey{}, *state)
	logger.Log("Created policy: %s", policyName)

	return ctx, nil
}

func runPipeline(ctx context.Context, params *godog.Table) (context.Context, error) {
	logger, ctx := log.LoggerFor(ctx)

	state := testenv.FetchState[testState](ctx)
	if state == nil {
		return ctx, errors.New("test state not initialized")
	}

	clusterState := testenv.FetchState[kind.ClusterState](ctx)
	if clusterState == nil {
		return ctx, errors.New("cluster not initialized")
	}

	kubeconfig, err := clusterState.KubeConfig()
	if err != nil {
		return ctx, fmt.Errorf("getting kubeconfig: %w", err)
	}

	config, err := clientcmd.RESTConfigFromKubeConfig([]byte(kubeconfig))
	if err != nil {
		return ctx, fmt.Errorf("parsing kubeconfig: %w", err)
	}

	tektonClient, err := tekton.NewForConfig(config)
	if err != nil {
		return ctx, fmt.Errorf("creating tekton client: %w", err)
	}

	// Build parameters from table
	pipelineParams := make([]pipeline.Param, 0, len(params.Rows))
	for _, row := range params.Rows {
		name := row.Cells[0].Value
		value := row.Cells[1].Value

		// Expand variables
		value = strings.ReplaceAll(value, "${NAMESPACE}", state.namespace)
		value = strings.ReplaceAll(value, "${POLICY_NAME}", state.policyName)

		pipelineParams = append(pipelineParams, pipeline.Param{
			Name: name,
			Value: pipeline.ParamValue{
				Type:      pipeline.ParamTypeString,
				StringVal: value,
			},
		})
	}

	// Create PipelineRun
	pr, err := tektonClient.PipelineRuns(state.namespace).Create(ctx, &pipeline.PipelineRun{
		ObjectMeta: metav1.ObjectMeta{
			GenerateName: "acceptance-",
		},
		Spec: pipeline.PipelineRunSpec{
			PipelineRef: &pipeline.PipelineRef{
				Name: "conforma",
			},
			Params: pipelineParams,
			Timeouts: &pipeline.TimeoutFields{
				Pipeline: &metav1.Duration{Duration: 30 * time.Minute},
			},
		},
	}, metav1.CreateOptions{})
	if err != nil {
		return ctx, fmt.Errorf("creating pipelinerun: %w", err)
	}

	state.pipelineRunName = pr.Name
	logger.Log("Created PipelineRun: %s", pr.Name)

	// Wait for completion
	logger.Log("Waiting for PipelineRun to complete...")
	watcher, err := tektonClient.PipelineRuns(state.namespace).Watch(ctx, metav1.SingleObject(metav1.ObjectMeta{
		Name: pr.Name,
	}))
	if err != nil {
		return ctx, fmt.Errorf("watching pipelinerun: %w", err)
	}
	defer watcher.Stop()

	for event := range watcher.ResultChan() {
		pr, ok := event.Object.(*pipeline.PipelineRun)
		if !ok {
			continue
		}

		if pr.IsDone() {
			state.pipelineResult = pr.IsSuccessful()

			// Get TEST_OUTPUT result
			for _, result := range pr.Status.Results {
				if result.Name == "TEST_OUTPUT" {
					state.testOutput = result.Value.StringVal
				}
			}

			// Log failure reason if not successful
			if !state.pipelineResult {
				for _, cond := range pr.Status.Conditions {
					logger.Log("PipelineRun condition: %s=%s, reason=%s, message=%s",
						cond.Type, cond.Status, cond.Reason, cond.Message)
				}
				// Fetch and log TaskRun status
				for _, child := range pr.Status.ChildReferences {
					logger.Log("Child %s: kind=%s, name=%s", child.PipelineTaskName, child.Kind, child.Name)
					if child.Kind == "TaskRun" {
						tr, err := tektonClient.TaskRuns(state.namespace).Get(ctx, child.Name, metav1.GetOptions{})
						if err == nil {
							for _, cond := range tr.Status.Conditions {
								logger.Log("TaskRun %s condition: %s=%s, reason=%s, message=%s",
									child.Name, cond.Type, cond.Status, cond.Reason, cond.Message)
							}
							// Log step states
							for _, step := range tr.Status.Steps {
								if step.Terminated != nil {
									logger.Log("Step %s: exitCode=%d, reason=%s, message=%s",
										step.Name, step.Terminated.ExitCode, step.Terminated.Reason, step.Terminated.Message)
								}
							}
						}
					}
				}
			}

			logger.Log("PipelineRun completed: success=%v", state.pipelineResult)
			break
		}
	}

	// Store updated state back into context
	ctx = context.WithValue(ctx, testStateKey{}, *state)

	return ctx, nil
}

func pipelineShouldSucceed(ctx context.Context) error {
	state := testenv.FetchState[testState](ctx)
	if state == nil {
		return errors.New("test state not initialized")
	}

	if !state.pipelineResult {
		return fmt.Errorf("pipeline failed, expected success. TEST_OUTPUT: %s", state.testOutput)
	}

	return nil
}

func pipelineShouldFail(ctx context.Context) error {
	state := testenv.FetchState[testState](ctx)
	if state == nil {
		return errors.New("test state not initialized")
	}

	if state.pipelineResult {
		return errors.New("pipeline succeeded, expected failure")
	}

	return nil
}
