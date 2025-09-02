package service

import "context"

// A new Service struct should be created with `name.New(..deps) (*Service, error)`.
//
// The Service is stopped when the context is cancelled.
// It returns an error if the service fails to start, stop or operate.
//
//	func (s *MyService) Run(ctx context.Context) error {
//	    // Connect to NATS
//	    // Register Service with internal name
//	    // Run until context cancelled
//	    <-ctx.Done()
//	    // Cleanup NATS connection
//	    // Cleanup other resources
//	    // Return error if cleanup fails
//	    return ctx.Err()
//	}
type Service interface {
	Run(ctx context.Context) error
	Name() string
}
