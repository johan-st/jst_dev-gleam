ARG GO_VERSION=1
ARG GLEAM_VERSION=1.11.0

# GLEAM ------------------------------------------------------------------------

FROM ghcr.io/gleam-lang/gleam:v${GLEAM_VERSION}-erlang-alpine AS builder_gleam

WORKDIR /usr/src/app
COPY jst_lustre ./jst_lustre
WORKDIR /usr/src/app/jst_lustre
RUN apk add --no-cache nodejs npm
RUN gleam test
RUN gleam run -m lustre/dev build --minify --tailwind-entry=./src/styles.css --outdir=../build

# GO ----------------------------------------------------------------------------
    
FROM golang:${GO_VERSION}-bookworm AS builder_go
    
WORKDIR /usr/src/app
COPY server/go.mod server/go.sum ./
RUN go mod download && go mod verify
COPY ./server .
COPY --from=builder_gleam /usr/src/app/build ./web/static
RUN go test ./...
RUN go build -v -o /run-app .

# RUNNER ------------------------------------------------------------------------

FROM gcr.io/distroless/base-debian12 AS runner
COPY --from=builder_go /run-app /usr/local/bin/
ENTRYPOINT ["run-app"]
