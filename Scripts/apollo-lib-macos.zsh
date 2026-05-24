#!/usr/local/bin/zsh

# Always run this script with zsh, even if it was launched through another shell.
if [ -z "${ZSH_VERSION:-}" ]; then
    exec /usr/local/bin/zsh "$0" "$@"
fi

emulate -LR zsh
set -e
setopt pipefail

# if you want to place the compiled binaries somewhere after building
STORE_PATH="$HOME/Desktop/Apollo CLI Tools"
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
    if ! command -v git &>/dev/null; then
        echo "Error: git is required to clone apollo-lib but was not found." >&2
        exit 1
    fi

    echo "apollo-lib repository not found, cloning fresh copy..."
    git clone "$APOLLO_REPO_URL" "$apollo_repo_dir"
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

    if ! command -v git &>/dev/null; then
        echo "Warning: git is not installed, skipping repository pull." >&2
        return
    fi

    echo "Pulling latest apollo-lib changes..."
    git -C "$repo_root" pull --ff-only
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

    # List of binaries
    binaries=("patcher-bigendian" "patcher" "dumper")

    echo "Ensuring STORE_PATH exists: $STORE_PATH"
    mkdir -p "$STORE_PATH"

    # Copy each binary
    for binary in "${binaries[@]}"; do
        if [ -f "$binary" ]; then
            echo "Copying $binary to $STORE_PATH"
            cp "$binary" "$STORE_PATH"
        else
            echo "Warning: Expected binary file $binary does not exist and was not copied." >&2
        fi
    done
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

# make PS3 patcher
echo "Building PS3 Patcher"
make BIGENDIAN=1

# Rename the patcher to patcher-bigendian
mv patcher patcher-bigendian

# make default patcher + dumper
echo "Building default Apollo CLI tools"
make clean
make

# List of binaries
binaries=("patcher-bigendian" "patcher" "dumper")

# Change file permissions for each binary
for binary in "${binaries[@]}"; do
    if [ -f "$binary" ]; then
        echo "Setting execute permissions for $binary"
        chmod 755 "$binary"
    else
        echo "Warning: Expected binary file $binary does not exist, unable to set permissions." >&2
    fi
done

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

# Call the function to store binaries
store_binaries
