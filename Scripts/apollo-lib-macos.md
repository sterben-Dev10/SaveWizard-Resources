# Apollo-lib Compiler for macOS

The [`apollo-lib-macos.zsh`](apollo-lib-macos.zsh) wrapper builds Universal2 (`x86_64` + `arm64`) Apollo CLI tools (`patcher`, `dumper`) and the macOS GUI app (`apollo_patcher_gui.app`) for macOS 11.0 or later. Full Xcode is not required: Command Line Tools (CLT) are enough for Apollo and Homebrew.

## Toolchain and dependencies

The wrapper accepts a caller-provided `DEVELOPER_DIR`, then checks the active `xcode-select` path, installed full Xcode, and the standard CLT directory. Apple `clang`, `clang++`, the macOS SDK, and `lipo` are resolved through the active `xcrun`.

If none of those developer directories is usable, the wrapper runs `xcode-select --install` and polls until the tools become available. macOS presents Apple’s installer and license flow; the user must approve it manually. The wrapper cannot silently accept that GUI/license step, but it resumes automatically after the installation completes.

Ordinary `git`, `cmake`, `make`, `curl`, and `tar` commands resolve from `PATH` first. Homebrew is used or installed only when CMake is missing. The macOS SDK supplies zlib and the system Cocoa/OpenGL frameworks; GUI CMake `FetchContent` downloads GLFW and Dear ImGui, so network access and Git are required, with no separate Homebrew GUI dependencies.

## Build flow

Each fresh run clones or pulls the latest `apollo-lib` source, reads the workflow-selected mbedTLS version, and downloads that archive. It then cleans and rebuilds mbedTLS, CLI objects and binaries, and the GUI `build`/`dist` output before building the GUI.

| Artifact | Destination | Notes |
| --- | --- | --- |
| `patcher`, `dumper` | `~/Desktop/Apollo CLI Tools` by default | Set `STORE_PATH` for a per-invocation CLI destination. |
| `apollo_patcher_gui.app` | `/Applications/apollo_patcher_gui.app` | Fixed location; `STORE_PATH` never controls the GUI. |

The GUI bundle is staged and verified before promotion. If an existing app is present, it is backed up during replacement and restored if promotion or final verification fails.

## Signing and verification

The wrapper applies `chmod 755` to executables, recursively removes `com.apple.quarantine`, and ad-hoc signs artifacts with `codesign --force --sign -` without `--deep`. CLI signatures are verified strictly; GUI bundle signatures are verified with `--deep --strict`. Built and stored artifacts are checked for both Universal2 slices with `lipo`.

## Usage

From the `Scripts` directory, make the wrapper executable and run it:

```zsh
chmod 755 apollo-lib-macos.zsh
./apollo-lib-macos.zsh
```

To choose another CLI destination for one invocation:

```zsh
STORE_PATH="/path/to/Apollo CLI Tools" ./apollo-lib-macos.zsh
```

`patcher` selects endianness at runtime with `-b`/`--big-endian`; the build does not produce a separate `patcher-bigendian` executable.
