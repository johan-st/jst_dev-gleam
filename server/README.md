---
title: Server README
---

## TODOs

- [ ] json files for cli nats requests **(in progress)**
- [ ] have local logging be disconnected from nats
- [ ] make a version that works with the nats global supercluster
- [ ] clean up architecture from superflous code and logic
- [ ] admin panel 

### `v0`

- [ ] fix editing of articles
- [ ] seed initial admin somehow (from environment?)
- [ ] clean up and protect api endpoints
- [ ] check auth and permissions on api endpoints

### `v0.1`

- [ ] build some tests for critical functionality
  - [ ] testdata should be populated from a series of json files in the testdata directory that are to be used with the nats cli. We could then have a script that requests each service to create the data we want for local development.
- [ ] add "new" article button
- [ ] support publish/unpublish

### `later`

## Bechmarking

```sh
# Benchmarking the talk package (nats basically)
server > go test -benchmem -bench . jst_dev/server/talk
```
    goos: windows
    goarch: amd64
    pkg: jst_dev/server/talk
    cpu: Intel(R) Core(TM) Ultra 7 155H
    BenchmarkMessagingInProcess-22    42262    24624 ns/op    1649 B/op    29 allocs/op
    BenchmarkMessagingLoopback-22     16885    61609 ns/op    1396 B/op    25 allocs/op
    PASS
    ok      jst_dev/server/talk     3.421s

