ARG GLEAM_VERSION=v1.5.1

# Node builder
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-node-alpine AS node

# Add client dependencies
COPY ./client/package.json /build/client/package.json
COPY ./client/package-lock.json /build/client/package-lock.json
WORKDIR /build/client
RUN npm ci

# Build the client code
COPY ./common /build/common
COPY ./client /build/client
COPY ./server /build/server
RUN gleam --version
RUN rm -rf /build/client/build
RUN npm run build

# Erlang builder
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine AS erlang
COPY --from=node /build/server /build/server

# Build the server code
WORKDIR /build/server
RUN gleam --version
RUN gleam export erlang-shipment

# Start from a clean slate
# FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang
FROM ghcr.io/gleam-lang/gleam:${GLEAM_VERSION}-erlang-alpine
EXPOSE 8000
# Copy the compiled server code from the builder stage
COPY --from=erlang /build/server/build/erlang-shipment /app

# Run the server
WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["run"]