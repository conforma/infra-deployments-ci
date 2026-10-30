package kubernetes

import "testing"

func TestValidateTestOutput(t *testing.T) {
	for _, tc := range []struct {
		raw   string
		valid bool
	}{
		{`{"result":"SUCCESS","timestamp":"2026-10-30T00:00:00Z","successes":1,"failures":0,"warnings":0}`, true},
		{`{"result":"FAILURE","timestamp":"2026-10-30T00:00:00Z","successes":0,"failures":1,"warnings":0}`, true},
		{``, false}, {`{}`, false},
		{`{"result":"ERROR","timestamp":"2026-10-30T00:00:00Z","successes":0,"failures":1,"warnings":0}`, false},
		{`{"result":"SUCCESS","timestamp":"2026-10-30T00:00:00Z","successes":0,"failures":0,"warnings":0}`, false},
		{`{"result":"SUCCESS","timestamp":"2026-10-30T00:00:00Z","successes":1,"failures":1,"warnings":0}`, false},
	} {
		t.Run(tc.raw, func(t *testing.T) {
			if err := validateTestOutput(tc.raw); (err == nil) != tc.valid {
				t.Fatalf("valid=%v, error=%v", tc.valid, err)
			}
		})
	}
}
