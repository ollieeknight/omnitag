# Development

## Two front doors, one source of truth

`Package.swift` defines every module and test target. `project.yml` adds only the
macOS **app bundle** wrapper Xcode needs for ⌘R and SwiftUI Previews.
`OmniTag.xcodeproj` is generated from it and is **gitignored** — never edit the
project file by hand, and never add sources to it that are not in the package.

```sh
make xcode     # xcodegen generate + open OmniTag.xcodeproj
make xcbuild   # build the app target as Xcode does (xcbeautify output)
make xctest    # run the suite through the Xcode scheme
```

Regenerating is safe and idempotent: `xcodegen generate` after any change to
`project.yml` or after adding a module to `Package.swift`.

## Command line

```sh
make test      # swift test — the fast loop, 242 tests, ~1s
make run       # swift run OmniTagApp
make app       # assemble .build/OmniTag.app (ad-hoc signed)
make install   # symlink that bundle into /Applications
make lint      # warnings-as-errors build
make clean
```

## Testing against real media

The synthetic Twin Peaks fixtures cover the parsers; the developer's own files
cover reality. Point the suite at them:

```sh
OMNITAG_REAL_MEDIA=~/Desktop/tp make test
```

In Xcode: edit the OmniTag scheme → Test → Arguments → enable the
`OMNITAG_REAL_MEDIA` environment variable (already defined, disabled by default)
and set the path.

Those tests skip themselves when the variable is unset, so the suite is green on
a machine with no media. **Never write to that folder in a test** — copy a file
to a temp directory first.

## Xcode specifics

- Scheme `OmniTag` runs the app and all test targets (`MediaCoreTests`, `TagIOTests`, `EditEngineTests`, `MetadataAPITests`), with coverage on.
- Previews work on views in `Sources/OmniTagApp`. Views live in the app target,
  not in a package module, precisely so Previews are available.
- Strict concurrency is set to `complete`. A data-race warning is a bug report,
  not noise to silence.
- Signing is ad-hoc (`CODE_SIGN_IDENTITY: "-"`). See `DISTRIBUTION.md` for why
  that is enough for a Homebrew formula and not enough for a cask.

## XcodeBuildMCP

The `XcodeBuildMCP` server gives an agent direct build/run/test tools. The entry
in `~/.claude.json` for this directory was malformed (`command: "--env"`, which
produced `ENOENT: Executable not found in $PATH: --env`) and has been fixed to:

```json
{ "type": "stdio", "command": "npx", "args": ["-y", "xcodebuildmcp@latest"],
  "env": { "INCREMENTAL_BUILDS_ENABLED": "true", "XCODEBUILDMCP_DYNAMIC_TOOLS": "true" } }
```

It connects on the **next** session start, not this one. A backup of the original
config sits beside it as `~/.claude.json.bak-<timestamp>`. If the server still
fails, the `make xcbuild` / `make xctest` targets do the same job through the CLI
and are what the agent should fall back to — never claim the MCP is unavailable
without checking whether the CLI path works.

## Formatting

`swiftformat` and `swiftlint` are installed on this machine but **not** wired
into the build, and there is no config in the repo. Match the surrounding style
by hand. If you want them enforced, add the config and a `make format` target in
one commit — do not reformat the codebase as a side effect of another change.
