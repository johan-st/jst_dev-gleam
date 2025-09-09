package main

import (
	"fmt"
	"log"
	"net/http"
	"time"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

// This example demonstrates how to use the NATS-based real-time architecture
func mainRealtime() {
	// Setup NATS connection
	nc, err := nats.Connect("nats://localhost:4222")
	if err != nil {
		log.Fatal("Failed to connect to NATS:", err)
	}
	defer nc.Close()

	// Create logger
	logger := jst_log.NewLogger("realtime-example", jst_log.DefaultSubjects())
	logger.Connect(nc)

	// Create real-time manager
	realtimeConfig := core.RealtimeConfig{
		SubjectPatterns: core.SubjectPatterns{
			Updates:             "updates.{service}.{resource}.{action}",
			CacheInvalidation:   "cache.{service}.{resource}",
			ServiceDiscovery:    "service.{service}.{endpoint}",
			ClientSubscriptions: "client.{client_id}.{subscription_id}",
		},
		CacheConfig: core.CacheConfig{
			DefaultTTL: 5 * time.Minute,
			MaxSize:    1000,
		},
		StreamConfig: core.StreamConfig{
			UpdatesStream: "updates",
			CacheStream:   "cache_events",
		},
	}

	realtimeManager, err := core.NewRealtimeManager(nc, logger, realtimeConfig)
	if err != nil {
		log.Fatal("Failed to create real-time manager:", err)
	}

	// Create WebSocket handler
	wsConfig := core.WebSocketConfig{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		PingPeriod:      54 * time.Second,
		PongWait:        60 * time.Second,
		WriteWait:       10 * time.Second,
		CheckOrigin: func(r *http.Request) bool {
			return true // Allow all origins in development
		},
	}

	wsHandler := core.NewWebSocketHandler(realtimeManager, wsConfig, logger)

	// Register a sample service
	registerSampleService(realtimeManager, logger)

	// Setup HTTP server with WebSocket endpoint
	http.HandleFunc("/ws", wsHandler.HandleWebSocket)
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		fmt.Fprintf(w, `
<!DOCTYPE html>
<html>
<head>
    <title>Real-time Example</title>
</head>
<body>
    <h1>Real-time Updates Example</h1>
    <div id="messages"></div>
    <script>
        const ws = new WebSocket('ws://localhost:8080/ws');
        
        ws.onopen = function() {
            console.log('Connected to WebSocket');
            // Subscribe to article updates
            ws.send(JSON.stringify({
                type: 'subscribe',
                data: 'updates.articles.article.*'
            }));
        };
        
        ws.onmessage = function(event) {
            const msg = JSON.parse(event.data);
            console.log('Received:', msg);
            
            const div = document.getElementById('messages');
            div.innerHTML += '<p>' + JSON.stringify(msg, null, 2) + '</p>';
        };
        
        ws.onclose = function() {
            console.log('WebSocket closed');
        };
    </script>
</body>
</html>
		`)
	})

	// Start publishing sample updates
	go publishSampleUpdates(realtimeManager, logger)

	// Start HTTP server
	log.Println("Starting server on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

// registerSampleService registers a sample service with the real-time manager
func registerSampleService(rm *core.RealtimeManager, logger *jst_log.Logger) {
	subjects := map[string]string{
		"created":   "articles.created",
		"updated":   "articles.updated",
		"deleted":   "articles.deleted",
		"list":      "articles.list",
		"get":       "articles.get",
		"revisions": "articles.revisions",
	}

	patterns := []string{
		"articles.*",
		"cache.articles.*",
	}

	if err := rm.RegisterService("articles", subjects, patterns); err != nil {
		logger.Error("Failed to register articles service: %v", err)
	}

	logger.Info("Registered articles service with %d subjects", len(subjects))
}

// publishSampleUpdates publishes sample real-time updates
func publishSampleUpdates(rm *core.RealtimeManager, logger *jst_log.Logger) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	updateCount := 0
	for {
		select {
		case <-ticker.C:
			updateCount++

			// Publish a sample article update
			articleData := map[string]interface{}{
				"id":      fmt.Sprintf("article-%d", updateCount),
				"title":   fmt.Sprintf("Sample Article %d", updateCount),
				"slug":    fmt.Sprintf("sample-article-%d", updateCount),
				"content": fmt.Sprintf("This is the content of sample article %d", updateCount),
				"author":  "example-author",
				"tags":    []string{"sample", "example", "test"},
			}

			// Publish different types of updates
			switch updateCount % 3 {
			case 0:
				// Article created
				rm.PublishUpdate("articles", "article", "created", articleData, map[string]interface{}{
					"timestamp": time.Now(),
					"source":    "example",
				})
				logger.Info("Published article created update: %s", articleData["title"])

			case 1:
				// Article updated
				articleData["title"] = fmt.Sprintf("Updated Sample Article %d", updateCount)
				rm.PublishUpdate("articles", "article", "updated", articleData, map[string]interface{}{
					"timestamp": time.Now(),
					"source":    "example",
					"revision":  updateCount,
				})
				logger.Info("Published article updated update: %s", articleData["title"])

			case 2:
				// Article deleted
				rm.PublishUpdate("articles", "article", "deleted", map[string]interface{}{
					"id": articleData["id"],
				}, map[string]interface{}{
					"timestamp": time.Now(),
					"source":    "example",
				})
				logger.Info("Published article deleted update: %s", articleData["id"])
			}

			// Publish cache invalidation
			rm.PublishCacheInvalidation("articles", "all", []string{
				fmt.Sprintf("article-%d", updateCount),
				"list:",
			})
			logger.Info("Published cache invalidation for articles")

			// Demonstrate service discovery
			discoveryData := map[string]interface{}{
				"service": "articles",
				"subjects": map[string]string{
					"created": "articles.created",
					"updated": "articles.updated",
					"deleted": "articles.deleted",
				},
				"updated_at": time.Now(),
			}

			rm.PublishUpdate("articles", "discovery", "service", discoveryData, map[string]interface{}{
				"timestamp": time.Now(),
			})
			logger.Info("Published service discovery update for articles")
		}
	}
}

// Example of how to use the real-time service in your application
func exampleUsage() {
	// This would be in your main application

	// Create real-time manager
	nc, _ := nats.Connect("nats://localhost:4222")
	logger := jst_log.NewLogger("app", jst_log.DefaultSubjects())
	realtimeManager, _ := core.NewRealtimeManager(nc, logger, core.RealtimeConfig{})

	// Register your service
	subjects := map[string]string{
		"created": "my-service.created",
		"updated": "my-service.updated",
	}
	patterns := []string{"my-service.*"}

	realtimeManager.RegisterService("my-service", subjects, patterns)

	// Publish real-time updates
	realtimeManager.PublishUpdate("my-service", "resource", "created", map[string]interface{}{
		"id":   "123",
		"name": "Example Resource",
	}, map[string]interface{}{
		"author": "user123",
	})

	// Set cache
	realtimeManager.SetCache("my-service", "key123", "value123", 5*time.Minute)

	// Get from cache
	if value, found := realtimeManager.GetCache("my-service", "key123"); found {
		fmt.Printf("Cached value: %v\n", value)
	}

	// Invalidate cache
	realtimeManager.InvalidateCache("my-service", []string{"key123"})

	// Create client subscription
	sub, _ := realtimeManager.CreateClientSubscription("client123", "sub1", []string{"my-service.*"}, nil)
	fmt.Printf("Created subscription: %s\n", sub.SubscriptionID)

	// Subscribe to updates
	realtimeManager.GetNatsConn().Subscribe("my-service.*", func(msg *nats.Msg) {
		fmt.Printf("Received update: %s\n", string(msg.Data))
	})

	// Keep running
	select {}
}
