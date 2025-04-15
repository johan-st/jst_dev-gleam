package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"jst_dev/server/blog"
	"jst_dev/server/jst_log"
	"jst_dev/server/talk"
	"jst_dev/server/web"
)

const AppName = "local-dev"

func main() {
	err := run()
	if err != nil {
		log.Fatal(err)
	}
}

func run() error {
	conf, err := loadConf()
	if err != nil {
		return fmt.Errorf("load conf: %w", err)
	}

	l := jst_log.NewLogger(AppName, jst_log.DefaultSubjects())

	talk, err := talk.New(conf.Talk, l.WithBreadcrumb("talk"))
	if err != nil {
		return fmt.Errorf("new talk: %w", err)
	}

	err = talk.Start()
	if err != nil {
		return fmt.Errorf("start talk: %w", err)
	}
	l.Connect(talk.Conn)
	logLevel := jst_log.LogLevelDebug
	jst_log.StdOut(talk.Conn, "log."+AppName, jst_log.DefaultSubjects(), logLevel)
	time.Sleep(1 * time.Millisecond)

	// --- Start Services ---
	ctx := context.Background()
	// - blog
	blog, err := blog.New(ctx, talk, l.WithBreadcrumb("blog"))
	if err != nil {
		return fmt.Errorf("new blog: %w", err)
	}
	err = blog.Start()
	if err != nil {
		return fmt.Errorf("start blog: %w", err)
	}
	// - web
	web, err := web.New(ctx, talk, l.WithBreadcrumb("web"))
	if err != nil {
		return fmt.Errorf("new web: %w", err)
	}
	err = web.Start()
	if err != nil {
		return fmt.Errorf("start web: %w", err)
	}

	talk.WaitForShutdown()
	return nil
}
