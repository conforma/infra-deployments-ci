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

package log

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	kindlog "sigs.k8s.io/kind/pkg/log"
)

type loggerKey struct{}

// Logger provides logging functionality for tests
// It implements sigs.k8s.io/kind/pkg/log.Logger interface
type Logger struct {
	name   string
	writer io.Writer
}

// Ensure Logger implements kindlog.Logger
var _ kindlog.Logger = Logger{}

// LoggerFor retrieves or creates a logger from context
func LoggerFor(ctx context.Context) (Logger, context.Context) {
	if l := ctx.Value(loggerKey{}); l != nil {
		return l.(Logger), ctx
	}
	logger := Logger{writer: os.Stdout}
	return logger, context.WithValue(ctx, loggerKey{}, logger)
}

// Name sets the logger name (typically the scenario name)
func (l *Logger) Name(name string) {
	l.name = name
}

// Log writes a formatted log message
func (l Logger) Log(format string, args ...any) {
	timestamp := time.Now().Format("15:04:05")
	prefix := fmt.Sprintf("[%s]", timestamp)
	if l.name != "" {
		prefix = fmt.Sprintf("%s [%s]", prefix, l.name)
	}
	message := fmt.Sprintf(format, args...)
	fmt.Fprintf(l.writer, "%s %s\n", prefix, message)
}

// Error writes an error log message
func (l Logger) Error(message string) {
	l.Log("ERROR: %s", message)
}

// Errorf writes a formatted error log message
func (l Logger) Errorf(format string, args ...any) {
	l.Error(fmt.Sprintf(format, args...))
}

// Info writes an info log message
func (l Logger) Info(message string) {
	l.Log("INFO: %s", message)
}

// Infof writes a formatted info log message
func (l Logger) Infof(format string, args ...any) {
	l.Info(fmt.Sprintf(format, args...))
}

// V returns an InfoLogger at the specified verbosity level (Kind compatibility)
func (l Logger) V(level kindlog.Level) kindlog.InfoLogger {
	return l
}

// Enabled returns true (for Kind compatibility)
func (l Logger) Enabled() bool {
	return true
}

// Write implements io.Writer for Kind compatibility
func (l Logger) Write(p []byte) (n int, err error) {
	lines := strings.Split(string(p), "\n")
	for _, line := range lines {
		if line != "" {
			l.Log("%s", line)
		}
	}
	return len(p), nil
}

// Warn logs a warning message (for Kind compatibility)
func (l Logger) Warn(message string) {
	l.Log("WARN: %s", message)
}

// Warnf logs a formatted warning message (for Kind compatibility)
func (l Logger) Warnf(format string, args ...any) {
	l.Warn(fmt.Sprintf(format, args...))
}
