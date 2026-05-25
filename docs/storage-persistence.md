# Storage Persistence And Concurrent Writes

## Summary

Astrolabe persists `@Storage` values and `AstrolabeUtils.StorageClient` values in:

```text
/Library/Application Support/Astrolabe/storage.json
```

This file is shared by the main Astrolabe daemon, the updater process, CLI commands, and consumer code that imports `AstrolabeUtils`.

Astrolabe previously used whole-file read-modify-write persistence without a shared write coordinator. That could lose keys when multiple writers touched `storage.json` at the same time.

## The Bug

The issue was first visible through GitGate checksum tracking in `macrocosm-astrolabe`.

GitGate stores package checksums under keys like:

```text
gitgate/photon-hq/macrocosm-route
```

`GitGate.isInstalled()` treats a missing checksum key as "not installed" or "drifted", because it cannot prove that the installed binary matches the expected release.

Astrolabe can run same-priority package installs in parallel. If two package installs wrote checksums concurrently, this sequence was possible:

1. Package A read `storage.json`.
2. Package B read the same older snapshot.
3. Package A wrote its checksum key.
4. Package B wrote its older snapshot plus its own checksum key.
5. Package A's checksum key disappeared.

On the next loop, GitGate saw the missing checksum and remediated the package even though the package binary had not changed.

The updater process could create the same class of bug because it also writes status fields into `storage.json` through `StorageStore`. A stale in-memory `StorageStore` snapshot could overwrite newer keys written externally by `StorageClient`.

## Root Cause

The root cause was Astrolabe's storage layer, not the package being remediated.

The previous implementation had two unsafe patterns:

1. `StorageClient.write()` and `StorageClient.remove()` did read-modify-write of the entire JSON file with no shared lock.
2. `StorageStore` persisted its full in-memory snapshot, which could be older than the current file on disk.

The log message from package reconciliation is generic. A message like:

```text
pkg:photon-hq/macrocosm-route not installed, reinstalling...
```

means the package provider returned `false` from `isInstalled()`. It does not necessarily mean the binary or package receipt is missing.

## Resolution

Astrolabe now coordinates all `storage.json` access through `StorageFileCoordinator` in `AstrolabeUtils`.

The coordinator provides:

1. An in-process `NSLock`, so concurrent tasks inside the same daemon serialize storage access.
2. A cross-process advisory lock using `fcntl` on:

```text
/Library/Application Support/Astrolabe/storage.json.lock
```

3. Atomic replacement when writing `storage.json`.
4. Read-modify-write mutation performed while the lock is held.

`StorageStore` now persists only the changed key by merging into the latest on-disk snapshot under the same coordinator. It no longer writes its stale in-memory snapshot over unrelated keys.

## Current Behavior

`StorageClient.write(key:value:)` now:

1. Encodes the value.
2. Acquires the process-local lock.
3. Acquires the file lock.
4. Reads the latest `storage.json`.
5. Mutates only the requested key.
6. Writes the updated JSON atomically.
7. Releases both locks.

`StorageClient.remove(_:)` follows the same path and only writes when the key existed.

`StorageStore.set(_:value:)` still updates the daemon's in-memory state first, but disk persistence is now a locked merge with the latest file contents. If another process wrote a different key first, that key is preserved.

Reads also go through the file coordinator. Shared reads may run concurrently across processes, while writes are exclusive.

## Operational Notes

The lock file is expected and should not be deleted during normal operation:

```text
/Library/Application Support/Astrolabe/storage.json.lock
```

The fix does not require user interaction. It uses normal filesystem operations only:

1. `open` to create or access the lock file.
2. `fcntl` advisory locks.
3. Atomic file replacement for `storage.json`.

It does not invoke `sudo`, Authorization Services, Keychain prompts, GUI prompts, Touch ID, or biometric approval flows.

## Guidance For Consumers

Consumers can keep using `StorageClient` for small pieces of shared state such as GitGate checksum keys.

Avoid writing `storage.json` directly. Direct writes bypass the coordinator and can reintroduce lost-update behavior.

If a consumer needs to update multiple storage keys as one logical operation, add an Astrolabe API that performs the full mutation under `StorageFileCoordinator` instead of issuing separate direct file writes.
