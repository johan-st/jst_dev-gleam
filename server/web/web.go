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

type Web struct {
	l              *jst_log.Logger
	ctx            context.Context
	talk           *talk.Talk
	routesKv       nats.KeyValue
	assetsObjStore nats.ObjectStore
	assetsMetaKv   nats.KeyValue
}

func New(ctx context.Context, talk *talk.Talk, l *jst_log.Logger) (*Web, error) {
	return &Web{
		l:              l,
		ctx:            ctx,
		talk:           talk,
		routesKv:       nil,
		assetsObjStore: nil,
		assetsMetaKv:   nil,
	}, nil
}

func (w *Web) Start() error {
	// grab jetstream
	js, err := w.talk.Conn.JetStream()
	if err != nil {
		return fmt.Errorf("get jetstream: %w", err)
	}

	// -- ROUTES --

	routesMetadata := map[string]string{}
	routesMetadata["location"] = "unknown"
	routesMetadata["environment"] = "development"
	routesSvc, err := micro.AddService(w.talk.Conn, micro.Config{
		Name:        "web_routes",
		Version:     "1.0.0",
		Description: "routes handler",
		Metadata:    routesMetadata,
	})
	if err != nil {
		return fmt.Errorf("add service: %w", err)
	}

	kvPagesConfig := nats.KeyValueConfig{
		Bucket:       "web_routes",
		Description:  "web pages by path. e.g. about -> /about, about.me -> /about/me",
		Storage:      nats.FileStorage,
		MaxValueSize: 1024 * 1024 * 10, // 10MB
		History:      64,
	}
	routesKv, err := js.CreateKeyValue(&kvPagesConfig)
	if err != nil {
		w.l.Error(fmt.Sprintf("Create pages kv store %s:%s", kvPagesConfig.Bucket, err.Error()))
		return err
	}
	w.routesKv = routesKv

	routesSvcGroup := routesSvc.AddGroup("svc.web", micro.WithGroupQueueGroup("svc.web.routes"))
	if err := routesSvcGroup.AddEndpoint("info", w.handleRoutesInfo(), micro.WithEndpointSubject("routes")); err != nil {
		return fmt.Errorf("add routes endpoint (info): %w", err)
	}
	if err := routesSvcGroup.AddEndpoint("register", w.handleRoutesRegister(), micro.WithEndpointSubject("routes.register")); err != nil {
		return fmt.Errorf("add routes endpoint (register): %w", err)
	}
	if err := routesSvcGroup.AddEndpoint("remove", w.handleRoutesRemove(), micro.WithEndpointSubject("routes.remove")); err != nil {
		return fmt.Errorf("add routes endpont (remove): %w", err)
	}

	// -- ASSETS --

	assetsMetadata := map[string]string{}
	assetsMetadata["location"] = "unknown"
	assetsMetadata["environment"] = "development"
	assetsSvc, err := micro.AddService(w.talk.Conn, micro.Config{
		Name:        "web_assets",
		Version:     "1.0.0",
		Description: "assets handler",
		Metadata:    assetsMetadata,
	})
	if err != nil {
		return fmt.Errorf("add service: %w", err)
	}

	assetsKvConf := nats.ObjectStoreConfig{
		Bucket:      "web_assets",
		Description: "web assets by hash", // TODO: metadata?
		Storage:     nats.FileStorage,
		MaxBytes:    1024 * 1024 * 1024 * 10, // 10GB
		Compression: true,
	}
	assetsObjStore, err := js.CreateObjectStore(&assetsKvConf)
	if err != nil {
		w.l.Error(fmt.Sprintf("Create assets kv store %s:%s", assetsKvConf.Bucket, err.Error()))
		return err
	}
	w.assetsObjStore = assetsObjStore

	assetsSvcGroup := assetsSvc.AddGroup("svc.web", micro.WithGroupQueueGroup("svc.web.assets"))
	if err := assetsSvcGroup.AddEndpoint("list", w.handleAssetsList(), micro.WithEndpointSubject("assets")); err != nil {
		return fmt.Errorf("add assets endpont (list): %w", err)
	}
	if err := assetsSvcGroup.AddEndpoint("find", w.handleTodo("find", ""), micro.WithEndpointSubject("assets.find")); err != nil {
		return fmt.Errorf("add assets endpont (find): %w", err)
	}
	if err := assetsSvcGroup.AddEndpoint("add", w.handleTodo("add", ""), micro.WithEndpointSubject("assets.add")); err != nil {
		return fmt.Errorf("add assets endpont (put): %w", err)
	}
	if err := assetsSvcGroup.AddEndpoint("delete", w.handleTodo("delete", ""), micro.WithEndpointSubject("assets.delete")); err != nil {
		return fmt.Errorf("add assets endpont (delete): %w", err)
	}

	// -- SERVER --
	srv := NewServer(w.l.WithBreadcrumb("http"), w.routesKv, w.assetsObjStore)
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

func (w *Web) handleAssetsList() micro.HandlerFunc {
	l := w.l.WithBreadcrumb("assets.list")
	return func(req micro.Request) {
		l.Debug("called with %s", req.Data())
		info, err := w.assetsObjStore.List()
		if err != nil {
			w.l.Error(fmt.Sprintf("List:%e", err))
			req.Respond([]byte(err.Error()))
			return
		}
		infoBytes := []byte{}
		for _, info := range info {
			infoBytes = append(infoBytes, []byte(fmt.Sprintf("%s: %d\n", info.Name, info.Size))...)
			l.Debug("asset: %s\n%+v", info.Name, info)
		}
		req.Respond(infoBytes)
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
		keysBytes := []byte{}
		for _, key := range keys {
			keysBytes = append(keysBytes, []byte(key+"\n")...)
		}
		req.Respond(keysBytes)
	}
}

func (w *Web) handleRoutesRegister() micro.HandlerFunc {
	type RouteRegReq struct {
		Path    string `json:"path"`
		Content string `json:"content"`
	}
	return func(req micro.Request) {
		w.l.Debug(string(req.Data()))
		var page RouteRegReq
		err := json.Unmarshal(req.Data(), &page)
		if err != nil {
			w.l.Warn(fmt.Sprintf("Unmarshaling page: %s", err.Error()))
			req.Respond([]byte(fmt.Sprintf("Unmarshaling page: %s", err.Error())))
			return
		}
		rev, err := w.routesKv.Put(page.Path, []byte(page.Content))
		if err != nil {
			req.Error("PUT_ERROR", "Registration Failed", []byte(fmt.Sprintf("failed to register route: %s", err.Error())))
		}
		req.Respond([]byte(fmt.Sprintf("OK, current revision is %d", rev)))
	}
}

// func (w *Web) handlerRoutesGetContent() micro.HandlerFunc {
// 	return func(req micro.Request) {
// 		w.l.Debug(string(req.Data()))
// 		path := string(req.Data())
// 		page, err := w.routesKv.Get(path)
// 		if err != nil {
// 			w.l.Error(fmt.Sprintf("Get page: %s", err.Error()))
// 			req.Error("404", "route not found", []byte(fmt.Sprintf("Get page error: %s", err.Error())))
// 			return
// 		}
// 		req.Respond(page.Value())
// 	}
// }

// func (w *Web) handlerRoutesUpdate() micro.HandlerFunc {
// 	type RouteUpdateReq
// 	return func(req micro.Request) {
// 		w.l.Debug(string(req.Data()))
// 		var page Route
// 		err := json.Unmarshal(req.Data(), &page)
// 		if err != nil {
// 			w.l.Error(fmt.Sprintf("Unmarshaling page: %s", err.Error()))
// 			req.Respond([]byte(fmt.Sprintf("Unmarshaling page: %s", err.Error())))
// 			return
// 		}
// 		rev, err := w.routesKv.Put(page.Path, []byte(page.Content))
// 		if err != nil {
// 			req.Error("000", "failed to put", []byte(fmt.Sprintf("the route '%s' was not registered update. (%s)", page.Path, err.Error())))
// 		}
// 		req.Respond([]byte(fmt.Sprintf("%d", rev)))
// 	}
// }

func (w *Web) handleRoutesRemove() micro.HandlerFunc {
	return func(req micro.Request) {
		w.l.Debug(string(req.Data()))
		path := string(req.Data())
		err := w.routesKv.Delete(path)
		if err != nil {
			req.Error("DELETE_FAILED", "failed to delete", []byte(fmt.Sprintf("route '%s'  could not be deleted: %s", path, err.Error())))
		}
		req.Respond([]byte("OK"))
	}
}
