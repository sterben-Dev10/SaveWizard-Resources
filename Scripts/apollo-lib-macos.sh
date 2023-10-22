#!/usr/bin/env zsh

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
    read -n 1 -s -r  # This line waits for a user to press any key
fi

# Check for Homebrew installation
if ! command -v brew &>/dev/null; then
    echo "Homebrew is not installed. Attempting to install Homebrew now..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Verify if Homebrew was installed successfully
    if [ $? -ne 0 ]; then
        echo "Failed to install Homebrew. Please check your internet connection or try again later." >&2
        exit 1
    fi
fi
echo "Homebrew is installed, proceeding..."

echo "Checking if git is installed via Homebrew..."

if brew list git &>/dev/null; then
    echo "git is already installed."
else
    echo "git not found, installing now..."
    brew install git
    if [ $? -ne 0 ]; then
        echo "Failed to install git via Homebrew. Please check your Homebrew installation and try again." >&2
        exit 1
    fi
fi

echo "Checking if cmake is installed..."

if ! command -v cmake &>/dev/null; then
    echo "cmake not found, installing now via Homebrew..."
    brew install cmake
    if [ $? -ne 0 ]; then
        echo "Failed to install cmake via Homebrew. Please check your Homebrew installation and try again." >&2
        exit 1
    fi
fi

echo "Checking if zlib is installed via Homebrew..."

if brew list zlib &>/dev/null; then
    echo "zlib is already installed."
else
    echo "zlib not found, installing now..."
    brew install zlib
    if [ $? -ne 0 ]; then
        echo "Failed to install zlib via Homebrew. Please check your Homebrew installation and try again." >&2
        exit 1
    fi
fi

# if you want to place the compiled binaries somewhere after building
STORE_PATH="$HOME/Desktop/Apollo CLI Tools"

# Resolve the full absolute path of the directory where the script is located
script_dir="$(cd "$(dirname "$0")" && pwd)"

# Print the script's directory for debugging purposes
echo "Script directory: $script_dir"

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
    binaries=("patcher-bigendian" "patcher" "parser")

    # Verify that STORE_PATH directory exists
    if [ ! -d "$STORE_PATH" ]; then
        echo "The directory specified by STORE_PATH does not exist. Creating the directory..."
        mkdir -p "$STORE_PATH"
    fi

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

# Repository details
APOLLO_LIB_DIR="apollo-lib"
APOLLO_LIB_URL="https://github.com/bucanero/apollo-lib.git"

# Check if the "apollo-lib" directory exists.
if [ -d "$script_dir/$APOLLO_LIB_DIR" ]; then
    # The directory exists, update the repo
    echo "$APOLLO_LIB_DIR directory exists, updating repository..."
    # Change into the "apollo-lib" directory
    cd "$script_dir/$APOLLO_LIB_DIR"
    # Perform git pull to update the repository
    if ! git pull; then
        echo "Failed to update $APOLLO_LIB_DIR" >&2
        exit 1
    fi
else
    # The directory does not exist, clone the repository
    echo "$APOLLO_LIB_DIR directory does not exist, cloning now..."
    # Clone and check for failure
    if ! git clone "$APOLLO_LIB_URL" "$script_dir/$APOLLO_LIB_DIR"; then
        echo "Git clone failed!" >&2
        exit 1
    fi
    # Change into the directory after a successful clone
    cd "$script_dir/$APOLLO_LIB_DIR"
fi

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

# Define oosdk_libraries directory/repository name
REPO_OOSDK_DIR="oosdk_libraries"
REPO_OOSDK_URL="https://github.com/bucanero/oosdk_libraries.git"

# Check if the oosdk_libraries directory exists
if [ -d "$REPO_OOSDK_DIR" ]; then
    # The directory exists, change into it
    echo "oosdk_libraries directory exists, changing into $REPO_OOSDK_DIR."
    cd "$REPO_OOSDK_DIR"
    # do git update if exists
    git pull
else
    # The directory does not exist, clone the repository
    echo "oosdk_libraries directory does not exist, cloning now..."
    # Clone and check for failure
    if ! git clone "$REPO_OOSDK_URL" "$REPO_OOSDK_DIR" --depth 1; then
        echo "Git clone failed!" >&2
        exit 1
    fi
    # Change into the directory after a successful clone
    cd "$REPO_OOSDK_DIR"
fi

# Build polarSSL

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

# Find the directory with the highest version number
latest_polarssl_dir=$(ls -d polarssl-* 2>/dev/null | sort -V | tail -n 1)

# Check if the directory was found
if [ -n "$latest_polarssl_dir" ]; then
    echo "Latest polarssl directory: $latest_polarssl_dir"  # Echoing the directory name
    cd "$latest_polarssl_dir"
else
    echo "No polarssl- directory found" >&2
    exit 1
fi

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

# Assuming you are currently in the directory where the 'build' directory is created
# Check if the 'build' directory exists
if [ -d "build" ]; then
    # If it exists, delete the directory
    echo "The 'build' directory exists, deleting it to start fresh..."
    rm -rf build
fi

sleep 2

# At this point, the 'build' directory either never existed or has been deleted.
# Create a new 'build' directory and navigate into it.
echo "Creating a new 'build' directory..."
mkdir build && cd build
# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

# Run cmake and check if it was successful
echo "Running cmake..."
cmake ..
if [ $? -ne 0 ]; then
    echo "cmake failed" >&2  # Redirects the error message to standard error
    exit 1  # Exits the script with a non-zero status to indicate an error occurred
fi

# Run make and check if it was successful
echo "Building polarSSL..."
make polarssl
if [ $? -ne 0 ]; then
    echo "make polarssl failed" >&2
    exit 1
fi

echo "Navigating Back to $APOLLO_LIB_DIR"
cd "$script_dir/$APOLLO_LIB_DIR"
# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

# Building Apollo CLI tools
cd tools

# Confirm the current directory
echo "Current directory: $(pwd)"
sleep 1

# List of binaries to check and delete if they exist
binaries=("patcher-bigendian" "patcher" "parser")

# Loop through the binaries array and delete the files if they exist
for binary in "${binaries[@]}"; do
    if [ -f "$binary" ]; then
        echo "Deleting existing file: $binary"  # Echoing the name of the file being deleted
        rm "$binary"

        # Verify if deletion was successful or not
        if [ $? -ne 0 ]; then
            echo "Error: Failed to delete $binary" >&2
            exit 1
        fi
    else
        echo "$binary does not exist, no need to delete."
    fi
done

sleep 2

# make PS3 patcher
echo "Building PS3 Patcher"
make BIGENDIAN=1
if [ $? -ne 0 ]; then
    echo "Error: Building PS3 Patcher failed" >&2  # Redirect the error message to standard error
    exit 1  # Exit the script with a non-zero status to indicate an error occurred
fi

# Rename the patcher to patcher-bigendian
mv patcher patcher-bigendian

# make PS4 patcher
echo "Building PS4 Patcher"
make clean
if [ $? -ne 0 ]; then
    echo "Error: make clean failed" >&2
    exit 1
fi

make
if [ $? -ne 0 ]; then
    echo "Error: Building PS4 Patcher failed" >&2
    exit 1
fi

# List of binaries
binaries=("patcher-bigendian" "patcher" "parser")

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
# Uncomment the line below if you want to store the binaries after building
store_binaries
