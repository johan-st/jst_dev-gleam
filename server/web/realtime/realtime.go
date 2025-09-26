package realtime

import (
	"context"
	"jst_dev/server/articles"
	"jst_dev/server/convo"
	"jst_dev/server/core"
	"jst_dev/server/jst_log"
	"jst_dev/server/urlShort"
	"jst_dev/server/who"

	"github.com/nats-io/nats.go"
)

type Realtime struct {
	l              *jst_log.Logger
	nc             *nats.Conn
	allowedOrigins []string

	// Repos
	repoUsers      core.Repo[who.UserRepoValue]
	repoArticles   core.Repo[articles.Article]
	repoShortUrls  core.Repo[urlShort.ShortUrlRepoValue]
	repoConvoRooms core.Repo[convo.RoomRepoValue]
	// repoMessages   core.RepoAppendOnly[convo.]
}

func NewRealtime(ctx context.Context, l *jst_log.Logger, nc *nats.Conn) *Realtime {

	return &Realtime{nc: nc}
}
