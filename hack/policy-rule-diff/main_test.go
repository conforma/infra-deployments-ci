package main

import (
	"strings"
	"testing"
	"time"
)

func TestValidateEffectiveOn(t *testing.T) {
	now := time.Date(2026, time.October, 5, 12, 0, 0, 0, time.UTC)
	minimum := now.Add(56 * 24 * time.Hour)
	tests := []struct {
		name      string
		value     string
		wantError string
	}{
		{"at the eight-week boundary", minimum.Format(time.RFC3339), ""},
		{"after the boundary with an offset", minimum.Add(time.Hour).In(time.FixedZone("UTC+2", 2*60*60)).Format(time.RFC3339), ""},
		{"one second early", minimum.Add(-time.Second).Format(time.RFC3339), "before"},
		{"missing date", "", "missing"},
		{"invalid date", "2026-12-01", "not RFC3339"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			added := []ruleChange{{rule: &rule{shortName: "example", effectiveOn: tc.value}, file: "policy/release/example.rego"}}
			err := validateEffectiveOn(added, 56, now)
			if tc.wantError == "" {
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
			} else if err == nil || !strings.Contains(err.Error(), tc.wantError) {
				t.Fatalf("error = %v, want substring %q", err, tc.wantError)
			}
		})
	}

	if err := validateEffectiveOn(nil, 56, now); err != nil {
		t.Fatalf("no added rules should pass: %v", err)
	}
	if err := validateEffectiveOn([]ruleChange{{rule: &rule{effectiveOn: ""}}}, 0, now); err != nil {
		t.Fatalf("disabled check should pass: %v", err)
	}
}

func TestReorderArgsWithLeadTime(t *testing.T) {
	args := reorderArgs([]string{"old", "new", "-min-effective-lead-days", "56", "-json"})
	want := []string{"-min-effective-lead-days", "56", "-json", "old", "new"}
	if strings.Join(args, " ") != strings.Join(want, " ") {
		t.Fatalf("args = %q, want %q", args, want)
	}
}

func TestParseOCIRef(t *testing.T) {
	tests := []struct {
		input     string
		reference string
	}{
		{"quay.io/conforma/release-policy:konflux", "konflux"},
		{"quay.io/conforma/release-policy@sha256:abcdef", "sha256:abcdef"},
		{"registry.example:5000/conforma/release-policy:latest", "latest"},
	}
	for _, tc := range tests {
		ref, err := parseOCIRef(tc.input)
		if err != nil {
			t.Fatalf("parseOCIRef(%q): %v", tc.input, err)
		}
		if ref.reference != tc.reference || ref.repository != "conforma/release-policy" {
			t.Errorf("parseOCIRef(%q) = %+v", tc.input, ref)
		}
	}
	if _, err := parseOCIRef("quay.io/conforma/release-policy@"); err == nil {
		t.Fatal("empty digest should be rejected")
	}
}

func TestNewRuleMetadataReachesLeadTimeCheck(t *testing.T) {
	oldRule := `package example
# METADATA
# title: Existing rule
# custom:
# short_name: existing_rule
# effective_on: 2025-01-01T00:00:00Z
deny if {
    true
}
`
	newRule := `# METADATA
# title: New rule
# custom:
# short_name: new_rule
# effective_on: 2026-10-06T00:00:00Z
warn if {
    true
}
`
	var added, removed []ruleChange
	after := oldRule + newRule
	diffRules(&oldRule, &after, "policy/release/example.rego", &added, &removed)
	if len(added) != 1 || added[0].rule.shortName != "new_rule" || len(removed) != 0 {
		t.Fatalf("unexpected rule diff: added=%+v removed=%+v", added, removed)
	}
	now := time.Date(2026, time.October, 5, 12, 0, 0, 0, time.UTC)
	if err := validateEffectiveOn(added, 56, now); err == nil || !strings.Contains(err.Error(), "new_rule") {
		t.Fatalf("new rule should fail lead-time check: %v", err)
	}
}
