package shorturl

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"jst_dev/server/jst_log"
	"jst_dev/server/short_url/api"

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

	// Test empty short code
	_, err = service.shortUrlCreate("", "https://example.com", "user")
	if err == nil {
		t.Error("Expected error for empty short code")
	}

	// Test empty target URL
	_, err = service.shortUrlCreate("test", "", "user")
	if err == nil {
		t.Error("Expected error for empty target URL")
	}

	// Test empty created by
	_, err = service.shortUrlCreate("test", "https://example.com", "")
	if err == nil {
		t.Error("Expected error for empty created by")
	}
}

func TestShortUrlAPIStructs(t *testing.T) {
	// Test JSON marshaling/unmarshaling of API structs
	shortUrl := api.ShortUrl{
		ID:          "test-id",
		ShortCode:   "test",
		TargetURL:   "https://example.com",
		CreatedBy:   "user",
		CreatedAt:   time.Now(),
		UpdatedAt:   time.Now(),
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