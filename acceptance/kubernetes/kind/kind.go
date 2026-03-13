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

package kind

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"math"
	"math/big"
	"os"
	"path"
	"sync"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/meta"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/fields"
	util "k8s.io/apimachinery/pkg/util/yaml"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/restmapper"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	w "k8s.io/client-go/tools/watch"
	"sigs.k8s.io/kind/pkg/apis/config/v1alpha4"
	k "sigs.k8s.io/kind/pkg/cluster"
	"sigs.k8s.io/yaml"

	"github.com/conforma/infra-deployments-ci/acceptance/kustomize"
	"github.com/conforma/infra-deployments-ci/acceptance/log"
	"github.com/conforma/infra-deployments-ci/acceptance/testenv"
)

// cluster consumers sync
var clusterGroup = sync.WaitGroup{}

// ensure single cluster creation
var create = sync.Once{}

// ensure single cluster destruction
var destroy = sync.Once{}

// global cluster instance
var globalCluster *kindCluster

// createErr holds any error from cluster creation
var createErr error

type kindCluster struct {
	name           string
	kubeconfigPath string
	provider       *k.Provider
	config         *rest.Config
	client         *kubernetes.Clientset
	dynamic        dynamic.Interface
	mapper         meta.RESTMapper
}

func (k *kindCluster) Up(_ context.Context) bool {
	if k == nil || k.provider == nil || k.name == "" {
		return false
	}
	nodes, err := k.provider.ListNodes(k.name)
	return len(nodes) > 0 && err == nil
}

// Start creates and starts a Kind cluster
func Start(givenCtx context.Context) (context.Context, error) {
	var logger log.Logger
	logger, ctx := log.LoggerFor(givenCtx)

	create.Do(func() {
		logger.Log("Creating Kind cluster...")

		var configDir string
		configDir, createErr = os.MkdirTemp("", "ec-acceptance.*")
		if createErr != nil {
			logger.Errorf("Unable to create temp directory: %v", createErr)
			return
		}

		var id *big.Int
		id, createErr = rand.Int(rand.Reader, big.NewInt(math.MaxUint32))
		if createErr != nil {
			logger.Errorf("Unable to generate random cluster id: %v", createErr)
			return
		}

		kCluster := kindCluster{
			name:     fmt.Sprintf("acceptance-%d", id.Uint64()),
			provider: k.NewProvider(k.ProviderWithLogger(logger)),
		}
		kCluster.kubeconfigPath = path.Join(configDir, "kubeconfig")

		defer func() {
			if createErr != nil {
				logger.Infof("Error creating cluster, cleaning up: %v", createErr)
				if err := kCluster.provider.Delete(kCluster.name, kCluster.kubeconfigPath); err != nil {
					logger.Infof("Error deleting cluster: %v", err)
				}
			}
		}()

		logger.Log("Creating Kind cluster: %s", kCluster.name)
		if createErr = kCluster.provider.Create(kCluster.name,
			k.CreateWithV1Alpha4Config(&v1alpha4.Cluster{
				TypeMeta: v1alpha4.TypeMeta{
					Kind:       "Cluster",
					APIVersion: "kind.x-k8s.io/v1alpha4",
				},
				Nodes: []v1alpha4.Node{
					{
						Role: v1alpha4.ControlPlaneRole,
					},
				},
			}),
			k.CreateWithKubeconfigPath(kCluster.kubeconfigPath)); createErr != nil {
			logger.Errorf("Unable to create Kind cluster: %v", createErr)
			return
		}

		rules := clientcmd.NewDefaultClientConfigLoadingRules()
		rules.ExplicitPath = kCluster.kubeconfigPath

		clientConfig := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(rules, nil)

		if kCluster.config, createErr = clientConfig.ClientConfig(); createErr != nil {
			logger.Errorf("Unable to get client config: %v", createErr)
			return
		}

		if kCluster.dynamic, createErr = dynamic.NewForConfig(kCluster.config); createErr != nil {
			logger.Errorf("Unable to get dynamic client: %v", createErr)
			return
		}

		if kCluster.client, createErr = kubernetes.NewForConfig(kCluster.config); createErr != nil {
			logger.Errorf("Unable to create k8s client: %v", createErr)
			return
		}

		disc := discovery.NewDiscoveryClientForConfigOrDie(kCluster.config)

		var resources []*restmapper.APIGroupResources
		if resources, createErr = restmapper.GetAPIGroupResources(disc); createErr != nil {
			logger.Errorf("Unable to access API resources: %v", createErr)
			return
		}
		kCluster.mapper = restmapper.NewDiscoveryRESTMapper(resources)

		// Install Tekton and pipeline
		logger.Log("Installing Tekton Pipelines...")
		repoRoot := testenv.RepoRoot(ctx)
		var tektonYaml []byte
		tektonYaml, createErr = kustomize.Render(repoRoot, "test")
		if createErr != nil {
			logger.Errorf("Unable to render test kustomization: %v", createErr)
			return
		}

		createErr = applyConfiguration(ctx, &kCluster, tektonYaml)
		if createErr != nil {
			logger.Errorf("Unable to apply cluster configuration: %v", createErr)
			return
		}

		// Wait for Tekton deployments to be ready
		logger.Log("Waiting for Tekton Pipelines to be ready...")
		createErr = waitForDeploymentsIn(ctx, &kCluster, "tekton-pipelines")
		if createErr != nil {
			logger.Errorf("Tekton Pipelines not ready: %v", createErr)
			return
		}

		globalCluster = &kCluster
		logger.Log("Kind cluster ready: %s", kCluster.name)
	})

	if createErr != nil {
		return ctx, createErr
	}

	if globalCluster == nil {
		return ctx, errors.New("no cluster available")
	}

	clusterGroup.Add(1)

	// Store cluster state in context
	state := ClusterState{cluster: globalCluster}
	ctx, _ = testenv.SetupState(ctx, &state)

	return ctx, nil
}

// waitForDeploymentsIn waits for all deployments in the namespace to be available
func waitForDeploymentsIn(ctx context.Context, k *kindCluster, namespace string) error {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()

	watcher := cache.NewListWatchFromClient(
		k.client.AppsV1().RESTClient(),
		"deployments",
		namespace,
		fields.Everything(),
	)

	available := make(map[string]bool)

	condition := func(event watch.Event) (bool, error) {
		deployment, ok := event.Object.(*appsv1.Deployment)
		if !ok {
			return false, nil
		}

		for _, c := range deployment.Status.Conditions {
			if c.Type == appsv1.DeploymentAvailable {
				available[deployment.Name] = c.Status == corev1.ConditionTrue
				break
			}
		}

		// Check if all known deployments are available
		for _, isAvailable := range available {
			if !isAvailable {
				return false, nil
			}
		}

		// Need at least one deployment to be ready
		return len(available) > 0, nil
	}

	_, err := w.UntilWithSync(ctx, watcher, &appsv1.Deployment{}, nil, condition)
	return err
}

// applyConfiguration applies YAML definitions to the cluster
func applyConfiguration(ctx context.Context, k *kindCluster, definitions []byte) error {
	reader := util.NewYAMLReader(bufio.NewReader(bytes.NewReader(definitions)))
	for {
		definition, err := reader.Read()
		if err != nil {
			if err == io.EOF {
				break
			}
			return err
		}

		var obj unstructured.Unstructured
		if err = yaml.Unmarshal(definition, &obj); err != nil {
			return err
		}

		mapping, err := k.mapper.RESTMapping(obj.GroupVersionKind().GroupKind())
		if err != nil {
			return err
		}

		var c dynamic.ResourceInterface = k.dynamic.Resource(mapping.Resource)
		if mapping.Scope.Name() == meta.RESTScopeNameNamespace {
			c = c.(dynamic.NamespaceableResourceInterface).Namespace(obj.GetNamespace())
		}

		_, err = c.Apply(ctx, obj.GetName(), &obj, metav1.ApplyOptions{FieldManager: "application/apply-patch"})
		if err != nil {
			return err
		}
	}

	return nil
}

// Destroy tears down the Kind cluster
func Destroy(ctx context.Context) {
	logger, _ := log.LoggerFor(ctx)

	destroy.Do(func() {
		if globalCluster == nil {
			logger.Log("No cluster to destroy")
			return
		}

		logger.Log("Waiting for cluster consumers to finish...")
		clusterGroup.Wait()

		// Check if persist mode is enabled
		if persist, ok := ctx.Value(testenv.PersistKey).(bool); ok && persist {
			logger.Log("Persist mode enabled - keeping cluster: %s", globalCluster.name)
			logger.Log("To access the cluster, run: kind get kubeconfig --name %s", globalCluster.name)
			return
		}

		logger.Log("Destroying Kind cluster: %s", globalCluster.name)

		defer func() {
			kindDir := path.Join(globalCluster.kubeconfigPath, "..")
			if err := os.RemoveAll(kindDir); err != nil {
				logger.Errorf("Error removing kubeconfig dir: %v", err)
			}
		}()

		if err := globalCluster.provider.Delete(globalCluster.name, globalCluster.kubeconfigPath); err != nil {
			logger.Errorf("Error deleting cluster: %v", err)
		}

		logger.Log("Cluster destroyed")
	})
}

// ClusterState holds cluster reference for context
type ClusterState struct {
	cluster *kindCluster
}

type clusterStateKey struct{}

func (c ClusterState) Key() any {
	return clusterStateKey{}
}

func (c ClusterState) Up(ctx context.Context) bool {
	return c.cluster != nil && c.cluster.Up(ctx)
}

func (c ClusterState) KubeConfig() (string, error) {
	if c.cluster == nil {
		return "", errors.New("cluster not initialized")
	}
	bytes, err := os.ReadFile(c.cluster.kubeconfigPath)
	if err != nil {
		return "", err
	}
	return string(bytes), nil
}

// Stop releases the cluster for this consumer
func (c ClusterState) Stop() {
	clusterGroup.Done()
}
