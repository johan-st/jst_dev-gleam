ARG GO_VERSION=1
FROM golang:${GO_VERSION}-bookworm AS builder

WORKDIR /usr/src/app
COPY server/go.mod server/go.sum ./
RUN go mod download && go mod verify
COPY ./server .
RUN go build -v -o /run-app .


FROM gcr.io/distroless/base-debian12 AS runner

COPY --from=builder /run-app /usr/local/bin/
ENTRYPOINT ["run-app"]
