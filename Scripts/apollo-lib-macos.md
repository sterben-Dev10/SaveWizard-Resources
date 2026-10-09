<a id="apollo-lib-compiler-for-macos"></a>

# 🧱 Apollo-lib Compiler for macOS

The [`apollo-lib-macos.zsh`](apollo-lib-macos.zsh) wrapper builds Universal2 (`x86_64` + `arm64`) Apollo CLI tools (`patcher`, `dumper`) from [apollo-lib](https://github.com/bucanero/apollo-lib) and the desktop GUI from [apollo-patcher](https://github.com/bucanero/apollo-patcher), with a minimum deployment target of macOS 11.0. The GUI includes the [apollo-patches](https://github.com/bucanero/apollo-patches) database, font, and generated code-type icons. Upstream CMake produces `apollo_patcher_gui.app`; the wrapper installs it as `Apollo Patcher.app` by default. Full Xcode is not required: [Command Line Tools (CLT)](https://developer.apple.com/documentation/xcode/installing-the-command-line-tools/) supply Apple's build tools and SDK.

**Browse:** [⚙️ Configuration](#local-configuration) · [🧰 Toolchain](#toolchain-and-dependencies) · [🔄 Build flow](#build-flow) · [🔏 Signing](#signing-and-verification) · [📋 Output & log](#terminal-output-and-build-log) · [▶️ Usage](#usage)

## Local configuration

On its first run, the wrapper creates `apollo-lib-macos.conf` beside the script and reads it before installing tools, updating repositories, or cleaning build output. The file is ignored by Git and existing files are never overwritten. A renamed copy uses its own basename: `build-apollo-lib.zsh` reads `build-apollo-lib.conf` beside that copy.

The generated defaults are:

```ini
WORKSPACE_DIR="$HOME/Desktop/apollo"
BUILD_DIR="$HOME/Desktop/apollo/apollo_build"
STORE_PATH="$HOME/Desktop/apollo/Apollo CLI Tools"
GUI_INSTALL_DIR=/Applications
GUI_BUILD_APP_NAME=apollo_patcher_gui.app
GUI_INSTALL_APP_NAME="Apollo Patcher.app"
```

| Setting | Purpose |
| --- | --- |
| `WORKSPACE_DIR` | Parent directory for the three source checkouts. |
| `BUILD_DIR` | Shared build root for disposable `apollo-lib` and `apollo-patcher` copies. It must be outside the source checkouts. |
| `STORE_PATH` | Persistent destination for the CLI tools. Set this to another location to store the tools elsewhere without editing the script. |
| `GUI_INSTALL_DIR` | Existing writable directory where the GUI app is installed, such as `$HOME/Applications`. |
| `GUI_BUILD_APP_NAME` | Name of the bundle produced by CMake. Changing this setting does not rename CMake's output. |
| `GUI_INSTALL_APP_NAME` | Name for the installed GUI bundle. |

Edit the config to retain your choices between runs. For example, use `WORKSPACE_DIR="$HOME/Apps/Dev/apollo"` and `BUILD_DIR="$HOME/Apps/Dev/apollo/apollo_build"` to keep source checkouts and build output together under your development directory, and set `STORE_PATH="$HOME/Apps/SWTools/Apollo CLI Tools"` to choose a separate persistent CLI destination.

The config is literal `key=value` data and is never sourced or evaluated. Blank lines, whole-line `#` comments, spaces around assignments, surrounding single or double quotes, and CRLF line endings are supported. Only a leading `$HOME`, `${HOME}`, or `~/` is expanded in path settings; all paths must then be absolute. App names must be simple `.app` basenames using letters, digits, spaces, dots, underscores, or hyphens, starting with a letter or digit and without `..` or a slash. Unknown, duplicate, missing, or malformed settings fail before tool installation or repository/build changes. A nonempty caller-provided `STORE_PATH` overrides the config for that invocation only.

## Toolchain and dependencies

The wrapper accepts a caller-provided `DEVELOPER_DIR`, then checks the active `xcode-select` path, installed full Xcode, and the standard CLT directory. Apple `clang`, `clang++`, the macOS SDK, and `lipo` are resolved through the active `xcrun`.

LaunchServices registration discovers an executable `lsregister` on `PATH`, then falls back to Apple's standard system-framework location, which is the same on Intel and Apple Silicon. No Homebrew-specific path or user setting is required.

If none of those developer directories is usable, the wrapper runs `xcode-select --install` and polls until the tools become available. macOS presents Apple's installer and license flow; the user must approve it manually. The wrapper cannot silently accept that GUI/license step, but resumes automatically after installation completes.

Dependency handling is automatic. Ordinary tools resolve from `PATH` first, and existing executable `git`, `cmake`, `python3`, and `rsync` binaries are retained. Apple's `/usr/bin/rsync` is also usable when `rsync` is absent from `PATH`. The wrapper does not check tool versions or request upgrades; managing installed versions is the user's responsibility.

| Missing dependency | Automatic handling |
| --- | --- |
| `git` | Reuse an installed Homebrew formula when available; otherwise run `brew install git`. |
| `cmake` | Reuse an installed Homebrew formula when available; otherwise run `brew install cmake`. |
| `python3` | Reuse an installed Homebrew formula when available; otherwise run `brew install python`. |
| `rsync` | Use Apple's `/usr/bin/rsync` if available; otherwise reuse an installed Homebrew formula or run `brew install rsync`. |

Homebrew is bootstrapped only when a required tool and Homebrew are both missing. macOS 11.0 is the artifact target, not a promise that current Homebrew supports a macOS 11 build host; consult [Homebrew's current requirements](https://docs.brew.sh/Installation) when installing missing tools on older systems. Existing tools remain usable without Homebrew.

CLT/Xcode provides Apple Clang, `make`, the SDK, zlib, and Cocoa/OpenGL frameworks. The workflow-selected mbedTLS archive is built locally as Universal2. GUI CMake `FetchContent` downloads GLFW and Dear ImGui, so there are no separate Homebrew installs for those libraries, mbedTLS, zlib, or LLVM. GLFW and Dear ImGui are linked statically.

Git and Python are passed explicitly to GUI CMake as `GIT_EXECUTABLE` and `Python3_EXECUTABLE`, including when discovered outside `PATH`. Upstream's database and icon generators use the Python standard library and require no pip packages. This is separate from the Python save-editing scripts and their `requirements.txt`.

## Build flow

The wrapper manages three checkouts side by side under `WORKSPACE_DIR`: `apollo-lib`, `apollo-patcher`, and `apollo-patches`. By default, `$HOME/Desktop/apollo` holds these checkouts, the `apollo_build` build root, and stored CLI tools, keeping the Desktop uncluttered. The wrapper itself and its adjacent config stay wherever you placed them.

```text
$HOME/Desktop/apollo/
├── apollo-lib/                   # Library and CLI source checkout
├── apollo-patcher/               # GUI source checkout
├── apollo-patches/               # Patch database checkout
├── build.log                     # Full output, overwritten every run
├── apollo_build/
│   ├── apollo-lib/               # Disposable CLI and mbedTLS build copy
│   └── apollo-patcher/            # Disposable GUI build copy
└── Apollo CLI Tools/             # Installed patcher and dumper
```

Missing checkouts are cloned and existing Git checkouts are updated with `git pull --ff-only`. Fresh clones use GitHub SSH URLs (`git@github.com:bucanero/...`), so GitHub SSH authentication must be configured. Other network access is needed for the mbedTLS archive and GUI dependencies.

After updating the checkouts, the wrapper validates required library and GUI sources, the patch database's `PSP/gamekeys.txt` and `python` directory, and the GUI's font/license. It reads the mbedTLS version from the original library workflow before preparing `BUILD_DIR`. Original checkouts remain source-only: the wrapper never cleans or compiles in them.

### Disposable build copies

The wrapper replaces only its two managed directories, `BUILD_DIR/apollo-lib` and `BUILD_DIR/apollo-patcher`, then copies current source files with `rsync`, including local edits. Git metadata, scratch directories, old build/dist output, downloaded mbedTLS directories, object/dependency files, generated CLI binaries, and the generated GUI icon header are excluded. mbedTLS is downloaded and built in the copied library; CLI objects and executables also stay in that copy. The GUI source is copied because upstream generates `gui/src/type_icons.h` during the build. Patch source data stays in its original checkout and is read when generating the database zip.

Before deleting either managed directory, cleanup validates both. The wrapper rejects build paths inside source checkouts or whose managed children contain a source checkout, refuses symlink children, and requires its exact ownership marker before replacing an existing child directory. Fresh copies are marked before copying starts, so an interrupted copy can be replaced on the next run. Other `BUILD_DIR` contents are retained, and `BUILD_DIR` itself is never removed. Use a new empty build location if existing child directories are unrecognized; the wrapper refuses to delete them.

### GUI build and required resources

GUI configuration uses `BUILD_DIR/apollo-patcher` as its source root and `BUILD_DIR/apollo-patcher/build` as its CMake build directory, with `-DAPOLLO_ROOT` pointing to `BUILD_DIR/apollo-lib` and `-DAPOLLO_PATCHES` pointing to the original patch-data checkout. The full default `cmake --build` builds the app and resource targets, including `apollo-patches.zip`, the desktop font, and generated code-type icons.

The resulting bundle is `BUILD_DIR/apollo-patcher/build/gui/apollo_patcher_gui.app`. Before signing or installing it, the wrapper requires the GUI executable and `Contents/Resources/apollo-patches.zip`, `NotoSansJP-Medium.otf`, and `OFL.txt`.

Upstream code may emit legacy mbedTLS CMake compatibility/policy warnings and Apple OpenGL deprecation warnings. The wrapper keeps the full warnings in `WORKSPACE_DIR/build.log` while showing concise progress in the terminal. Source and syntax checks of the wrapper do not establish a successful build or GUI runtime on your host.

### Artifacts

| Artifact | Default destination | Notes |
| --- | --- | --- |
| `BUILD_DIR/apollo-lib/tools/patcher` and `dumper` | `$HOME/Desktop/apollo/Apollo CLI Tools` | Configure `STORE_PATH` persistently, or override it for one invocation. |
| `BUILD_DIR/apollo-patcher/build/gui/apollo_patcher_gui.app` | `/Applications/Apollo Patcher.app` | Configure `GUI_INSTALL_DIR` and `GUI_INSTALL_APP_NAME`; `STORE_PATH` controls only the CLI. |

## Signing and verification

The wrapper ad-hoc signs artifacts with `codesign --force --sign -` without `--deep`, signing the completed GUI bundle with its resources. CLI signatures are verified strictly, and built and stored CLI artifacts are checked for both Universal2 slices with `lipo`.

The built GUI bundle is signed and verified before installation, so its build copy is ready for manual installation. The wrapper stages a copy on the destination filesystem and verifies it before replacing the installed app. A successful run replaces the whole destination bundle; files from the old bundle are not merged into the new one. It overwrites both stored CLI files, `patcher` and `dumper`, and retains the source app bundle in the build folder. There are no GUI backups or rollback.

If the GUI destination is not writable, or another GUI copy/install check fails, the wrapper warns, prints the exact signed and verified source `.app` path for manual Finder copying, and continues with CLI installation. It does not request `sudo`. Build failures or failure to sign/verify the built app remain fatal. After installing and verifying the GUI, the wrapper removes its staging directory and force-registers the installed bundle with LaunchServices using `lsregister -f`. Registration failure produces a separate warning and retains the verified installed app while CLI installation continues. `pluginkit` is not involved because this is a normal app with no embedded extension or plugin.

After GUI promotion to the configured destination, the wrapper applies `chmod 755` to the executable, recursively removes `com.apple.quarantine`, verifies both Universal2 slices with `lipo`, and verifies the bundle signature with `codesign --verify --deep --strict` before LaunchServices registration.

Both built and installed CLI files, and the built, staged, and installed GUI executable under `Contents/MacOS`, receive mode `755`. App directory access permissions are preserved when copying; ordinary resource files are not made executable.

Interrupting with Ctrl-C (SIGINT) or SIGTERM stops further installation with exit status 130 or 143. Once the foreground command has stopped, the wrapper rechecks ownership and path safety before removing its two partial build copies. Source checkouts, unrelated build-root contents, the log, and installed files are preserved. If the CLI tools and built GUI have already completed signing and verification, those ready outputs are retained for manual copying instead. Any active temporary GUI staging directory is removed; no rollback is performed.

Cleanup refusal or failure produces a warning and preserves the cancellation exit status. Ordinary build failures retain their diagnostics and partial build files for inspection.

## Terminal output and build log

The terminal shows a banner and eight numbered sections, with `→` for starting a step, `✓` for success, and `✗` for failure. Colors appear only on a real terminal and are disabled by `NO_COLOR` or `TERM=dumb`. Redirected output has no ANSI colors or animated redraws. Long commands show their action before running and elapsed time when at least one second passes.

Selected noninteractive long steps (CMake, make, and mbedTLS extraction) show a rotating Braille spinner beside `Working`, cycling through `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏` with one frame every 0.1 seconds. This uses the existing shell helper and needs no extra dependency. The animated line is cleared before the result. Animation is disabled for redirected output and `TERM=dumb`; `NO_COLOR` disables colors while retaining animation. Git and interactive installers do not animate. Build commands and their input stay in the foreground, and the display helper is stopped and reaped on completion or cancellation.

After config validation, each invocation creates or truncates the single `WORKSPACE_DIR/build.log`. Existing logs are overwritten; new logs are private to the current user. Symlink and non-regular log targets are refused. Full raw build/configure/extract/Git/signing output, including warnings, is appended directly to this file while commands run, so it can be followed with `tail -f`. Interactive Apple CLT and Homebrew bootstrap installer output remains live on the terminal to keep prompts visible. A separately saved log, such as `log.txt`, is not touched.

On a failed command, the terminal shows the named step, its exit status, and a bounded excerpt from that command's log segment. Recognized compiler, CMake, or linker errors include useful context; unknown errors show a short tail. The complete output remains in `build.log`. GUI installation and registration warnings follow the nonfatal behavior described above. The final summary reports the actual GUI result, the CLI destination, and the raw log path.

Illustrative abbreviated successful output (not a captured build):

```text
+----------------------------------------------------------------+
|  👾 Apollo macOS · Universal2 CLI + GUI                          |
+----------------------------------------------------------------+

  [1/8] 🧰  Configuration & tools
  ✓ Configuration validated
  ✓ Apple developer tools ready
  [2/8] 🔄  Source repositories
  → Update apollo-lib (fast-forward only)
  ✓ Update apollo-lib (fast-forward only)
  [3/8] 📁  Disposable build workspace
  [4/8] 🧱  mbedTLS
  → Build Universal2 mbedcrypto
  ✓ Build Universal2 mbedcrypto (12s)
  [5/8] 🔧  CLI build, signing & verification
  [6/8] 💻  GUI build & bundled database
  [7/8] 🔏  GUI signing, installation & registration
  ✓ GUI installed, verified and registered
  [8/8] 📦  CLI installation
  ✓ Apollo build and installation complete
  GUI: /Applications/Apollo Patcher.app
  CLI: $HOME/Desktop/apollo/Apollo CLI Tools
  Log: $HOME/Desktop/apollo/build.log
```

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
