// Copyright The Conforma Contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

// policy-rule-diff reports which Rego policy rules (deny/warn) were added or
// removed between two OCI bundle tags, git versions, or local files.
//
// Primary usage (OCI bundles):
//
//	go run ./hack/policy-rule-diff -bundle -json \
//	  quay.io/conforma/release-policy:konflux \
//	  quay.io/conforma/release-policy:latest
//
// Other modes:
//
//	go run ./hack/policy-rule-diff -before f1 -after f2         # Two files directly
//	go run ./hack/policy-rule-diff <from-ref> <to-ref>          # Between two git refs (requires a Rego repo)
package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strings"
	"time"
)

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

type rule struct {
	kind        string   // "deny", "warn", "allow", "helper"
	pkg         string   // Rego package name
	shortName   string   // from METADATA custom.short_name
	title       string   // from METADATA title
	description string   // from METADATA description
	head        string   // full rule head line, stripped
	body        []string // body lines with common indentation removed
	collections []string // from METADATA custom.collections
	effectiveOn string   // from METADATA custom.effective_on
	solution    string   // from METADATA custom.solution
	failureMsg  string   // from METADATA custom.failure_msg
	lineNum     int      // 1-based
}

func (r *rule) key() string {
	if r.shortName != "" {
		return r.shortName
	}
	if r.title != "" {
		return r.title
	}
	return r.head
}

func (r *rule) source() string {
	var b strings.Builder
	b.WriteString(r.head)
	b.WriteByte('\n')
	for _, l := range r.body {
		b.WriteByte('\t')
		b.WriteString(l)
		b.WriteByte('\n')
	}
	b.WriteByte('}')
	return b.String()
}

// ---------------------------------------------------------------------------
// Rego parser
// ---------------------------------------------------------------------------

var (
	ruleHeadRE   = regexp.MustCompile(`^(deny|warn|allow)\s+(contains\s+\w+\s+if|if)\s*\{?\s*$`)
)

// netBraceDepth returns the net change in brace depth for a single line,
// skipping content inside double-quoted strings.
func netBraceDepth(line string) int {
	depth := 0
	inStr := false
	escape := false
	for _, ch := range line {
		if escape {
			escape = false
			continue
		}
		if ch == '\\' {
			escape = true
			continue
		}
		if ch == '"' {
			inStr = !inStr
			continue
		}
		if inStr {
			continue
		}
		if ch == '{' {
			depth++
		} else if ch == '}' {
			depth--
		}
	}
	return depth
}

// extractBody returns the lines inside the outermost {} of the rule starting
// at headIdx, plus the index of the line containing the closing brace.
func extractBody(lines []string, headIdx int) ([]string, int) {
	depth := netBraceDepth(lines[headIdx])

	if depth <= 0 {
		// Opening brace might be on the next line.
		if headIdx+1 < len(lines) && strings.TrimSpace(lines[headIdx+1]) == "{" {
			depth = 1
			headIdx++
		} else {
			return nil, headIdx
		}
	}

	var body []string
	i := headIdx + 1
	for i < len(lines) && depth > 0 {
		l := lines[i]
		depth += netBraceDepth(l)
		if depth > 0 {
			body = append(body, strings.TrimRight(l, " \t"))
		}
		i++
	}
	return dedent(body), i - 1
}

// dedent removes the shortest common leading whitespace from non-empty lines.
func dedent(lines []string) []string {
	minPrefix := -1
	for _, l := range lines {
		if strings.TrimSpace(l) == "" {
			continue
		}
		p := len(l) - len(strings.TrimLeft(l, " \t"))
		if minPrefix < 0 || p < minPrefix {
			minPrefix = p
		}
	}
	if minPrefix <= 0 {
		return lines
	}
	out := make([]string, len(lines))
	for i, l := range lines {
		if len(l) >= minPrefix {
			out[i] = l[minPrefix:]
		} else {
			out[i] = l
		}
	}
	return out
}

// pendingMeta holds metadata parsed from a METADATA block before a rule.
type pendingMeta struct {
	title       string
	description string
	shortName   string
	collections []string
	effectiveOn string
	solution    string
	failureMsg  string
}

// parseRegoRules parses a Rego source file and returns all deny/warn/allow
// and helper rules, keyed by their stable identifier.
func parseRegoRules(content string) map[string]*rule {
	lines := strings.Split(content, "\n")
	n := len(lines)
	rules := make(map[string]*rule)
	var meta *pendingMeta
	var pkg string

	i := 0
	for i < n {
		stripped := strings.TrimSpace(lines[i])

		// ── Package declaration ──────────────────────────────────────────
		if strings.HasPrefix(stripped, "package ") {
			pkg = strings.TrimSpace(stripped[len("package "):])
			i++
			continue
		}

		// ── METADATA block ────────────────────────────────────────────────
		if stripped == "# METADATA" {
			meta = &pendingMeta{}
			i++
			inCustom := false
			inCollections := false
			inDescription := false
			inSolution := false
			inFailureMsg := false
			for i < n && strings.HasPrefix(lines[i], "#") {
				m := strings.TrimSpace(strings.TrimPrefix(lines[i], "#"))
				switch {
				case strings.HasPrefix(m, "title:"):
					meta.title = strings.TrimSpace(m[len("title:"):])
					inCustom, inCollections, inDescription = false, false, false
					inSolution, inFailureMsg = false, false
				case strings.HasPrefix(m, "description:"):
					desc := strings.TrimSpace(m[len("description:"):])
					// Handle >- (folded block scalar) — content follows on next lines.
					if desc == ">-" || desc == ">" || desc == "|" || desc == "|-" {
						desc = ""
					}
					meta.description = desc
					inDescription = true
					inCustom, inCollections = false, false
					inSolution, inFailureMsg = false, false
				case inDescription && !strings.Contains(m, ":") && !strings.HasPrefix(m, "- "):
					// Continuation line of a multi-line description.
					if meta.description != "" {
						meta.description += " "
					}
					meta.description += strings.TrimSpace(m)
				case m == "custom:":
					inCustom = true
					inCollections, inDescription = false, false
					inSolution, inFailureMsg = false, false
				case inCustom && strings.HasPrefix(m, "short_name:"):
					meta.shortName = strings.TrimSpace(m[len("short_name:"):])
					inCollections, inSolution, inFailureMsg = false, false, false
				case inCustom && strings.HasPrefix(m, "failure_msg:"):
					val := strings.TrimSpace(m[len("failure_msg:"):])
					if val == ">-" || val == ">" || val == "|" || val == "|-" {
						val = ""
					}
					meta.failureMsg = val
					inFailureMsg = true
					inCollections, inSolution = false, false
				case inCustom && inFailureMsg && !strings.Contains(m, ":") && !strings.HasPrefix(m, "- "):
					if meta.failureMsg != "" {
						meta.failureMsg += " "
					}
					meta.failureMsg += strings.TrimSpace(m)
				case inCustom && strings.HasPrefix(m, "solution:"):
					val := strings.TrimSpace(m[len("solution:"):])
					if val == ">-" || val == ">" || val == "|" || val == "|-" {
						val = ""
					}
					meta.solution = val
					inSolution = true
					inCollections, inFailureMsg = false, false
				case inCustom && inSolution && !strings.Contains(m, ":") && !strings.HasPrefix(m, "- "):
					if meta.solution != "" {
						meta.solution += " "
					}
					meta.solution += strings.TrimSpace(m)
				case inCustom && strings.HasPrefix(m, "effective_on:"):
					meta.effectiveOn = strings.TrimSpace(m[len("effective_on:"):])
					inCollections, inSolution, inFailureMsg = false, false, false
				case inCustom && strings.HasPrefix(m, "collections:"):
					inCollections = true
					inSolution, inFailureMsg = false, false
				case inCustom && inCollections && strings.HasPrefix(m, "- "):
					meta.collections = append(meta.collections, strings.TrimSpace(m[2:]))
				case inCustom && strings.HasPrefix(m, "depends_on:"):
					inCollections, inSolution, inFailureMsg = false, false, false
				case inCustom:
					inCollections, inSolution, inFailureMsg = false, false, false
				default:
					inDescription = false
					inSolution, inFailureMsg = false, false
				}
				i++
			}
			continue
		}

		// ── Policy rule head (deny / warn / allow) ────────────────────────
		if ruleHeadRE.MatchString(stripped) {
			kind := strings.Fields(stripped)[0]
			body, endIdx := extractBody(lines, i)
			r := &rule{
				kind:    kind,
				pkg:     pkg,
				head:    stripped,
				body:    body,
				lineNum: i + 1,
			}
			if meta != nil {
				r.shortName = meta.shortName
				r.title = meta.title
				r.description = meta.description
				r.collections = meta.collections
				r.effectiveOn = meta.effectiveOn
				r.solution = meta.solution
				r.failureMsg = meta.failureMsg
			}
			if k := r.key(); k != "" {
				rules[k] = r
			}
			meta = nil
			i = endIdx + 1
			continue
		}

		// Non-comment, non-blank line resets pending metadata.
		if stripped != "" && !strings.HasPrefix(stripped, "#") {
			meta = nil
		}
		i++
	}
	return rules
}

// ---------------------------------------------------------------------------
// Color output
// ---------------------------------------------------------------------------

var useColor bool

func colorize(text, code string) string {
	if !useColor {
		return text
	}
	return code + text + "\033[0m"
}

func bold(s string) string   { return colorize(s, "\033[1m") }
func dim(s string) string    { return colorize(s, "\033[2m") }
func green(s string) string  { return colorize(s, "\033[32m") }
func red(s string) string    { return colorize(s, "\033[31m") }
func yellow(s string) string { return colorize(s, "\033[33m") }
func cyan(s string) string   { return colorize(s, "\033[36m") }

func isTerminal() bool {
	fi, err := os.Stdout.Stat()
	if err != nil {
		return false
	}
	return fi.Mode()&os.ModeCharDevice != 0
}

// ---------------------------------------------------------------------------
// Git helpers
// ---------------------------------------------------------------------------

func repoRoot() string {
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: not inside a git repository")
		os.Exit(1)
	}
	return strings.TrimSpace(string(out))
}

// fileAtRef returns the content of a repo-relative path at a git ref.
// Returns ("", false) if the file did not exist at that ref.
func fileAtRef(relPath, ref, root string) (string, bool) {
	out, err := exec.Command("git", "-C", root, "show", ref+":"+relPath).Output()
	if err != nil {
		return "", false
	}
	return string(out), true
}

// changedFiles returns repo-relative paths of changed .rego files
// (excluding test files) that match the given path prefix.
func changedFiles(fromRef string, toRef *string, root, prefix string) []string {
	args := []string{"-C", root, "diff", "--name-only", fromRef}
	if toRef != nil {
		args = append(args, *toRef)
	}
	out, err := exec.Command("git", args...).Output()
	if err != nil {
		return nil
	}
	var files []string
	for _, f := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if f == "" {
			continue
		}
		if strings.HasPrefix(f, prefix) && strings.HasSuffix(f, ".rego") && !strings.HasSuffix(f, "_test.rego") {
			files = append(files, f)
		}
	}
	return files
}

// ---------------------------------------------------------------------------
// Formatting and diff output
// ---------------------------------------------------------------------------

// ruleChange represents a single added or removed rule.
type ruleChange struct {
	rule *rule
	file string // source file path
}

// summary returns a formatted block for a rule change with a colored bullet.
func (c *ruleChange) summary(bullet, bulletColor string) string {
	r := c.rule
	name := r.shortName
	if name == "" {
		name = r.title
	}
	if name == "" {
		name = r.head
	}
	line := colorize(bullet, bulletColor) + " " + bold(name) + " " + dim("("+r.kind+")")
	if r.description != "" {
		line += "\n        " + dim(r.description)
	}
	return line
}

// diffRules compares two versions of a Rego file and appends changes to added/removed.
func diffRules(beforeContent, afterContent *string, file string, added, removed *[]ruleChange) {
	var beforeRules, afterRules map[string]*rule
	if beforeContent != nil {
		beforeRules = parseRegoRules(*beforeContent)
	}
	if afterContent != nil {
		afterRules = parseRegoRules(*afterContent)
	}

	for key, after := range afterRules {
		if after.kind != "deny" && after.kind != "warn" {
			continue
		}
		if beforeRules[key] == nil {
			*added = append(*added, ruleChange{rule: after, file: file})
		}
	}
	for key, before := range beforeRules {
		if before.kind != "deny" && before.kind != "warn" {
			continue
		}
		if afterRules[key] == nil {
			*removed = append(*removed, ruleChange{rule: before, file: file})
		}
	}
}

// groupByPackage groups rule changes by Rego package name, returning sorted
// package names and a map of package → changes.
func groupByPackage(changes []ruleChange) ([]string, map[string][]ruleChange) {
	byPkg := make(map[string][]ruleChange)
	for _, c := range changes {
		pkg := c.rule.pkg
		if pkg == "" {
			pkg = "(unknown)"
		}
		byPkg[pkg] = append(byPkg[pkg], c)
	}
	pkgs := make([]string, 0, len(byPkg))
	for pkg := range byPkg {
		pkgs = append(pkgs, pkg)
	}
	sort.Strings(pkgs)
	// Sort rules within each package.
	for _, rules := range byPkg {
		sort.Slice(rules, func(i, j int) bool { return rules[i].rule.key() < rules[j].rule.key() })
	}
	return pkgs, byPkg
}

// printChanges prints added and removed rules grouped by package.
func printChanges(added, removed []ruleChange) {
	if len(added) == 0 && len(removed) == 0 {
		fmt.Println(dim("No rules added or removed."))
		return
	}

	if len(added) > 0 {
		fmt.Printf("\n %s %s\n", bold(green("✚ Rules added")), dim(fmt.Sprintf("(%d)", len(added))))
		pkgs, byPkg := groupByPackage(added)
		for _, pkg := range pkgs {
			fmt.Printf("\n   %s\n", cyan(pkg))
			for _, c := range byPkg[pkg] {
				fmt.Printf("      %s\n", c.summary("▸", "\033[32m"))
			}
		}
	}
	if len(removed) > 0 {
		fmt.Printf("\n %s %s\n", bold(red("✖ Rules removed")), dim(fmt.Sprintf("(%d)", len(removed))))
		pkgs, byPkg := groupByPackage(removed)
		for _, pkg := range pkgs {
			fmt.Printf("\n   %s\n", cyan(pkg))
			for _, c := range byPkg[pkg] {
				fmt.Printf("      %s\n", c.summary("▸", "\033[31m"))
			}
		}
	}
	fmt.Println()
}

// ---------------------------------------------------------------------------
// JSON output
// ---------------------------------------------------------------------------

type jsonReport struct {
	Before  string                      `json:"before"`
	After   string                      `json:"after"`
	Added   []jsonRule                  `json:"added"`
	Removed []jsonRule                  `json:"removed"`
	Files   map[string]jsonFileVersions `json:"files,omitempty"`
}

type jsonFileVersions struct {
	Before string `json:"before,omitempty"`
	After  string `json:"after,omitempty"`
}

type jsonRule struct {
	ShortName   string   `json:"short_name"`
	Kind        string   `json:"kind"`
	Package     string   `json:"package"`
	Title       string   `json:"title,omitempty"`
	Description string   `json:"description,omitempty"`
	Solution    string   `json:"solution,omitempty"`
	FailureMsg  string   `json:"failure_msg,omitempty"`
	EffectiveOn string   `json:"effective_on,omitempty"`
	Collections []string `json:"collections,omitempty"`
	File        string   `json:"file"`
	Source      string   `json:"source"`
}

func ruleChangeToJSON(c ruleChange) jsonRule {
	return jsonRule{
		ShortName:   c.rule.shortName,
		Kind:        c.rule.kind,
		Package:     c.rule.pkg,
		Title:       c.rule.title,
		Description: c.rule.description,
		Solution:    c.rule.solution,
		FailureMsg:  c.rule.failureMsg,
		EffectiveOn: c.rule.effectiveOn,
		Collections: c.rule.collections,
		File:        c.file,
		Source:      c.rule.source(),
	}
}

func printChangesJSON(beforeLabel, afterLabel string, added, removed []ruleChange, filesBefore, filesAfter map[string]string) {
	report := jsonReport{
		Before: beforeLabel,
		After:  afterLabel,
	}

	sort.Slice(added, func(i, j int) bool {
		if added[i].rule.pkg != added[j].rule.pkg {
			return added[i].rule.pkg < added[j].rule.pkg
		}
		return added[i].rule.key() < added[j].rule.key()
	})
	sort.Slice(removed, func(i, j int) bool {
		if removed[i].rule.pkg != removed[j].rule.pkg {
			return removed[i].rule.pkg < removed[j].rule.pkg
		}
		return removed[i].rule.key() < removed[j].rule.key()
	})

	for _, c := range added {
		report.Added = append(report.Added, ruleChangeToJSON(c))
	}
	for _, c := range removed {
		report.Removed = append(report.Removed, ruleChangeToJSON(c))
	}

	// Include file contents for files that have changed rules.
	changedFiles := make(map[string]bool)
	for _, c := range added {
		changedFiles[c.file] = true
	}
	for _, c := range removed {
		changedFiles[c.file] = true
	}
	if len(changedFiles) > 0 && (len(filesBefore) > 0 || len(filesAfter) > 0) {
		report.Files = make(map[string]jsonFileVersions)
		for p := range changedFiles {
			fv := jsonFileVersions{}
			if s, ok := filesBefore[p]; ok {
				fv.Before = s
			}
			if s, ok := filesAfter[p]; ok {
				fv.After = s
			}
			report.Files[p] = fv
		}
	}

	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	enc.Encode(report)
}

func readFile(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error reading %s: %v\n", path, err)
		os.Exit(1)
	}
	return string(b)
}

// reorderArgs moves flag arguments before positional arguments so that
// flag.Parse works correctly even when flags appear after positional args.
func reorderArgs(args []string) []string {
	// Flags that consume the next argument as their value.
	stringFlags := map[string]bool{"before": true, "after": true}

	var flags, positional []string
	i := 0
	for i < len(args) {
		arg := args[i]
		if strings.HasPrefix(arg, "-") {
			name := strings.TrimLeft(arg, "-")
			if idx := strings.Index(name, "="); idx >= 0 {
				name = name[:idx]
			}
			flags = append(flags, arg)
			// Consume the next token as the flag value if needed.
			if stringFlags[name] && !strings.Contains(arg, "=") && i+1 < len(args) {
				i++
				flags = append(flags, args[i])
			}
		} else {
			positional = append(positional, arg)
		}
		i++
	}
	return append(flags, positional...)
}

// ---------------------------------------------------------------------------
// OCI bundle support
// ---------------------------------------------------------------------------

type ociRef struct {
	registry   string // e.g. "quay.io"
	repository string // e.g. "conforma/release-policy"
	tag        string // e.g. "latest" or "git-abc1234"
	original   string // original full string
}

func parseOCIRef(s string) (ociRef, error) {
	// Expected form: registry/repo/path:tag
	// e.g.  quay.io/conforma/release-policy:latest
	slashIdx := strings.Index(s, "/")
	if slashIdx < 0 {
		return ociRef{}, fmt.Errorf("invalid OCI reference %q: expected registry/repository:tag", s)
	}
	registry := s[:slashIdx]
	rest := s[slashIdx+1:]

	tag := "latest"
	if colonIdx := strings.LastIndex(rest, ":"); colonIdx >= 0 {
		tag = rest[colonIdx+1:]
		rest = rest[:colonIdx]
	}
	return ociRef{registry: registry, repository: rest, tag: tag, original: s}, nil
}

// ociClient handles the OCI Distribution Spec auth + request flow.
type ociClient struct {
	http   *http.Client
	tokens map[string]string // registry host → bearer token
}

func newOCIClient() *ociClient {
	return &ociClient{
		http:   &http.Client{Timeout: 60 * time.Second},
		tokens: make(map[string]string),
	}
}

func (c *ociClient) get(rawURL string) (*http.Response, error) {
	req, err := http.NewRequest("GET", rawURL, nil)
	if err != nil {
		return nil, err
	}
	if tok, ok := c.tokens[req.URL.Host]; ok {
		req.Header.Set("Authorization", "Bearer "+tok)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusUnauthorized {
		return resp, nil
	}
	resp.Body.Close()

	// Authenticate and retry once.
	tok, err := c.authenticate(resp.Header.Get("Www-Authenticate"))
	if err != nil {
		return nil, fmt.Errorf("auth: %w", err)
	}
	c.tokens[req.URL.Host] = tok

	req2, _ := http.NewRequest("GET", rawURL, nil)
	req2.Header.Set("Authorization", "Bearer "+tok)
	return c.http.Do(req2)
}

func (c *ociClient) authenticate(wwwAuth string) (string, error) {
	// Parse: Bearer realm="https://...",service="...",scope="..."
	params := make(map[string]string)
	for _, part := range strings.Split(strings.TrimPrefix(wwwAuth, "Bearer "), ",") {
		part = strings.TrimSpace(part)
		if eq := strings.Index(part, "="); eq >= 0 {
			params[part[:eq]] = strings.Trim(part[eq+1:], `"`)
		}
	}
	realm := params["realm"]
	if realm == "" {
		return "", fmt.Errorf("no realm in %q", wwwAuth)
	}

	u, err := url.Parse(realm)
	if err != nil {
		return "", err
	}
	q := u.Query()
	if v := params["service"]; v != "" {
		q.Set("service", v)
	}
	if v := params["scope"]; v != "" {
		q.Set("scope", v)
	}
	u.RawQuery = q.Encode()

	resp, err := c.http.Get(u.String())
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var result struct {
		Token       string `json:"token"`
		AccessToken string `json:"access_token"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return "", err
	}
	if result.Token != "" {
		return result.Token, nil
	}
	return result.AccessToken, nil
}

// ociManifest is a minimal representation of an OCI image manifest.
type ociManifest struct {
	Layers []struct {
		MediaType   string            `json:"mediaType"`
		Digest      string            `json:"digest"`
		Annotations map[string]string `json:"annotations"`
	} `json:"layers"`
}

// ociManifestAccept lists the media types we'll accept for a manifest.
// Order matters — the registry serves the first type it supports.
var ociManifestAccept = strings.Join([]string{
	"application/vnd.oci.image.manifest.v1+json",
	"application/vnd.oci.artifact.manifest.v1+json",
	"application/vnd.docker.distribution.manifest.v2+json",
	"application/vnd.docker.distribution.manifest.list.v2+json",
	"*/*",
}, ", ")

func (c *ociClient) fetchManifest(ref ociRef) (ociManifest, error) {
	u := fmt.Sprintf("https://%s/v2/%s/manifests/%s", ref.registry, ref.repository, ref.tag)

	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return ociManifest{}, err
	}
	req.Header.Set("Accept", ociManifestAccept)
	if tok, ok := c.tokens[req.URL.Host]; ok {
		req.Header.Set("Authorization", "Bearer "+tok)
	}

	resp, err := c.http.Do(req)
	if err != nil {
		return ociManifest{}, fmt.Errorf("fetching manifest %s: %w", ref.original, err)
	}

	if resp.StatusCode == http.StatusUnauthorized {
		resp.Body.Close()
		tok, err := c.authenticate(resp.Header.Get("Www-Authenticate"))
		if err != nil {
			return ociManifest{}, fmt.Errorf("auth for %s: %w", ref.original, err)
		}
		c.tokens[req.URL.Host] = tok

		req2, _ := http.NewRequest("GET", u, nil)
		req2.Header.Set("Accept", ociManifestAccept)
		req2.Header.Set("Authorization", "Bearer "+tok)
		resp, err = c.http.Do(req2)
		if err != nil {
			return ociManifest{}, fmt.Errorf("fetching manifest %s: %w", ref.original, err)
		}
	}

	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return ociManifest{}, fmt.Errorf("manifest %s: HTTP %d: %s", ref.original, resp.StatusCode, bytes.TrimSpace(body))
	}
	var m ociManifest
	if err := json.NewDecoder(resp.Body).Decode(&m); err != nil {
		return ociManifest{}, fmt.Errorf("decoding manifest: %w", err)
	}
	return m, nil
}

func (c *ociClient) fetchBlob(ref ociRef, digest string) ([]byte, error) {
	u := fmt.Sprintf("https://%s/v2/%s/blobs/%s", ref.registry, ref.repository, digest)
	resp, err := c.get(u)
	if err != nil {
		return nil, fmt.Errorf("fetching blob %s: %w", digest, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("blob %s: HTTP %d", digest, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// extractRegoFiles walks a tar.gz blob and returns .rego file contents keyed
// by their path within the archive (excluding _test.rego files).
func extractRegoFiles(data []byte) (map[string]string, error) {
	gr, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("opening gzip: %w", err)
	}
	defer gr.Close()

	tr := tar.NewReader(gr)
	files := make(map[string]string)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("reading tar: %w", err)
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		if !strings.HasSuffix(hdr.Name, ".rego") || strings.HasSuffix(hdr.Name, "_test.rego") {
			continue
		}
		content, err := io.ReadAll(tr)
		if err != nil {
			return nil, fmt.Errorf("reading %s: %w", hdr.Name, err)
		}
		// Normalize path: strip leading ./ if present.
		files[strings.TrimPrefix(hdr.Name, "./")] = string(content)
	}
	return files, nil
}

// fetchBundleFiles pulls all policy .rego files from an OCI bundle image.
// Returns a map of file path → file content.
func fetchBundleFiles(client *ociClient, imageRef string) (map[string]string, error) {
	ref, err := parseOCIRef(imageRef)
	if err != nil {
		return nil, err
	}

	fmt.Fprintf(os.Stderr, "  fetching %s...\n", imageRef)

	manifest, err := client.fetchManifest(ref)
	if err != nil {
		return nil, err
	}

	all := make(map[string]string)
	for _, layer := range manifest.Layers {
		title := layer.Annotations["org.opencontainers.image.title"]
		blob, err := client.fetchBlob(ref, layer.Digest)
		if err != nil {
			return nil, fmt.Errorf("layer %s (%s): %w", title, layer.Digest, err)
		}
		files, err := extractRegoFiles(blob)
		if err != nil {
			return nil, fmt.Errorf("extracting layer %s: %w", title, err)
		}
		for k, v := range files {
			all[k] = v
		}
	}
	return all, nil
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

func main() {
	before := flag.String("before", "", "Before file (use with -after to compare two files directly)")
	after := flag.String("after", "", "After file (use with -before to compare two files directly)")
	bundle := flag.Bool("bundle", false, "Compare two OCI bundle image references (pass as positional args)")
	noColor := flag.Bool("no-color", false, "Disable color output")
	jsonOut := flag.Bool("json", false, "Output structured JSON for LLM consumption")

	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, `Usage: policy-rule-diff [flags] [refs...]

Report which Rego policy rules (deny/warn) were added or removed between
two OCI bundle tags, git versions, or local files.

  -bundle img:t1 img:t2    Compare two OCI bundle tags (primary use case)
  -json                    Output structured JSON
  -before f -after g       Compare two specific files directly
  <from-ref> <to-ref>      Between two git refs (requires a Rego repo)

Flags:`)
		flag.PrintDefaults()
	}
	os.Args = append(os.Args[:1], reorderArgs(os.Args[1:])...)
	flag.Parse()

	useColor = !*noColor && isTerminal()

	// ── Direct file comparison ───────────────────────────────────────────
	if *before != "" || *after != "" {
		if *before == "" || *after == "" {
			fmt.Fprintln(os.Stderr, "error: -before and -after must be used together")
			os.Exit(1)
		}
		bc := readFile(*before)
		ac := readFile(*after)
		var added, removed []ruleChange
		diffRules(&bc, &ac, *before, &added, &removed)
		if *jsonOut {
			filesBefore := map[string]string{*before: bc}
			filesAfter := map[string]string{*after: ac}
			printChangesJSON(*before, *after, added, removed, filesBefore, filesAfter)
		} else {
			fmt.Printf("\n %s  %s  →  %s\n", bold("File diff:"), dim(*before), dim(*after))
			printChanges(added, removed)
		}
		return
	}

	// ── Bundle comparison ─────────────────────────────────────────────────
	if *bundle {
		args := flag.Args()
		if len(args) != 2 {
			fmt.Fprintln(os.Stderr, "error: -bundle requires exactly two image references")
			os.Exit(1)
		}
		client := newOCIClient()
		if !*jsonOut {
			fmt.Printf("\n %s  %s  →  %s\n", bold("Bundle diff:"), dim(args[0]), dim(args[1]))
		}

		beforeFiles, err := fetchBundleFiles(client, args[0])
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		afterFiles, err := fetchBundleFiles(client, args[1])
		if err != nil {
			fmt.Fprintln(os.Stderr, "error:", err)
			os.Exit(1)
		}
		if !*jsonOut {
			fmt.Println()
		}

		// Union of all file paths.
		allPaths := make(map[string]bool)
		for k := range beforeFiles {
			allPaths[k] = true
		}
		for k := range afterFiles {
			allPaths[k] = true
		}

		var added, removed []ruleChange
		for p := range allPaths {
			var bp, ap *string
			if s, ok := beforeFiles[p]; ok {
				bp = &s
			}
			if s, ok := afterFiles[p]; ok {
				ap = &s
			}
			diffRules(bp, ap, p, &added, &removed)
		}
		if *jsonOut {
			printChangesJSON(args[0], args[1], added, removed, beforeFiles, afterFiles)
		} else {
			printChanges(added, removed)
		}
		return
	}

	// ── Git-based comparison ─────────────────────────────────────────────
	args := flag.Args()
	if len(args) > 2 {
		fmt.Fprintln(os.Stderr, "error: too many arguments — provide 0, 1, or 2 git refs")
		os.Exit(1)
	}

	root := repoRoot()

	var fromRef string
	var toRef *string // nil means working tree

	switch len(args) {
	case 0:
		fromRef = "HEAD"
	case 1:
		fromRef = args[0]
	case 2:
		fromRef = args[0]
		toRef = &args[1]
	}

	toLabel := "working tree"
	if toRef != nil {
		toLabel = *toRef
	}
	if !*jsonOut {
		fmt.Printf("\n %s  %s  →  %s\n", bold("Rule diff:"), dim(fromRef), dim(toLabel))
	}

	policyFiles := changedFiles(fromRef, toRef, root, "policy/")
	// Separate lib-only changes for the secondary notice.
	var libOnly []string
	var directPolicy []string
	for _, f := range policyFiles {
		if strings.HasPrefix(f, "policy/lib/") {
			libOnly = append(libOnly, f)
		} else {
			directPolicy = append(directPolicy, f)
		}
	}

	if len(policyFiles) == 0 {
		if *jsonOut {
			printChangesJSON(fromRef, toLabel, nil, nil, nil, nil)
		} else {
			fmt.Println("No changed policy or library .rego files found.")
		}
		return
	}

	filesBefore := make(map[string]string)
	filesAfter := make(map[string]string)
	var added, removed []ruleChange
	for _, relPath := range directPolicy {
		bc, beforeExists := fileAtRef(relPath, fromRef, root)
		var beforePtr *string
		if beforeExists {
			beforePtr = &bc
			filesBefore[relPath] = bc
		}

		var afterPtr *string
		if toRef != nil {
			ac, afterExists := fileAtRef(relPath, *toRef, root)
			if afterExists {
				afterPtr = &ac
				filesAfter[relPath] = ac
			}
		} else {
			absPath := root + "/" + relPath
			ac := readFile(absPath)
			afterPtr = &ac
			filesAfter[relPath] = ac
		}

		diffRules(beforePtr, afterPtr, relPath, &added, &removed)
	}

	if *jsonOut {
		printChangesJSON(fromRef, toLabel, added, removed, filesBefore, filesAfter)
	} else {
		printChanges(added, removed)

		// ── Library change notice ────────────────────────────────────────
		if len(libOnly) > 0 {
			fmt.Println()
			fmt.Println(yellow("NOTE: Library files also changed (may affect rules indirectly):"))
			for _, f := range libOnly {
				fmt.Println("  " + f)
			}
			fmt.Println("  Run with a specific policy file to see which rules import these libraries.")
		}
	}
}
