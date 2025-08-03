# AGENTS.md - Guidelines for Agentic Coding

## Build/Test Commands
- **Go Server**:
  - Build: `go build ./server`
  - Run tests: `go test ./server/...`
  - Run single test: `go test ./server/path/to/package -run TestName`
  - Benchmark: `go test -bench=. ./server/path/to/package`
  - Lint: `cd server && golangci-lint run`
  - Check: ``

- **Gleam Frontend**:
  - Build: `gleam build`
  - Run tests: `gleam test`
  - Run single test: `gleam test -m test_name_test`

## Code Style Guidelines

### Go
- Use error handling with explicit returns (`if err != nil { return err }`)
- Follow standard Go naming: CamelCase for exported, camelCase for private
- Group imports: standard lib, then third-party, then local packages
- Use context for cancellation and timeouts
- Format code with `gofmt -s` and `goimports -local jst_dev/server`
- Avoid unnecessary whitespace (leading/trailing newlines)

### Gleam
- Use snake_case for function and variable names
- Use PascalCase for type names and constructors
- Pattern matching for error handling
- Explicit type annotations for public functions
- Organize imports alphabetically

### General
- Write comprehensive tests for new functionality
- Document public APIs with comments
- Keep functions small and focused
- Use descriptive variable names