package urlShort

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"jst_dev/server/jst_log"
	"jst_dev/server/urlShort/api"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/nats-io/nats.go/micro"
)

const ShortUrlKey = "shorturl_url"

type ShortUrlService struct {
	shortUrls []ShortUrl
	l         *jst_log.Logger
	nc        *nats.Conn
	shortUrlsKv jetstream.KeyValue
	ctx        context.Context
}

type ShortUrl struct {
	api.ShortUrl
	revision uint64
}

type Conf struct {
	NatsConn *nats.Conn
	Logger   *jst_log.Logger
}

// New creates a new ShortUrlService instance with the provided configuration.
func New(ctx context.Context, c *Conf) (*ShortUrlService, error) {
	service := &ShortUrlService{
		l:         c.Logger,
		nc:        c.NatsConn,
		ctx:       ctx,
		shortUrls: []ShortUrl{},
	}

	return service, nil
}

func (s *ShortUrlService) Start(ctx context.Context) error {
	if s.nc.Status() != nats.CONNECTED {
		return fmt.Errorf("nats connection not connected: %s", s.nc.Status())
	}

	js, err := jetstream.New(s.nc)
	if err != nil {
		return fmt.Errorf("failed to get JetStream context: %w", err)
	}

	confKv := jetstream.KeyValueConfig{
		Bucket:       "url_short",
		Description:  "short url mappings",
		Storage:      jetstream.FileStorage,
		MaxValueSize: 1 * 1024,       // 1 KB
		MaxBytes:     50 * 1024 * 1024, // 50 MB
		History:      1,
		Compression:  false,
	}
	kv, err := js.CreateOrUpdateKeyValue(s.ctx, confKv)
	if err != nil {
		s.l.Error(fmt.Sprintf("create short urls kv store %s:%s", confKv.Bucket, err.Error()))
		return fmt.Errorf("create short urls kv store %s:%w", confKv.Bucket, err)
	}
	s.shortUrlsKv = kv
	s.shortUrlWatcher()

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

	return nil
}

// ----------- WATCHERS -----------

func (s *ShortUrlService) shortUrlWatcher() error {
	var (
		watcher jetstream.KeyWatcher
		err     error
		kv      jetstream.KeyValueEntry
		shortUrl ShortUrl
	)

	watcher, err = s.shortUrlsKv.WatchAll(s.ctx)
	if err != nil {
		return fmt.Errorf("failed to watch short urls: %w", err)
	}

	go func() {
		for {
			select {
			case kv = <-watcher.Updates():
				if kv == nil {
					s.l.Debug("up to date. %d short urls loaded", len(s.shortUrls))
					continue
				}
				switch kv.Operation() {
				case jetstream.KeyValuePut:
					err = json.Unmarshal(kv.Value(), &shortUrl)
					if err != nil {
						s.l.Error("failed to unmarshal short url: %s", err.Error())
						continue
					}
					found := false
					for i, existingShortUrl := range s.shortUrls {
						if existingShortUrl.ID == shortUrl.ID {
							s.shortUrls[i] = shortUrl
							found = true
							s.l.Debug("updated short url(%s). %d short urls loaded", shortUrl.ID, len(s.shortUrls))
							break
						}
					}
					if !found {
						s.shortUrls = append(s.shortUrls, shortUrl)
						s.l.Debug("new short url(%s). %d short urls loaded", shortUrl.ID, len(s.shortUrls))
					}
				case jetstream.KeyValueDelete:
					for i, existingShortUrl := range s.shortUrls {
						if existingShortUrl.ID == kv.Key() {
							s.shortUrls = append(s.shortUrls[:i], s.shortUrls[i+1:]...)
							s.l.Debug("deleted short url(%s). %d short urls loaded", kv.Key(), len(s.shortUrls))
							break
						}
					}
				default:
					s.l.Error("unknown operation: %s", kv.Operation())
				}
			case <-s.ctx.Done():
				s.l.Debug("watcher: context done")
				return
			}
		}
	}()

	return nil
}

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
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		if reqData.ShortCode == "" {
			l.Debug("short code is empty, generating one")
			reqData.ShortCode = s.generateUniqueShortCode()
			if reqData.ShortCode == "" {
				l.Error("failed to generate unique short code after 10000 attempts")
				req.Error("SERVER_ERROR", "unable to generate unique short code", []byte("short code generation failed"))
				return
			}
			l.Debug("generated short code: %s", reqData.ShortCode)
		}
		if reqData.TargetURL == "" {
			l.Warn("target URL is empty")
			req.Error("INVALID_REQUEST", "target URL is empty", []byte("target URL is empty"))
			return
		}
		// Note: CreatedBy is now optional - will be handled by the web layer

		// Check if short code already exists
		existing := s.shortUrlByShortCode(reqData.ShortCode)
		if existing != nil {
			l.Warn("short code already exists")
			req.Error("SHORT_CODE_TAKEN", "a short url with this code already exists", []byte(reqData.ShortCode))
			return
		}

		shortUrl, err = s.shortUrlCreate(reqData.ShortCode, reqData.TargetURL, reqData.CreatedBy)
		if err != nil {
			l.Error(fmt.Sprintf("failed to create short url: %s", err.Error()))
			req.Error("SERVER_ERROR", "server error", []byte(err.Error()))
			return
		}

		req.RespondJSON(shortUrl.ShortUrl)
	}
}

func (s *ShortUrlService) handleShortUrlGet() micro.HandlerFunc {
	l := s.l.WithBreadcrumb("shorturl_get")

	return func(req micro.Request) {
		var (
			reqData api.ShortUrlGetRequest
			err     error
			shortUrl *ShortUrl
		)
		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal short url get request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		if reqData.ID == "" && reqData.ShortCode == "" {
			l.Warn("no id or short code provided")
			req.Error("INVALID_REQUEST", "no id or short code provided", []byte("no id or short code provided"))
			return
		}
		if reqData.ID != "" {
			shortUrl = s.shortUrlGet(reqData.ID)
			if shortUrl == nil {
				l.Warn(fmt.Sprintf("short url not found: %s", reqData.ID))
				req.Error("NOT_FOUND", "short url not found", []byte(reqData.ID))
				return
			}
		} else if reqData.ShortCode != "" {
			shortUrl = s.shortUrlByShortCode(reqData.ShortCode)
			if shortUrl == nil {
				l.Warn(fmt.Sprintf("short url not found: %s", reqData.ShortCode))
				req.Error("NOT_FOUND", "short url not found", []byte(reqData.ShortCode))
				return
			}
		}

		req.RespondJSON(shortUrl.ShortUrl)
	}
}

func (s *ShortUrlService) handleShortUrlUpdate() micro.HandlerFunc {
	l := s.l.WithBreadcrumb("shorturl_update")
	return func(req micro.Request) {
		var (
			err       error
			shortUrl  *ShortUrl
			reqData   api.ShortUrlUpdateRequest
			userBytes []byte
			rev       uint64
		)

		l.Debug("got request")
		err = json.Unmarshal(req.Data(), &reqData)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to unmarshal short url update request: %s", err.Error()))
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		shortUrl = s.shortUrlGet(reqData.ID)
		if shortUrl == nil {
			l.Warn(fmt.Sprintf("short url not found: %s", reqData.ID))
			req.Error("NOT_FOUND", "short url not found", []byte(reqData.ID))
			return
		}

		// Update fields if provided
		if reqData.ShortCode != "" {
			// Check if new short code already exists
			existing := s.shortUrlByShortCode(reqData.ShortCode)
			if existing != nil && existing.ID != shortUrl.ID {
				l.Warn("short code already exists")
				req.Error("SHORT_CODE_TAKEN", "a short url with this code already exists", []byte(reqData.ShortCode))
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

		userBytes, err = json.Marshal(shortUrl)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to marshal short url: %s", err.Error()))
			req.Error("SERVER_ERROR", "server error while updating short url", []byte(err.Error()))
			return
		}
		rev, err = s.shortUrlsKv.Put(s.ctx, shortUrl.ID, userBytes)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to update short url: %s", err.Error()))
			req.Error("SERVER_ERROR", "server error while updating short url", []byte(err.Error()))
			return
		}
		shortUrl.revision = rev
		req.RespondJSON(shortUrl.ShortUrl)
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
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		shortUrl = s.shortUrlGet(reqData.ID)
		if shortUrl == nil {
			l.Warn(fmt.Sprintf("short url not found: %s", reqData.ID))
			req.Error("NOT_FOUND", "short url not found and could thus not be deleted", []byte(reqData.ID))
			return
		}
		err = s.shortUrlsKv.Delete(s.ctx, shortUrl.ID)
		if err != nil {
			l.Warn(fmt.Sprintf("failed to delete short url: %s", err.Error()))
			req.Error("SERVER_ERROR", "server error while deleting short url", []byte(err.Error()))
			return
		}
		respData = api.ShortUrlDeleteResponse{
			IDDeleted: shortUrl.ID,
		}
		req.RespondJSON(respData)
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
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
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
		req.RespondJSON(respData)
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
			req.Error("INVALID_REQUEST", "invalid request", []byte(err.Error()))
			return
		}
		if reqData.ShortCode == "" {
			l.Warn("short code is empty")
			req.Error("INVALID_REQUEST", "short code is empty", []byte("short code is empty"))
			return
		}

		// Get short URL
		shortUrl := s.shortUrlByShortCode(reqData.ShortCode)
		if shortUrl == nil {
			l.Warn(fmt.Sprintf("short url not found: %s", reqData.ShortCode))
			req.Error("NOT_FOUND", "short url not found", []byte(reqData.ShortCode))
			return
		}

		// Check if short URL is active
		if !shortUrl.IsActive {
			l.Warn(fmt.Sprintf("short url is inactive: %s", reqData.ShortCode))
			req.Error("GONE", "short url is inactive", []byte(reqData.ShortCode))
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
		req.RespondJSON(respData)
	}
}

// ----------- Helper Functions -----------

func (s *ShortUrlService) shortUrlCreate(shortCode, targetURL, createdBy string) (*ShortUrl, error) {
	var (
		err       error
		shortUrl  *ShortUrl
		shortUrlBytes []byte
		rev       uint64
	)

	if shortCode == "" || targetURL == "" {
		return nil, fmt.Errorf("short code and target URL are required")
	}

	// Normalize short code
	shortCode = strings.ToLower(strings.TrimSpace(shortCode))

	nowUnix := time.Now().Unix()
	shortUrl = &ShortUrl{
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
	}

	shortUrlBytes, err = json.Marshal(shortUrl)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal short url: %w", err)
	}
	rev, err = s.shortUrlsKv.Create(s.ctx, shortUrl.ID, shortUrlBytes)
	if err != nil {
		return nil, fmt.Errorf("failed to put short url in kv: %w", err)
	}
	s.l.Debug("short url created %s, rev %d", shortUrl.ShortCode, rev)
	return shortUrl, nil
}

func (s *ShortUrlService) shortUrlGet(id string) *ShortUrl {
	for _, shortUrl := range s.shortUrls {
		if shortUrl.ID == id {
			return &shortUrl
		}
	}
	return nil
}

func (s *ShortUrlService) shortUrlByShortCode(shortCode string) *ShortUrl {
	shortCode = strings.ToLower(strings.TrimSpace(shortCode))
	for _, shortUrl := range s.shortUrls {
		if shortUrl.ShortCode == shortCode {
			return &shortUrl
		}
	}
	return nil
}

func (s *ShortUrlService) filterShortUrls(createdBy string) []ShortUrl {
	if createdBy == "" {
		return s.shortUrls
	}
	
	filtered := make([]ShortUrl, 0)
	for _, shortUrl := range s.shortUrls {
		if shortUrl.CreatedBy == createdBy {
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

	shortUrlBytes, err := json.Marshal(shortUrl)
	if err != nil {
		return fmt.Errorf("failed to marshal short url: %w", err)
	}
	_, err = s.shortUrlsKv.Put(s.ctx, shortUrl.ID, shortUrlBytes)
	if err != nil {
		return fmt.Errorf("failed to update short url in KV store: %w", err)
	}

	return nil
}

// generateShortCode creates a random 4-character alphanumeric short code
func (s *ShortUrlService) generateShortCode() string {
	const charset = "abcdefghijklmnopqrstuvwxyz0123456789"
	const length = 4
	
	bytes := make([]byte, length)
	rand.Read(bytes)
	
	result := make([]byte, length)
	for i := range result {
		result[i] = charset[bytes[i]%byte(len(charset))]
	}
	
	return string(result)
}

// generateUniqueShortCode generates a unique short code, starting with 4 chars and increasing length if needed
func (s *ShortUrlService) generateUniqueShortCode() string {
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
			rand.Read(bytes)
			
			result := make([]byte, length)
			for j := range result {
				result[j] = charset[bytes[j]%byte(len(charset))]
			}
			
			shortCode := string(result)
			if s.shortUrlByShortCode(shortCode) == nil {
				return shortCode
			}
		}
		
		// If we hit 100 attempts at current length, try one character longer
		length++
	}
	
	// If we've exhausted all attempts, fail
	return ""
}

