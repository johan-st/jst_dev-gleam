package articles

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/nats-io/nats.go/micro"

	"jst_dev/server/core"
)

// RealtimeArticlesService implements real-time articles with caching and live updates
type RealtimeArticlesService struct {
	*core.RealtimeService
	kv jetstream.KeyValue
}

// NewRealtimeArticlesService creates a new real-time articles service
func NewRealtimeArticlesService(config core.RealtimeServiceConfig) (core.Service, error) {
	// Define subjects for real-time updates
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

	realtimeConfig := config
	realtimeConfig.Subjects = subjects
	realtimeConfig.Patterns = patterns
	realtimeConfig.KVStoreName = "articles"
	realtimeConfig.EnableCache = true
	realtimeConfig.CacheTTL = 5 * time.Minute

	base := core.NewRealtimeService("articles", []string{}, realtimeConfig)

	service := &RealtimeArticlesService{
		RealtimeService: base,
	}

	// Build the service with custom implementations
	return core.NewRealtimeServiceBuilder("articles", realtimeConfig).
		WithKVStore("articles").
		WithSubjects(subjects).
		WithPatterns(patterns).
		WithCache(5 * time.Minute).
		WithKVWatcher(true).
		WithInitializer(service.initialize).
		WithRunner(service.run).
		WithShutdowner(service.shutdown).
		WithHealthChecker(service.health).
		Build(), nil
}

// initialize sets up the JetStream KV store and real-time features
func (s *RealtimeArticlesService) initialize(ctx context.Context) error {
	if err := s.RealtimeService.Initialize(ctx); err != nil {
		return err
	}

	// Get KV store
	kv, err := s.GetRealtimeManager().GetKVStore("articles")
	if err != nil {
		return fmt.Errorf("failed to get articles KV store: %w", err)
	}
	s.kv = kv

	// Set up cache with initial data
	if err := s.loadInitialCache(); err != nil {
		s.GetLogger().Warn("failed to load initial cache: %v", err)
	}

	s.GetLogger().Info("real-time articles service initialized")
	return nil
}

// run starts the articles microservice with real-time capabilities
func (s *RealtimeArticlesService) run(ctx context.Context) error {
	svcMetadata := map[string]string{
		"location":    "unknown",
		"environment": "development",
	}

	// Create microservice
	articlesSvc, err := micro.AddService(s.GetNatsConn(), micro.Config{
		Name:        "articles",
		Version:     "1.0.0",
		Description: "real-time articles management service",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "run",
			"failed to create microservice").WithCause(err)
	}

	// Add service endpoints
	articlesGroup := articlesSvc.AddGroup("articles", micro.WithGroupQueueGroup("articles"))

	// Article CRUD endpoints
	if err := articlesGroup.AddEndpoint("get", s.handleGet(), micro.WithEndpointSubject("articles.get")); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "run",
			"failed to add get endpoint").WithCause(err)
	}

	if err := articlesGroup.AddEndpoint("get_by_slug", s.handleGetBySlug(), micro.WithEndpointSubject("articles.get_by_slug")); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "run",
			"failed to add get_by_slug endpoint").WithCause(err)
	}

	if err := articlesGroup.AddEndpoint("list", s.handleList(), micro.WithEndpointSubject("articles.list")); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "run",
			"failed to add list endpoint").WithCause(err)
	}

	if err := articlesGroup.AddEndpoint("create", s.handleCreate(), micro.WithEndpointSubject("articles.create")); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "run",
			"failed to add create endpoint").WithCause(err)
	}

	if err := articlesGroup.AddEndpoint("update", s.handleUpdate(), micro.WithEndpointSubject("articles.update")); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "run",
			"failed to add update endpoint").WithCause(err)
	}

	if err := articlesGroup.AddEndpoint("delete", s.handleDelete(), micro.WithEndpointSubject("articles.delete")); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "run",
			"failed to add delete endpoint").WithCause(err)
	}

	if err := articlesGroup.AddEndpoint("revisions", s.handleRevisions(), micro.WithEndpointSubject("articles.revisions")); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "run",
			"failed to add revisions endpoint").WithCause(err)
	}

	// Subscribe to real-time updates
	if err := s.subscribeToUpdates(); err != nil {
		return fmt.Errorf("failed to subscribe to updates: %w", err)
	}

	s.GetLogger().Info("real-time articles service started")

	// Wait for context cancellation
	<-ctx.Done()

	// Cleanup
	s.GetLogger().Info("real-time articles service stopping...")
	if err := articlesSvc.Stop(); err != nil {
		s.GetLogger().Error("failed to stop articles service: %v", err)
	}

	s.GetLogger().Info("real-time articles service stopped")
	return nil
}

// shutdown performs cleanup
func (s *RealtimeArticlesService) shutdown(ctx context.Context) error {
	return s.RealtimeService.Shutdown(ctx)
}

// health performs health check
func (s *RealtimeArticlesService) health() error {
	if err := s.RealtimeService.Health(); err != nil {
		return err
	}

	// Additional health checks specific to articles service
	if s.kv == nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "health",
			"KV store not initialized")
	}

	return nil
}

// loadInitialCache loads initial data into cache
func (s *RealtimeArticlesService) loadInitialCache() error {
	keys, err := s.kv.ListKeys(context.Background())
	if err != nil {
		return fmt.Errorf("failed to list keys: %w", err)
	}

	for key := range keys.Keys() {
		entry, err := s.kv.Get(context.Background(), key)
		if err != nil {
			continue
		}

		var article Article
		if err := json.Unmarshal(entry.Value(), &article); err != nil {
			continue
		}

		// Cache the article
		s.SetCache(key, article, 0)
	}

	s.GetLogger().Info("loaded %d articles into cache", len(keys.Keys()))
	return nil
}

// subscribeToUpdates subscribes to real-time update events
func (s *RealtimeArticlesService) subscribeToUpdates() error {
	// Subscribe to cache invalidation events
	if err := s.SubscribeToUpdates("cache.articles.*", s.handleCacheInvalidation); err != nil {
		return fmt.Errorf("failed to subscribe to cache invalidation: %w", err)
	}

	// Subscribe to article updates from other services
	if err := s.SubscribeToUpdates("articles.*", s.handleArticleUpdate); err != nil {
		return fmt.Errorf("failed to subscribe to article updates: %w", err)
	}

	return nil
}

// handleCacheInvalidation handles cache invalidation events
func (s *RealtimeArticlesService) handleCacheInvalidation(update *core.UpdateMessage) {
	s.GetLogger().Debug("cache invalidation: %s", update.Resource)

	// Extract keys from the update
	if keys, ok := update.Data.(map[string]interface{})["keys"].([]interface{}); ok {
		var keyStrings []string
		for _, key := range keys {
			if keyStr, ok := key.(string); ok {
				keyStrings = append(keyStrings, keyStr)
			}
		}

		// Invalidate cache
		if err := s.InvalidateCache(keyStrings); err != nil {
			s.GetLogger().Error("failed to invalidate cache: %v", err)
		}
	}
}

// handleArticleUpdate handles article update events
func (s *RealtimeArticlesService) handleArticleUpdate(update *core.UpdateMessage) {
	s.GetLogger().Debug("article update: %s %s", update.Action, update.Resource)

	// Update cache based on the action
	switch update.Action {
	case "created", "updated":
		// Refresh the article in cache
		if articleData, ok := update.Data.(map[string]interface{}); ok {
			if id, ok := articleData["id"].(string); ok {
				// Fetch fresh data from KV store
				if entry, err := s.kv.Get(context.Background(), id); err == nil {
					var article Article
					if err := json.Unmarshal(entry.Value(), &article); err == nil {
						s.SetCache(id, article, 0)
					}
				}
			}
		}
	case "deleted":
		// Remove from cache
		if articleData, ok := update.Data.(map[string]interface{}); ok {
			if id, ok := articleData["id"].(string); ok {
				s.InvalidateCache([]string{id})
			}
		}
	}
}

// Enhanced handlers with caching and real-time updates

func (s *RealtimeArticlesService) handleGet() micro.HandlerFunc {
	return func(req micro.Request) {
		var request GetArticleRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		id, err := uuid.Parse(request.ID)
		if err != nil {
			s.respondError(req, "invalid ID format", err)
			return
		}

		// Try cache first
		if cached, found := s.GetCache(id.String()); found {
			if article, ok := cached.(Article); ok {
				s.respondSuccess(req, ArticleResponse{Article: &article})
				return
			}
		}

		// Fallback to KV store
		article, err := s.getArticle(id)
		if err != nil {
			s.respondError(req, "failed to get article", err)
			return
		}

		// Cache the result
		s.SetCache(id.String(), article, 0)

		s.respondSuccess(req, ArticleResponse{Article: &article})
	}
}

func (s *RealtimeArticlesService) handleGetBySlug() micro.HandlerFunc {
	return func(req micro.Request) {
		var request GetArticleBySlugRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		// Try cache first
		cacheKey := "slug:" + request.Slug
		if cached, found := s.GetCache(cacheKey); found {
			if article, ok := cached.(Article); ok {
				s.respondSuccess(req, ArticleResponse{Article: &article})
				return
			}
		}

		// Fallback to KV store
		article, err := s.getArticleBySlug(request.Slug)
		if err != nil {
			s.respondError(req, "failed to get article by slug", err)
			return
		}

		// Cache the result
		s.SetCache(cacheKey, article, 0)
		s.SetCache(article.Id.String(), article, 0) // Also cache by ID

		s.respondSuccess(req, ArticleResponse{Article: &article})
	}
}

func (s *RealtimeArticlesService) handleList() micro.HandlerFunc {
	return func(req micro.Request) {
		var request ListArticlesRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		// Try cache first
		cacheKey := fmt.Sprintf("list:%d:%d", request.Limit, request.Offset)
		if cached, found := s.GetCache(cacheKey); found {
			if articles, ok := cached.([]Article); ok {
				s.respondSuccess(req, ListArticlesResponse{
					Articles: articles,
					Total:    len(articles),
				})
				return
			}
		}

		// Fallback to KV store
		articles, err := s.listArticles(request.Limit, request.Offset)
		if err != nil {
			s.respondError(req, "failed to list articles", err)
			return
		}

		// Cache the result
		s.SetCache(cacheKey, articles, 0)

		s.respondSuccess(req, ListArticlesResponse{
			Articles: articles,
			Total:    len(articles),
		})
	}
}

func (s *RealtimeArticlesService) handleCreate() micro.HandlerFunc {
	return func(req micro.Request) {
		var request CreateArticleRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		article := Article{
			StructVersion: 1,
			Id:            uuid.New(),
			Slug:          uuid.New().String(), // TODO: Generate proper slug
			Title:         request.Title,
			Subtitle:      request.Subtitle,
			Leading:       request.Leading,
			Content:       request.Content,
			Author:        request.Author,
			PublishedAt:   int(time.Now().UnixMilli()),
			Tags:          request.Tags,
		}

		createdArticle, err := s.createArticle(article)
		if err != nil {
			s.respondError(req, "failed to create article", err)
			return
		}

		// Cache the new article
		s.SetCache(createdArticle.Id.String(), createdArticle, 0)
		s.SetCache("slug:"+createdArticle.Slug, createdArticle, 0)

		// Publish real-time update
		s.PublishUpdate("article", "created", map[string]interface{}{
			"id":    createdArticle.Id.String(),
			"slug":  createdArticle.Slug,
			"title": createdArticle.Title,
		}, map[string]interface{}{
			"author": request.Author,
		})

		// Invalidate list caches
		s.InvalidateCache([]string{"list:"})

		s.respondSuccess(req, ArticleResponse{Article: &createdArticle})
	}
}

func (s *RealtimeArticlesService) handleUpdate() micro.HandlerFunc {
	return func(req micro.Request) {
		var request UpdateArticleRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		id, err := uuid.Parse(request.ID)
		if err != nil {
			s.respondError(req, "invalid ID format", err)
			return
		}

		// Get existing article
		existing, err := s.getArticle(id)
		if err != nil {
			s.respondError(req, "article not found", err)
			return
		}

		// Update fields
		if request.Title != "" {
			existing.Title = request.Title
		}
		if request.Subtitle != "" {
			existing.Subtitle = request.Subtitle
		}
		if request.Leading != "" {
			existing.Leading = request.Leading
		}
		if request.Content != "" {
			existing.Content = request.Content
		}
		if request.Tags != nil {
			existing.Tags = request.Tags
		}
		existing.Rev = request.Rev

		updatedArticle, err := s.updateArticle(existing)
		if err != nil {
			s.respondError(req, "failed to update article", err)
			return
		}

		// Update cache
		s.SetCache(updatedArticle.Id.String(), updatedArticle, 0)
		s.SetCache("slug:"+updatedArticle.Slug, updatedArticle, 0)

		// Publish real-time update
		s.PublishUpdate("article", "updated", map[string]interface{}{
			"id":    updatedArticle.Id.String(),
			"slug":  updatedArticle.Slug,
			"title": updatedArticle.Title,
		}, map[string]interface{}{
			"revision": updatedArticle.Rev,
		})

		// Invalidate list caches
		s.InvalidateCache([]string{"list:"})

		s.respondSuccess(req, ArticleResponse{Article: &updatedArticle})
	}
}

func (s *RealtimeArticlesService) handleDelete() micro.HandlerFunc {
	return func(req micro.Request) {
		var request DeleteArticleRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		id, err := uuid.Parse(request.ID)
		if err != nil {
			s.respondError(req, "invalid ID format", err)
			return
		}

		// Get article before deletion for real-time update
		article, _ := s.getArticle(id)

		if err := s.deleteArticle(id); err != nil {
			s.respondError(req, "failed to delete article", err)
			return
		}

		// Remove from cache
		s.InvalidateCache([]string{id.String(), "slug:" + article.Slug})

		// Publish real-time update
		s.PublishUpdate("article", "deleted", map[string]interface{}{
			"id": id.String(),
		}, map[string]interface{}{
			"title": article.Title,
		})

		// Invalidate list caches
		s.InvalidateCache([]string{"list:"})

		s.respondSuccess(req, map[string]string{"status": "deleted"})
	}
}

func (s *RealtimeArticlesService) handleRevisions() micro.HandlerFunc {
	return func(req micro.Request) {
		var request GetRevisionsRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		id, err := uuid.Parse(request.ID)
		if err != nil {
			s.respondError(req, "invalid ID format", err)
			return
		}

		revisions, err := s.getArticleRevisions(id)
		if err != nil {
			s.respondError(req, "failed to get revisions", err)
			return
		}

		s.respondSuccess(req, RevisionsResponse{Revisions: revisions})
	}
}

// Helper methods (same as before but using the real-time service)

func (s *RealtimeArticlesService) respondSuccess(req micro.Request, data interface{}) {
	response, err := json.Marshal(data)
	if err != nil {
		s.GetLogger().Error("failed to marshal response: %v", err)
		req.Error("INTERNAL_ERROR", "failed to marshal response", []byte(err.Error()))
		return
	}
	req.Respond(response)
}

func (s *RealtimeArticlesService) respondError(req micro.Request, message string, err error) {
	s.GetLogger().Error("%s: %v", message, err)
	req.Error("INTERNAL_ERROR", message, []byte(err.Error()))
}

// Core article operations (same as before but using the real-time service's KV store)
func (s *RealtimeArticlesService) getArticle(id uuid.UUID) (Article, error) {
	entry, err := s.kv.Get(context.Background(), id.String())
	if err != nil {
		return Article{}, core.NewServiceError(core.ErrorCodeNotFound, "articles", "get",
			"article not found").WithCause(err)
	}

	var article Article
	if err := json.Unmarshal(entry.Value(), &article); err != nil {
		return Article{}, core.NewServiceError(core.ErrorCodeInternalError, "articles", "get",
			"failed to unmarshal article").WithCause(err)
	}

	article.Rev = entry.Revision()
	return article, nil
}

func (s *RealtimeArticlesService) getArticleBySlug(slug string) (Article, error) {
	keys, err := s.kv.ListKeys(context.Background())
	if err != nil {
		return Article{}, core.NewServiceError(core.ErrorCodeInternalError, "articles", "get_by_slug",
			"failed to list keys").WithCause(err)
	}

	for key := range keys.Keys() {
		entry, err := s.kv.Get(context.Background(), key)
		if err != nil {
			continue
		}

		var article Article
		if err := json.Unmarshal(entry.Value(), &article); err != nil {
			continue
		}

		if article.Slug == slug {
			article.Rev = entry.Revision()
			return article, nil
		}
	}

	return Article{}, core.NewServiceError(core.ErrorCodeNotFound, "articles", "get_by_slug",
		fmt.Sprintf("article with slug %s not found", slug))
}

func (s *RealtimeArticlesService) listArticles(limit, offset int) ([]Article, error) {
	keys, err := s.kv.ListKeys(context.Background())
	if err != nil {
		return nil, core.NewServiceError(core.ErrorCodeInternalError, "articles", "list",
			"failed to list keys").WithCause(err)
	}

	var articles []Article
	count := 0
	skipped := 0

	for key := range keys.Keys() {
		if offset > 0 && skipped < offset {
			skipped++
			continue
		}

		if limit > 0 && count >= limit {
			break
		}

		entry, err := s.kv.Get(context.Background(), key)
		if err != nil {
			continue
		}

		var article Article
		if err := json.Unmarshal(entry.Value(), &article); err != nil {
			continue
		}

		// Create metadata-only version (no content)
		metadataArticle := Article{
			StructVersion: article.StructVersion,
			Id:            article.Id,
			Author:        article.Author,
			PublishedAt:   article.PublishedAt,
			Tags:          article.Tags,
			Rev:           entry.Revision(),
			Slug:          article.Slug,
			Title:         article.Title,
			Subtitle:      article.Subtitle,
			Leading:       article.Leading,
			// Content is omitted for list view
		}

		articles = append(articles, metadataArticle)
		count++
	}

	return articles, nil
}

func (s *RealtimeArticlesService) createArticle(article Article) (Article, error) {
	article.Rev = 1
	data, err := json.Marshal(article)
	if err != nil {
		return Article{}, core.NewServiceError(core.ErrorCodeInternalError, "articles", "create",
			"failed to marshal article").WithCause(err)
	}

	rev, err := s.kv.Create(context.Background(), article.Id.String(), data)
	if err != nil {
		return Article{}, core.NewServiceError(core.ErrorCodeInternalError, "articles", "create",
			"failed to create article").WithCause(err)
	}

	article.Rev = rev
	return article, nil
}

func (s *RealtimeArticlesService) updateArticle(article Article) (Article, error) {
	article.Rev++
	data, err := json.Marshal(article)
	if err != nil {
		return Article{}, core.NewServiceError(core.ErrorCodeInternalError, "articles", "update",
			"failed to marshal article").WithCause(err)
	}

	rev, err := s.kv.Put(context.Background(), article.Id.String(), data)
	if err != nil {
		return Article{}, core.NewServiceError(core.ErrorCodeInternalError, "articles", "update",
			"failed to update article").WithCause(err)
	}

	article.Rev = rev
	return article, nil
}

func (s *RealtimeArticlesService) deleteArticle(id uuid.UUID) error {
	if err := s.kv.Delete(context.Background(), id.String()); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "delete",
			"failed to delete article").WithCause(err)
	}
	return nil
}

func (s *RealtimeArticlesService) getArticleRevisions(id uuid.UUID) ([]Article, error) {
	history, err := s.kv.History(context.Background(), id.String())
	if err != nil {
		return nil, core.NewServiceError(core.ErrorCodeInternalError, "articles", "revisions",
			"failed to get article history").WithCause(err)
	}

	var revisions []Article
	for _, entry := range history {
		if entry.Operation() == jetstream.KeyValuePut {
			var article Article
			if err := json.Unmarshal(entry.Value(), &article); err != nil {
				continue
			}
			article.Rev = entry.Revision()
			revisions = append(revisions, article)
		}
	}

	// Reverse to show newest first
	for i, j := 0, len(revisions)-1; i < j; i, j = i+1, j-1 {
		revisions[i], revisions[j] = revisions[j], revisions[i]
	}

	return revisions, nil
}
