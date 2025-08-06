# GLEAM ------------------------------------------------------------------------

FROM ghcr.io/gleam-lang/gleam:v1.11.0-erlang-alpine AS builder_gleam

WORKDIR /usr/src/app
COPY jst_lustre ./jst_lustre
WORKDIR /usr/src/app/jst_lustre
RUN apk add --no-cache nodejs npm
RUN gleam test
RUN gleam run -m lustre/dev build --minify --tailwind-entry=./src/styles.css --outdir=../build

# GO ----------------------------------------------------------------------------
    
FROM golang:1.23.3-alpine AS builder_go
    
WORKDIR /usr/src/app
COPY server/go.mod server/go.sum ./
RUN go mod download -x || (sleep 5 && go mod download -x) || (sleep 10 && go mod download -x) && \
    go mod verify 

# Install linting tools
RUN go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
RUN go install github.com/securego/gosec/v2/cmd/gosec@latest
RUN go install honnef.co/go/tools/cmd/staticcheck@latest

# copy server code
COPY ./server .

# Run code quality checks
# RUN golangci-lint run --timeout=5m
# RUN gosec ./...
# RUN staticcheck ./...
# RUN go vet ./...
# RUN go test -race ./...

# Add frontend code
COPY --from=builder_gleam /usr/src/app/build ./web/static

RUN go build -v -o /run-app .

# RUNNER ------------------------------------------------------------------------

FROM gcr.io/distroless/base-debian12 AS runner
COPY --from=builder_go /run-app /usr/local/bin/
ENTRYPOINT ["run-app"]
