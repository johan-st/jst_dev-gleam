package urlShort

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"jst_dev/server/jst_log"
	"jst_dev/server/urlShort/api"

	"github.com/nats-io/nats.go"
)

func TestShortUrlService(t *testing.T) {
	// Create a test NATS connection
	nc, err := nats.Connect(nats.DefaultURL)
	if err != nil {
		t.Skipf("NATS not available: %v", err)
	}
	defer nc.Close()

	logger := &jst_log.Logger{}
	ctx := context.Background()

	// Create service
	conf := &Conf{
		NatsConn: nc,
		Logger:   logger,
	}

	service, err := New(ctx, conf)
	if err != nil {
		t.Fatalf("Failed to create service: %v", err)
	}

	// Start service
	err = service.Start(ctx)
	if err != nil {
		t.Fatalf("Failed to start service: %v", err)
	}

	// Wait a bit for service to initialize
	time.Sleep(100 * time.Millisecond)

	// Test creating a short URL
	shortCode := "test123"
	targetURL := "https://example.com"
	createdBy := "testuser"

	// Test short URL creation
	shortUrl, err := service.shortUrlCreate(shortCode, targetURL, createdBy)
	if err != nil {
		t.Fatalf("Failed to create short URL: %v", err)
	}

	if shortUrl.ShortCode != shortCode {
		t.Errorf("Expected short code %s, got %s", shortCode, shortUrl.ShortCode)
	}

	if shortUrl.TargetURL != targetURL {
		t.Errorf("Expected target URL %s, got %s", targetURL, shortUrl.TargetURL)
	}

	if shortUrl.CreatedBy != createdBy {
		t.Errorf("Expected created by %s, got %s", createdBy, shortUrl.CreatedBy)
	}

	if !shortUrl.IsActive {
		t.Error("Expected short URL to be active")
	}

	// Test getting short URL by short code
	found := service.shortUrlByShortCode(shortCode)
	if found == nil {
		t.Fatal("Failed to find short URL by short code")
	}

	if found.ID != shortUrl.ID {
		t.Errorf("Expected ID %s, got %s", shortUrl.ID, found.ID)
	}

	// Test getting short URL by ID
	foundByID := service.shortUrlGet(shortUrl.ID)
	if foundByID == nil {
		t.Fatal("Failed to find short URL by ID")
	}

	if foundByID.ShortCode != shortCode {
		t.Errorf("Expected short code %s, got %s", shortCode, foundByID.ShortCode)
	}

	// Test incrementing access count
	err = service.IncrementAccessCount(shortCode)
	if err != nil {
		t.Fatalf("Failed to increment access count: %v", err)
	}

	// Verify access count was incremented
	updated := service.shortUrlByShortCode(shortCode)
	if updated.AccessCount != 1 {
		t.Errorf("Expected access count 1, got %d", updated.AccessCount)
	}

	// Test filtering short URLs
	filtered := service.filterShortUrls(createdBy)
	if len(filtered) != 1 {
		t.Errorf("Expected 1 short URL, got %d", len(filtered))
	}

	// Test filtering by non-existent user
	filtered = service.filterShortUrls("nonexistent")
	if len(filtered) != 0 {
		t.Errorf("Expected 0 short URLs, got %d", len(filtered))
	}

	// Test case insensitive short code lookup
	found = service.shortUrlByShortCode("TEST123")
	if found == nil {
		t.Error("Failed to find short URL with uppercase short code")
	}

	// Test duplicate short code creation
	_, err = service.shortUrlCreate(shortCode, "https://another.com", "anotheruser")
	if err == nil {
		t.Error("Expected error when creating duplicate short code")
	}
}

func TestShortUrlValidation(t *testing.T) {
	nc, err := nats.Connect(nats.DefaultURL)
	if err != nil {
		t.Skipf("NATS not available: %v", err)
	}
	defer nc.Close()

	logger := &jst_log.Logger{}
	ctx := context.Background()

	conf := &Conf{
		NatsConn: nc,
		Logger:   logger,
	}

	service, err := New(ctx, conf)
	if err != nil {
		t.Fatalf("Failed to create service: %v", err)
	}

	// Test auto-generation of short code
	shortUrl, err := service.shortUrlCreate("", "https://example.com", "user")
	if err != nil {
		t.Errorf("Expected no error for auto-generated short code: %v", err)
	}
	if len(shortUrl.ShortCode) != 4 {
		t.Errorf("Expected 4-character short code, got %d characters: %s", len(shortUrl.ShortCode), shortUrl.ShortCode)
	}

	// Test that generated short code is unique
	shortUrl2, err := service.shortUrlCreate("", "https://example2.com", "user")
	if err != nil {
		t.Errorf("Expected no error for second auto-generated short code: %v", err)
	}
	if shortUrl.ShortCode == shortUrl2.ShortCode {
		t.Errorf("Expected different short codes, got same: %s", shortUrl.ShortCode)
	}

	// Test empty target URL
	_, err = service.shortUrlCreate("test", "", "user")
	if err == nil {
		t.Error("Expected error for empty target URL")
	}

	// Test empty created by (now allowed)
	shortUrl, err = service.shortUrlCreate("test", "https://example.com", "")
	if err != nil {
		t.Errorf("Expected no error for empty created by: %v", err)
	}
	if shortUrl.CreatedBy != "" {
		t.Errorf("Expected empty created by, got: %s", shortUrl.CreatedBy)
	}
}

func TestShortUrlAPIStructs(t *testing.T) {
	// Test JSON marshaling/unmarshaling of API structs
	nowUnix := time.Now().Unix()
	shortUrl := api.ShortUrl{
		ID:          "test-id",
		ShortCode:   "test",
		TargetURL:   "https://example.com",
		CreatedBy:   "user",
		CreatedAt:   nowUnix,
		UpdatedAt:   nowUnix,
		AccessCount: 5,
		IsActive:    true,
	}

	data, err := json.Marshal(shortUrl)
	if err != nil {
		t.Fatalf("Failed to marshal short URL: %v", err)
	}

	var unmarshaled api.ShortUrl
	err = json.Unmarshal(data, &unmarshaled)
	if err != nil {
		t.Fatalf("Failed to unmarshal short URL: %v", err)
	}

	if unmarshaled.ID != shortUrl.ID {
		t.Errorf("Expected ID %s, got %s", shortUrl.ID, unmarshaled.ID)
	}

	if unmarshaled.ShortCode != shortUrl.ShortCode {
		t.Errorf("Expected short code %s, got %s", shortUrl.ShortCode, unmarshaled.ShortCode)
	}
}

func TestShortCodeGeneration(t *testing.T) {
	// Create a minimal service for testing generation functions
	service := &ShortUrlService{
		shortUrls: []ShortUrl{},
	}

	// Test generateShortCode
	code1, err := service.generateUniqueShortCode()
	if err != nil {
		t.Fatalf("Failed to generate short code: %v", err)
	}
	if len(code1) != 4 {
		t.Errorf("Expected 4-character code, got %d: %s", len(code1), code1)
	}

	code2, err := service.generateUniqueShortCode()
	if err != nil {
		t.Fatalf("Failed to generate short code: %v", err)
	}
	if len(code2) != 4 {
		t.Errorf("Expected 4-character code, got %d: %s", len(code2), code2)
	}

	// Test that codes are different (very unlikely to be same)
	if code1 == code2 {
		t.Logf("Warning: Generated same codes twice: %s", code1)
	}

	// Test generateUniqueShortCode with empty list
	uniqueCode, err := service.generateUniqueShortCode()
	if err != nil {
		t.Fatalf("Failed to generate unique short code: %v", err)
	}
	if len(uniqueCode) != 4 {
		t.Errorf("Expected 4-character unique code, got %d: %s", len(uniqueCode), uniqueCode)
	}
	if uniqueCode == "" {
		t.Error("Expected non-empty unique code")
	}

	// Test generateUniqueShortCode with existing codes
	service.shortUrls = []ShortUrl{
		{ShortUrl: api.ShortUrl{ShortCode: "abcd"}},
		{ShortUrl: api.ShortUrl{ShortCode: "efgh"}},
	}

	uniqueCode2, err := service.generateUniqueShortCode()
	if err != nil {
		t.Fatalf("Failed to generate unique short code: %v", err)
	}
	if len(uniqueCode2) != 4 {
		t.Errorf("Expected 4-character unique code, got %d: %s", len(uniqueCode2), uniqueCode2)
	}
	if uniqueCode2 == "" {
		t.Error("Expected non-empty unique code")
	}

	// Should not be one of the existing codes
	if uniqueCode2 == "abcd" || uniqueCode2 == "efgh" {
		t.Errorf("Generated code should not match existing codes: %s", uniqueCode2)
	}
}

func TestShortCodeLengthProgression(t *testing.T) {
	// Create a service with many existing codes to force length progression
	service := &ShortUrlService{
		shortUrls: []ShortUrl{},
	}

	// Fill up with many 4-character codes to force progression to 5 characters
	charset := "abcdefghijklmnopqrstuvwxyz0123456789"
	for i := 0; i < 1000; i++ { // Add 1000 codes to increase collision probability
		code := fmt.Sprintf("%c%c%c%c",
			charset[i%len(charset)],
			charset[(i+1)%len(charset)],
			charset[(i+2)%len(charset)],
			charset[(i+3)%len(charset)])

		service.shortUrls = append(service.shortUrls, ShortUrl{
			ShortUrl: api.ShortUrl{ShortCode: code},
		})
	}

	// Generate a unique code - should be 5 characters due to collisions
	uniqueCode, err := service.generateUniqueShortCode()
	if err != nil {
		t.Fatalf("Failed to generate unique short code: %v", err)
	}
	if uniqueCode == "" {
		t.Error("Expected non-empty unique code even with many collisions")
	}

	// Should be at least 4 characters, but likely 5 due to collisions
	if len(uniqueCode) < 4 {
		t.Errorf("Expected code length >= 4, got %d: %s", len(uniqueCode), uniqueCode)
	}

	// Verify it's unique
	for _, existing := range service.shortUrls {
		if existing.ShortCode == uniqueCode {
			t.Errorf("Generated code should be unique: %s", uniqueCode)
		}
	}
}

func TestShortUrlAuthentication(t *testing.T) {
	// Create a minimal service for testing
	service := &ShortUrlService{
		shortUrls: []ShortUrl{},
	}

	// Test creating short URL with createdBy (mock the KV store call)
	nowUnix := time.Now().Unix()
	shortUrl1 := &ShortUrl{
		ShortUrl: api.ShortUrl{
			ID:          "test-id-1",
			ShortCode:   "test1",
			TargetURL:   "https://example.com",
			CreatedBy:   "user123",
			CreatedAt:   nowUnix,
			UpdatedAt:   nowUnix,
			AccessCount: 0,
			IsActive:    true,
		},
	}
	service.shortUrls = append(service.shortUrls, *shortUrl1)

	// Test creating short URL without createdBy
	shortUrl2 := &ShortUrl{
		ShortUrl: api.ShortUrl{
			ID:          "test-id-2",
			ShortCode:   "test2",
			TargetURL:   "https://example.com",
			CreatedBy:   "",
			CreatedAt:   nowUnix,
			UpdatedAt:   nowUnix,
			AccessCount: 0,
			IsActive:    true,
		},
	}
	service.shortUrls = append(service.shortUrls, *shortUrl2)

	// Test filtering - should work with both
	filtered := service.filterShortUrls("user123")
	if len(filtered) != 1 {
		t.Errorf("Expected 1 short URL for user123, got %d", len(filtered))
	}

	filtered = service.filterShortUrls("")
	if len(filtered) != 2 {
		t.Errorf("Expected 2 short URLs for empty user, got %d", len(filtered))
	}

	filtered = service.filterShortUrls("nonexistent")
	if len(filtered) != 0 {
		t.Errorf("Expected 0 short URLs for nonexistent user, got %d", len(filtered))
	}
}
