package core

import (
	"fmt"
	"net/http"
)

// ErrorCode represents a standardized error code
type ErrorCode string

const (
	// Service errors
	ErrorCodeServiceNotFound    ErrorCode = "SERVICE_NOT_FOUND"
	ErrorCodeServiceNotRunning  ErrorCode = "SERVICE_NOT_RUNNING"
	ErrorCodeServiceInitialized ErrorCode = "SERVICE_ALREADY_INITIALIZED"
	ErrorCodeServiceNotInit     ErrorCode = "SERVICE_NOT_INITIALIZED"
	ErrorCodeCircularDependency ErrorCode = "CIRCULAR_DEPENDENCY"
	ErrorCodeInvalidDependency  ErrorCode = "INVALID_DEPENDENCY"

	// Configuration errors
	ErrorCodeInvalidConfig ErrorCode = "INVALID_CONFIG"
	ErrorCodeMissingConfig ErrorCode = "MISSING_CONFIG"

	// NATS errors
	ErrorCodeNatsNotConnected   ErrorCode = "NATS_NOT_CONNECTED"
	ErrorCodeNatsRequestTimeout ErrorCode = "NATS_REQUEST_TIMEOUT"

	// Generic errors
	ErrorCodeInternalError ErrorCode = "INTERNAL_ERROR"
	ErrorCodeTimeout       ErrorCode = "TIMEOUT"
	ErrorCodeUnauthorized  ErrorCode = "UNAUTHORIZED"
	ErrorCodeForbidden     ErrorCode = "FORBIDDEN"
	ErrorCodeNotFound      ErrorCode = "NOT_FOUND"
	ErrorCodeConflict      ErrorCode = "CONFLICT"
	ErrorCodeValidation    ErrorCode = "VALIDATION_ERROR"
)

// ServiceError represents a standardized service error
type ServiceError struct {
	Code      ErrorCode
	Message   string
	Details   map[string]interface{}
	Service   string
	Operation string
	Cause     error
}

// Error implements the error interface
func (e *ServiceError) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("[%s] %s: %s (caused by: %v)", e.Code, e.Service, e.Message, e.Cause)
	}
	return fmt.Sprintf("[%s] %s: %s", e.Code, e.Service, e.Message)
}

// Unwrap returns the underlying error
func (e *ServiceError) Unwrap() error {
	return e.Cause
}

// NewServiceError creates a new service error
func NewServiceError(code ErrorCode, service, operation, message string) *ServiceError {
	return &ServiceError{
		Code:      code,
		Message:   message,
		Service:   service,
		Operation: operation,
		Details:   make(map[string]interface{}),
	}
}

// WithCause sets the underlying cause
func (e *ServiceError) WithCause(cause error) *ServiceError {
	e.Cause = cause
	return e
}

// WithDetail adds a detail to the error
func (e *ServiceError) WithDetail(key string, value interface{}) *ServiceError {
	if e.Details == nil {
		e.Details = make(map[string]interface{})
	}
	e.Details[key] = value
	return e
}

// WithDetails adds multiple details to the error
func (e *ServiceError) WithDetails(details map[string]interface{}) *ServiceError {
	if e.Details == nil {
		e.Details = make(map[string]interface{})
	}
	for k, v := range details {
		e.Details[k] = v
	}
	return e
}

// ToHTTPStatus converts the error code to an HTTP status code
func (e *ServiceError) ToHTTPStatus() int {
	switch e.Code {
	case ErrorCodeServiceNotFound, ErrorCodeNotFound:
		return http.StatusNotFound
	case ErrorCodeUnauthorized:
		return http.StatusUnauthorized
	case ErrorCodeForbidden:
		return http.StatusForbidden
	case ErrorCodeConflict:
		return http.StatusConflict
	case ErrorCodeValidation:
		return http.StatusBadRequest
	case ErrorCodeTimeout, ErrorCodeNatsRequestTimeout:
		return http.StatusRequestTimeout
	case ErrorCodeInvalidConfig, ErrorCodeMissingConfig:
		return http.StatusBadRequest
	case ErrorCodeInternalError, ErrorCodeNatsNotConnected:
		return http.StatusInternalServerError
	default:
		return http.StatusInternalServerError
	}
}

// APIError represents a standardized API error response
type APIError struct {
	Code    ErrorCode              `json:"code"`
	Message string                 `json:"message"`
	Details map[string]interface{} `json:"details,omitempty"`
	Service string                 `json:"service,omitempty"`
}

// APIResponse represents a standardized API response
type APIResponse struct {
	Success bool                   `json:"success"`
	Data    interface{}            `json:"data,omitempty"`
	Error   *APIError              `json:"error,omitempty"`
	Meta    map[string]interface{} `json:"meta,omitempty"`
}

// NewAPIResponse creates a successful API response
func NewAPIResponse(data interface{}) *APIResponse {
	return &APIResponse{
		Success: true,
		Data:    data,
	}
}

// NewAPIErrorResponse creates an error API response
func NewAPIErrorResponse(err *ServiceError) *APIResponse {
	return &APIResponse{
		Success: false,
		Error: &APIError{
			Code:    err.Code,
			Message: err.Message,
			Details: err.Details,
			Service: err.Service,
		},
	}
}

// Common error constructors
func ErrServiceNotFound(serviceName string) *ServiceError {
	return NewServiceError(ErrorCodeServiceNotFound, "registry", "get",
		fmt.Sprintf("service %s not found", serviceName))
}

func ErrServiceNotRunning(serviceName string) *ServiceError {
	return NewServiceError(ErrorCodeServiceNotRunning, serviceName, "health",
		"service is not running")
}

func ErrCircularDependency(serviceName string) *ServiceError {
	return NewServiceError(ErrorCodeCircularDependency, "registry", "start",
		fmt.Sprintf("circular dependency detected involving service %s", serviceName))
}

func ErrInvalidDependency(serviceName, dependency string) *ServiceError {
	return NewServiceError(ErrorCodeInvalidDependency, "registry", "start",
		fmt.Sprintf("service %s depends on unknown service %s", serviceName, dependency))
}

func ErrNatsNotConnected() *ServiceError {
	return NewServiceError(ErrorCodeNatsNotConnected, "nats", "connect",
		"NATS connection not established")
}

func ErrInvalidConfig(field string) *ServiceError {
	return NewServiceError(ErrorCodeInvalidConfig, "config", "validate",
		fmt.Sprintf("invalid configuration: %s", field))
}

func ErrTimeout(operation string) *ServiceError {
	return NewServiceError(ErrorCodeTimeout, "service", operation,
		"operation timed out")
}
