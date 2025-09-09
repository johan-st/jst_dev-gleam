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

// ArticlesService implements the core.Service interface for articles
type ArticlesService struct {
	*core.BaseService
	kv jetstream.KeyValue
}

// NewArticlesService creates a new articles service
func NewArticlesService(config core.ServiceConfig) (core.Service, error) {
	base := core.NewBaseService("articles", []string{}, config)

	service := &ArticlesService{
		BaseService: base,
	}

	// Build the service with custom implementations
	return core.NewServiceBuilder("articles", config).
		WithInitializer(service.initialize).
		WithRunner(service.run).
		WithShutdowner(service.shutdown).
		WithHealthChecker(service.health).
		Build(), nil
}

// initialize sets up the JetStream KV store
func (s *ArticlesService) initialize(ctx context.Context) error {
	if err := s.BaseService.Initialize(ctx); err != nil {
		return err
	}

	js, err := jetstream.New(s.GetNatsConn())
	if err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "initialize",
			"failed to get JetStream context").WithCause(err)
	}

	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "article",
		Description:  "articles in json format",
		MaxValueSize: 1024 * 1024 * 5,  // 5 MB
		MaxBytes:     1024 * 1024 * 50, // 50 MB
		History:      64,
		Storage:      jetstream.FileStorage,
		Compression:  true,
	})
	if err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "initialize",
			"failed to create KV store").WithCause(err)
	}

	s.kv = kv
	s.GetLogger().Info("articles service initialized")

	return nil
}

// run starts the articles microservice
func (s *ArticlesService) run(ctx context.Context) error {
	svcMetadata := map[string]string{
		"location":    "unknown",
		"environment": "development",
	}

	// Create microservice
	articlesSvc, err := micro.AddService(s.GetNatsConn(), micro.Config{
		Name:        "articles",
		Version:     "1.0.0",
		Description: "articles management service",
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

	s.GetLogger().Info("articles service started")

	// Wait for context cancellation
	<-ctx.Done()

	// Cleanup
	s.GetLogger().Info("articles service stopping...")
	if err := articlesSvc.Stop(); err != nil {
		s.GetLogger().Error("failed to stop articles service: %v", err)
	}

	s.GetLogger().Info("articles service stopped")
	return nil
}

// shutdown performs cleanup
func (s *ArticlesService) shutdown(ctx context.Context) error {
	return s.BaseService.Shutdown(ctx)
}

// health performs health check
func (s *ArticlesService) health() error {
	if err := s.BaseService.Health(); err != nil {
		return err
	}

	// Additional health checks specific to articles service
	if s.kv == nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "health",
			"KV store not initialized")
	}

	return nil
}

// Request/Response types for the microservice API
type GetArticleRequest struct {
	ID string `json:"id"`
}

type GetArticleBySlugRequest struct {
	Slug string `json:"slug"`
}

type ListArticlesRequest struct {
	Limit  int `json:"limit,omitempty"`
	Offset int `json:"offset,omitempty"`
}

type CreateArticleRequest struct {
	Title    string   `json:"title"`
	Subtitle string   `json:"subtitle,omitempty"`
	Leading  string   `json:"leading,omitempty"`
	Content  string   `json:"content"`
	Tags     []string `json:"tags,omitempty"`
	Author   string   `json:"author"`
}

type UpdateArticleRequest struct {
	ID       string   `json:"id"`
	Title    string   `json:"title,omitempty"`
	Subtitle string   `json:"subtitle,omitempty"`
	Leading  string   `json:"leading,omitempty"`
	Content  string   `json:"content,omitempty"`
	Tags     []string `json:"tags,omitempty"`
	Rev      uint64   `json:"rev"`
}

type DeleteArticleRequest struct {
	ID string `json:"id"`
}

type GetRevisionsRequest struct {
	ID string `json:"id"`
}

type ArticleResponse struct {
	Article *Article `json:"article,omitempty"`
	Error   string   `json:"error,omitempty"`
}

type ListArticlesResponse struct {
	Articles []Article `json:"articles"`
	Total    int       `json:"total"`
	Error    string    `json:"error,omitempty"`
}

type RevisionsResponse struct {
	Revisions []Article `json:"revisions"`
	Error     string    `json:"error,omitempty"`
}

// Microservice handlers
func (s *ArticlesService) handleGet() micro.HandlerFunc {
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

		article, err := s.getArticle(id)
		if err != nil {
			s.respondError(req, "failed to get article", err)
			return
		}

		s.respondSuccess(req, ArticleResponse{Article: &article})
	}
}

func (s *ArticlesService) handleGetBySlug() micro.HandlerFunc {
	return func(req micro.Request) {
		var request GetArticleBySlugRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		article, err := s.getArticleBySlug(request.Slug)
		if err != nil {
			s.respondError(req, "failed to get article by slug", err)
			return
		}

		s.respondSuccess(req, ArticleResponse{Article: &article})
	}
}

func (s *ArticlesService) handleList() micro.HandlerFunc {
	return func(req micro.Request) {
		var request ListArticlesRequest
		if err := json.Unmarshal(req.Data(), &request); err != nil {
			s.respondError(req, "invalid request", err)
			return
		}

		articles, err := s.listArticles(request.Limit, request.Offset)
		if err != nil {
			s.respondError(req, "failed to list articles", err)
			return
		}

		s.respondSuccess(req, ListArticlesResponse{
			Articles: articles,
			Total:    len(articles),
		})
	}
}

func (s *ArticlesService) handleCreate() micro.HandlerFunc {
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

		s.respondSuccess(req, ArticleResponse{Article: &createdArticle})
	}
}

func (s *ArticlesService) handleUpdate() micro.HandlerFunc {
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

		s.respondSuccess(req, ArticleResponse{Article: &updatedArticle})
	}
}

func (s *ArticlesService) handleDelete() micro.HandlerFunc {
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

		if err := s.deleteArticle(id); err != nil {
			s.respondError(req, "failed to delete article", err)
			return
		}

		s.respondSuccess(req, map[string]string{"status": "deleted"})
	}
}

func (s *ArticlesService) handleRevisions() micro.HandlerFunc {
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

// Helper methods for microservice responses
func (s *ArticlesService) respondSuccess(req micro.Request, data interface{}) {
	response, err := json.Marshal(data)
	if err != nil {
		s.GetLogger().Error("failed to marshal response: %v", err)
		req.Error("INTERNAL_ERROR", "failed to marshal response", []byte(err.Error()))
		return
	}
	req.Respond(response)
}

func (s *ArticlesService) respondError(req micro.Request, message string, err error) {
	s.GetLogger().Error("%s: %v", message, err)
	req.Error("INTERNAL_ERROR", message, []byte(err.Error()))
}

// Core article operations (adapted from existing articles.go)
func (s *ArticlesService) getArticle(id uuid.UUID) (Article, error) {
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

func (s *ArticlesService) getArticleBySlug(slug string) (Article, error) {
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

func (s *ArticlesService) listArticles(limit, offset int) ([]Article, error) {
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

func (s *ArticlesService) createArticle(article Article) (Article, error) {
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

func (s *ArticlesService) updateArticle(article Article) (Article, error) {
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

func (s *ArticlesService) deleteArticle(id uuid.UUID) error {
	if err := s.kv.Delete(context.Background(), id.String()); err != nil {
		return core.NewServiceError(core.ErrorCodeInternalError, "articles", "delete",
			"failed to delete article").WithCause(err)
	}
	return nil
}

func (s *ArticlesService) getArticleRevisions(id uuid.UUID) ([]Article, error) {
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
