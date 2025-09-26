package core

import "fmt"

type ErrCode string

const (
	ErrCodeNotFound = "NOT_FOUND"
	ErrCodeInvalid  = "INVALID"
	ErrCodeInternal = "INTERNAL"
	ErrCodeTimeout  = "TIMEOUT"
	ErrCodeConflict = "CONFLICT"
)

type Error struct {
	ErrCode ErrCode
	Message string
	Data    []byte
}

func (e *Error) Error() string {
	return fmt.Sprintf("%s: %s", e.ErrCode, e.Message)
}
