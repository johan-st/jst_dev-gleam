package who

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"

	"jst_dev/server/core"
	"jst_dev/server/jst_log"
	"jst_dev/server/who/api"
)

// --- USER VALUE ---

type UserRepoValue struct {
	api.User
	PasswordHash string `json:"passwordHash"`
	Revision     uint64 `json:"revision"`
}

func (u UserRepoValue) Bytes() []byte {
	data, err := json.Marshal(u)
	if err != nil {
		panic("UserRepoValue.Bytes") // TODO: evaluate this. Do I need another interface for the repo?
	}
	return data
}

func (u UserRepoValue) FromBytes(value []byte) (UserRepoValue, error) {
	err := json.Unmarshal(value, &u)
	if err != nil {
		return UserRepoValue{}, err
	}
	return u, nil
}

// --- REPO ---
type userRepo struct {
	core.Repo[UserRepoValue]
	emailToKey      map[string]string
	usernameToKey   map[string]string
	mu              sync.RWMutex
	done            chan struct{}
	wg              sync.WaitGroup
	closeOnce       sync.Once
	logger          *jst_log.Logger
}

// NewUserRepo initializes and returns a UserRepo backed by a JetStream key-value store.
// Returns an error if the key-value store cannot be set up.
func NewUserRepo(ctx context.Context, nc *nats.Conn, l *jst_log.Logger) (*userRepo, error) {
	l = l.WithBreadcrumb("new")
	l.Debug("creating user repo kv")
	kv, err := setupUserKV(ctx, nc)
	if err != nil {
		return nil, fmt.Errorf("repo setup: %w", err)
	}
	l.Debug("creating repo")
	repo, err := core.NewRepoKv[UserRepoValue](ctx, l, kv)
	if err != nil {
		return nil, fmt.Errorf("create repo: %w", err)
	}
	l.Debug("creating user repo")
	ur := &userRepo{
		Repo:          repo,
		emailToKey:    make(map[string]string),
		usernameToKey: make(map[string]string),
		done:          make(chan struct{}),
		logger:        l,
	}
	l.Debug("running watcher")
	err = ur.runWatcher()
	if err != nil {
		return nil, fmt.Errorf("run watcher: %w", err)
	}
	l.Debug("user repo created")
	return ur, nil
}

func (ur *userRepo) Keys() (<-chan string, error) {
	return ur.Repo.Keys()
}

func (ur *userRepo) Get(key string) (UserRepoValue, error) {
	return ur.Repo.Get(key)
}

func (ur *userRepo) History(key string) ([]UserRepoValue, error) {
	return ur.Repo.History(key)
}
func (ur *userRepo) Put(key string, value UserRepoValue) error {
	if err := ur.Repo.Put(key, value); err != nil {
		return err
	}
	ur.mu.Lock()
	ur.emailToKey[value.Email] = key
	ur.usernameToKey[value.Username] = key
	ur.mu.Unlock()
	return nil
}

func (ur *userRepo) Delete(key string) error {
	// Get the value first to update caches
	value, err := ur.Get(key)
	if err != nil {
		return ur.Repo.Delete(key) // Still try to delete even if Get fails
	}
	if err := ur.Repo.Delete(key); err != nil {
		return err
	}
	ur.mu.Lock()
	delete(ur.emailToKey, value.Email)
	delete(ur.usernameToKey, value.Username)
	ur.mu.Unlock()
	return nil
}


func (ur *userRepo) Watch() (<-chan core.RepoUpdate[UserRepoValue], error) {
	return ur.Repo.Watch()
}

func (ur *userRepo) Close() error {
	ur.closeOnce.Do(func() {
		close(ur.done)
	})
	ur.wg.Wait()
	return ur.Repo.Close()
}

func (ur *userRepo) GetByEmail(email string) (UserRepoValue, error) {
	ur.mu.RLock()
	key, ok := ur.emailToKey[email]
	ur.mu.RUnlock()
	if !ok {
		return UserRepoValue{}, fmt.Errorf("email not found")
	}
	return ur.Get(key)
}

func (ur *userRepo) GetByUsername(username string) (UserRepoValue, error) {
	ur.mu.RLock()
	key, ok := ur.usernameToKey[username]
	ur.mu.RUnlock()
	if !ok {
		return UserRepoValue{}, fmt.Errorf("username not found")
	}
	return ur.Get(key)
}

// --- SETUP ---

// setupUserKV initializes and returns a JetStream key-value store bucket named "who_users" for storing users in JSON format.
// The bucket is configured with a 1MB maximum value size, 64 history entries, and file storage.
// Returns the created key-value store or an error if initialization fails.
func setupUserKV(ctx context.Context, nc *nats.Conn) (jetstream.KeyValue, error) {
	js, err := jetstream.New(nc)
	if err != nil {
		return nil, fmt.Errorf("jetstream new: %w", err)
	}
	kv, err := js.CreateOrUpdateKeyValue(ctx, jetstream.KeyValueConfig{
		Bucket:       "who_users",
		Description:  "who users by id",
		MaxValueSize: 1024 * 1024 * 1,  // 1 MB
		MaxBytes:     1024 * 1024 * 50, // 50 MB,
		History:      64,
		Storage:      jetstream.FileStorage,
		Compression:  true,
	})
	if err != nil {
		return nil, fmt.Errorf("kv create: %w", err)
	}
	return kv, nil
}

// --- WATCHER ---
func (ur *userRepo) runWatcher() error {
	ur.logger.Debug("running watcher")
	updates, err := ur.Repo.Watch()
	if err != nil {
		return fmt.Errorf("failed to watch: %w", err)
	}
	ur.logger.Debug("watcher created")
	
	ur.wg.Add(1)
	go func(ur *userRepo) {
		defer ur.wg.Done()
		ur.logger.Debug("watcher started")
		for {
			select {
			case update, ok := <-updates:
				if !ok {
					ur.logger.Debug("watcher channel closed")
					return
				}
				ur.logger.Debug("received update", "update", update)
				
				ur.mu.Lock()
				if update.IsPut() {
					ur.emailToKey[update.Value().Email] = update.Key()
					ur.usernameToKey[update.Value().Username] = update.Key()
				} else if update.IsDelete() {
					delete(ur.emailToKey, update.Value().Email)
					delete(ur.usernameToKey, update.Value().Username)
				} else if update.IsUpdate() {
					// For updates, we need to remove old mappings first
					// Get the old value from the repo to find the old email/username
					oldValue, err := ur.Repo.Get(update.Key())
					if err == nil {
						// Remove old mappings
						delete(ur.emailToKey, oldValue.Email)
						delete(ur.usernameToKey, oldValue.Username)
					}
					// Add new mappings
					ur.emailToKey[update.Value().Email] = update.Key()
					ur.usernameToKey[update.Value().Username] = update.Key()
				}
				ur.mu.Unlock()
			case <-ur.done:
				ur.logger.Debug("watcher cancelled")
				return
			}
		}
	}(ur)
	ur.logger.Debug("watcher started")
	ur.logger.Debug("emailToKey initialized", "count", len(ur.emailToKey))
	ur.logger.Debug("usernameToKey initialized", "count", len(ur.usernameToKey))
	return nil
}
