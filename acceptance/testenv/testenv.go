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
	"context"
	"testing"
)

// Context keys for test configuration
type contextKey int

const (
	TestingTKey contextKey = iota
	PersistKey
	NoColorsKey
	ScenarioKey
	RepoRootKey
)

// State is an interface for state objects that can be stored in context
type State interface {
	Key() any
}

// SetupState initializes or retrieves state from context
func SetupState[T State](ctx context.Context, state *T) (context.Context, error) {
	key := (*state).Key()
	if existing := ctx.Value(key); existing != nil {
		*state = existing.(T)
		return ctx, nil
	}
	return context.WithValue(ctx, key, *state), nil
}

// FetchState retrieves state from context
func FetchState[T State](ctx context.Context) *T {
	var zero T
	key := zero.Key()
	if state := ctx.Value(key); state != nil {
		s := state.(T)
		return &s
	}
	return nil
}

// Persisted returns true if the test environment should be persisted
func Persisted(ctx context.Context) bool {
	if v := ctx.Value(PersistKey); v != nil {
		return v.(bool)
	}
	return false
}

// RepoRoot returns the repository root path from context
func RepoRoot(ctx context.Context) string {
	if v := ctx.Value(RepoRootKey); v != nil {
		return v.(string)
	}
	return ""
}

// NoColorOutput returns true if colored output should be disabled
func NoColorOutput(ctx context.Context) bool {
	if v := ctx.Value(NoColorsKey); v != nil {
		return v.(bool)
	}
	return false
}

// Testing returns the *testing.T from context
func Testing(ctx context.Context) *testing.T {
	if v := ctx.Value(TestingTKey); v != nil {
		return v.(*testing.T)
	}
	return nil
}
