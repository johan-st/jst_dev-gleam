---
title: Server README
---

## Bechmarking

```sh
# Benchmarking the talk package (nats basically)
server > go test -benchmem -bench . jst_dev/server/talk

# Output
goos: windows
goarch: amd64
pkg: jst_dev/server/talk
cpu: Intel(R) Core(TM) Ultra 7 155H
BenchmarkMessagingInProcess-22             42262             24624 ns/op            1649 B/op             29 allocs/op
BenchmarkMessagingLoopback-22              16885             61609 ns/op            1396 B/op             25 allocs/op
PASS
ok      jst_dev/server/talk     3.421s
```

