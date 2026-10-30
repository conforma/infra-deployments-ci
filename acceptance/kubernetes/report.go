package kubernetes

import (
	"encoding/json"
	"fmt"
	"time"
)

// Completion with STRICT=false is insufficient: an operational error can still
// yield a completed TaskRun. Require a populated, internally consistent report.
func validateTestOutput(raw string) error {
	var report struct {
		Result    string `json:"result"`
		Timestamp string `json:"timestamp"`
		Successes *int   `json:"successes"`
		Failures  *int   `json:"failures"`
		Warnings  *int   `json:"warnings"`
	}
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		return fmt.Errorf("invalid TEST_OUTPUT: %w", err)
	}
	if report.Successes == nil || report.Failures == nil || report.Warnings == nil ||
		*report.Successes < 0 || *report.Failures < 0 || *report.Warnings < 0 ||
		*report.Successes+*report.Failures == 0 {
		return fmt.Errorf("TEST_OUTPUT has missing or invalid evaluation counts: %s", raw)
	}
	if _, err := time.Parse(time.RFC3339, report.Timestamp); err != nil {
		return fmt.Errorf("invalid TEST_OUTPUT timestamp: %w", err)
	}
	if (report.Result != "SUCCESS" && report.Result != "FAILURE") ||
		(report.Result == "SUCCESS" && *report.Failures != 0) ||
		(report.Result == "FAILURE" && *report.Failures == 0) {
		return fmt.Errorf("operational error or inconsistent TEST_OUTPUT: %s", raw)
	}
	return nil
}
