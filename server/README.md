---
title: Server README
---

## Development Status

### Current Focus
- [ ] Clean up architecture from superfluous code and logic
- [ ] Implement optimistic updates (with visual feedback in UI)
- [ ] Disconnect local logging from NATS for better development experience

### Completed
- [x] NATS global supercluster integration
- [x] JWT/NKEY authentication (replaced .creds file)

### `v0` - Core Features

- [ ] Fix article editing functionality
- [ ] Clean up and secure API endpoints
- [ ] Implement proper auth and permissions on API endpoints
- [ ] Ensure slug uniqueness validation on updates
- [ ] Handle deleted article history visibility for authenticated users

#### Completed
- [x] Initial admin user seeding via environment configuration
  - Use: `cat usersCreate.json | nats req svc.who.users.create`

### `v0.1` - Enhanced Features

- [ ] Preserve draft state during article updates
- [ ] Add comprehensive testing for critical functionality
  - [ ] Create testdata JSON files for NATS CLI testing
  - [ ] Build development data seeding scripts
- [ ] Add "New Article" button to UI
- [ ] Implement publish/unpublish functionality
- [ ] Add article delete button
- [ ] Add article history button
- [ ] Refactor `whoApi`/`who/api` for better intuitiveness


### `later`

- [ ] do not store rev in kv value. It can cause confusion as we should rely on the nats kv revision number.
- [ ] do not store id in kv value. It can cause confusion as we should rely on the nats kv key.
- [ ] revisions increese globally. We should have one per article as well and use the global one to ensure we are not overwritting changes.
- [ ] implement authorization on a per article basis.
- [ ] admin panel
- [ ] json files for cli nats requests **(in progress)**
- [ ] preload data on mobile (not just on hover)
- [ ] one go-routine per connected client
  - [ ] isolate it

### Bug

- [ ] Initial load on a missing article results in the article metadata not being put into the model.. repro: reload on a missing article. go to article listing. It should show "loading...".
- [ ] /static/ does not handle redirects propperly
- [ ] "USER_NOT_FOUND" results in a 500 from http handler. It expects json..

## Bechmarking

```sh
# Benchmarking the talk package (nats basically)
server > go test -benchmem -bench . jst_dev/server/talk
    goos: windows
    goarch: amd64
    pkg: jst_dev/server/talk
    cpu: Intel(R) Core(TM) Ultra 7 155H
    BenchmarkMessagingInProcess-22    42262    24624 ns/op    1649 B/op    29 allocs/op
    BenchmarkMessagingLoopback-22     16885    61609 ns/op    1396 B/op    25 allocs/op
    PASS
    ok      jst_dev/server/talk     3.421s
```
