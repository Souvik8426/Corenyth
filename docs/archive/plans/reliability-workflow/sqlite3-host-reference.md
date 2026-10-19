# Parent-verified host SQLite hook reference

Source inspected locally: sqlite3-3.7.1/doc/hook.md and hook/build.dart in the installed pub cache. This is a task summary, not an assumption that the system library supports FTS4.

The package's bundled binaries enable FTS5, but do not list FTS4. The installed hook supports `hooks.user_defines.sqlite3.source` with per-operating-system mappings. `system` loads the OS library; `sqlite3` selects the normal bundled binary. A host-only candidate configuration is:

```yaml
hooks:
  user_defines:
    sqlite3:
      source:
        macos: system
        default: sqlite3
```

`name` also supports a platform map if an explicit system library path is needed. Do not modify dependency cache binaries. No new dependency/version is necessary for this hook. Android's production sqflite path must retain its behavior.

Verify actual Dart runtime support and run production memory SQL against a fresh real schema. Successful Python sqlite3 queries do not establish Dart FFI capability. Capture native runtime version/compile options, actual FTS4 creation/search/update/delete and relevant prompt integration tests. If unsupported, report the exact blocker; never fake FTS results or silently skip mandatory retrieval checks.
