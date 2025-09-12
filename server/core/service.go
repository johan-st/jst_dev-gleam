// Package core shared base types and functions for all services to build on.
package core

import (
	"context"
	"fmt"
	"sync"
)

// A new Service implementation should be created with `name.New(..deps) (*Service, error)`.
//
// Lifecycle contract:
// - Start any required resources (HTTP server, message endpoints, schedulers, etc.)
// - Log a concise "started" message
// - Block until the provided context is cancelled
// - Perform cleanup (stop servers, unregister/endpoints, close connections)
// - Log "stopping..." and "stopped" around cleanup
// - Return nil on normal cancellation, or a wrapped error on failure
//
//	func (s *MyService) Run(ctx context.Context) error {
//	    // Initialize service (set up routes, endpoints, connections, etc.)
//	    // s.l.Info("service started")
//	    <-ctx.Done()
//	    // s.l.Info("service stopping...")
//	    // Cleanup resources
//	    // s.l.Info("service stopped")
//	    return nil
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
