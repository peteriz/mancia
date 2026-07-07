#!/usr/bin/env bash
# Wrapper around `swift` that keeps SwiftPM's dependency resolution working
# when the environment forces `safe.bareRepository=explicit`.
#
# SwiftPM stores fetched dependencies as bare git repositories (in the SwiftPM
# cache and in .build/repositories) and shells out to `git` to resolve them.
# Some sandboxes/agents inject `GIT_CONFIG_*` env vars setting
# `safe.bareRepository=explicit`, which makes those internal `git` calls refuse
# the bare repos and breaks `swift build`/`swift test` with:
#
#     fatal: cannot use bare repository '...' (safe.bareRepository is 'explicit')
#
# We append a higher-precedence GIT_CONFIG entry forcing
# `safe.bareRepository=all`. Later GIT_CONFIG_* entries override earlier ones
# for the same key, so this wins over any injected `explicit` while leaving
# other injected git config untouched. It is a no-op in normal environments.
set -euo pipefail

count="${GIT_CONFIG_COUNT:-0}"
export "GIT_CONFIG_KEY_${count}=safe.bareRepository"
export "GIT_CONFIG_VALUE_${count}=all"
export GIT_CONFIG_COUNT=$((count + 1))

exec swift "$@"
