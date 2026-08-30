#!/usr/bin/env zsh

# Always run this script with zsh, even if it was launched through another shell.
if [ -z "${ZSH_VERSION:-}" ]; then
    exec /usr/local/bin/zsh "$0" "$@"
fi

emulate -LR zsh
set -e
setopt pipefail

# if you want to place the compiled binaries somewhere after building
STORE_PATH="${STORE_PATH:-$HOME/Desktop/Apollo CLI Tools}"

GIT_BIN="$(command -v git 2>/dev/null || true)"
XATTR_BIN="$(command -v xattr 2>/dev/null || true)"
CODESIGN_BIN="$(command -v codesign 2>/dev/null || true)"
APOLLO_REPO_URL="git@github.com:bucanero/apollo-lib.git"

MBEDTLS_VERSION=""
MBEDTLS_ARCHIVE=""
MBEDTLS_DIR=""
MBEDTLS_URL=""

# Resolve the full absolute path of the directory where the script is located
script_dir="$(cd "$(dirname "$0")" && pwd)"
apollo_repo_dir="$script_dir/apollo-lib"
repo_root=""

if [ -f "$script_dir/tools/Makefile" ]; then
    repo_root="$script_dir"
elif [ ! -e "$apollo_repo_dir" ]; then
    if [ ! -x "$GIT_BIN" ]; then
        echo "Error: git is required to clone apollo-lib but was not found." >&2
        exit 1
    fi

    echo "apollo-lib repository not found, cloning fresh copy..."
    "$GIT_BIN" clone "$APOLLO_REPO_URL" "$apollo_repo_dir"
    repo_root="$(cd "$apollo_repo_dir" && pwd)"
elif [ -f "$apollo_repo_dir/tools/Makefile" ]; then
    repo_root="$(cd "$apollo_repo_dir" && pwd)"
else
    echo "Unable to locate the apollo-lib repository root from: $script_dir" >&2
    exit 1
fi

echo "Script directory: $script_dir"
echo "Repository root: $repo_root"

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
        exit 1
    fi
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

# Function to handle the SIGINT signal
function handle_sigint() {
    echo "Killing process..."
    exit 0
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
        verify_cli_artifact "$binary"
        echo "Copying $(basename "$binary") to $STORE_PATH"
        cp "$binary" "$STORE_PATH"
        chmod 755 "$STORE_PATH/$(basename "$binary")"
        clear_quarantine "$STORE_PATH/$(basename "$binary")" "stored CLI artifact $(basename "$binary")"
        verify_cli_artifact "$STORE_PATH/$(basename "$binary")"
    done
}

store_gui_bundle() {
    if [ -z "$STORE_PATH" ]; then
        echo "Error: STORE_PATH is not set. Set the STORE_PATH variable to the directory where you want to store the compiled artifacts." >&2
        exit 1
    fi

    local gui_app="$repo_root/gui/build/apollo_patcher_gui.app"
    local gui_exec="$gui_app/Contents/MacOS/apollo_patcher_gui"
    local destination_app="$STORE_PATH/apollo_patcher_gui.app"
    local staged_app="$STORE_PATH/.apollo_patcher_gui.staged.app"
    local staged_exec="$staged_app/Contents/MacOS/apollo_patcher_gui"

    echo "Ensuring STORE_PATH exists: $STORE_PATH"
    mkdir -p "$STORE_PATH"

    ensure_artifact_exists "$gui_app" "GUI bundle"
    ensure_artifact_exists "$gui_exec" "GUI executable"

    chmod 755 "$gui_exec"
    clear_quarantine "$gui_exec" "built GUI executable"
    clear_quarantine "$gui_app" "built GUI app"
    sign_gui_app "$gui_app"
    verify_gui_app "$gui_app"

    if [ -e "$staged_app" ]; then
        rm -rf -- "$staged_app"
    fi

    echo "Staging Apollo GUI bundle in $STORE_PATH"
    if ! cp -R -- "$gui_app" "$staged_app"; then
        rm -rf -- "$staged_app"
        echo "Error: Unable to stage Apollo GUI bundle in $STORE_PATH" >&2
        return 1
    fi

    chmod 755 "$staged_exec"
    clear_quarantine "$staged_exec" "staged GUI executable"
    clear_quarantine "$staged_app" "staged GUI app"
    if [ ! -x "$staged_exec" ]; then
        rm -rf -- "$staged_app"
        echo "Error: Staged GUI executable is missing or not executable: $staged_exec" >&2
        return 1
    fi
    verify_gui_app "$staged_app"

    if [ -e "$destination_app" ]; then
        echo "Replacing existing GUI bundle: $destination_app"
        rm -rf -- "$destination_app"
    fi

    mv -- "$staged_app" "$destination_app"
    chmod 755 "$destination_app/Contents/MacOS/apollo_patcher_gui"
    clear_quarantine "$destination_app" "stored GUI app"
    clear_quarantine "$destination_app/Contents/MacOS/apollo_patcher_gui" "stored GUI executable"
    verify_gui_app "$destination_app"
    echo "Stored Apollo GUI bundle: $destination_app"
}

# Trap the SIGINT signal
trap handle_sigint SIGINT

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
            make clean || true
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

# Check for Xcode installation by checking for xcode-select
if ! command -v xcode-select &>/dev/null; then
    echo "Xcode is not installed. Please install Xcode from the App Store before running this script." >&2
    exit 1
fi
echo "Xcode is installed, proceeding..."

# Check for Xcode Command Line Tools installation
if ! xcode-select --print-path &>/dev/null; then
    echo "Xcode Command Line Tools not found. Attempting to install..."
    xcode-select --install

    # Wait for user to complete Command Line Tools installation process
    echo "Please follow the on-screen instructions to install Xcode Command Line Tools. Press any key to continue once you're ready..."
    read -n 1 -s -r
fi

# Check for Homebrew installation
if ! command -v brew &>/dev/null; then
    echo "Homebrew is not installed. Attempting to install Homebrew now..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
echo "Homebrew is installed, proceeding..."

echo "Checking if cmake is installed..."

if ! command -v cmake &>/dev/null; then
    echo "cmake not found, installing now via Homebrew..."
    brew install cmake
fi

echo "Checking if zlib is installed via Homebrew..."

if brew list zlib &>/dev/null; then
    echo "zlib is already installed."
else
    echo "zlib not found, installing now..."
    brew install zlib
fi

if ! command -v curl &>/dev/null; then
    echo "curl is not installed. Please install curl and rerun the script." >&2
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

cd "$repo_root"

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

pull_latest_source
load_mbedtls_settings_from_workflow
cleanup_previous_builds

echo "Preparing mbedTLS ${MBEDTLS_VERSION}..."
echo "Downloading $MBEDTLS_ARCHIVE..."
curl -sL "$MBEDTLS_URL" | tar xvz -C "$repo_root"

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
cmake .. -DCMAKE_POLICY_VERSION_MINIMUM=3.5

echo "Building mbedcrypto..."
make mbedcrypto

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
make clean
make
ensure_artifact_exists "$repo_root/tools/patcher" "CLI artifact patcher"
ensure_artifact_exists "$repo_root/tools/dumper" "CLI artifact dumper"
chmod 755 "$repo_root/tools/patcher" "$repo_root/tools/dumper"
clear_quarantine "$repo_root/tools/patcher" "built CLI artifact patcher"
clear_quarantine "$repo_root/tools/dumper" "built CLI artifact dumper"
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
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel

store_gui_bundle

# Call the function to store binaries
store_binaries
