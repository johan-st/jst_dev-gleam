package core

import (
	"encoding/json"
	"fmt"
	"time"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/nats-io/nats.go/micro"
)

// MinimalService provides a minimal service with repository
type MinimalService struct {
	name       string
	repo       *SimpleRepository
	nc         *nats.Conn
	logger     *jst_log.Logger
	service    micro.Service
}

// NewMinimalService creates a minimal service
func NewMinimalService(name string, nc *nats.Conn, kv jetstream.KeyValue, logger *jst_log.Logger) *MinimalService {
	repo := NewSimpleRepository(kv, logger)
	
	return &MinimalService{
		name:   name,
		repo:   repo,
		nc:     nc,
		logger: logger,
	}
}

// Start starts the service
func (s *MinimalService) Start() error {
	// Create microservice
	svc, err := micro.AddService(s.nc, micro.Config{
		Name:        s.name,
		Version:     "1.0.0",
		Description: fmt.Sprintf("minimal %s service", s.name),
	})
	if err != nil {
		return err
	}
	
	s.service = svc
	
	// Add basic endpoints
	group := svc.AddGroup(s.name)
	group.AddEndpoint("get", s.handleGet())
	group.AddEndpoint("set", s.handleSet())
	group.AddEndpoint("list", s.handleList())
	group.AddEndpoint("delete", s.handleDelete())
	
	s.logger.Info("minimal service %s started", s.name)
	return nil
}

// Stop stops the service
func (s *MinimalService) Stop() error {
	if s.service != nil {
		return s.service.Stop()
	}
	return nil
}

// GetRepository returns the repository
func (s *MinimalService) GetRepository() *SimpleRepository {
	return s.repo
}

// handleGet handles GET requests
func (s *MinimalService) handleGet() micro.HandlerFunc {
	return func(req micro.Request) {
		var request struct {
			Key string `json:"key"`
		}
		
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		
		value, exists := s.repo.Get(request.Key)
		if !exists {
			req.Error("NOT_FOUND", "key not found", []byte("key not found"))
			return
		}
		
		response, _ := json.Marshal(map[string]interface{}{
			"key":   request.Key,
			"value": value,
		})
		req.Respond(response)
	}
}

// handleSet handles SET requests
func (s *MinimalService) handleSet() micro.HandlerFunc {
	return func(req micro.Request) {
		var request struct {
			Key   string      `json:"key"`
			Value interface{} `json:"value"`
		}
		
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		
		if err := s.repo.Set(request.Key, request.Value); err != nil {
			req.Error("SET_FAILED", "failed to set value", []byte(err.Error()))
			return
		}
		
		response, _ := json.Marshal(map[string]interface{}{
			"success": true,
			"key":     request.Key,
		})
		req.Respond(response)
	}
}

// handleList handles LIST requests
func (s *MinimalService) handleList() micro.HandlerFunc {
	return func(req micro.Request) {
		keys := s.repo.List()
		
		response, _ := json.Marshal(map[string]interface{}{
			"keys": keys,
			"count": len(keys),
		})
		req.Respond(response)
	}
}

// handleDelete handles DELETE requests
func (s *MinimalService) handleDelete() micro.HandlerFunc {
	return func(req micro.Request) {
		var request struct {
			Key string `json:"key"`
		}
		
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		
		if err := s.repo.Delete(request.Key); err != nil {
			req.Error("DELETE_FAILED", "failed to delete key", []byte(err.Error()))
			return
		}
		
		response, _ := json.Marshal(map[string]interface{}{
			"success": true,
			"key":     request.Key,
		})
		req.Respond(response)
	}
}

// PublishUpdate publishes a real-time update
func (s *MinimalService) PublishUpdate(resource, action string, data interface{}) error {
	subject := fmt.Sprintf("updates.%s.%s.%s", s.name, resource, action)
	
	update := map[string]interface{}{
		"service":  s.name,
		"resource": resource,
		"action":   action,
		"data":     data,
		"time":     time.Now(),
	}
	
	jsonData, err := json.Marshal(update)
	if err != nil {
		return err
	}
	
	return s.nc.Publish(subject, jsonData)
}
