package articles

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"

	"github.com/google/uuid"
)

// ArticleRepository provides a local-like interface to articles with KV synchronization
type ArticleRepository struct {
	*core.GenericRepository[Article]
	slugIndex map[string]string // slug -> id mapping
	slugMu    sync.RWMutex
}

// NewArticleRepository creates a new article repository
func NewArticleRepository(realtimeManager *core.RealtimeManager, logger *jst_log.Logger) (*ArticleRepository, error) {
	// Create repository configuration
	config := core.RepositoryConfig{
		KVStoreName: "articles",
		CacheConfig: core.CacheConfig{
			DefaultTTL: 5 * time.Minute,
			MaxSize:    1000,
		},
		SyncConfig: core.SyncConfig{
			BatchSize: 100,
		},
		Logger: logger,
	}

	// Get KV store
	kvStore, err := realtimeManager.GetKVStore("articles")
	if err != nil {
		return nil, fmt.Errorf("failed to get articles KV store: %w", err)
	}

	// Create generic repository
	baseRepo := core.NewGenericRepository[Article](
		kvStore,
		config,
		unmarshalArticle,
		marshalArticle,
	)

	repo := &ArticleRepository{
		GenericRepository: baseRepo,
		slugIndex:         make(map[string]string),
	}

	// Start the repository
	if err := repo.Start(); err != nil {
		return nil, fmt.Errorf("failed to start repository: %w", err)
	}

	// Build slug index
	repo.buildSlugIndex()

	// Watch for changes to update slug index
	repo.OnTypedEvent("created", repo.handleArticleCreated)
	repo.OnTypedEvent("updated", repo.handleArticleUpdated)
	repo.OnTypedEvent("deleted", repo.handleArticleDeleted)

	return repo, nil
}

// GetBySlug retrieves an article by its slug
func (ar *ArticleRepository) GetBySlug(slug string) (Article, bool) {
	ar.slugMu.RLock()
	id, exists := ar.slugIndex[slug]
	ar.slugMu.RUnlock()

	if !exists {
		var zero Article
		return zero, false
	}

	return ar.GetTyped(id)
}

// GetByID retrieves an article by its ID
func (ar *ArticleRepository) GetByID(id uuid.UUID) (Article, bool) {
	return ar.GetTyped(id.String())
}

// Create creates a new article
func (ar *ArticleRepository) Create(article Article) (Article, error) {
	// Generate ID if not provided
	if article.Id == uuid.Nil {
		article.Id = uuid.New()
	}

	// Generate slug if not provided
	if article.Slug == "" {
		article.Slug = generateSlug(article.Title)
	}

	// Ensure slug is unique
	article.Slug = ar.ensureUniqueSlug(article.Slug)

	// Set timestamps
	now := time.Now()
	article.PublishedAt = int(now.UnixMilli())
	article.Rev = 1

	// Store in repository
	if err := ar.SetTyped(article.Id.String(), article); err != nil {
		return Article{}, fmt.Errorf("failed to create article: %w", err)
	}

	return article, nil
}

// Update updates an existing article
func (ar *ArticleRepository) Update(article Article) (Article, error) {
	// Get existing article to check revision
	existing, exists := ar.GetByID(article.Id)
	if !exists {
		return Article{}, fmt.Errorf("article not found")
	}

	// Update revision
	article.Rev = existing.Rev + 1

	// Update slug if changed
	if article.Slug != existing.Slug {
		// Remove old slug from index
		ar.slugMu.Lock()
		delete(ar.slugIndex, existing.Slug)
		ar.slugMu.Unlock()

		// Ensure new slug is unique
		article.Slug = ar.ensureUniqueSlug(article.Slug)
	}

	// Store updated article
	if err := ar.SetTyped(article.Id.String(), article); err != nil {
		return Article{}, fmt.Errorf("failed to update article: %w", err)
	}

	return article, nil
}

// Delete deletes an article
func (ar *ArticleRepository) Delete(id uuid.UUID) error {
	// Get article to remove from slug index
	if article, exists := ar.GetByID(id); exists {
		ar.slugMu.Lock()
		delete(ar.slugIndex, article.Slug)
		ar.slugMu.Unlock()
	}

	// Delete from repository
	return ar.GenericRepository.Delete(id.String())
}

// List returns all articles with optional pagination
func (ar *ArticleRepository) List(limit, offset int) ([]Article, error) {
	allArticles := ar.ListTyped()

	// Convert to slice and sort by published date
	articles := make([]Article, 0, len(allArticles))
	for _, article := range allArticles {
		articles = append(articles, article)
	}

	// Sort by published date (newest first)
	sort.Slice(articles, func(i, j int) bool {
		return articles[i].PublishedAt > articles[j].PublishedAt
	})

	// Apply pagination
	if offset > 0 && offset < len(articles) {
		articles = articles[offset:]
	}
	if limit > 0 && limit < len(articles) {
		articles = articles[:limit]
	}

	return articles, nil
}

// Search searches articles by title, content, or tags
func (ar *ArticleRepository) Search(query string) ([]Article, error) {
	allArticles := ar.ListTyped()
	var results []Article

	query = strings.ToLower(query)

	for _, article := range allArticles {
		// Search in title
		if strings.Contains(strings.ToLower(article.Title), query) {
			results = append(results, article)
			continue
		}

		// Search in subtitle
		if strings.Contains(strings.ToLower(article.Subtitle), query) {
			results = append(results, article)
			continue
		}

		// Search in leading
		if strings.Contains(strings.ToLower(article.Leading), query) {
			results = append(results, article)
			continue
		}

		// Search in content
		if strings.Contains(strings.ToLower(article.Content), query) {
			results = append(results, article)
			continue
		}

		// Search in tags
		for _, tag := range article.Tags {
			if strings.Contains(strings.ToLower(tag), query) {
				results = append(results, article)
				break
			}
		}
	}

	return results, nil
}

// GetByAuthor returns articles by a specific author
func (ar *ArticleRepository) GetByAuthor(author string) ([]Article, error) {
	allArticles := ar.ListTyped()
	var results []Article

	for _, article := range allArticles {
		if article.Author == author {
			results = append(results, article)
		}
	}

	// Sort by published date
	sort.Slice(results, func(i, j int) bool {
		return results[i].PublishedAt > results[j].PublishedAt
	})

	return results, nil
}

// GetByTag returns articles with a specific tag
func (ar *ArticleRepository) GetByTag(tag string) ([]Article, error) {
	allArticles := ar.ListTyped()
	var results []Article

	for _, article := range allArticles {
		for _, articleTag := range article.Tags {
			if articleTag == tag {
				results = append(results, article)
				break
			}
		}
	}

	// Sort by published date
	sort.Slice(results, func(i, j int) bool {
		return results[i].PublishedAt > results[j].PublishedAt
	})

	return results, nil
}

// GetRevisions returns all revisions of an article
func (ar *ArticleRepository) GetRevisions(id uuid.UUID) ([]Article, error) {
	// This would need to be implemented with KV history
	// For now, return the current version
	article, exists := ar.GetByID(id)
	if !exists {
		return nil, fmt.Errorf("article not found")
	}

	return []Article{article}, nil
}

// buildSlugIndex builds the slug to ID mapping
func (ar *ArticleRepository) buildSlugIndex() {
	ar.slugMu.Lock()
	defer ar.slugMu.Unlock()

	ar.slugIndex = make(map[string]string)

	allArticles := ar.ListTyped()
	for _, article := range allArticles {
		ar.slugIndex[article.Slug] = article.Id.String()
	}
}

// ensureUniqueSlug ensures the slug is unique
func (ar *ArticleRepository) ensureUniqueSlug(slug string) string {
	ar.slugMu.RLock()
	_, exists := ar.slugIndex[slug]
	ar.slugMu.RUnlock()

	if !exists {
		return slug
	}

	// Add timestamp to make it unique
	return fmt.Sprintf("%s-%d", slug, time.Now().Unix())
}

// handleArticleCreated handles article creation events
func (ar *ArticleRepository) handleArticleCreated(key string, oldArticle, newArticle Article) {
	ar.slugMu.Lock()
	ar.slugIndex[newArticle.Slug] = newArticle.Id.String()
	ar.slugMu.Unlock()
}

// handleArticleUpdated handles article update events
func (ar *ArticleRepository) handleArticleUpdated(key string, oldArticle, newArticle Article) {
	ar.slugMu.Lock()

	// Remove old slug if it changed
	if oldArticle.Slug != newArticle.Slug {
		delete(ar.slugIndex, oldArticle.Slug)
	}

	// Add new slug
	ar.slugIndex[newArticle.Slug] = newArticle.Id.String()

	ar.slugMu.Unlock()
}

// handleArticleDeleted handles article deletion events
func (ar *ArticleRepository) handleArticleDeleted(key string, oldArticle, newArticle Article) {
	ar.slugMu.Lock()
	delete(ar.slugIndex, oldArticle.Slug)
	ar.slugMu.Unlock()
}

// generateSlug generates a URL-friendly slug from a title
func generateSlug(title string) string {
	// Simple slug generation - in production you'd want more sophisticated logic
	slug := strings.ToLower(title)
	slug = strings.ReplaceAll(slug, " ", "-")
	slug = strings.ReplaceAll(slug, "_", "-")

	// Remove special characters
	var result strings.Builder
	for _, char := range slug {
		if (char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || char == '-' {
			result.WriteRune(char)
		}
	}

	return result.String()
}

// marshalArticle marshals an article to JSON
func marshalArticle(article Article) ([]byte, error) {
	return json.Marshal(article)
}

// unmarshalArticle unmarshals JSON to an article
func unmarshalArticle(data []byte) (Article, error) {
	var article Article
	err := json.Unmarshal(data, &article)
	return article, err
}

// RepositoryService integrates the article repository with real-time service
type ArticleRepositoryService struct {
	*core.RepositoryService
	articleRepo *ArticleRepository
}

// NewArticleRepositoryService creates a new article repository service
func NewArticleRepositoryService(
	realtimeManager *core.RealtimeManager,
	logger *jst_log.Logger,
) (*ArticleRepositoryService, error) {
	// Create repository
	articleRepo, err := NewArticleRepository(realtimeManager, logger)
	if err != nil {
		return nil, fmt.Errorf("failed to create article repository: %w", err)
	}

	// Create base repository service
	baseService, err := core.NewRepositoryService(
		"articles",
		[]string{},
		core.RealtimeServiceConfig{
		ServiceConfig: core.ServiceConfig{
			Logger:   logger,
			NatsConn: realtimeManager.GetNatsConn(),
			Timeout:  30 * time.Second,
		},
			RealtimeManager: realtimeManager,
			KVStoreName:     "articles",
			Subjects: map[string]string{
				"created": "articles.created",
				"updated": "articles.updated",
				"deleted": "articles.deleted",
			},
			Patterns: []string{"articles.*"},
		},
		core.RepositoryConfig{
			KVStoreName: "articles",
			CacheConfig: core.CacheConfig{
				DefaultTTL: 5 * time.Minute,
				MaxSize:    1000,
			},
			SyncConfig: core.SyncConfig{
				BatchSize: 100,
			},
			Logger: logger,
		},
	)
	if err != nil {
		return nil, fmt.Errorf("failed to create repository service: %w", err)
	}

	return &ArticleRepositoryService{
		RepositoryService: baseService,
		articleRepo:       articleRepo,
	}, nil
}

// GetArticleRepository returns the article repository
func (ars *ArticleRepositoryService) GetArticleRepository() *ArticleRepository {
	return ars.articleRepo
}

// Shutdown stops the service and repository
func (ars *ArticleRepositoryService) Shutdown(ctx context.Context) error {
	// Stop article repository
	if err := ars.articleRepo.Stop(); err != nil {
		ars.GetLogger().Error("failed to stop article repository: %v", err)
	}

	// Stop base service
	return ars.RepositoryService.Shutdown(ctx)
}
