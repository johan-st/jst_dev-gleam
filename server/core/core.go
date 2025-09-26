// Package core shared base types and functions for all services to build on.
package core

import (
	"encoding/json"
	"fmt"
	"regexp"
)

type DummyValue struct {
	Id      string `json:"id"`
	Rev     uint64 `json:"revision"`
	Content string `json:"content"`
}

func (d DummyValue) Bytes() []byte {
	bytes, err := json.Marshal(d)
	if err != nil {
		return []byte{}
	}
	return bytes
}

func (d DummyValue) FromBytes(bytes []byte) (DummyValue, error) {
	err := json.Unmarshal(bytes, d)
	if err != nil {
		return d, fmt.Errorf("from bytes: %w", err)
	}
	return d, nil
}

var subjectRegexp = regexp.MustCompile(`^[^ >]*[>]?$`)

func SubjectValid(subject string) error {
	if subject == "" {
		return fmt.Errorf("subject cannot be empty")
	}
	if subject[0] == '.' || subject[len(subject)-1] == '.' || !subjectRegexp.MatchString(subject) {
		return fmt.Errorf("subject is invalid: %s", subject)
	}
	return nil
}
