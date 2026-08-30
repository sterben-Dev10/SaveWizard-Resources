#!/usr/bin/env zsh

# Always run this script with zsh, even if it was launched through another shell.
if [ -z "${ZSH_VERSION:-}" ]; then
    exec /bin/zsh "$0" "$@"
fi

emulate -LR zsh
set -e
setopt pipefail

# if you want to place the compiled binaries somewhere after building
STORE_PATH="${STORE_PATH:-$HOME/Desktop/Apollo CLI Tools}"
GUI_INSTALL_DIR="/Applications"
GUI_APP_NAME="apollo_patcher_gui.app"

GIT_BIN="$(command -v git 2>/dev/null || true)"
XCODESELECT_BIN="$(command -v xcode-select 2>/dev/null || true)"
CMAKE_BIN="$(command -v cmake 2>/dev/null || true)"
MAKE_BIN="$(command -v make 2>/dev/null || true)"
CURL_BIN="$(command -v curl 2>/dev/null || true)"
TAR_BIN="$(command -v tar 2>/dev/null || true)"
BREW_BIN="$(command -v brew 2>/dev/null || true)"
XATTR_BIN="$(command -v xattr 2>/dev/null || true)"
CODESIGN_BIN="$(command -v codesign 2>/dev/null || true)"
XCRUN_BIN="$(command -v xcrun 2>/dev/null || true)"
UNIVERSAL_CMAKE_ARCHITECTURES='x86_64;arm64'
MACOS_DEPLOYMENT_TARGET='11.0'
APPLE_CLANG_BIN="${APPLE_CLANG_BIN:-}"
APPLE_CLANGPP_BIN="${APPLE_CLANGPP_BIN:-}"
LIPO_BIN="${LIPO_BIN:-}"
MACOS_SDK_PATH="${MACOS_SDK_PATH:-}"
UNIVERSAL_CC="${UNIVERSAL_CC:-}"
APOLLO_REPO_URL="git@github.com:bucanero/apollo-lib.git"
GUI_TRANSACTION_ACTIVE=false
GUI_TRANSACTION_COMMITTED=false
GUI_TRANSACTION_DESTINATION_APP=""
GUI_TRANSACTION_BACKUP_APP=""
GUI_TRANSACTION_STAGING_DIR=""
GUI_TRANSACTION_STAGED_APP=""
GUI_TRANSACTION_DESTINATION_EXISTED=false
GUI_TRANSACTION_BACKUP_CREATED=false
GUI_TRANSACTION_PROMOTED=false

MBEDTLS_VERSION=""
MBEDTLS_ARCHIVE=""
MBEDTLS_DIR=""
MBEDTLS_URL=""

# Resolve the full absolute path of the directory where the script is located
script_dir="$(cd "$(dirname "$0")" && pwd)"
apollo_repo_dir="$script_dir/apollo-lib"
repo_root=""
resolve_repo_root() {
    if [ -f "$script_dir/tools/Makefile" ]; then
        repo_root="$script_dir"
        return
    fi

    if [ ! -e "$apollo_repo_dir" ]; then
        if [ ! -x "$GIT_BIN" ]; then
            echo "Error: git is required to clone apollo-lib but was not found." >&2
            exit 1
        fi

        echo "apollo-lib repository not found, cloning fresh copy..."
        "$GIT_BIN" clone "$APOLLO_REPO_URL" "$apollo_repo_dir"
        repo_root="$(cd "$apollo_repo_dir" && pwd)"
        return
    fi

    if [ -f "$apollo_repo_dir/tools/Makefile" ]; then
        repo_root="$(cd "$apollo_repo_dir" && pwd)"
        return
    fi

    echo "Unable to locate the apollo-lib repository root from: $script_dir" >&2
    exit 1
}

echo "Script directory: $script_dir"

pull_latest_source() {
    if [ ! -d "$repo_root/.git" ]; then
        echo "Repository root is not a Git checkout, skipping pull."
        return
    fi

    if [ ! -x "$GIT_BIN" ]; then
        echo "Warning: git is not installed, skipping repository pull." >&2
        return
    fi

    echo "Pulling latest apollo-lib changes..."
    "$GIT_BIN" -C "$repo_root" pull --ff-only
}

ensure_artifact_exists() {
    local artifact="$1"
    local description="$2"

    if [ ! -e "$artifact" ]; then
        echo "Error: Required $description not found: $artifact" >&2
        exit 1
    fi
}

clear_quarantine() {
    local artifact_path="$1"
    local description="$2"
    local attribute_listing

    if [ -n "$description" ]; then
        echo "Checking quarantine state for $description: $artifact_path"
    fi

    "$XATTR_BIN" -dr com.apple.quarantine "$artifact_path" 2>/dev/null || true

    attribute_listing="$("$XATTR_BIN" -lr "$artifact_path" 2>/dev/null || true)"
    if [[ "$attribute_listing" == *": com.apple.quarantine:"* ]]; then
        echo "Error: $description still has com.apple.quarantine." >&2
        return 1
    fi

    return 0
}

verify_universal_binary() {
    local artifact_path="$1"
    local description="$2"

    if [ -n "$description" ]; then
        echo "Verifying universal2 architecture for $description: $artifact_path"
    fi

    if ! "$LIPO_BIN" "$artifact_path" -verify_arch x86_64 arm64; then
        echo "Error: $description missing required x86_64 and/or arm64 slice: $artifact_path" >&2
        echo "lipo -archs output: $("$LIPO_BIN" -archs "$artifact_path" 2>/dev/null || true)" >&2
        return 1
    fi

    echo "lipo -archs output for $artifact_path: $("$LIPO_BIN" -archs "$artifact_path" 2>/dev/null || true)"
}

sign_cli_artifact() {
    local artifact="$1"

    "$CODESIGN_BIN" --force --sign - "$artifact"
}

verify_cli_artifact() {
    local artifact="$1"

    "$CODESIGN_BIN" --verify --strict --verbose=2 "$artifact"
}

sign_gui_app() {
    local artifact="$1"

    "$CODESIGN_BIN" --force --sign - "$artifact"
}

verify_gui_app() {
    local artifact="$1"

    "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$artifact"
}

load_mbedtls_settings_from_workflow() {
    local workflow_path="$repo_root/.github/workflows/build.yml"
    local workflow_url=""

    if [ ! -f "$workflow_path" ]; then
        echo "Error: Unable to find workflow file: $workflow_path" >&2
        exit 1
    fi

    workflow_url="$(sed -nE 's|^[[:space:]]*curl[[:space:]]+-sL[[:space:]]+([^[:space:]]*mbedtls-[0-9][0-9.]*\.tar\.gz).*|\1|p' "$workflow_path" | head -n 1)"
    workflow_url="${workflow_url#\"}"
    workflow_url="${workflow_url%\"}"
    workflow_url="${workflow_url#\'}"
    workflow_url="${workflow_url%\'}"

    if [ -z "$workflow_url" ]; then
        echo "Error: Unable to find an mbedTLS tarball URL in $workflow_path" >&2
        exit 1
    fi

    MBEDTLS_URL="$workflow_url"
    MBEDTLS_ARCHIVE="${MBEDTLS_URL:t}"
    MBEDTLS_DIR="${MBEDTLS_ARCHIVE%.tar.gz}"
    MBEDTLS_VERSION="${MBEDTLS_DIR#mbedtls-}"

    if [[ ! "$MBEDTLS_VERSION" =~ '^[0-9]+(\.[0-9]+)+$' ]]; then
        echo "Error: Parsed invalid mbedTLS version from $workflow_path: $MBEDTLS_VERSION" >&2
        exit 1
    fi

    echo "Using mbedTLS ${MBEDTLS_VERSION} from workflow: $workflow_path"
}

is_valid_developer_dir() {
    local developer_dir="$1"
    local xcrun_bin=""
    local clang_path=""
    local sdk_path=""

    if [ -z "$developer_dir" ] || [ ! -d "$developer_dir" ]; then
        return 1
    fi

    xcrun_bin="$(command -v xcrun 2>/dev/null || true)"
    if [ ! -x "$xcrun_bin" ]; then
        return 1
    fi

    clang_path="$(DEVELOPER_DIR="$developer_dir" "$xcrun_bin" --sdk macosx --find clang 2>/dev/null || true)"
    if [ ! -x "$clang_path" ]; then
        return 1
    fi

    sdk_path="$(DEVELOPER_DIR="$developer_dir" "$xcrun_bin" --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [ ! -d "$sdk_path" ]; then
        return 1
    fi

    return 0
}

resolve_developer_dir() {
    local active_developer_dir=""
    local wait_seconds=0
    local max_wait_seconds=3600
    local wait_step_seconds=5
    local fallback_xcode="/Applications/Xcode.app/Contents/Developer"
    local fallback_clt="/Library/Developer/CommandLineTools"
    local selected_developer_dir=""

    if is_valid_developer_dir "$DEVELOPER_DIR"; then
        selected_developer_dir="$DEVELOPER_DIR"
    elif [ -x "$XCODESELECT_BIN" ]; then
        active_developer_dir="$("$XCODESELECT_BIN" --print-path 2>/dev/null || true)"
        if is_valid_developer_dir "$active_developer_dir"; then
            selected_developer_dir="$active_developer_dir"
        fi
    fi

    if [ -z "$selected_developer_dir" ] && is_valid_developer_dir "$fallback_xcode"; then
        echo "Using fallback full Xcode developer directory: $fallback_xcode"
        selected_developer_dir="$fallback_xcode"
    fi

    if [ -z "$selected_developer_dir" ] && is_valid_developer_dir "$fallback_clt"; then
        echo "Using fallback Command Line Tools developer directory: $fallback_clt"
        selected_developer_dir="$fallback_clt"
    fi

    if [ -z "$selected_developer_dir" ]; then
        if [ ! -x "$XCODESELECT_BIN" ]; then
            echo "Error: xcode-select is not available and no usable Apple developer directory was found." >&2
            echo "Please install Xcode or Command Line Tools manually and rerun this script." >&2
            exit 1
        fi

        echo "No usable Apple developer directory was found. Attempting to install Command Line Tools..."
        if ! "$XCODESELECT_BIN" --install; then
            echo "Note: xcode-select --install did not launch the installer (tools may already be present). Re-checking discovery immediately..." >&2
        else
            echo "Installer started. Waiting for installation to provide a usable developer directory..."
        fi

        # Wait for installer completion by polling for a usable developer directory.
        while true; do
            sleep "$wait_step_seconds"
            wait_seconds=$((wait_seconds + wait_step_seconds))

            if [ -x "$XCODESELECT_BIN" ]; then
                active_developer_dir="$("$XCODESELECT_BIN" --print-path 2>/dev/null || true)"
                if is_valid_developer_dir "$active_developer_dir"; then
                    selected_developer_dir="$active_developer_dir"
                    break
                fi
            fi

            if is_valid_developer_dir "$fallback_xcode"; then
                echo "Falling back to full Xcode after installer: $fallback_xcode"
                selected_developer_dir="$fallback_xcode"
                break
            elif is_valid_developer_dir "$fallback_clt"; then
                echo "Falling back to Command Line Tools after installer: $fallback_clt"
                selected_developer_dir="$fallback_clt"
                break
            fi

            if [ "$wait_seconds" -ge "$max_wait_seconds" ]; then
                break
            fi

            if [ "$((wait_seconds % 60))" -eq 0 ]; then
                echo "Still waiting for developer tools: ${wait_seconds}s elapsed."
            fi
        done
    fi

    if [ -z "$selected_developer_dir" ]; then
        echo "Error: unable to locate a usable full Xcode or Command Line Tools directory." >&2
        echo "Please ensure Xcode or Command Line Tools are installed or install Command Line Tools via: xcode-select --install." >&2
        exit 1
    fi

    export DEVELOPER_DIR="$selected_developer_dir"
    echo "Using Apple developer tools: $DEVELOPER_DIR"
}

discover_build_tools() {
    GIT_BIN="$(command -v git 2>/dev/null || true)"
    CMAKE_BIN="$(command -v cmake 2>/dev/null || true)"
    MAKE_BIN="$(command -v make 2>/dev/null || true)"
    CURL_BIN="$(command -v curl 2>/dev/null || true)"
    TAR_BIN="$(command -v tar 2>/dev/null || true)"
    BREW_BIN="$(command -v brew 2>/dev/null || true)"
    XCRUN_BIN="$(command -v xcrun 2>/dev/null || true)"
    XATTR_BIN="$(command -v xattr 2>/dev/null || true)"
    CODESIGN_BIN="$(command -v codesign 2>/dev/null || true)"
}

resolve_brew_bin() {
    BREW_BIN="$(command -v brew 2>/dev/null || true)"
    if [ -x "$BREW_BIN" ]; then
        return
    fi

    if [ -x /opt/homebrew/bin/brew ]; then
        BREW_BIN="/opt/homebrew/bin/brew"
        if [ ":$PATH:" != *":/opt/homebrew/bin:"* ]; then
            PATH="/opt/homebrew/bin:$PATH"
        fi
        return
    fi

    if [ -x /usr/local/bin/brew ]; then
        BREW_BIN="/usr/local/bin/brew"
        if [ ":$PATH:" != *":/usr/local/bin:"* ]; then
            PATH="/usr/local/bin:$PATH"
        fi
        return
    fi

}

ensure_homebrew_and_cmake() {
    if [ -x "$CMAKE_BIN" ]; then
        return
    fi

    local install_script=""

    discover_build_tools
    resolve_brew_bin

    if [ ! -x "$BREW_BIN" ]; then
        if [ ! -x "$CURL_BIN" ]; then
            echo "Error: cmake is not installed and brew is unavailable. Install curl (or install cmake another way) and rerun." >&2
            exit 1
        fi

        echo "cmake not found, installing Homebrew now..."
        if ! install_script="$("$CURL_BIN" -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
            echo "Error: failed to download Homebrew installer script." >&2
            exit 1
        fi

        if [ -z "$install_script" ]; then
            echo "Error: downloaded Homebrew installer script is empty." >&2
            exit 1
        fi

        if ! /bin/bash -c "$install_script"; then
            echo "Error: Homebrew installer failed. Check the installer output and rerun." >&2
            exit 1
        fi
        resolve_brew_bin
        discover_build_tools
    fi

    if [ ! -x "$BREW_BIN" ]; then
        echo "Error: Homebrew is unavailable; install cmake from a source available on PATH." >&2
        exit 1
    fi

    if [ ! -x "$CMAKE_BIN" ]; then
        echo "cmake not found, installing via Homebrew..."
        "$BREW_BIN" install cmake
    fi

    discover_build_tools
}

# Function to initialize GUI transaction state
reset_gui_transaction_state() {
    GUI_TRANSACTION_ACTIVE=false
    GUI_TRANSACTION_COMMITTED=false
    GUI_TRANSACTION_DESTINATION_APP=""
    GUI_TRANSACTION_BACKUP_APP=""
    GUI_TRANSACTION_STAGING_DIR=""
    GUI_TRANSACTION_STAGED_APP=""
    GUI_TRANSACTION_DESTINATION_EXISTED=false
    GUI_TRANSACTION_BACKUP_CREATED=false
    GUI_TRANSACTION_PROMOTED=false
}

# Function to begin GUI transaction
start_gui_transaction() {
    local destination_app="$1"
    local backup_app="$2"
    local staging_dir="$3"
    local staged_app="$4"
    local destination_existed="${5:-false}"

    GUI_TRANSACTION_ACTIVE=true
    GUI_TRANSACTION_COMMITTED=false
    GUI_TRANSACTION_DESTINATION_APP="$destination_app"
    GUI_TRANSACTION_BACKUP_APP="$backup_app"
    GUI_TRANSACTION_STAGING_DIR="$staging_dir"
    GUI_TRANSACTION_STAGED_APP="$staged_app"
    GUI_TRANSACTION_DESTINATION_EXISTED="$destination_existed"
    GUI_TRANSACTION_BACKUP_CREATED=false
    GUI_TRANSACTION_PROMOTED=false
}

rollback_gui_transaction() {
    local reason="${1:-interrupted}"
    local destination_app=""
    local backup_app=""
    local staging_dir=""
    local destination_existed=""

    if [ "$GUI_TRANSACTION_ACTIVE" != true ]; then
        return 0
    fi

    if [ "$GUI_TRANSACTION_COMMITTED" = true ]; then
        return 0
    fi

    destination_app="$GUI_TRANSACTION_DESTINATION_APP"
    backup_app="$GUI_TRANSACTION_BACKUP_APP"
    staging_dir="$GUI_TRANSACTION_STAGING_DIR"
    destination_existed="$GUI_TRANSACTION_DESTINATION_EXISTED"

    if [ -e "$backup_app" ] || [ -L "$backup_app" ]; then
        if [ -e "$destination_app" ] || [ -L "$destination_app" ]; then
            if ! rm -rf -- "$destination_app"; then
                echo "Error: failed to remove GUI bundle before restoring the previous bundle during rollback due to: $reason" >&2
                echo "Manual recovery path: backup still at $backup_app" >&2
                echo "Manual recovery path: staging directory still at $staging_dir" >&2
                GUI_TRANSACTION_ACTIVE=false
                return 1
            fi
        fi

        if mv -- "$backup_app" "$destination_app"; then
            echo "Restored previous GUI bundle after rollback due to: $reason"
            rm -rf -- "$staging_dir"
            reset_gui_transaction_state
            return 0
        fi

        echo "Error: failed to restore previous GUI bundle during rollback due to: $reason" >&2
        echo "Manual recovery path: backup still at $backup_app" >&2
        echo "Manual recovery path: staging directory still at $staging_dir" >&2
        GUI_TRANSACTION_ACTIVE=false
        return 1
    fi

    if [ "$destination_existed" = false ]; then
        if [ -e "$destination_app" ] || [ -L "$destination_app" ]; then
            rm -rf -- "$destination_app"
        fi
    fi

    if [ -n "$staging_dir" ] && [ -d "$staging_dir" ]; then
        rm -rf -- "$staging_dir"
    fi

    reset_gui_transaction_state
    return 0
}

handle_gui_interrupt() {
    local reason="$1"
    local exit_code="$2"

    if [ "$GUI_TRANSACTION_ACTIVE" = true ] && ! rollback_gui_transaction "$reason"; then
        echo "Rollback reported an error during $reason." >&2
        if [ -n "$GUI_TRANSACTION_BACKUP_APP" ]; then
            echo "Manual recovery path: backup still at $GUI_TRANSACTION_BACKUP_APP" >&2
        fi
        if [ -n "$GUI_TRANSACTION_STAGING_DIR" ]; then
            echo "Manual recovery path: staging directory still at $GUI_TRANSACTION_STAGING_DIR" >&2
        fi
    fi

    echo "Aborting with signal ($reason)."
    exit "$exit_code"
}

# Function to handle the SIGINT signal
function handle_sigint() {
    handle_gui_interrupt "SIGINT" 130
}

# Function to handle SIGTERM
function handle_sigterm() {
    handle_gui_interrupt "SIGTERM" 143
}

# Function to store binaries
store_binaries() {
    # Check if STORE_PATH is set
    if [ -z "$STORE_PATH" ]; then
        echo "Error: STORE_PATH is not set. Set the STORE_PATH variable to the directory where you want to store the compiled binaries." >&2
        exit 1
    fi

    echo "Ensuring STORE_PATH exists: $STORE_PATH"
    mkdir -p "$STORE_PATH"

    # Copy each CLI binary
    local binaries=(
        "$repo_root/tools/patcher"
        "$repo_root/tools/dumper"
    )

    for binary in "${binaries[@]}"; do
        ensure_artifact_exists "$binary" "CLI artifact"
        chmod 755 "$binary"
        clear_quarantine "$binary" "built CLI artifact $(basename "$binary")"
        verify_universal_binary "$binary" "CLI artifact $(basename "$binary")"
        verify_cli_artifact "$binary"
        echo "Copying $(basename "$binary") to $STORE_PATH"
        cp "$binary" "$STORE_PATH"
        chmod 755 "$STORE_PATH/$(basename "$binary")"
        clear_quarantine "$STORE_PATH/$(basename "$binary")" "stored CLI artifact $(basename "$binary")"
        verify_universal_binary "$STORE_PATH/$(basename "$binary")" "stored CLI artifact $(basename "$binary")"
        verify_cli_artifact "$STORE_PATH/$(basename "$binary")"
    done
}

store_gui_bundle() {
    local gui_app="$repo_root/gui/build/$GUI_APP_NAME"
    local gui_exec="$gui_app/Contents/MacOS/apollo_patcher_gui"
    local destination_app="$GUI_INSTALL_DIR/$GUI_APP_NAME"
    local destination_existed="false"
    local staging_dir=""
    local staged_app=""
    local staged_exec=""
    local backup_app=""

    if ! check_gui_install_dir; then
        echo "Error: unable to install Apollo GUI bundle." >&2
        return 1
    fi

    ensure_artifact_exists "$gui_app" "GUI bundle"
    ensure_artifact_exists "$gui_exec" "GUI executable"

    chmod 755 "$gui_exec"
    clear_quarantine "$gui_exec" "built GUI executable"
    clear_quarantine "$gui_app" "built GUI app"
    verify_universal_binary "$gui_exec" "built GUI executable"
    sign_gui_app "$gui_app"
    verify_gui_app "$gui_app"

    if ! staging_dir="$(mktemp -d "$GUI_INSTALL_DIR/.apollo_patcher_gui.XXXXXX")"; then
        echo "Error: failed to create unique staging directory under $GUI_INSTALL_DIR" >&2
        return 1
    fi
    if [ -z "$staging_dir" ] || [ ! -d "$staging_dir" ]; then
        echo "Error: failed to create unique staging directory under $GUI_INSTALL_DIR" >&2
        return 1
    fi

    staged_app="$staging_dir/$GUI_APP_NAME"
    staged_exec="$staged_app/Contents/MacOS/apollo_patcher_gui"
    backup_app="$staging_dir/.apollo_patcher_gui.previous.app"

    echo "Staging Apollo GUI bundle in $staging_dir"
    if ! cp -R -- "$gui_app" "$staged_app"; then
        rm -rf -- "$staging_dir"
        echo "Error: Unable to stage Apollo GUI bundle in $staging_dir" >&2
        return 1
    fi

    chmod 755 "$staged_exec"
    clear_quarantine "$staged_exec" "staged GUI executable"
    clear_quarantine "$staged_app" "staged GUI app"
    if ! verify_universal_binary "$staged_exec" "staged GUI executable"; then
        rm -rf -- "$staging_dir"
        echo "Error: Staged GUI executable failed universal verification: $staged_exec" >&2
        return 1
    fi
    if [ ! -x "$staged_exec" ]; then
        rm -rf -- "$staging_dir"
        echo "Error: Staged GUI executable is missing or not executable: $staged_exec" >&2
        return 1
    fi
    if ! verify_gui_app "$staged_app"; then
        rm -rf -- "$staging_dir"
        echo "Error: Staged GUI app failed signature verification." >&2
        return 1
    fi

    if [ -e "$destination_app" ] || [ -L "$destination_app" ]; then
        destination_existed=true
    fi

    start_gui_transaction "$destination_app" "$backup_app" "$staging_dir" "$staged_app" "$destination_existed"

    if [ "$destination_existed" = true ]; then
        echo "Moving existing GUI bundle to backup: $destination_app"
        if ! mv -- "$destination_app" "$backup_app"; then
            rollback_gui_transaction "existing destination backup"
            echo "Error: failed to backup existing GUI bundle: $destination_app" >&2
            return 1
        fi
        GUI_TRANSACTION_BACKUP_CREATED=true
    fi

    if ! mv -- "$staged_app" "$destination_app"; then
        if ! rollback_gui_transaction "promotion failure"; then
            if [ -n "$GUI_TRANSACTION_STAGING_DIR" ]; then
                echo "Manual recovery path: staging directory still at $GUI_TRANSACTION_STAGING_DIR" >&2
            fi
            return 1
        fi
        echo "Error: unable to promote Apollo GUI bundle to $destination_app" >&2
        return 1
    fi
    GUI_TRANSACTION_PROMOTED=true

    if ! chmod 755 "$destination_app/Contents/MacOS/apollo_patcher_gui"; then
        if ! rollback_gui_transaction "post-promotion chmod"; then
            if [ -n "$GUI_TRANSACTION_STAGING_DIR" ]; then
                echo "Manual recovery path: staging directory still at $GUI_TRANSACTION_STAGING_DIR" >&2
            fi
            return 1
        fi
        echo "Error: failed to set executable permissions for $destination_app/Contents/MacOS/apollo_patcher_gui" >&2
        return 1
    fi

    if ! clear_quarantine "$destination_app" "stored GUI app"; then
        if ! rollback_gui_transaction "stored GUI app quarantine clear"; then
            if [ -n "$GUI_TRANSACTION_STAGING_DIR" ]; then
                echo "Manual recovery path: staging directory still at $GUI_TRANSACTION_STAGING_DIR" >&2
            fi
            return 1
        fi
        echo "Error: stored GUI app quarantine clear failed: $destination_app" >&2
        return 1
    fi

    if ! clear_quarantine "$destination_app/Contents/MacOS/apollo_patcher_gui" "stored GUI executable"; then
        if ! rollback_gui_transaction "stored GUI executable quarantine clear"; then
            if [ -n "$GUI_TRANSACTION_STAGING_DIR" ]; then
                echo "Manual recovery path: staging directory still at $GUI_TRANSACTION_STAGING_DIR" >&2
            fi
            return 1
        fi
        echo "Error: stored GUI executable quarantine clear failed: $destination_app/Contents/MacOS/apollo_patcher_gui" >&2
        return 1
    fi

    if ! verify_universal_binary "$destination_app/Contents/MacOS/apollo_patcher_gui" "stored GUI executable"; then
        if ! rollback_gui_transaction "stored GUI executable verification"; then
            if [ -n "$GUI_TRANSACTION_STAGING_DIR" ]; then
                echo "Manual recovery path: staging directory still at $GUI_TRANSACTION_STAGING_DIR" >&2
            fi
            return 1
        fi
        echo "Error: stored GUI executable failed universal verification: $destination_app/Contents/MacOS/apollo_patcher_gui" >&2
        return 1
    fi

    if ! verify_gui_app "$destination_app"; then
        if ! rollback_gui_transaction "stored GUI app verification"; then
            if [ -n "$GUI_TRANSACTION_STAGING_DIR" ]; then
                echo "Manual recovery path: staging directory still at $GUI_TRANSACTION_STAGING_DIR" >&2
            fi
            return 1
        fi
        echo "Error: stored GUI app failed final signature verification: $destination_app" >&2
        return 1
    fi

    GUI_TRANSACTION_COMMITTED=true
    GUI_TRANSACTION_ACTIVE=false
    rm -rf -- "$GUI_TRANSACTION_BACKUP_APP"
    rm -rf -- "$GUI_TRANSACTION_STAGING_DIR"
    reset_gui_transaction_state
    echo "Stored Apollo GUI bundle: $destination_app"
}

check_gui_install_dir() {
    if [ ! -d "$GUI_INSTALL_DIR" ]; then
        echo "Error: GUI install directory does not exist: $GUI_INSTALL_DIR" >&2
        return 1
    fi

    if [ ! -w "$GUI_INSTALL_DIR" ]; then
        echo "Error: GUI install directory is not writable: $GUI_INSTALL_DIR" >&2
        return 1
    fi
}

# Trap interrupt/termination signals
trap handle_sigint SIGINT
trap handle_sigterm SIGTERM

cleanup_previous_builds() {
    echo "Cleaning previous build artifacts..."

    cd "$repo_root"

    if [ -d "$MBEDTLS_DIR" ]; then
        echo "Removing existing $MBEDTLS_DIR directory..."
        rm -rf "$MBEDTLS_DIR"
    fi

    rm -f -- source/*.o(N) source/*.d(N)

    if [ -d "tools" ]; then
        cd tools

        if [ -f "Makefile" ]; then
            "$MAKE_BIN" clean || true
        fi

        rm -f -- ./*.o(N) ./*.d(N)
        rm -f patcher patcher-bigendian dumper
        rm -f patcher.exe patcher-bigendian.exe dumper.exe

        cd "$repo_root"
    fi

    if [ -d "gui/build" ]; then
        echo "Removing existing gui/build directory..."
        rm -rf "gui/build"
    fi

    if [ -d "gui/dist" ]; then
        echo "Removing existing gui/dist directory..."
        rm -rf "gui/dist"
    fi
}

# Resolve Apple toolchain and required build tools.
resolve_developer_dir
discover_build_tools
ensure_homebrew_and_cmake
discover_build_tools

if [ ! -x "$GIT_BIN" ]; then
    echo "Error: git is required to clone/pull apollo-lib and was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$MAKE_BIN" ]; then
    echo "Error: make is required to build Apollo CLI tools and was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$CURL_BIN" ]; then
    echo "Error: curl is required to fetch external dependencies and was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$TAR_BIN" ]; then
    echo "Error: tar is required to unpack external dependencies and was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$CMAKE_BIN" ]; then
    echo "Error: cmake is required and still not installed after attempting Homebrew fallback." >&2
    exit 1
fi

if [ ! -x "$XATTR_BIN" ]; then
    echo "Error: xattr is required to clear quarantine but was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$CODESIGN_BIN" ]; then
    echo "Error: codesign is required for artifact signing but was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$XCRUN_BIN" ]; then
    echo "Error: xcrun is required for Apple toolchain discovery but was not found on PATH." >&2
    exit 1
fi

APPLE_CLANG_BIN="$("$XCRUN_BIN" --sdk macosx --find clang 2>/dev/null || true)"
if [ ! -x "$APPLE_CLANG_BIN" ]; then
    echo "Error: Apple clang was not found via xcrun --sdk macosx --find clang: $APPLE_CLANG_BIN" >&2
    exit 1
fi

APPLE_CLANGPP_BIN="$("$XCRUN_BIN" --sdk macosx --find clang++ 2>/dev/null || true)"
if [ ! -x "$APPLE_CLANGPP_BIN" ]; then
    echo "Error: Apple clang++ was not found via xcrun --sdk macosx --find clang++: $APPLE_CLANGPP_BIN" >&2
    exit 1
fi

LIPO_BIN="$("$XCRUN_BIN" --find lipo 2>/dev/null || true)"
if [ ! -x "$LIPO_BIN" ]; then
    echo "Error: lipo was not found via xcrun --find lipo: $LIPO_BIN" >&2
    exit 1
fi

MACOS_SDK_PATH="$("$XCRUN_BIN" --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [ ! -d "$MACOS_SDK_PATH" ]; then
    echo "Error: failed to resolve macOS SDK path via xcrun --sdk macosx --show-sdk-path: ${MACOS_SDK_PATH:-<empty>}" >&2
    exit 1
fi

UNIVERSAL_CC="${(q)APPLE_CLANG_BIN} -isysroot ${(q)MACOS_SDK_PATH} -arch ${UNIVERSAL_CMAKE_ARCHITECTURES%%;*} -arch ${UNIVERSAL_CMAKE_ARCHITECTURES##*;} -mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}"

if ! check_gui_install_dir; then
    echo "Error: GUI application destination is not available before repository resolution." >&2
    exit 1
fi

resolve_repo_root
echo "Script directory: $script_dir"
echo "Repository root: $repo_root"

cd "$repo_root"

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

pull_latest_source
load_mbedtls_settings_from_workflow
cleanup_previous_builds

echo "Preparing mbedTLS ${MBEDTLS_VERSION}..."
echo "Downloading $MBEDTLS_ARCHIVE..."
"$CURL_BIN" -fsSL "$MBEDTLS_URL" | "$TAR_BIN" xvz -C "$repo_root"

cd "$MBEDTLS_DIR"

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

if [ -d "build" ]; then
    echo "The 'build' directory exists, deleting it to start fresh..."
    rm -rf build
fi

echo "Creating a new 'build' directory..."
mkdir build
cd build

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

echo "Running cmake..."
"$CMAKE_BIN" .. \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$APPLE_CLANG_BIN" \
    -DCMAKE_OSX_ARCHITECTURES="$UNIVERSAL_CMAKE_ARCHITECTURES" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH" \
    -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
    -DUSE_STATIC_MBEDTLS_LIBRARY=ON \
    -DENABLE_PROGRAMS=OFF \
    -DENABLE_TESTING=OFF

echo "Building mbedcrypto..."
"$CMAKE_BIN" --build . --parallel --target mbedcrypto
ensure_artifact_exists "$repo_root/$MBEDTLS_DIR/build/library/libmbedcrypto.a" "mbedTLS static library"
verify_universal_binary "$repo_root/$MBEDTLS_DIR/build/library/libmbedcrypto.a" "mbedTLS static library"

echo "Navigating back to repository root"
cd "$repo_root"

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

echo "Building Apollo CLI tools"
cd tools

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

# Build patcher + dumper
echo "Building default Apollo CLI tools"
"$MAKE_BIN" clean
"$MAKE_BIN" CC="$UNIVERSAL_CC"
ensure_artifact_exists "$repo_root/tools/patcher" "CLI artifact patcher"
ensure_artifact_exists "$repo_root/tools/dumper" "CLI artifact dumper"
chmod 755 "$repo_root/tools/patcher" "$repo_root/tools/dumper"
clear_quarantine "$repo_root/tools/patcher" "built CLI artifact patcher"
clear_quarantine "$repo_root/tools/dumper" "built CLI artifact dumper"
verify_universal_binary "$repo_root/tools/patcher" "built CLI artifact patcher"
verify_universal_binary "$repo_root/tools/dumper" "built CLI artifact dumper"
sign_cli_artifact "$repo_root/tools/patcher"
sign_cli_artifact "$repo_root/tools/dumper"
verify_cli_artifact "$repo_root/tools/patcher"
verify_cli_artifact "$repo_root/tools/dumper"
cd "$repo_root"

if [ ! -d "$repo_root/gui" ]; then
    echo "Error: Unable to locate gui directory from repo root: $repo_root/gui" >&2
    exit 1
fi

echo "Building Apollo GUI"
cd "$repo_root/gui"
"$CMAKE_BIN" -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$APPLE_CLANG_BIN" \
    -DCMAKE_CXX_COMPILER="$APPLE_CLANGPP_BIN" \
    -DCMAKE_OSX_ARCHITECTURES="$UNIVERSAL_CMAKE_ARCHITECTURES" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH"
"$CMAKE_BIN" --build build --parallel

store_gui_bundle

# Call the function to store binaries
store_binaries
