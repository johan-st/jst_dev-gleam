---
title: Web README
---

## NOTES

- routes can just live in the kv.. no need for a service.
  - I see no need to put a service in front of the routes as all information needed can be put into the kv.
  - If accessing it in a consistent way turns out to be a problem, we should have a package that provides some convenience functions.
- Assets are another story. Here we need to match paths to hashes but it should be enough to have a importable package here as well. 

