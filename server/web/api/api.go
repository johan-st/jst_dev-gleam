package api

var Subj = struct {
	// routes
	RouteGroup    string
	RouteInfo     string
	RouteRegister string
	RouteRemove   string
	// assets
	AssetGroup  string
	AssetInfo   string
	AssetFind   string
	AssetAdd    string
	AssetDelete string
}{
	// routes
	RouteGroup:    "svc.web.routes",
	RouteInfo:     "info",
	RouteRegister: "register",
	RouteRemove:   "remove",
	// assets
	AssetGroup:  "svc.web.assets",
	AssetInfo:   "info",
	AssetFind:   "find",
	AssetAdd:    "add",
	AssetDelete: "delete",
}

type RouteRegReq struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

