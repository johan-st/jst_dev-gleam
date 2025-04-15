package web

import (
	"context"
	"encoding/json"
	"fmt"

	"jst_dev/server/jst_log"
	"jst_dev/server/talk"

	"github.com/nats-io/nats.go"

	"github.com/nats-io/nats.go/micro"
)

type Page struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

type Web struct {
	l              *jst_log.Logger
	ctx            context.Context
	talk           *talk.Talk
	routesKv       nats.KeyValue
	assetsObjStore nats.ObjectStore
	svc            micro.Service
}

func New(ctx context.Context, talk *talk.Talk, l *jst_log.Logger) (*Web, error) {
	return &Web{
		l:              l,
		ctx:            ctx,
		talk:           talk,
		routesKv:       nil,
		assetsObjStore: nil,
	}, nil
}

func (w *Web) Start() error {
	// grab jetstream
	js, err := w.talk.Conn.JetStream()
	if err != nil {
		return fmt.Errorf("get jetstream: %w", err)
	}

	// pages kv store
	kvPagesConfig := nats.KeyValueConfig{
		Bucket:       "web_routes",
		Description:  "web pages by path. e.g. about -> /about, about.me -> /about/me",
		Storage:      nats.FileStorage,
		MaxValueSize: 1024 * 1024 * 10, // 10MB
		History:      64,
	}
	pagesKv, err := js.CreateKeyValue(&kvPagesConfig)
	if err != nil {
		w.l.Error(fmt.Sprintf("Create pages kv store %s:%s", kvPagesConfig.Bucket, err.Error()))
		return err
	}
	w.routesKv = pagesKv

	// assets object store

	kvAssetsConfig := nats.ObjectStoreConfig{
		Bucket:      "web_assets",
		Description: "web assets by hash", // TODO: metadata?
		Storage:     nats.FileStorage,
		MaxBytes:    1024 * 1024 * 1024 * 10, // 10GB
		Compression: true,
		// TTL:         time.Hour * 24 * 356,
	}
	assetsObjStore, err := js.CreateObjectStore(&kvAssetsConfig)
	if err != nil {
		w.l.Error(fmt.Sprintf("Create assets kv store %s:%s", kvAssetsConfig.Bucket, err.Error()))
		return err
	}
	w.assetsObjStore = assetsObjStore

	// service registration
	metadata := map[string]string{}
	metadata["location"] = "unknown"
	metadata["environment"] = "development"
	svc, err := micro.AddService(w.talk.Conn, micro.Config{
		Name:        "web",
		Version:     "1.0.0",
		Description: "serving web requests. Routes and Assets",
		Metadata:    metadata,
	})

	routesSvcGroup := svc.AddGroup("routes")
	if err := routesSvcGroup.AddEndpoint("routes_info", w.handleRoutesInfo()); err != nil {
		return fmt.Errorf("add routes endpoint (info): %w", err)
	}
	if err := routesSvcGroup.AddEndpoint("routes_register", w.handleRoutesRegister()); err != nil {
		return fmt.Errorf("add routes endpoint (register): %w", err)
	}
	if err := routesSvcGroup.AddEndpoint("routes_remove", w.handleRoutesRemove()); err != nil {
		return fmt.Errorf("add routes endpont (remove): %w", err)
	}

	assetsSvcGroup := svc.AddGroup("assets")
	if err := assetsSvcGroup.AddEndpoint("assets_list", w.handleTodo("list", "")); err != nil {
		return fmt.Errorf("add assets endpont (list): %w", err)
	}
	if err := assetsSvcGroup.AddEndpoint("assets_get", w.handleTodo("get", "")); err != nil {
		return fmt.Errorf("add assets endpont (get): %w", err)
	}
	if err := assetsSvcGroup.AddEndpoint("assets_put", w.handleTodo("put", "")); err != nil {
		return fmt.Errorf("add assets endpont (put): %w", err)
	}
	if err := assetsSvcGroup.AddEndpoint("assets_delete", w.handleTodo("delete", "")); err != nil {
		return fmt.Errorf("add assets endpont (delete): %w", err)
	}

	// start server
	srv := NewServer(w.l, w.routesKv, w.assetsObjStore)
	go srv.Start(8080)
	return nil
}

func (w *Web) handleTodo(name, msg string) micro.HandlerFunc {
	l := w.l.WithBreadcrumb(name)
	if msg == "" {
		msg = fmt.Sprintf("todo: implement %s", name)
	}
	return func(req micro.Request) {
		l.Debug("called with %s", req.Data())
		req.Respond([]byte(msg))
	}

}

func (w *Web) handleRoutesInfo() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("status")
	return func(req micro.Request) {
		keysLister, err := w.routesKv.ListKeys()
		if err != nil {
			l.Error(fmt.Sprintf("ListKeys:%e", err))
			req.Respond([]byte(err.Error()))
			return
		}
		keys := []string{}
		for key := range keysLister.Keys() {
			keys = append(keys, key)
		}
		keysBytes := []byte("OK\n\nregistered routes:\n")
		for _, key := range keys {
			keysBytes = append(keysBytes, []byte(key+"\n")...)
		}
		req.Respond(keysBytes)
	}
}

func (w *Web) handleRoutesRegister() micro.HandlerFunc {
	return func(req micro.Request) {
		w.l.Debug(string(req.Data()))
		var page Page
		err := json.Unmarshal(req.Data(), &page)
		if err != nil {
			w.l.Warn(fmt.Sprintf("Unmarshaling page: %s", err.Error()))
			req.Respond([]byte(fmt.Sprintf("Unmarshaling page: %s", err.Error())))
			return
		}
		w.routesKv.Put(page.Path, []byte(page.Content))
		req.Respond([]byte("OK"))
	}
}

func (w *Web) handlerRoutesGetContent() micro.HandlerFunc {
	return func(req micro.Request) {
		w.l.Debug(string(req.Data()))
		path := string(req.Data())
		page, err := w.routesKv.Get(path)
		if err != nil {
			w.l.Error(fmt.Sprintf("Get page: %s", err.Error()))
			req.Error("404", "route not found", []byte(fmt.Sprintf("Get page error: %s", err.Error())))
			return
		}
		req.Respond(page.Value())
	}
}

func (w *Web) handlerRoutesUpdate() micro.HandlerFunc {
	return func(req micro.Request) {
		w.l.Debug(string(req.Data()))
		var page Page
		err := json.Unmarshal(req.Data(), &page)
		if err != nil {
			w.l.Error(fmt.Sprintf("Unmarshaling page: %s", err.Error()))
			req.Respond([]byte(fmt.Sprintf("Unmarshaling page: %s", err.Error())))
			return
		}
		rev, err := w.routesKv.Put(page.Path, []byte(page.Content))
		if err != nil {
			req.Error("000", "failed to put", []byte(fmt.Sprintf("the route '%s' was not registered update. (%s)", page.Path, err.Error())))
		}
		req.Respond([]byte(fmt.Sprintf("%d", rev)))
	}
}

func (w *Web) handleRoutesRemove() micro.HandlerFunc {
	return func(req micro.Request) {
		w.l.Debug(string(req.Data()))
		path := string(req.Data())
		err := w.routesKv.Delete(path)
		if err != nil {
			req.Error("404", "key not found", []byte(fmt.Sprintf("the '%s' is not registered in routes. (%s)", path, err.Error())))
		}
		req.Respond([]byte("OK"))
	}
}
