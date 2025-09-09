package main

import (
	"encoding/json"
	"fmt"
	"log"
	"time"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"
)

// SimpleArticle represents a simple article structure
type SimpleArticle struct {
	ID      string    `json:"id"`
	Title   string    `json:"title"`
	Content string    `json:"content"`
	Author  string    `json:"author"`
	Created time.Time `json:"created"`
}

// This example demonstrates the simplified NATS-native repository pattern
func mainSimple() {
	// Connect to NATS
	nc, err := nats.Connect("nats://localhost:4222")
	if err != nil {
		log.Fatal("Failed to connect to NATS:", err)
	}
	defer nc.Close()

	// Create logger
	logger := jst_log.NewLogger("simple-repo-example", jst_log.DefaultSubjects())
	logger.Connect(nc)

	// Create real-time manager
	realtimeManager, err := core.NewRealtimeManager(nc, logger, core.RealtimeConfig{})
	if err != nil {
		log.Fatal("Failed to create real-time manager:", err)
	}

	// Create repository factory
	repoFactory := core.NewRepositoryFactory(realtimeManager)

	// Create a simple repository for articles
	articleRepo, err := repoFactory.CreateRepository("articles", core.RepositoryConfig{
		KVStoreName: "articles",
		CacheConfig: core.CacheConfig{
			DefaultTTL: 5 * time.Minute,
			MaxSize:    1000,
		},
		SyncConfig: core.SyncConfig{
			BatchSize: 100,
		},
		Logger: logger,
	})
	if err != nil {
		log.Fatal("Failed to create repository:", err)
	}
	defer articleRepo.Stop()

	// Set up event handlers
	articleRepo.OnEvent("created", func(key string, oldValue, newValue interface{}) {
		logger.Info("Article created: %s", key)
	})

	articleRepo.OnEvent("updated", func(key string, oldValue, newValue interface{}) {
		logger.Info("Article updated: %s", key)
	})

	articleRepo.OnEvent("deleted", func(key string, oldValue, newValue interface{}) {
		logger.Info("Article deleted: %s", key)
	})

	// Create some sample articles
	articles := []SimpleArticle{
		{
			ID:      "article-1",
			Title:   "Getting Started with NATS",
			Content: "NATS is a simple, secure and high performance open source messaging system.",
			Author:  "nats-team",
			Created: time.Now(),
		},
		{
			ID:      "article-2",
			Title:   "Building Real-time Applications",
			Content: "Learn how to build real-time applications using NATS JetStream.",
			Author:  "developer",
			Created: time.Now().Add(-1 * time.Hour),
		},
		{
			ID:      "article-3",
			Title:   "Microservices with NATS",
			Content: "Use NATS as the backbone for your microservices architecture.",
			Author:  "architect",
			Created: time.Now().Add(-2 * time.Hour),
		},
	}

	// Store articles in the repository
	logger.Info("Storing %d articles...", len(articles))
	for _, article := range articles {
		if err := articleRepo.Set(article.ID, article); err != nil {
			logger.Error("Failed to store article %s: %v", article.ID, err)
		}
	}

	// Wait a moment for the repository to sync
	time.Sleep(1 * time.Second)

	// Demonstrate repository operations
	logger.Info("Repository operations:")

	// Get a specific article
	if article, found := articleRepo.Get("article-1"); found {
		logger.Info("Retrieved article: %+v", article)
	}

	// List all articles
	allArticles := articleRepo.ListWithValues()
	logger.Info("Total articles in repository: %d", len(allArticles))

	// Search for articles by author
	authorArticles := make([]SimpleArticle, 0)
	for _, value := range allArticles {
		if article, ok := value.(SimpleArticle); ok && article.Author == "developer" {
			authorArticles = append(authorArticles, article)
		}
	}
	logger.Info("Articles by 'developer': %d", len(authorArticles))

	// Update an article
	updatedArticle := SimpleArticle{
		ID:      "article-1",
		Title:   "Getting Started with NATS (Updated)",
		Content: "NATS is a simple, secure and high performance open source messaging system. Updated with more details.",
		Author:  "nats-team",
		Created: time.Now(),
	}
	if err := articleRepo.Set("article-1", updatedArticle); err != nil {
		logger.Error("Failed to update article: %v", err)
	}

	// Demonstrate real-time updates
	logger.Info("Demonstrating real-time updates...")

	// Start a goroutine to simulate external updates
	go func() {
		for i := 0; i < 5; i++ {
			time.Sleep(2 * time.Second)

			newArticle := SimpleArticle{
				ID:      fmt.Sprintf("dynamic-article-%d", i+1),
				Title:   fmt.Sprintf("Dynamic Article %d", i+1),
				Content: fmt.Sprintf("This is a dynamically created article number %d", i+1),
				Author:  "system",
				Created: time.Now(),
			}

			if err := articleRepo.Set(newArticle.ID, newArticle); err != nil {
				logger.Error("Failed to create dynamic article: %v", err)
			}
		}
	}()

	// Wait for updates
	time.Sleep(15 * time.Second)

	// Show final state
	logger.Info("Final repository state:")
	stats := articleRepo.GetStats()
	logger.Info("Repository stats: %+v", stats)

	// List all articles again
	finalArticles := articleRepo.ListWithValues()
	logger.Info("Final article count: %d", len(finalArticles))

	// Demonstrate deletion
	if err := articleRepo.Delete("article-2"); err != nil {
		logger.Error("Failed to delete article: %v", err)
	}

	logger.Info("Repository example completed")
}

// Example of using the generic repository with typed operations
func exampleGenericRepository() {
	// This would be in your service code
	nc, _ := nats.Connect("nats://localhost:4222")
	logger := jst_log.NewLogger("generic-repo", jst_log.DefaultSubjects())
	realtimeManager, _ := core.NewRealtimeManager(nc, logger, core.RealtimeConfig{})

	// Create a generic repository for SimpleArticle
	kvStore, _ := realtimeManager.GetKVStore("articles")

	genericRepo := core.NewGenericRepository[SimpleArticle](
		kvStore,
		core.RepositoryConfig{
			CacheConfig: core.CacheConfig{
				DefaultTTL: 5 * time.Minute,
				MaxSize:    1000,
			},
			SyncConfig: core.SyncConfig{
				BatchSize: 100,
			},
			Logger: logger,
		},
		func(data []byte) (SimpleArticle, error) {
			var article SimpleArticle
			err := json.Unmarshal(data, &article)
			return article, err
		},
		func(article SimpleArticle) ([]byte, error) {
			return json.Marshal(article)
		},
	)

	// Start the repository
	genericRepo.Start()
	defer genericRepo.Stop()

	// Use typed operations
	article := SimpleArticle{
		ID:      "typed-article",
		Title:   "Typed Article",
		Content: "This is a typed article",
		Author:  "developer",
		Created: time.Now(),
	}

	// Set typed value
	genericRepo.SetTyped("typed-article", article)

	// Get typed value
	if retrieved, found := genericRepo.GetTyped("typed-article"); found {
		fmt.Printf("Retrieved typed article: %+v\n", retrieved)
	}

	// List all typed articles
	allTyped := genericRepo.ListTyped()
	fmt.Printf("All typed articles: %+v\n", allTyped)

	// Set up typed event handlers
	genericRepo.OnTypedEvent("created", func(key string, oldArticle, newArticle SimpleArticle) {
		fmt.Printf("Typed article created: %s - %s\n", key, newArticle.Title)
	})

	genericRepo.OnTypedEvent("updated", func(key string, oldArticle, newArticle SimpleArticle) {
		fmt.Printf("Typed article updated: %s - %s\n", key, newArticle.Title)
	})
}
