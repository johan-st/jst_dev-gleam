package urlShort

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"
	"jst_dev/server/urlShort/api"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/micro"
)

const ShortUrlKey = "shorturl_url"

type ShortUrlService struct {
	shortUrlRepo core.Repo[ShortUrlRepoKey, ShortUrlRepoValue]
	l            *jst_log.Logger
	nc           *nats.Conn
	ctx          context.Context
}

type ShortUrl struct {
	api.ShortUrl
	revision uint64
}

// Helper functions to convert between old and new data types
func shortUrlToRepoValue(su ShortUrl) ShortUrlRepoValue {
	return ShortUrlRepoValue{
		ShortUrl: su.ShortUrl,
		Revision: su.revision,
	}
}

func repoValueToShortUrl(rv ShortUrlRepoValue) ShortUrl {
	return ShortUrl{
		ShortUrl: rv.ShortUrl,
		revision: rv.Revision,
	}
}

type Conf struct {
	NatsConn *nats.Conn
	Logger   *jst_log.Logger
}

// New creates a new ShortUrlService instance with the provided configuration.
func New(ctx context.Context, c *Conf) (*ShortUrlService, error) {
	// Initialize short URL repository
	shortUrlRepo, err := NewShortUrlRepo(ctx, c.NatsConn, c.Logger)
	if err != nil {
		return nil, fmt.Errorf("failed to create short URL repo: %w", err)
	}

	service := &ShortUrlService{
		shortUrlRepo: shortUrlRepo,
		l:            c.Logger,
		nc:           c.NatsConn,
		ctx:          ctx,
	}

	return service, nil
}

// Run implements the service.Service interface
// The service runs until the context is cancelled, then performs cleanup
func (s *ShortUrlService) Run(ctx context.Context) error {
	if s.nc.Status() != nats.CONNECTED {
		return fmt.Errorf("nats connection not connected: %s", s.nc.Status())
	}

	// Short URL repository is already initialized in New()

	svcMetadata := map[string]string{}
	svcMetadata["location"] = "unknown"
	svcMetadata["environment"] = "development"
	shortUrlSvc, err := micro.AddService(s.nc, micro.Config{
		Name:        "shorturl",
		Version:     "1.0.0",
		Description: "short url service",
		Metadata:    svcMetadata,
	})
	if err != nil {
		return fmt.Errorf("add service: %w", err)
	}

	// ----------- Short URLs -----------
	shortUrlSvcGroup := shortUrlSvc.AddGroup(api.Subj.ShortUrlGroup, micro.WithGroupQueueGroup(api.Subj.ShortUrlGroup))
	if err = shortUrlSvcGroup.AddEndpoint("shorturl_create", s.handleShortUrlCreate(), micro.WithEndpointSubject(api.Subj.ShortUrlCreate)); err != nil {
		return fmt.Errorf("add shorturl endpoint (shorturl_create): %w", err)
	}
	if err = shortUrlSvcGroup.AddEndpoint("shorturl_get", s.handleShortUrlGet(), micro.WithEndpointSubject(api.Subj.ShortUrlGet)); err != nil {
		return fmt.Errorf("add shorturl endpoint (shorturl_get): %w", err)
	}
	if err = shortUrlSvcGroup.AddEndpoint("shorturl_update", s.handleShortUrlUpdate(), micro.WithEndpointSubject(api.Subj.ShortUrlUpdate)); err != nil {
		return fmt.Errorf("add shorturl endpoint (shorturl_update): %w", err)
	}
	if err = shortUrlSvcGroup.AddEndpoint("shorturl_delete", s.handleShortUrlDelete(), micro.WithEndpointSubject(api.Subj.ShortUrlDelete)); err != nil {
		return fmt.Errorf("add shorturl endpoint (shorturl_delete): %w", err)
	}
	if err = shortUrlSvcGroup.AddEndpoint("shorturl_list", s.handleShortUrlList(), micro.WithEndpointSubject(api.Subj.ShortUrlList)); err != nil {
		return fmt.Errorf("add shorturl endpoint (shorturl_list): %w", err)
	}
	if err = shortUrlSvcGroup.AddEndpoint("shorturl_access", s.handleShortUrlAccess(), micro.WithEndpointSubject(api.Subj.ShortUrlAccess)); err != nil {
		return fmt.Errorf("add shorturl endpoint (shorturl_access): %w", err)
	}

	s.l.Info("short url service started")

	// Wait for context cancellation
	<-ctx.Done()

	// Cleanup
	s.l.Info("short url service stopping...")
	if err := shortUrlSvc.Stop(); err != nil {
		s.l.Error("failed to stop short url service: %v", err)
	}

	s.l.Info("short url service stopped")
	return nil
}

// Name returns the service name for identification
func (s *ShortUrlService) Name() string {
	return "shorturl"
}

// ----------- WATCHERS -----------

// shortUrlWatcher removed - repository handles watching automatically

// ----------- HANDLERS -----------

func (s *ShortUrlService) handleShortUrlCreate() micro.HandlerFunc {
	l := s.l.WithBreadcrumb("shorturl_create")
	return func(req micro.Request) {
		var (
			err      error
			shortUrl *ShortUrl
			reqData  api.ShortUrlCreateRequest
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal short url create request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url create request: %v", err)
			}
			return
		}
		if reqData.ShortCode == "" {
			l.Debug("short code is empty, generating one")
			reqData.ShortCode, err = s.generateUniqueShortCode()
			if err != nil {
				l.Error("failed to generate unique short code: %s", err.Error())
				if err := req.Error("SERVER_ERROR", "unable to generate unique short code", []byte(err.Error())); err != nil {
					l.Error("failed to respond to short url create request: %v", err)
				}
				return
			}
			l.Debug("generated short code: %s", reqData.ShortCode)
		}
		if reqData.TargetURL == "" {
			l.Warn("target URL is empty")
			if err := req.Error("INVALID_REQUEST", "target URL is empty", []byte("target URL is empty")); err != nil {
				l.Error("failed to respond to short url create request: %v", err)
			}
			return
		}
		// Note: CreatedBy is now optional - will be handled by the web layer

		// Check if short code already exists
		existing := s.shortUrlByShortCode(reqData.ShortCode)
		if existing != nil {
			l.Warn("short code already exists")
			if err := req.Error("SHORT_CODE_TAKEN", "a short url with this code already exists", []byte(reqData.ShortCode)); err != nil {
				l.Error("failed to respond to short url create request: %v", err)
			}
			return
		}

		shortUrl, err = s.shortUrlCreate(reqData.ShortCode, reqData.TargetURL, reqData.CreatedBy)
		if err != nil {
			l.Error(fmt.Sprintf("failed to create short url: %s", err.Error()))
			if err := req.Error("SERVER_ERROR", "server error", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url create request: %v", err)
			}
			return
		}

		if err := req.RespondJSON(shortUrl.ShortUrl); err != nil {
			l.Error("failed to respond to short url create request: %v", err)
		}
	}
}

func (s *ShortUrlService) handleShortUrlGet() micro.HandlerFunc {
	l := s.l.WithBreadcrumb("shorturl_get")

	return func(req micro.Request) {
		var (
			reqData  api.ShortUrlGetRequest
			err      error
			shortUrl *ShortUrl
		)
		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal short url get request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url get request: %v", err)
			}
			return
		}
		if reqData.ID == "" && reqData.ShortCode == "" {
			l.Warn("no id or short code provided")
			if err := req.Error("INVALID_REQUEST", "no id or short code provided", []byte("no id or short code provided")); err != nil {
				l.Error("failed to respond to short url get request: %v", err)
			}
			return
		}
		if reqData.ID != "" {
			shortUrl = s.shortUrlGet(reqData.ID)
			if shortUrl == nil {
				l.Warn(fmt.Sprintf("short url not found: %s", reqData.ID))
				if err := req.Error("NOT_FOUND", "short url not found", []byte(reqData.ID)); err != nil {
					l.Error("failed to respond to short url get request: %v", err)
				}
				return
			}
		} else if reqData.ShortCode != "" {
			shortUrl = s.shortUrlByShortCode(reqData.ShortCode)
			if shortUrl == nil {
				l.Warn(fmt.Sprintf("short url not found: %s", reqData.ShortCode))
				if err := req.Error("NOT_FOUND", "short url not found", []byte(reqData.ShortCode)); err != nil {
					l.Error("failed to respond to short url get request: %v", err)
				}
				return
			}
		}

		if err := req.RespondJSON(shortUrl.ShortUrl); err != nil {
			l.Error("failed to respond to short url get request: %v", err)
		}
	}
}

func (s *ShortUrlService) handleShortUrlUpdate() micro.HandlerFunc {
	l := s.l.WithBreadcrumb("shorturl_update")
	return func(req micro.Request) {
		var (
			err      error
			shortUrl *ShortUrl
			reqData  api.ShortUrlUpdateRequest
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal short url update request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url update request: %v", err)
			}
			return
		}
		shortUrl = s.shortUrlGet(reqData.ID)
		if shortUrl == nil {
			l.Warn(fmt.Sprintf("short url not found: %s", reqData.ID))
			if err := req.Error("NOT_FOUND", "short url not found", []byte(reqData.ID)); err != nil {
				l.Error("failed to respond to short url update request: %v", err)
			}
			return
		}

		// Update fields if provided
		if reqData.ShortCode != "" {
			// Check if new short code already exists
			existing := s.shortUrlByShortCode(reqData.ShortCode)
			if existing != nil && existing.ID != shortUrl.ID {
				l.Warn("short code already exists")
				if err := req.Error("SHORT_CODE_TAKEN", "a short url with this code already exists", []byte(reqData.ShortCode)); err != nil {
					l.Error("failed to respond to short url update request: %v", err)
				}
				return
			}
			shortUrl.ShortCode = reqData.ShortCode
		}
		if reqData.TargetURL != "" {
			shortUrl.TargetURL = reqData.TargetURL
		}
		if reqData.IsActive != nil {
			shortUrl.IsActive = *reqData.IsActive
		}
		shortUrl.UpdatedAt = time.Now().Unix()

		// Convert to repo value and update
		shortUrlRepoValue := shortUrlToRepoValue(*shortUrl)
		key := ShortUrlRepoKey{ID: shortUrl.ID}
		err = s.shortUrlRepo.Put(key, shortUrlRepoValue)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to update short url: %s", err.Error()))
			if err := req.Error("SERVER_ERROR", "server error while updating short url", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url update request: %v", err)
			}
			return
		}
		if err := req.RespondJSON(shortUrl.ShortUrl); err != nil {
			l.Error("failed to respond to short url update request: %v", err)
		}
	}
}

func (s *ShortUrlService) handleShortUrlDelete() micro.HandlerFunc {
	l := s.l.WithBreadcrumb("shorturl_delete")
	return func(req micro.Request) {
		var (
			err      error
			shortUrl *ShortUrl
			reqData  api.ShortUrlDeleteRequest
			respData api.ShortUrlDeleteResponse
		)
		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal short url delete request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url delete request: %v", err)
			}
			return
		}
		shortUrl = s.shortUrlGet(reqData.ID)
		if shortUrl == nil {
			l.Warn(fmt.Sprintf("short url not found: %s", reqData.ID))
			if err := req.Error("NOT_FOUND", "short url not found and could thus not be deleted", []byte(reqData.ID)); err != nil {
				l.Error("failed to respond to short url delete request: %v", err)
			}
			return
		}
		key := ShortUrlRepoKey{ID: shortUrl.ID}
		err = s.shortUrlRepo.Delete(key)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to delete short url: %s", err.Error()))
			if err := req.Error("SERVER_ERROR", "server error while deleting short url", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url delete request: %v", err)
			}
			return
		}
		respData = api.ShortUrlDeleteResponse{
			IDDeleted: shortUrl.ID,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to short url delete request: %v", err)
		}
	}
}

func (s *ShortUrlService) handleShortUrlList() micro.HandlerFunc {
	l := s.l.WithBreadcrumb("shorturl_list")
	return func(req micro.Request) {
		var (
			reqData  api.ShortUrlListRequest
			respData api.ShortUrlListResponse
			err      error
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal short url list request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url list request: %v", err)
			}
			return
		}

		// Set defaults
		if reqData.Limit <= 0 {
			reqData.Limit = 50
		}
		if reqData.Offset < 0 {
			reqData.Offset = 0
		}

		// Filter short urls
		filtered := s.filterShortUrls(reqData.CreatedBy)
		total := len(filtered)

		// Apply pagination
		end := reqData.Offset + reqData.Limit
		if end > len(filtered) {
			end = len(filtered)
		}
		if reqData.Offset >= len(filtered) {
			filtered = []ShortUrl{}
		} else {
			filtered = filtered[reqData.Offset:end]
		}

		// Convert to API types
		apiShortUrls := make([]api.ShortUrl, len(filtered))
		for i, shortUrl := range filtered {
			apiShortUrls[i] = shortUrl.ShortUrl
		}

		respData = api.ShortUrlListResponse{
			ShortUrls: apiShortUrls,
			Total:     total,
			Limit:     reqData.Limit,
			Offset:    reqData.Offset,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to short url list request: %v", err)
		}
	}
}

func (s *ShortUrlService) handleShortUrlAccess() micro.HandlerFunc {
	l := s.l.WithBreadcrumb("shorturl_access")
	return func(req micro.Request) {
		var (
			err      error
			reqData  api.ShortUrlAccessRequest
			respData api.ShortUrlAccessResponse
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal short url access request: %s", err.Error()))
			if err := req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error())); err != nil {
				l.Error("failed to respond to short url access request: %v", err)
			}
			return
		}
		if reqData.ShortCode == "" {
			l.Warn("short code is empty")
			if err := req.Error("INVALID_REQUEST", "short code is empty", []byte("short code is empty")); err != nil {
				l.Error("failed to respond to short url access request: %v", err)
			}
			return
		}

		// Get short URL
		shortUrl := s.shortUrlByShortCode(reqData.ShortCode)
		if shortUrl == nil {
			l.Warn(fmt.Sprintf("short url not found: %s", reqData.ShortCode))
			if err := req.Error("NOT_FOUND", "short url not found", []byte(reqData.ShortCode)); err != nil {
				l.Error("failed to respond to short url access request: %v", err)
			}
			return
		}

		// Check if short URL is active
		if !shortUrl.IsActive {
			l.Warn(fmt.Sprintf("short url is inactive: %s", reqData.ShortCode))
			if err := req.Error("GONE", "short url is inactive", []byte(reqData.ShortCode)); err != nil {
				l.Error("failed to respond to short url access request: %v", err)
			}
			return
		}

		// Increment access count
		err = s.IncrementAccessCount(reqData.ShortCode)
		if err != nil {
			l.Error(fmt.Sprintf("failed to increment access count: %s", err.Error()))
			// Don't fail the request, just log the error
		}

		respData = api.ShortUrlAccessResponse{
			TargetURL: shortUrl.TargetURL,
			Redirect:  true,
		}
		if err := req.RespondJSON(respData); err != nil {
			l.Error("failed to respond to short url access request: %v", err)
		}
	}
}

// ----------- Helper Functions -----------

func (s *ShortUrlService) shortUrlCreate(shortCode, targetURL, createdBy string) (*ShortUrl, error) {
	var (
		err               error
		shortUrlRepoValue ShortUrlRepoValue
	)

	if shortCode == "" || targetURL == "" {
		return nil, fmt.Errorf("short code and target URL are required")
	}

	// Normalize short code
	shortCode = strings.ToLower(strings.TrimSpace(shortCode))

	nowUnix := time.Now().Unix()
	shortUrlRepoValue = ShortUrlRepoValue{
		ShortUrl: api.ShortUrl{
			ID:          uuid.New().String(),
			ShortCode:   shortCode,
			TargetURL:   targetURL,
			CreatedBy:   createdBy,
			CreatedAt:   nowUnix,
			UpdatedAt:   nowUnix,
			AccessCount: 0,
			IsActive:    true,
		},
		Revision: 0, // Will be set by the repo
	}

	key := ShortUrlRepoKey{ID: shortUrlRepoValue.ID}
	err = s.shortUrlRepo.Put(key, shortUrlRepoValue)
	if err != nil {
		return nil, fmt.Errorf("failed to put short url in repo: %w", err)
	}
	s.l.Debug("short url created %s", shortUrlRepoValue.ShortCode)

	// Convert back to ShortUrl for compatibility
	shortUrl := repoValueToShortUrl(shortUrlRepoValue)
	return &shortUrl, nil
}

func (s *ShortUrlService) shortUrlGet(id string) *ShortUrl {
	key := ShortUrlRepoKey{ID: id}
	shortUrlRepoValue, err := s.shortUrlRepo.Get(key)
	if err != nil {
		s.l.Debug("short URL not found: %s", id)
		return nil
	}
	shortUrl := repoValueToShortUrl(shortUrlRepoValue)
	return &shortUrl
}

func (s *ShortUrlService) shortUrlByShortCode(shortCode string) *ShortUrl {
	shortCode = strings.ToLower(strings.TrimSpace(shortCode))
	keys, err := s.shortUrlRepo.Keys()
	if err != nil {
		s.l.Error("failed to get short URL keys: %v", err)
		return nil
	}

	for key := range keys {
		shortUrlRepoValue, err := s.shortUrlRepo.Get(key)
		if err != nil {
			continue
		}
		if shortUrlRepoValue.ShortCode == shortCode {
			shortUrl := repoValueToShortUrl(shortUrlRepoValue)
			return &shortUrl
		}
	}
	return nil
}

func (s *ShortUrlService) filterShortUrls(createdBy string) []ShortUrl {
	keys, err := s.shortUrlRepo.Keys()
	if err != nil {
		s.l.Error("failed to get short URL keys: %v", err)
		return []ShortUrl{}
	}

	filtered := make([]ShortUrl, 0)
	for key := range keys {
		shortUrlRepoValue, err := s.shortUrlRepo.Get(key)
		if err != nil {
			continue
		}
		if createdBy == "" || shortUrlRepoValue.CreatedBy == createdBy {
			shortUrl := repoValueToShortUrl(shortUrlRepoValue)
			filtered = append(filtered, shortUrl)
		}
	}
	return filtered
}

func (s *ShortUrlService) IncrementAccessCount(shortCode string) error {
	shortUrl := s.shortUrlByShortCode(shortCode)
	if shortUrl == nil {
		return fmt.Errorf("short url not found")
	}

	shortUrl.AccessCount++
	shortUrl.UpdatedAt = time.Now().Unix()

	// Convert to repo value and update
	shortUrlRepoValue := shortUrlToRepoValue(*shortUrl)
	key := ShortUrlRepoKey{ID: shortUrl.ID}
	err := s.shortUrlRepo.Put(key, shortUrlRepoValue)
	if err != nil {
		return fmt.Errorf("failed to update short url in repository: %w", err)
	}

	return nil
}

// generateUniqueShortCode generates a unique short code, starting with 4 chars and increasing length if needed
func (s *ShortUrlService) generateUniqueShortCode() (string, error) {
	const charset = "abcdefghijklmnopqrstuvwxyz0123456789"
	maxTotalAttempts := 10000
	totalAttempts := 0

	// Start with 4 characters
	length := 4

	for totalAttempts < maxTotalAttempts {
		// Try up to 100 attempts at current length
		for i := 0; i < 100 && totalAttempts < maxTotalAttempts; i++ {
			totalAttempts++

			// Generate random code at current length
			bytes := make([]byte, length)
			if _, err := rand.Read(bytes); err != nil {
				return "", fmt.Errorf("failed to generate random bytes: %w", err)
			}

			result := make([]byte, length)
			for j := range result {
				result[j] = charset[bytes[j]%byte(len(charset))]
			}

			shortCode := string(result)
			if s.shortUrlByShortCode(shortCode) == nil {
				return shortCode, nil
			}
		}

		// If we hit 100 attempts at current length, try one character longer
		length++
	}
	return "", fmt.Errorf("failed to generate unique short code after %d attempts", maxTotalAttempts)
}
