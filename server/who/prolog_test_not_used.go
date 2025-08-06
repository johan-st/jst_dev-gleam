package who

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"testing"

	"jst_dev/server/jst_log"
)

var (
	update = flag.Bool("update", false, "update golden files")
)

type TestCase struct {
	User     string
	Resource string
	Expected bool
}

type TestResults struct {
	Read   map[string]bool `json:"read"`
	Change map[string]bool `json:"change"`
	Delete map[string]bool `json:"delete"`
	Create map[string]bool `json:"create"`
}

func TestWhoPermissions(t *testing.T) {
	flag.Parse()

	logger := &jst_log.Logger{}
	who, err := NewProlog(logger)
	if err != nil {
		t.Fatalf("create Who instance: %v", err)
	}

	// Define test cases
	testCases := []TestCase{
		{"johan", "johan_docs", true},  // Owner should be able to read
		{"johan", "other_docs", false}, // Not owner, not granted
		// Add more test cases as needed
	}

	// Run tests and collect results
	results := TestResults{
		Read:   make(map[string]bool),
		Change: make(map[string]bool),
		Delete: make(map[string]bool),
		Create: make(map[string]bool),
	}

	for _, tc := range testCases {
		key := tc.User + ":" + tc.Resource

		// Test Read permission
		allowed, err := who.Read(tc.User, tc.Resource)
		if err != nil {
			t.Errorf("Read(%s, %s) error: %v", tc.User, tc.Resource, err)
		}
		results.Read[key] = allowed

		// Test Change permission
		allowed, err = who.Change(tc.User, tc.Resource)
		if err != nil {
			t.Errorf("Change(%s, %s) error: %v", tc.User, tc.Resource, err)
		}
		results.Change[key] = allowed

		// Test Delete permission
		allowed, err = who.Delete(tc.User, tc.Resource)
		if err != nil {
			t.Errorf("Delete(%s, %s) error: %v", tc.User, tc.Resource, err)
		}
		results.Delete[key] = allowed

		// Test Create permission
		allowed, err = who.Create(tc.User, tc.Resource)
		if err != nil {
			t.Errorf("Create(%s, %s) error: %v", tc.User, tc.Resource, err)
		}
		results.Create[key] = allowed
	}

	// Compare with golden file or update it
	goldenPath := filepath.Join("testdata", "permissions.golden.json")

	if *update {
		err := os.MkdirAll(filepath.Dir(goldenPath), 0755)
		if err != nil {
			t.Fatalf("Failed to create testdata directory: %v", err)
		}

		data, err := json.MarshalIndent(results, "", "  ")
		if err != nil {
			t.Fatalf("Failed to marshal results: %v", err)
		}

		err = os.WriteFile(goldenPath, data, 0600)
		if err != nil {
			t.Fatalf("Failed to write golden file: %v", err)
		}

		t.Logf("Updated golden file: %s", goldenPath)
	} else {
		// Read golden file
		data, err := os.ReadFile(goldenPath)
		if err != nil {
			t.Fatalf("Failed to read golden file: %v", err)
		}

		var expected TestResults
		err = json.Unmarshal(data, &expected)
		if err != nil {
			t.Fatalf("Failed to unmarshal golden file: %v", err)
		}

		// Compare results with expected
		compareResults(t, "Read", expected.Read, results.Read)
		compareResults(t, "Change", expected.Change, results.Change)
		compareResults(t, "Delete", expected.Delete, results.Delete)
		compareResults(t, "Create", expected.Create, results.Create)
	}
}

func compareResults(t *testing.T, operation string, expected, actual map[string]bool) {
	for key, exp := range expected {
		act, ok := actual[key]
		if !ok {
			t.Errorf("%s: Missing test case %s", operation, key)
			continue
		}

		if exp != act {
			t.Errorf("%s: For %s, expected %v but got %v", operation, key, exp, act)
		}
	}

	for key := range actual {
		if _, ok := expected[key]; !ok {
			t.Errorf("%s: Unexpected test case %s", operation, key)
		}
	}
}

func TestMoreComprehensivePermissions(t *testing.T) {
	logger := &jst_log.Logger{}
	who, err := NewProlog(logger)
	if err != nil {
		t.Fatalf("Failed to create Who instance: %v", err)
	}

	// Define a more comprehensive set of test cases
	testCases := []struct {
		name      string
		user      string
		resource  string
		canRead   bool
		canWrite  bool
		canDelete bool
		canCreate bool
	}{
		{
			name:      "Owner has full access",
			user:      "johan",
			resource:  "johan_docs",
			canRead:   true,
			canWrite:  true,
			canDelete: true,
			canCreate: true,
		},
		{
			name:      "Admin has access to all resources",
			user:      "johan", // johan is in admin group
			resource:  "any_resource",
			canRead:   true,
			canWrite:  true,
			canDelete: true,
			canCreate: true,
		},
		// Add more test cases as needed
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			// Test Read permission
			allowed, err := who.Read(tc.user, tc.resource)
			if err != nil {
				t.Errorf("Read(%s, %s) error: %v", tc.user, tc.resource, err)
			}
			if allowed != tc.canRead {
				t.Errorf("Read(%s, %s): expected %v, got %v", tc.user, tc.resource, tc.canRead, allowed)
			}

			// Test Change permission
			allowed, err = who.Change(tc.user, tc.resource)
			if err != nil {
				t.Errorf("Change(%s, %s) error: %v", tc.user, tc.resource, err)
			}
			if allowed != tc.canWrite {
				t.Errorf("Change(%s, %s): expected %v, got %v", tc.user, tc.resource, tc.canWrite, allowed)
			}

			// Test Delete permission
			allowed, err = who.Delete(tc.user, tc.resource)
			if err != nil {
				t.Errorf("Delete(%s, %s) error: %v", tc.user, tc.resource, err)
			}
			if allowed != tc.canDelete {
				t.Errorf("Delete(%s, %s): expected %v, got %v", tc.user, tc.resource, tc.canDelete, allowed)
			}

			// Test Create permission
			allowed, err = who.Create(tc.user, tc.resource)
			if err != nil {
				t.Errorf("Create(%s, %s) error: %v", tc.user, tc.resource, err)
			}
			if allowed != tc.canCreate {
				t.Errorf("Create(%s, %s): expected %v, got %v", tc.user, tc.resource, tc.canCreate, allowed)
			}
		})
	}
}
