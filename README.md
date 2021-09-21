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

