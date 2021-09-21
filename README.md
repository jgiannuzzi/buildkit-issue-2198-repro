# Repro for Buildkit issues [#2198](https://github.com/moby/buildkit/issues/2198) and [#1980](https://github.com/moby/buildkit/issues/1980)

This repository is based on work by [Matt Bentley](https://github.com/mbentley) and [Patrick Remy](https://github.com/Patrick-Remy) to reproduce a bug in Buildkit that can cause some layers to be missing in the final image. See [Patrick's original repo](https://github.com/Patrick-Remy/buildkit-missing-layer-repro).

## Bug description

This bug happens when exporting a cache with removal of empty layers (as introduced in [PR #1739](https://github.com/moby/buildkit/pull/1739) that made it first in v0.8.0).
In certain conditions, importing this cache can result in the creation of an image with some layers missing.

## How to reproduce

Clone this repository and run `./test.sh`.

The script will try to reproduce the issue by:
- Building a container image and exporting the cache
- Running a loop in which it will:
  - Reset the `buildkitd` cache every few attempts
  - Import the cache and build the same container image as a tarball
  - Validate that tarball contains the expected layers and stop if it doesn't
- Cleanup all containers, volumes, directories and files that got created

In addition, the script will start two local registries: one just to avoid re-downloading the same `alpine` image over and over, and the other to export and import the cache.

A few environment variables can be used to tweak the script's behaviour:
- `BUILDKIT_IMAGE` can be set to a different Buildkit image. It defaults to `moby/buildkit:v0.9.0-rootless` (the latest stable release at the time of writing).
- `RETRIES` controls the total amount of retries. It defaults to 20 tries, which is usually enough to reproduce the issue.
- `CACHE_RESET_FREQ` controls the `buildkitd` cache reset frequency. It defaults to every 4 tries.
- `NO_CLEANUP` can be set to any value to prevent the script from cleaning up anything when it exits.
- `USE_LOCAL_CACHE` can be set to any value to make the script export the cache in a local directory instead of a registry.
- `SKIP_CREATE_CACHE` can be used to skip the cache creation step.
- `SKIP_TESTS` can be used to skip the tests altogether.

## Why is this broken?

Let's take a look at the `Dockerfile` provided in this repository:
```Dockerfile
FROM alpine:latest

# create a layer (empty or not)
RUN echo 1

# create a layer that also depends on the context
COPY repro.txt /

# create an empty layer
RUN echo 2
```

When importing the cache of a run that has empty layers removed, some vertexes will point to the same result, e.g. `COPY repro.txt /` and `RUN echo 2`.

In [`cache.remotecache.v1.(*cacheResultStorage).LoadWithParents`](https://github.com/moby/buildkit/blob/v0.9.0/cache/remotecache/v1/cachestorage.go#L216), we try to load a cache result with its parents. We start by looking up the corresponding item in a map, and because there are 2 possible values, it will randomly return one or the other.

If the 'wrong' item gets used (`COPY repro.txt /` in our example), then only a partial list of results will be loaded. They get returned to [`solver.(*cacheManager).LoadWithParents`](https://github.com/moby/buildkit/blob/v0.9.0/solver/cachemanager.go#L190), which will [filter them](https://github.com/moby/buildkit/blob/v0.9.0/solver/cachemanager.go#L153) and end up with the same partial list of results.

Those will eventually be saved in the `buildkitd` cache in [`solver.(*combinedCacheManager).Load`](https://github.com/moby/buildkit/blob/v0.9.0/solver/combinedcache.go#L70), thus missing the entry for `RUN echo 2`.

During a second run with the same cache, but this time with a partially populated `buildkitd` cache, if the 'wrong' item gets used again in [`cache.remotecache.v1.(*cacheResultStorage).LoadWithParents`](https://github.com/moby/buildkit/blob/v0.9.0/cache/remotecache/v1/cachestorage.go#L216), and the partial list of results is loaded and returned to [`solver.(*cacheManager).LoadWithParents`](https://github.com/moby/buildkit/blob/v0.9.0/solver/cachemanager.go#L190), something different from the previous run might happen.

During the result filtering, results originating from both caches could be walked, and the result for `RUN echo 1` could end up being returned as the first element of the list, instead of the one for `COPY repro.txt /` or `RUN echo 2`.

Unfortunately, [`solver.(*combinedCacheManager).Load`](https://github.com/moby/buildkit/blob/v0.9.0/solver/combinedcache.go#L70) assumes that the first result is the parent and will return that one, which eventually results in an image missing a layer!

## Note on previous releases of Buildkit

This bug can also happen on previous releases of Buildkit if the imported cache has been created with v0.8.0 or higher.

Here is how to reproduce on v0.7.2 for example:

```sh
# Create a local cache with v0.9.0
USE_LOCAL_CACHE=1 NO_CLEANUP=1 SKIP_TESTS=1 ./test.sh

# Test this cache with v0.7.2
USE_LOCAL_CACHE=1 NO_CLEANUP=1 SKIP_CREATE_CACHE=1 BUILDKIT_IMAGE=moby/buildkit:v0.7.2-rootless ./test.sh
```
