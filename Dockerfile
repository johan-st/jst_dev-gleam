# GLEAM FRONTEND ---------------------------------------------------------------

FROM ghcr.io/gleam-lang/gleam:v1.11.0-erlang-alpine AS builder_frontend

WORKDIR /usr/src/app
COPY shared ./shared
COPY client ./client

WORKDIR /usr/src/app/client
RUN apk add --no-cache nodejs npm
RUN gleam deps download
RUN gleam test
RUN gleam run -m lustre/dev build --minify --outdir=../build

# GLEAM BACKEND ----------------------------------------------------------------

FROM ghcr.io/gleam-lang/gleam:v1.11.0-erlang-alpine AS builder_backend

WORKDIR /usr/src/app
COPY shared ./shared
COPY server ./server

WORKDIR /usr/src/app/server
RUN gleam deps download
RUN gleam build

# Create release
RUN gleam export erlang-shipment

# RUNNER -----------------------------------------------------------------------

FROM alpine:3.20 AS runner

# Install runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    fuse3 \
    sqlite \
    bash \
    curl

# Install LiteFS
COPY --from=flyio/litefs:0.5 /usr/local/bin/litefs /usr/local/bin/litefs

WORKDIR /app

# Copy backend release
COPY --from=builder_backend /usr/src/app/server/build/erlang-shipment ./

# Copy frontend assets (index.html + built JS/CSS)
COPY --from=builder_frontend /usr/src/app/build ./priv/static
COPY --from=builder_frontend /usr/src/app/client/index.html ./priv/static/

# Copy LiteFS configuration
COPY litefs.yml /etc/litefs.yml

# Create data directory
RUN mkdir -p /data /litefs

# Expose port
EXPOSE 8080

# Start via LiteFS
ENTRYPOINT ["litefs", "mount"]
