#!/usr/bin/env bash
# Seed the local SQLite database with sample data
set -euo pipefail

DB_PATH="${DB_PATH:-./data/local.db}"

if [[ ! -f "$DB_PATH" ]]; then
  echo "Database not found at $DB_PATH"
  echo "Start the server first with 'make dev-server' to create it."
  exit 1
fi

echo "Seeding database at $DB_PATH..."

sqlite3 "$DB_PATH" <<'SQL'
-- Sample users (password is "password123" hashed with bcrypt)
INSERT OR IGNORE INTO users (id, username, password_hash, email, permissions) VALUES
  ('usr_001', 'admin', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/X4.qHOXfQVqVnpO.m', 'admin@example.com', '["admin","write"]'),
  ('usr_002', 'author', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/X4.qHOXfQVqVnpO.m', 'author@example.com', '["write"]'),
  ('usr_003', 'reader', '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/X4.qHOXfQVqVnpO.m', 'reader@example.com', '[]');

-- Sample articles
INSERT OR IGNORE INTO articles (id, slug, revision, author, tags, published_at_ms, title, subtitle, leading, content) VALUES
  ('art_001', 'getting-started-with-gleam', 1, 'admin', '["gleam","tutorial","beam"]',
   1702900800000, 'Getting Started with Gleam',
   'A practical introduction to the Gleam programming language',
   'Gleam is a type-safe functional language that runs on the BEAM VM.',
   '## Introduction

Gleam is a friendly language for building type-safe, scalable systems.

```gleam
pub fn main() {
  io.println("Hello, Gleam!")
}
```

## Why Gleam?

- Type safety without the complexity
- Runs on the battle-tested BEAM VM
- Great interop with Erlang and Elixir'),

  ('art_002', 'building-web-apps-with-lustre', 1, 'author', '["gleam","lustre","frontend"]',
   1702987200000, 'Building Web Apps with Lustre',
   'Create reactive frontends in Gleam',
   'Lustre brings the Elm architecture to Gleam for delightful frontend development.',
   '## What is Lustre?

Lustre is a framework for building web applications in Gleam.

```gleam
import lustre
import lustre/element.{text}

pub fn main() {
  lustre.simple(init, update, view)
}
```

## The Model-View-Update Pattern

Lustre uses a unidirectional data flow that makes state management predictable.'),

  ('art_003', 'sqlite-on-the-beam', 1, 'admin', '["gleam","sqlite","database"]',
   NULL, 'SQLite on the BEAM',
   'Using sqlight for persistence in Gleam applications',
   'SQLite provides a simple, reliable database for Gleam applications.',
   '## Why SQLite?

SQLite is perfect for:
- Single-node deployments
- Development and testing
- Applications with moderate write loads

```gleam
import sqlight

pub fn connect(path: String) {
  sqlight.open(path)
}
```');

-- Sample short URLs
INSERT OR IGNORE INTO short_urls (id, short_code, target_url, created_by, created_at, updated_at, access_count, is_active) VALUES
  ('url_001', 'gh', 'https://github.com', 'admin', 1702900800000, 1702900800000, 42, 1),
  ('url_002', 'gleam', 'https://gleam.run', 'admin', 1702900800000, 1702900800000, 128, 1),
  ('url_003', 'docs', 'https://hexdocs.pm/gleam_stdlib/', 'author', 1702987200000, 1702987200000, 15, 1),
  ('url_004', 'old', 'https://example.com/deprecated', 'admin', 1702900800000, 1702900800000, 5, 0);
SQL

echo "Done! Seeded:"
sqlite3 "$DB_PATH" "SELECT '  - ' || COUNT(*) || ' users' FROM users;"
sqlite3 "$DB_PATH" "SELECT '  - ' || COUNT(*) || ' articles' FROM articles;"
sqlite3 "$DB_PATH" "SELECT '  - ' || COUNT(*) || ' short_urls' FROM short_urls;"


