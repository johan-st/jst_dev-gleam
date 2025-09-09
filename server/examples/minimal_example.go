package main

import (
	"context"
	"encoding/json"
	"log"
	"time"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

// This example shows the minimal repository pattern
func main() {
	// Connect to NATS
	nc, err := nats.Connect("nats://localhost:4222")
	if err != nil {
		log.Fatal("Failed to connect to NATS:", err)
	}
	defer nc.Close()

	// Create logger
	logger := jst_log.NewLogger("minimal-example", jst_log.DefaultSubjects())
	logger.Connect(nc)

	// Create JetStream context
	js, err := jetstream.New(nc)
	if err != nil {
		log.Fatal("Failed to create JetStream:", err)
	}

	// Create KV store
	kv, err := js.CreateOrUpdateKeyValue(context.Background(), jetstream.KeyValueConfig{
		Bucket: "minimal_example",
	})
	if err != nil {
		log.Fatal("Failed to create KV store:", err)
	}

	// Create minimal service
	service := core.NewMinimalService("articles", nc, kv, logger)
	
	// Start service
	if err := service.Start(); err != nil {
		log.Fatal("Failed to start service:", err)
	}
	defer service.Stop()

	// Get repository
	repo := service.GetRepository()

	// Use the repository
	logger.Info("Using minimal repository...")

	// Set some data
	articles := []map[string]interface{}{
		{"id": "1", "title": "Article 1", "content": "Content 1"},
		{"id": "2", "title": "Article 2", "content": "Content 2"},
		{"id": "3", "title": "Article 3", "content": "Content 3"},
	}

	for _, article := range articles {
		if err := repo.Set(article["id"].(string), article); err != nil {
			logger.Error("Failed to set article: %v", err)
		}
	}

	// Wait for sync
	time.Sleep(100 * time.Millisecond)

	// Get data
	if article, exists := repo.Get("1"); exists {
		logger.Info("Retrieved article: %+v", article)
	}

	// List all keys
	keys := repo.List()
	logger.Info("All keys: %v", keys)

	// Publish real-time update
	service.PublishUpdate("article", "created", map[string]interface{}{
		"id": "4", "title": "New Article", "content": "New Content",
	})

	// Subscribe to updates
	sub, err := nc.Subscribe("updates.articles.*", func(msg *nats.Msg) {
		var update map[string]interface{}
		if err := json.Unmarshal(msg.Data, &update); err == nil {
			logger.Info("Received update: %+v", update)
		}
	})
	if err != nil {
		logger.Error("Failed to subscribe: %v", err)
	}
	defer sub.Unsubscribe()

	// Test NATS microservice endpoints
	testMicroserviceEndpoints(nc, logger)

	logger.Info("Minimal example completed")
}

func testMicroserviceEndpoints(nc *nats.Conn, logger *jst_log.Logger) {
	// Test GET
	getReq := map[string]interface{}{"key": "1"}
	getData, _ := json.Marshal(getReq)
	
	if msg, err := nc.Request("articles.get", getData, 5*time.Second); err == nil {
		var response map[string]interface{}
		json.Unmarshal(msg.Data, &response)
		logger.Info("GET response: %+v", response)
	}

	// Test SET
	setReq := map[string]interface{}{
		"key": "test",
		"value": map[string]interface{}{
			"title": "Test Article",
			"content": "Test Content",
		},
	}
	setData, _ := json.Marshal(setReq)
	
	if msg, err := nc.Request("articles.set", setData, 5*time.Second); err == nil {
		var response map[string]interface{}
		json.Unmarshal(msg.Data, &response)
		logger.Info("SET response: %+v", response)
	}

	// Test LIST
	if msg, err := nc.Request("articles.list", []byte("{}"), 5*time.Second); err == nil {
		var response map[string]interface{}
		json.Unmarshal(msg.Data, &response)
		logger.Info("LIST response: %+v", response)
	}
}
