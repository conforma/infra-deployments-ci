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

package acceptance

import (
	"context"
	"flag"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/cucumber/godog"

	"github.com/conforma/infra-deployments-ci/acceptance/kubernetes"
	"github.com/conforma/infra-deployments-ci/acceptance/log"
	"github.com/conforma/infra-deployments-ci/acceptance/testenv"
)

// flags for test configuration
var (
	persist  = flag.Bool("persist", false, "persist the test environment for debugging")
	noColors = flag.Bool("no-colors", false, "disable colored output")
	tags     = flag.String("tags", "", "select scenarios to run based on tags")
)

// repoRoot stores the absolute path to the repository root
var repoRoot string

// initializeScenario adds all steps and registers hooks to the ScenarioContext
func initializeScenario(sc *godog.ScenarioContext) {
	kubernetes.AddStepsTo(sc)

	sc.Before(func(ctx context.Context, sc *godog.Scenario) (context.Context, error) {
		logger, ctx := log.LoggerFor(ctx)
		logger.Log("Starting scenario: %s", sc.Name)
		return context.WithValue(ctx, testenv.ScenarioKey, sc), nil
	})

	sc.After(func(ctx context.Context, scenario *godog.Scenario, scenarioErr error) (context.Context, error) {
		logger, _ := log.LoggerFor(ctx)
		if scenarioErr != nil {
			logger.Log("FAILED: %s - %v", scenario.Name, scenarioErr)
		} else {
			logger.Log("PASSED: %s", scenario.Name)
		}
		return ctx, nil
	})
}

func initializeSuite(ctx context.Context) func(*godog.TestSuiteContext) {
	return func(tsc *godog.TestSuiteContext) {
		kubernetes.InitializeSuite(ctx, tsc)
	}
}

// setupContext creates a Context with test configuration
func setupContext(t *testing.T) context.Context {
	ctx := context.WithValue(context.Background(), testenv.TestingTKey, t)
	ctx = context.WithValue(ctx, testenv.PersistKey, *persist)
	ctx = context.WithValue(ctx, testenv.NoColorsKey, *noColors)
	ctx = context.WithValue(ctx, testenv.RepoRootKey, repoRoot)
	return ctx
}

// TestFeatures runs all acceptance test scenarios
func TestFeatures(t *testing.T) {
	// Get repository root (parent of acceptance directory)
	absPath, err := filepath.Abs("..")
	if err != nil {
		t.Fatal(err)
	}
	repoRoot = absPath

	featuresDir := filepath.Join(repoRoot, "features")

	ctx := setupContext(t)

	opts := godog.Options{
		Format:         "pretty",
		Paths:          []string{featuresDir},
		Concurrency:    runtime.NumCPU(),
		TestingT:       t,
		DefaultContext: ctx,
		Tags:           *tags,
		NoColors:       *noColors,
		Strict:         true,
	}

	suite := godog.TestSuite{
		ScenarioInitializer:  initializeScenario,
		TestSuiteInitializer: initializeSuite(ctx),
		Options:              &opts,
	}

	if suite.Run() != 0 {
		t.Fatal("acceptance tests failed")
	}
}
