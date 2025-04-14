package web

import (
	"encoding/json"
	"fmt"

	"jst_dev/server/jst_log"

	"github.com/nats-io/nats.go"

	"github.com/nats-io/nats.go/micro"
)

type Page struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

func Init(nc *nats.Conn, lParent *jst_log.Logger) error {
	l := lParent.WithBreadcrumb("Init")
	l.Debug("Init")
	l.Debug("get jetstream")
	js, err := nc.JetStream()
	if err != nil {
		return err
	}

	l.Debug("create kv")
	kvConfig := nats.KeyValueConfig{
		Bucket:      "web_routes",
		Description: "web pages by path",
		Storage:     nats.FileStorage,
		History:     64,
	}
	kv, err := js.CreateKeyValue(&kvConfig)

	if err != nil {
		l.Error(fmt.Sprintf("Create kv store %s:%s", kvConfig.Bucket, err.Error()))
		return err
	}

	err = registerService(lParent, nc, kv)
	if err != nil {
		l.Error(fmt.Sprintf("registerService:%e", err))
		return err
	}

	srv := NewServer(lParent, kv)
	go srv.Start(8080)
	return nil
}

func registerService(lParent *jst_log.Logger, nc *nats.Conn, pages nats.KeyValue) error {
	l := lParent.WithBreadcrumb("registerService")
	l.Debug("registerServices")

	l.Debug("add service Web")
	svc, err := micro.AddService(nc, micro.Config{
		Name:    "Web",
		Version: "0.0.1",
		Endpoint: &micro.EndpointConfig{
			Subject: "svc.web",
			Handler: micro.HandlerFunc(statusHandler(l, pages)),
		},
	})
	if err != nil {
		l.Error(fmt.Sprintf("AddService:%e", err))
		return err
	}

	l.Debug("add group web")
	web := svc.AddGroup("svc.web")

	l.Debug("Add endpoints")
	web.AddEndpoint("page_add", micro.HandlerFunc(addPageHandler(lParent, pages)))
	web.AddEndpoint("page_list", micro.HandlerFunc(listRoutesHandler(lParent, pages)))
	web.AddEndpoint("page_get", micro.HandlerFunc(getPageHandler(lParent, pages)))
	web.AddEndpoint("page_update", micro.HandlerFunc(updatePageHandler(lParent, pages)))
	web.AddEndpoint("page_delete", micro.HandlerFunc(deletePageHandler(lParent, pages)))

	l.Debug("done")
	return nil
}

func statusHandler(lParent *jst_log.Logger, kv nats.KeyValue) micro.HandlerFunc {
	l := lParent.WithBreadcrumb("status")
	return func(req micro.Request) {
		keysLister, err := kv.ListKeys()
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

func addPageHandler(lParent *jst_log.Logger, kv nats.KeyValue) micro.HandlerFunc {
	l := lParent.WithBreadcrumb("page_add")
	return func(req micro.Request) {
		l.Debug(string(req.Data()))
		var page Page
		err := json.Unmarshal(req.Data(), &page)
		if err != nil {
			l.Error(fmt.Sprintf("Unmarshaling page: %s", err.Error()))
			req.Respond([]byte(fmt.Sprintf("Unmarshaling page: %s", err.Error())))
			return
		}
		kv.Put(page.Path, []byte(page.Content))
		req.Respond([]byte("OK"))
	}
}

// get page by path (from request)
func getPageHandler(lParent *jst_log.Logger, kv nats.KeyValue) micro.HandlerFunc {
	l := lParent.WithBreadcrumb("page_get")
	return func(req micro.Request) {
		l.Debug(string(req.Data()))
		path := string(req.Data())
		page, err := kv.Get(path)
		if err != nil {
			l.Error(fmt.Sprintf("Get page: %s", err.Error()))
			req.Respond([]byte(fmt.Sprintf("Get page: %s", err.Error())))
			return
		}
		req.Respond(page.Value())
	}
}

func updatePageHandler(lParent *jst_log.Logger, kv nats.KeyValue) micro.HandlerFunc {
	l := lParent.WithBreadcrumb("page_update")
	return func(req micro.Request) {
		l.Debug(string(req.Data()))
		var page Page
		err := json.Unmarshal(req.Data(), &page)
		if err != nil {
			l.Error(fmt.Sprintf("Unmarshaling page: %s", err.Error()))
			req.Respond([]byte(fmt.Sprintf("Unmarshaling page: %s", err.Error())))
			return
		}
		kv.Put(page.Path, []byte(page.Content))
		req.Respond([]byte("OK"))
	}
}

func deletePageHandler(lParent *jst_log.Logger, kv nats.KeyValue) micro.HandlerFunc {
	l := lParent.WithBreadcrumb("page_delete")
	return func(req micro.Request) {
		l.Debug(string(req.Data()))
		path := string(req.Data())
		kv.Delete(path)
		req.Respond([]byte("OK"))
	}
}

func listRoutesHandler(lParent *jst_log.Logger, kv nats.KeyValue) micro.HandlerFunc {
	l := lParent.WithBreadcrumb("page_list")
	return func(req micro.Request) {
		l.Debug(string(req.Data()))
		keys, err := kv.ListKeys()
		if err != nil {
			l.Error(err.Error())
			req.Respond([]byte(err.Error()))
			return
		}
		routes := []string{}
		for route := range keys.Keys() {
			routes = append(routes, route)
		}
		routesBytes := []byte{}
		for _, route := range routes {
			routesBytes = append(routesBytes, []byte(route+"\n")...)
		}
		req.Respond(routesBytes)
	}
}
