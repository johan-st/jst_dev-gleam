---
title: Server README
---

## TODOs

- [ ] json files for cli nats requests **(in progress)**
- [ ] have local logging be disconnected from nats
- [ ] make a version that works with the nats global supercluster
- [ ] clean up architecture from superflous code and logic
- [ ] admin panel
- [ ] updates to an article should not reset the draft.
- [ ] implement optimistic updates (with visual feedback in UI)
- [ ] Use exteranl NATS cluster for production. Local could be a leaf node or just for local development.
- [ ] (!) Reevaluate including the .creds file.

### `v0`

- [ ] fix editing of articles
- [ ] seed initial admin somehow (from environment?)
- [ ] clean up and protect api endpoints
- [ ] check auth and permissions on api endpoints
- [ ] fail creation if slug is not unique (alt. create with id as slug)
- [ ] after delete, we can still access the article history (revisions). Should we show deleted articles to logged in users?

### `v0.1`

- [ ] build some tests for critical functionality
  - [ ] testdata should be populated from a series of json files in the testdata directory that are to be used with the nats cli. We could then have a script that requests each service to create the data we want for local development.
- [ ] add "new" article button
- [ ] support publish/unpublish
- [ ] add a "delete" button
- [ ] add a "history" button

### `later`

- [ ] do not store rev in kv value. It can cause confusion as we should rely on the nats kv revision number.
- [ ] do not store id in kv value. It can cause confusion as we should rely on the nats kv key.
- [ ] revisions increese globally. We should have one per article as well and use the global one to ensure we are not overwritting changes.
- [ ] implement authorization on a per article basis.

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
