package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"jst_dev/server/blog"
	"jst_dev/server/jst_log"
	"jst_dev/server/talk"
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

	lRun := l.WithBreadcrumb("run")

	// --- Start Services ---
	ctx := context.Background()
	// - blog
	if err := blog.Start(ctx, talk, l.WithBreadcrumb("blog")); err != nil {
		lRun.Fatal("start blog err: %w", err)
		return fmt.Errorf("start blog err: %w", err)
	}
	// - web
	// err = web.Init(nc, l.WithBreadcrumb("web"))
	// if err != nil {
	// 	l.Fatal(fmt.Sprintf(" to init web: %e", err))
	// 	ns.Shutdown()
	// 	return
	// }
	// go cnc.Tick(nc, l.WithBreadcrumb("tick"))

	talk.WaitForShutdown()
	return nil
}
