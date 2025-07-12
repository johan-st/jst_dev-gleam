package api

// the NATS subject used by this package
var Subj = struct {
	// short urls
	ShortUrlGroup string
	ShortUrlCreate string
	ShortUrlGet    string
	ShortUrlUpdate string
	ShortUrlDelete string
	ShortUrlList   string
	ShortUrlAccess string
}{
	// short urls
	ShortUrlGroup:  "svc.shorturl.urls",
	ShortUrlCreate: "create",
	ShortUrlGet:    "get",
	ShortUrlUpdate: "update",
	ShortUrlDelete: "delete",
	ShortUrlList:   "list",
	ShortUrlAccess: "access",
}

// SHORT URL
type ShortUrl struct {
	ID          string `json:"id"`
	ShortCode   string `json:"shortCode"`
	TargetURL   string `json:"targetUrl"`
	CreatedBy   string `json:"createdBy"`
	CreatedAt   int64  `json:"createdAt"`   // Unix seconds
	UpdatedAt   int64  `json:"updatedAt"`   // Unix seconds
	AccessCount int64  `json:"accessCount"`
	IsActive    bool   `json:"isActive"`
}

type ShortUrlCreateRequest struct {
	ShortCode string `json:"shortCode,omitempty"` // Optional: if empty, a 4-character code will be auto-generated
	TargetURL string `json:"targetUrl"`
	CreatedBy string `json:"createdBy,omitempty"` // Optional: if empty and user is authenticated, will use user's ID
}

type ShortUrlGetRequest struct {
	ID        string `json:"id,omitempty"`
	ShortCode string `json:"shortCode,omitempty"`
}

type ShortUrlUpdateRequest struct {
	ID        string `json:"id"`
	ShortCode string `json:"shortCode,omitempty"`
	TargetURL string `json:"targetUrl,omitempty"`
	IsActive  *bool  `json:"isActive,omitempty"`
}

type ShortUrlDeleteRequest struct {
	ID string `json:"id"`
}

type ShortUrlDeleteResponse struct {
	IDDeleted string `json:"deleted_id"`
}

type ShortUrlListRequest struct {
	CreatedBy string `json:"createdBy,omitempty"`
	Limit     int    `json:"limit,omitempty"`
	Offset    int    `json:"offset,omitempty"`
}

type ShortUrlListResponse struct {
	ShortUrls []ShortUrl `json:"shortUrls"`
	Total     int        `json:"total"`
	Limit     int        `json:"limit"`
	Offset    int        `json:"offset"`
}

type ShortUrlAccessRequest struct {
	ShortCode string `json:"shortCode"`
}

type ShortUrlAccessResponse struct {
	TargetURL string `json:"targetUrl"`
	Redirect  bool   `json:"redirect"`
} 