package service

import (
	"context"
	"fmt"
	"sync"
)

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

// Run starts a service in a goroutine and manages its lifecycle.
// It adds the service to the wait group, runs it in the background,
// and handles cleanup when the context is cancelled.
func Run(ctx context.Context, waitGroup *sync.WaitGroup, svc Service) {
	waitGroup.Add(1)
	go func() {
		defer waitGroup.Done()
		if err := svc.Run(ctx); err != nil {
			fmt.Printf("- Service error %s: %v\n", svc.Name(), err)
		}
	}()
}
