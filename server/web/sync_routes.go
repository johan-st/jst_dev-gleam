package web

import (
	"encoding/json"
	"net/http"
	"time"

	"jst_dev/server/jst_log"
)

// SetupSyncRoutes adds WebSocket and sync-related routes to the mux
func SetupSyncRoutes(mux *http.ServeMux, syncService *SyncService, logger *jst_log.Logger) {
	// WebSocket endpoint for real-time data sync
	mux.HandleFunc("/ws/sync", func(w http.ResponseWriter, r *http.Request) {
		HandleWebSocket(syncService.GetHub(), w, r)
	})

	// REST endpoints for data synchronization
	mux.HandleFunc("/api/sync/publish", func(w http.ResponseWriter, r *http.Request) {
		handlePublishData(w, r, syncService, logger)
	})

	mux.HandleFunc("/api/sync/broadcast", func(w http.ResponseWriter, r *http.Request) {
		handleBroadcastData(w, r, syncService, logger)
	})

	mux.HandleFunc("/api/sync/status", func(w http.ResponseWriter, r *http.Request) {
		handleSyncStatus(w, r, syncService, logger)
	})
}

// handlePublishData handles publishing data to a specific topic
func handlePublishData(w http.ResponseWriter, r *http.Request, syncService *SyncService, logger *jst_log.Logger) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse request body
	var request struct {
		Topic string      `json:"topic"`
		Data  interface{} `json:"data"`
	}

	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	if request.Topic == "" {
		http.Error(w, "Topic is required", http.StatusBadRequest)
		return
	}

	// Publish data
	if err := syncService.PublishData(request.Topic, request.Data); err != nil {
		logger.Error("Failed to publish data: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "published"})
}

// handleBroadcastData handles broadcasting data to all connected clients
func handleBroadcastData(w http.ResponseWriter, r *http.Request, syncService *SyncService, logger *jst_log.Logger) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	// Parse request body
	var request struct {
		Data interface{} `json:"data"`
	}

	if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
		http.Error(w, "Invalid request body", http.StatusBadRequest)
		return
	}

	// Broadcast data
	if err := syncService.PublishData("broadcast", request.Data); err != nil {
		logger.Error("Failed to broadcast data: %v", err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "broadcasted"})
}

// handleSyncStatus returns the current sync service status
func handleSyncStatus(w http.ResponseWriter, r *http.Request, syncService *SyncService, logger *jst_log.Logger) {
	if r.Method != http.MethodGet {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	hub := syncService.GetHub()
	hub.mu.RLock()
	clientCount := len(hub.clients)
	hub.mu.RUnlock()

	status := map[string]interface{}{
		"status":       "running",
		"clients":      clientCount,
		"connections":  clientCount,
		"timestamp":    time.Now().Unix(),
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(status)
} 