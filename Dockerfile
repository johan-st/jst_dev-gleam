ARG GO_VERSION=1
FROM golang:${GO_VERSION}-bookworm AS builder

WORKDIR /usr/src/app
COPY server/go.mod server/go.sum ./
RUN go mod download && go mod verify
COPY ./server .
RUN go build -v -o /run-app .


FROM debian:bookworm AS runner

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /run-app /usr/local/bin/
CMD ["run-app"]
