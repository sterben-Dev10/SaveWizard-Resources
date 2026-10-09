#!/usr/bin/env zsh

# Always run this script with zsh, even if it was launched through another shell.
if [ -z "${ZSH_VERSION:-}" ]; then
    exec /bin/zsh "$0" "$@"
fi

emulate -LR zsh
set -e
setopt pipefail

# A renamed copy gets its own adjacent config (for example build-apollo-lib.conf).
script_dir="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$script_dir/${${0:t}:r}.conf"
STORE_PATH_OVERRIDE="${STORE_PATH:-}"
LOG_FILE=""
UI_ACCENT="" UI_OK="" UI_WARN="" UI_ERROR="" UI_RESET=""
if [[ -t 1 && -z "${NO_COLOR+x}" && "${TERM:-}" != dumb ]]; then
    UI_ACCENT=$'\e[36m' UI_OK=$'\e[32m' UI_WARN=$'\e[33m' UI_ERROR=$'\e[31m' UI_RESET=$'\e[0m'
fi

UI_HELPER_PID=""
BUILD_WORKSPACE_ACTIVE=0
CLI_BUILD_READY=0
BUILD_OUTPUTS_READY=0
GUI_STAGING_DIR=""
GUI_STAGING_PARENT=""

# Only the display loop is backgrounded; build commands remain foreground jobs.
start_work_indicator() {
    [[ -t 1 && "${TERM:-}" != dumb ]] || return 0
    local owner_pid="$$"
    (
        trap - EXIT
        trap 'exit 0' INT TERM
        local frame=1
        local -a dots=(. .. ... .... ..)
        local use_zselect=0
        zmodload zsh/zselect 2>/dev/null && use_zselect=1
        while kill -0 "$owner_pid" 2>/dev/null; do
            printf '\r\033[2K  Working%s' "${dots[$frame]}"
            if (( use_zselect )); then
                zselect -t 25 || true
            else
                sleep 0.25
            fi
            frame=$((frame % ${#dots} + 1))
        done
    ) &
    UI_HELPER_PID=$!
}

stop_work_indicator() {
    local helper_pid="$UI_HELPER_PID"
    [ -n "$helper_pid" ] || return 0
    UI_HELPER_PID=""
    kill -TERM "$helper_pid" 2>/dev/null || true
    wait "$helper_pid" 2>/dev/null || true
    printf '\r\033[2K' || true
}

ui_emit() {
    local tone="$1" message="$2"
    print -r -- "${tone}${message}${UI_RESET}"
    if [ -n "$LOG_FILE" ]; then
        print -r -- "$message" >> "$LOG_FILE"
    fi
}

ui_banner() {
    ui_emit "$UI_ACCENT" $'\n+----------------------------------------------------------------+\n|  👾 Apollo macOS · Universal2 CLI + GUI                          |\n+----------------------------------------------------------------+'
}

ui_section() {
    ui_emit "$UI_ACCENT" "
+----------------------------------------------------------------+
  [$1/8] $2  $3
+----------------------------------------------------------------+"
}

ui_step() { ui_emit "$UI_ACCENT" "  → $1"; }
ui_done() { ui_emit "$UI_OK" "  ✓ $1"; }
ui_failed() { ui_emit "$UI_ERROR" "  ✗ $1" >&2; }

log_detail() {
    if [ -n "$LOG_FILE" ]; then
        print -r -- "$*" >> "$LOG_FILE"
    fi
}

initialize_build_log() {
    local log_target
    mkdir -p "$WORKSPACE_DIR" || return 1
    WORKSPACE_DIR="$(cd "$WORKSPACE_DIR" && pwd -P)" || return 1
    log_target="$WORKSPACE_DIR/build.log"
    if [ -L "$log_target" ] || { [ -e "$log_target" ] && [ ! -f "$log_target" ]; }; then
        ui_emit "$UI_ERROR" "Error: refusing a symlink or non-regular build log: $log_target" >&2
        return 1
    fi
    if [ -e "$log_target" ]; then
        : > "$log_target" || return 1
    else
        (setopt noclobber; umask 077; : > "$log_target") || return 1
    fi
    LOG_FILE="$log_target"
    log_detail "Apollo macOS · Universal2 CLI + GUI" "[1/8] Configuration & tools"
    log_detail "Configuration: $CONFIG_FILE"
}

show_command_diagnostics() {
    # Read only this command's segment; retain early errors even after many warnings.
    awk -v first="$1" '
        NR >= first {
            lines[++count] = $0
            lower = tolower($0)
            if (lower ~ /fatal error|error:|cmake error|undefined symbols|undefined reference|linker command failed/ ||
                (lower ~ /(^|[[:space:]])ld:/ && lower !~ /(^|[[:space:]])ld:[[:space:]]*warning/)) {
                found = 1
                for (i = count - 2; i <= count + 6; i++) selected[i] = 1
            }
        }
        END {
            if (!found) {
                start = count > 12 ? count - 11 : 1
                for (i = start; i <= count; i++) selected[i] = 1
            }
            for (i = 1; i <= count && printed < 32; i++) {
                if (selected[i]) { print "    " lines[i]; printed++ }
            }
            if (!count) print "    The command produced no diagnostic output."
        }
    ' "$LOG_FILE"
}

finish_logged_step() {
    local return_code="$1" description="$2" started_at="$3" first_line="$4"
    local elapsed=$((SECONDS - started_at)) diagnostic_context
    if [ "$return_code" -eq 0 ]; then
        if [ "$elapsed" -gt 0 ]; then
            ui_done "$description (${elapsed}s)" || true
        else
            ui_done "$description" || true
        fi
    else
        # Render before appending our failure header, keeping the excerpt raw.
        if ! diagnostic_context="$(show_command_diagnostics "$first_line")"; then
            diagnostic_context="    Unable to render diagnostics; consult the full log."
        fi
        ui_failed "$description (exit $return_code)" || true
        print -r -- "$diagnostic_context" >&2 || true
        print -r -- "  Full log: $LOG_FILE" >&2 || true
    fi
    return "$return_code"
}

cleanup_cancelled_work() {
    local managed_root staging_root cleanup_ok=1
    # The same two-child, ownership, physical-path and source-overlap checks
    # used before normal workspace preparation must pass before either deletion.
    if (( BUILD_WORKSPACE_ACTIVE && ! BUILD_OUTPUTS_READY )); then
        if validate_build_workspace; then
            for managed_root in "$lib_build_root" "$gui_build_root"; do
                if [ -d "$managed_root" ]; then
                    if ! rm -rf -- "$managed_root" >> "$LOG_FILE" 2>&1; then
                        cleanup_ok=0
                        ui_emit "$UI_WARN" "  ⚠ Unable to remove partial build copy: $managed_root" >&2 || true
                    fi
                fi
            done
            if (( cleanup_ok )); then
                ui_emit "$UI_WARN" "  Partial build copies cleaned; source checkouts and installed files retained." >&2 || true
            else
                ui_emit "$UI_WARN" "  ⚠ Partial build cleanup incomplete; inspect BUILD_DIR. Source checkouts and installed files retained." >&2 || true
            fi
        else
            ui_emit "$UI_WARN" "  ⚠ Partial build cleanup refused by workspace safety checks; inspect BUILD_DIR." >&2 || true
        fi
    fi
    # Keep only the temporary directory created by this invocation in scope.
    if [ -n "$GUI_STAGING_DIR" ]; then
        if [ ! -L "$GUI_STAGING_DIR" ] && [ -d "$GUI_STAGING_DIR" ] &&
           [[ "${GUI_STAGING_DIR:h}" == "$GUI_STAGING_PARENT" && "${GUI_STAGING_DIR:t}" == .apollo_patcher_gui.* ]] &&
           staging_root="$(physical_path "$GUI_STAGING_DIR")" && [[ "$staging_root" == "$GUI_STAGING_DIR" ]]; then
            if ! rm -rf -- "$GUI_STAGING_DIR" >> "$LOG_FILE" 2>&1; then
                ui_emit "$UI_WARN" "  ⚠ Temporary GUI staging directory remains: $GUI_STAGING_DIR" >&2 || true
            fi
        else
            ui_emit "$UI_WARN" "  ⚠ Temporary GUI staging cleanup refused: $GUI_STAGING_DIR" >&2 || true
        fi
    fi
}

handle_signal() {
    local signal_name="$1" exit_code="$2"
    trap '' INT TERM
    stop_work_indicator || true
    ui_emit "$UI_WARN" "  ⚠ Cancelled by $signal_name; no further installation will run." >&2 || true
    cleanup_cancelled_work || true
    exit "$exit_code"
}

# Use only for individual external commands, never multi-step shell functions.
run_logged() {
    local animate=0
    if [[ "$1" == --animate ]]; then
        animate=1
        shift
    fi
    local description="$1" started_at="$SECONDS" line_count return_code
    shift
    ui_step "$description" || return 1
    line_count="$(wc -l < "$LOG_FILE")" || return 1
    if (( animate )); then start_work_indicator; fi
    if "$@" >> "$LOG_FILE" 2>&1; then
        return_code=0
    else
        return_code=$?
    fi
    stop_work_indicator
    finish_logged_step "$return_code" "$description" "$started_at" "$((line_count + 1))"
}

download_mbedtls() {
    setopt localoptions pipefail
    local description="Download and extract mbedTLS $MBEDTLS_VERSION"
    local started_at="$SECONDS" line_count return_code
    ui_step "$description" || return 1
    line_count="$(wc -l < "$LOG_FILE")" || return 1
    start_work_indicator
    # The explicit conditional captures either pipeline failure under pipefail.
    if { "$CURL_BIN" -fsSL "$MBEDTLS_URL" | "$TAR_BIN" xvz -C "$lib_build_root"; } >> "$LOG_FILE" 2>&1; then
        return_code=0
    else
        return_code=$?
    fi
    stop_work_indicator
    finish_logged_step "$return_code" "$description" "$started_at" "$((line_count + 1))"
}

expand_config_path() {
    local value="$1"

    case "$value" in
        '$HOME'|'${HOME}'|'~') value="$HOME" ;;
        '$HOME/'*) value="$HOME/${value#\$HOME/}" ;;
        '${HOME}/'*) value="$HOME/${value#\$\{HOME\}/}" ;;
        '~/'*) value="$HOME/${value#\~/}" ;;
    esac

    if [[ "$value" != /* || "$value" =~ '[[:cntrl:]]' ]]; then
        ui_emit "$UI_ERROR" "Error: $2 must be an absolute path (leading \$HOME, \${HOME}, or ~/ is allowed)." >&2
        return 1
    fi
    REPLY="$value"
}

load_configuration() {
    setopt localoptions extendedglob
    local config_line key value
    local line_number=0
    local -A config_values
    local -a required_keys=(WORKSPACE_DIR STORE_PATH BUILD_DIR GUI_INSTALL_DIR GUI_BUILD_APP_NAME GUI_INSTALL_APP_NAME)

    if [ ! -e "$CONFIG_FILE" ]; then
        # noclobber also protects an existing file created by a concurrent run.
        if (setopt noclobber; umask 077; cat > "$CONFIG_FILE" <<'CONFIG'
# Literal key=value settings. No shell commands or general variable expansion.
# Paths may start with $HOME, ${HOME}, or ~/. Surrounding quotes are optional.
# STORE_PATH can also be overridden in the environment for one invocation.
WORKSPACE_DIR="$HOME/Desktop/apollo"
STORE_PATH="$HOME/Desktop/apollo/Apollo CLI Tools"
BUILD_DIR="$HOME/Desktop/apollo/apollo_build"
GUI_INSTALL_DIR=/Applications
GUI_BUILD_APP_NAME=apollo_patcher_gui.app
GUI_INSTALL_APP_NAME="Apollo Patcher.app"
CONFIG
        ); then
            ui_done "Created local configuration"
        elif [ ! -f "$CONFIG_FILE" ]; then
            ui_emit "$UI_ERROR" "Error: unable to create configuration: $CONFIG_FILE" >&2
            return 1
        fi
    fi

    if [ ! -f "$CONFIG_FILE" ] || [ ! -r "$CONFIG_FILE" ]; then
        ui_emit "$UI_ERROR" "Error: configuration is not a readable file: $CONFIG_FILE" >&2
        return 1
    fi

    while IFS= read -r config_line || [[ -n "$config_line" ]]; do
        (( line_number += 1 ))
        config_line="${config_line%$'\r'}"
        config_line="${config_line##[[:space:]]#}"
        config_line="${config_line%%[[:space:]]#}"
        [[ -z "$config_line" || "$config_line" == \#* ]] && continue

        if [[ "$config_line" != *=* ]]; then
            ui_emit "$UI_ERROR" "Error: malformed configuration line $line_number in $CONFIG_FILE; expected key=value." >&2
            return 1
        fi
        key="${config_line%%=*}"
        key="${key%%[[:space:]]#}"
        value="${config_line#*=}"
        value="${value##[[:space:]]#}"
        case "$key" in
            WORKSPACE_DIR|STORE_PATH|BUILD_DIR|GUI_INSTALL_DIR|GUI_BUILD_APP_NAME|GUI_INSTALL_APP_NAME) ;;
            *) ui_emit "$UI_ERROR" "Error: unknown configuration key '$key' at line $line_number in $CONFIG_FILE." >&2; return 1 ;;
        esac
        if [[ -n "${config_values[$key]+present}" ]]; then
            ui_emit "$UI_ERROR" "Error: duplicate configuration key '$key' in $CONFIG_FILE." >&2
            return 1
        fi

        # Strip matching surrounding quotes, without interpreting their contents.
        if [[ "$value" == \"* ]]; then
            if (( ${#value} < 2 )) || [[ "$value" != *\" ]]; then
                ui_emit "$UI_ERROR" "Error: unmatched quotes at line $line_number in $CONFIG_FILE." >&2
                return 1
            fi
            value="${value#\"}"
            value="${value%\"}"
        elif [[ "$value" == \'* ]]; then
            if (( ${#value} < 2 )) || [[ "$value" != *\' ]]; then
                ui_emit "$UI_ERROR" "Error: unmatched quotes at line $line_number in $CONFIG_FILE." >&2
                return 1
            fi
            value="${value#\'}"
            value="${value%\'}"
        elif [[ "$value" == *\" || "$value" == *\' ]]; then
            ui_emit "$UI_ERROR" "Error: unmatched quotes at line $line_number in $CONFIG_FILE." >&2
            return 1
        fi

        case "$key" in
            WORKSPACE_DIR|STORE_PATH|BUILD_DIR|GUI_INSTALL_DIR)
                expand_config_path "$value" "$key" || return 1
                value="$REPLY"
                ;;
            GUI_BUILD_APP_NAME|GUI_INSTALL_APP_NAME)
                if [[ ! "$value" =~ '^[[:alnum:]][[:alnum:] ._-]*[.]app$' || "$value" == *'..'* ]]; then
                    ui_emit "$UI_ERROR" "Error: $key must be a simple .app basename with no slash or traversal." >&2
                    return 1
                fi
                ;;
        esac
        config_values[$key]="$value"
    done < "$CONFIG_FILE"

    for key in "${required_keys[@]}"; do
        if [[ -z "${config_values[$key]+present}" ]]; then
            ui_emit "$UI_ERROR" "Error: missing configuration key '$key' in $CONFIG_FILE." >&2
            return 1
        fi
    done

    WORKSPACE_DIR="${config_values[WORKSPACE_DIR]}"
    STORE_PATH="${config_values[STORE_PATH]}"
    BUILD_DIR="${config_values[BUILD_DIR]}"
    GUI_INSTALL_DIR="${config_values[GUI_INSTALL_DIR]}"
    GUI_BUILD_APP_NAME="${config_values[GUI_BUILD_APP_NAME]}"
    GUI_INSTALL_APP_NAME="${config_values[GUI_INSTALL_APP_NAME]}"
    if [ -n "$STORE_PATH_OVERRIDE" ]; then
        expand_config_path "$STORE_PATH_OVERRIDE" "STORE_PATH override" || return 1
        STORE_PATH="$REPLY"
    fi
    ui_done "Configuration validated"
}

# Validate all settings before any installation, repository mutation, or cleanup.
ui_banner
ui_section 1 "🧰" "Configuration & tools"
load_configuration || exit 1
initialize_build_log || exit 1

# Apple's LaunchServices location is shared by Intel and Apple Silicon macOS.
LSREGISTER_SYSTEM_BIN="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
GIT_BIN="$(command -v git 2>/dev/null || true)"
XCODESELECT_BIN="$(command -v xcode-select 2>/dev/null || true)"
CMAKE_BIN="$(command -v cmake 2>/dev/null || true)"
PYTHON3_BIN="$(command -v python3 2>/dev/null || true)"
RSYNC_BIN="$(command -v rsync 2>/dev/null || true)"
RSYNC_SYSTEM_BIN="/usr/bin/rsync"
MAKE_BIN="$(command -v make 2>/dev/null || true)"
CURL_BIN="$(command -v curl 2>/dev/null || true)"
TAR_BIN="$(command -v tar 2>/dev/null || true)"
BREW_BIN="$(command -v brew 2>/dev/null || true)"
XATTR_BIN="$(command -v xattr 2>/dev/null || true)"
CODESIGN_BIN="$(command -v codesign 2>/dev/null || true)"
XCRUN_BIN="$(command -v xcrun 2>/dev/null || true)"
LSREGISTER_BIN=""
UNIVERSAL_CMAKE_ARCHITECTURES='x86_64;arm64'
MACOS_DEPLOYMENT_TARGET='11.0'
APPLE_CLANG_BIN="${APPLE_CLANG_BIN:-}"
APPLE_CLANGPP_BIN="${APPLE_CLANGPP_BIN:-}"
LIPO_BIN="${LIPO_BIN:-}"
MACOS_SDK_PATH="${MACOS_SDK_PATH:-}"
UNIVERSAL_CC="${UNIVERSAL_CC:-}"
APOLLO_REPO_URL="git@github.com:bucanero/apollo-lib.git"
APOLLO_GUI_REPO_URL="git@github.com:bucanero/apollo-patcher.git"
APOLLO_PATCHES_REPO_URL="git@github.com:bucanero/apollo-patches.git"
GUI_INSTALL_RESULT="pending"
GUI_BUILD_APP_PATH=""
GUI_INSTALL_NOTE=""

MBEDTLS_VERSION=""
MBEDTLS_ARCHIVE=""
MBEDTLS_DIR=""
MBEDTLS_URL=""

apollo_repo_dir="$WORKSPACE_DIR/apollo-lib"
repo_root=""
gui_repo_root=""
patches_repo_root=""
lib_build_root=""
gui_build_root=""
BUILD_OWNER_MARKER=".apollo-lib-macos-build"
BUILD_OWNER_CONTENT="apollo-lib-macos managed workspace v1"
resolve_repo_root() {
    if [ ! -e "$apollo_repo_dir" ]; then
        if [ ! -x "$GIT_BIN" ]; then
            ui_emit "$UI_ERROR" "Error: git is required to clone apollo-lib but was not found." >&2
            exit 1
        fi

        run_logged "Clone apollo-lib" "$GIT_BIN" clone "$APOLLO_REPO_URL" "$apollo_repo_dir"
        repo_root="$(cd "$apollo_repo_dir" && pwd)"
        return
    fi

    if [ -f "$apollo_repo_dir/tools/Makefile" ]; then
        repo_root="$(cd "$apollo_repo_dir" && pwd)"
        return
    fi

    ui_emit "$UI_ERROR" "Unable to locate the apollo-lib repository root from: $WORKSPACE_DIR" >&2
    exit 1
}

resolve_gui_repo_root() {
    local gui_repo_dir="$WORKSPACE_DIR/apollo-patcher"

    if [ ! -e "$gui_repo_dir" ]; then
        run_logged "Clone apollo-patcher" "$GIT_BIN" clone "$APOLLO_GUI_REPO_URL" "$gui_repo_dir"
    fi

    if [ -d "$gui_repo_dir" ]; then
        gui_repo_root="$(cd "$gui_repo_dir" && pwd)"
        return
    fi

    ui_emit "$UI_ERROR" "Unable to locate the apollo-patcher repository from: $WORKSPACE_DIR" >&2
    exit 1
}

resolve_patches_repo_root() {
    local patches_repo_dir="$WORKSPACE_DIR/apollo-patches"

    if [ ! -e "$patches_repo_dir" ]; then
        run_logged "Clone apollo-patches" "$GIT_BIN" clone "$APOLLO_PATCHES_REPO_URL" "$patches_repo_dir"
    fi

    if [ -d "$patches_repo_dir" ]; then
        patches_repo_root="$(cd "$patches_repo_dir" && pwd)"
        return
    fi

    ui_emit "$UI_ERROR" "Unable to locate the apollo-patches repository from: $WORKSPACE_DIR" >&2
    exit 1
}

pull_latest_source() {
    local source_root="$1"
    local source_name="$2"

    if [ ! -e "$source_root/.git" ]; then
        ui_done "$source_name source directory retained (no Git checkout)"
        return
    fi

    if [ ! -x "$GIT_BIN" ]; then
        ui_emit "$UI_ERROR" "Warning: git is not installed, skipping repository pull." >&2
        return
    fi

    run_logged "Update $source_name (fast-forward only)" "$GIT_BIN" -C "$source_root" pull --ff-only
}

validate_repository_layout() {
    local source_root="$1"
    local source_name="$2"
    local marker

    shift 2
    for marker in "$@"; do
        if [ ! -f "$source_root/$marker" ]; then
            ui_emit "$UI_ERROR" "Error: $source_name repository is missing required file: $source_root/$marker" >&2
            exit 1
        fi
    done
}

ensure_artifact_exists() {
    local artifact="$1"
    local description="$2"

    if [ ! -e "$artifact" ]; then
        ui_emit "$UI_ERROR" "Error: Required $description not found: $artifact" >&2
        exit 1
    fi
}

clear_quarantine() {
    local artifact_path="$1"
    local description="$2"
    local attribute_listing

    log_detail "Quarantine check: $description ($artifact_path)"
    "$XATTR_BIN" -dr com.apple.quarantine "$artifact_path" >> "$LOG_FILE" 2>&1 || true

    attribute_listing="$("$XATTR_BIN" -lr "$artifact_path" 2>> "$LOG_FILE" || true)"
    log_detail "$attribute_listing"
    if [[ "$attribute_listing" == *": com.apple.quarantine:"* ]]; then
        ui_emit "$UI_ERROR" "Error: $description still has com.apple.quarantine." >&2
        return 1
    fi

    return 0
}

verify_universal_binary() {
    local artifact_path="$1"
    local description="$2"

    if ! run_logged "Verify Universal2: $description" "$LIPO_BIN" "$artifact_path" -verify_arch x86_64 arm64; then
        ui_emit "$UI_ERROR" "Error: $description missing required x86_64 and/or arm64 slice: $artifact_path" >&2
        "$LIPO_BIN" -archs "$artifact_path" >> "$LOG_FILE" 2>&1 || true
        return 1
    fi

    "$LIPO_BIN" -archs "$artifact_path" >> "$LOG_FILE" 2>&1 || true
}

sign_cli_artifact() {
    local artifact="$1"

    run_logged "Ad-hoc sign CLI: ${artifact:t}" "$CODESIGN_BIN" --force --sign - "$artifact"
}

verify_cli_artifact() {
    local artifact="$1"

    run_logged "Verify CLI signature: ${artifact:t}" "$CODESIGN_BIN" --verify --strict --verbose=2 "$artifact"
}

sign_gui_app() {
    local artifact="$1"

    run_logged "Ad-hoc sign completed GUI bundle" "$CODESIGN_BIN" --force --sign - "$artifact"
}

verify_gui_app() {
    local artifact="$1"

    local bundle_state="staged"
    if [[ "$artifact" == "$GUI_INSTALL_DIR/$GUI_INSTALL_APP_NAME" ]]; then
        bundle_state="installed"
    elif [[ "$artifact" == "$gui_build_root/"* ]]; then
        bundle_state="built"
    fi
    run_logged "Verify $bundle_state GUI signature" "$CODESIGN_BIN" --verify --deep --strict --verbose=2 "$artifact"
}

load_mbedtls_settings_from_workflow() {
    local workflow_path="$repo_root/.github/workflows/build.yml"
    local workflow_url=""

    if [ ! -f "$workflow_path" ]; then
        ui_emit "$UI_ERROR" "Error: Unable to find workflow file: $workflow_path" >&2
        exit 1
    fi

    workflow_url="$(sed -nE "/^[[:space:]]*curl[[:space:]]/s|.*['\"]?(https?://[^[:space:]'\"]*mbedtls-[0-9][0-9.]*\.tar\.gz)['\"]?.*|\1|p" "$workflow_path" | head -n 1)"
    workflow_url="${workflow_url#\"}"
    workflow_url="${workflow_url%\"}"
    workflow_url="${workflow_url#\'}"
    workflow_url="${workflow_url%\'}"

    if [ -z "$workflow_url" ]; then
        ui_emit "$UI_ERROR" "Error: Unable to find an mbedTLS tarball URL in $workflow_path" >&2
        exit 1
    fi

    MBEDTLS_URL="$workflow_url"
    MBEDTLS_ARCHIVE="${MBEDTLS_URL:t}"
    MBEDTLS_DIR="${MBEDTLS_ARCHIVE%.tar.gz}"
    MBEDTLS_VERSION="${MBEDTLS_DIR#mbedtls-}"

    if [[ ! "$MBEDTLS_VERSION" =~ '^[0-9]+(\.[0-9]+)+$' ]]; then
        ui_emit "$UI_ERROR" "Error: Parsed invalid mbedTLS version from $workflow_path: $MBEDTLS_VERSION" >&2
        exit 1
    fi

    log_detail "mbedTLS ${MBEDTLS_VERSION} selected by $workflow_path"
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
        log_detail "Using fallback full Xcode developer directory: $fallback_xcode"
        selected_developer_dir="$fallback_xcode"
    fi

    if [ -z "$selected_developer_dir" ] && is_valid_developer_dir "$fallback_clt"; then
        log_detail "Using fallback Command Line Tools developer directory: $fallback_clt"
        selected_developer_dir="$fallback_clt"
    fi

    if [ -z "$selected_developer_dir" ]; then
        if [ ! -x "$XCODESELECT_BIN" ]; then
            ui_emit "$UI_ERROR" "Error: xcode-select is not available and no usable Apple developer directory was found." >&2
            ui_emit "$UI_ERROR" "Please install Xcode or Command Line Tools manually and rerun this script." >&2
            exit 1
        fi

        echo "No usable Apple developer directory was found. Attempting to install Command Line Tools..."
        log_detail "Interactive Apple installer output remains on the terminal."
        if ! "$XCODESELECT_BIN" --install; then
            ui_emit "$UI_ERROR" "Note: xcode-select --install did not launch the installer (tools may already be present). Re-checking discovery immediately..." >&2
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
        ui_emit "$UI_ERROR" "Error: unable to locate a usable full Xcode or Command Line Tools directory." >&2
        ui_emit "$UI_ERROR" "Please ensure Xcode or Command Line Tools are installed or install Command Line Tools via: xcode-select --install." >&2
        exit 1
    fi

    export DEVELOPER_DIR="$selected_developer_dir"
    log_detail "Using Apple developer tools: $DEVELOPER_DIR"
    ui_done "Apple developer tools ready"
}

discover_build_tools() {
    # Keep tools already found on PATH even if Homebrew adds another bin directory.
    if [ ! -x "$GIT_BIN" ]; then
        GIT_BIN="$(command -v git 2>/dev/null || true)"
    fi
    if [ ! -x "$CMAKE_BIN" ]; then
        CMAKE_BIN="$(command -v cmake 2>/dev/null || true)"
    fi
    if [ ! -x "$PYTHON3_BIN" ]; then
        PYTHON3_BIN="$(command -v python3 2>/dev/null || true)"
    fi
    if [ ! -x "$RSYNC_BIN" ]; then
        RSYNC_BIN="$(command -v rsync 2>/dev/null || true)"
        if [ ! -x "$RSYNC_BIN" ] && [ -x "$RSYNC_SYSTEM_BIN" ]; then
            RSYNC_BIN="$RSYNC_SYSTEM_BIN"
        fi
    fi
    MAKE_BIN="$(command -v make 2>/dev/null || true)"
    CURL_BIN="$(command -v curl 2>/dev/null || true)"
    TAR_BIN="$(command -v tar 2>/dev/null || true)"
    BREW_BIN="$(command -v brew 2>/dev/null || true)"
    XCRUN_BIN="$(command -v xcrun 2>/dev/null || true)"
    XATTR_BIN="$(command -v xattr 2>/dev/null || true)"
    CODESIGN_BIN="$(command -v codesign 2>/dev/null || true)"
}

resolve_lsregister_bin() {
    LSREGISTER_BIN="$(whence -p lsregister 2>/dev/null || true)"
    if [ ! -x "$LSREGISTER_BIN" ] && [ -x "$LSREGISTER_SYSTEM_BIN" ]; then
        LSREGISTER_BIN="$LSREGISTER_SYSTEM_BIN"
    fi
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

ensure_homebrew_build_tools() {
    local -a missing_formulas=()
    local formula tool_name tool_bin formula_prefix
    local install_script=""

    discover_build_tools
    [ -x "$GIT_BIN" ] || missing_formulas+=(git)
    [ -x "$CMAKE_BIN" ] || missing_formulas+=(cmake)
    [ -x "$PYTHON3_BIN" ] || missing_formulas+=(python)
    [ -x "$RSYNC_BIN" ] || missing_formulas+=(rsync)
    if (( ${#missing_formulas} == 0 )); then
        return
    fi

    resolve_brew_bin

    if [ ! -x "$BREW_BIN" ]; then
        if [ ! -x "$CURL_BIN" ]; then
            ui_emit "$UI_ERROR" "Error: missing build tools (${missing_formulas[*]}) and Homebrew is unavailable. Install curl or provide these tools on PATH and rerun." >&2
            exit 1
        fi

        echo "Missing build tools (${missing_formulas[*]}), installing Homebrew now..."
        if ! install_script="$("$CURL_BIN" -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh 2>> "$LOG_FILE")"; then
            ui_emit "$UI_ERROR" "Error: failed to download Homebrew installer script." >&2
            exit 1
        fi

        if [ -z "$install_script" ]; then
            ui_emit "$UI_ERROR" "Error: downloaded Homebrew installer script is empty." >&2
            exit 1
        fi

        log_detail "Interactive Homebrew installer output remains on the terminal."
        if ! /bin/bash -c "$install_script"; then
            ui_emit "$UI_ERROR" "Error: Homebrew installer failed. Check the installer output and rerun." >&2
            exit 1
        fi
        resolve_brew_bin
        discover_build_tools
    fi

    if [ ! -x "$BREW_BIN" ]; then
        ui_emit "$UI_ERROR" "Error: Homebrew is unavailable; provide the missing build tools on PATH." >&2
        exit 1
    fi

    for formula in "${missing_formulas[@]}"; do
        tool_name="$formula"
        [ "$formula" != python ] || tool_name=python3
        tool_bin="$(command -v "$tool_name" 2>/dev/null || true)"

        # An installed formula outside PATH also satisfies the requirement.
        if [ ! -x "$tool_bin" ]; then
            formula_prefix="$("$BREW_BIN" --prefix "$formula" 2>/dev/null || true)"
            tool_bin="${formula_prefix:+$formula_prefix/bin/$tool_name}"
        fi

        if [ ! -x "$tool_bin" ]; then
            run_logged "Install missing $tool_name with Homebrew" "$BREW_BIN" install "$formula"
            tool_bin="$(command -v "$tool_name" 2>/dev/null || true)"
            if [ ! -x "$tool_bin" ]; then
                formula_prefix="$("$BREW_BIN" --prefix "$formula" 2>/dev/null || true)"
                tool_bin="${formula_prefix:+$formula_prefix/bin/$tool_name}"
            fi
        fi

        if [ ! -x "$tool_bin" ]; then
            ui_emit "$UI_ERROR" "Error: $tool_name is still unavailable after Homebrew setup. Provide it on PATH and rerun." >&2
            exit 1
        fi
        case "$formula" in
            git) GIT_BIN="$tool_bin" ;;
            cmake) CMAKE_BIN="$tool_bin" ;;
            python) PYTHON3_BIN="$tool_bin" ;;
            rsync) RSYNC_BIN="$tool_bin" ;;
        esac
    done

    discover_build_tools
}

# Function to store binaries
store_binaries() {
    # Check if STORE_PATH is set
    if [ -z "$STORE_PATH" ]; then
        ui_emit "$UI_ERROR" "Error: STORE_PATH is not set. Set the STORE_PATH variable to the directory where you want to store the compiled binaries." >&2
        exit 1
    fi

    run_logged "Prepare CLI destination" mkdir -p "$STORE_PATH"

    # Copy each CLI binary
    local binaries=(
        "$lib_build_root/tools/patcher"
        "$lib_build_root/tools/dumper"
    )

    for binary in "${binaries[@]}"; do
        ensure_artifact_exists "$binary" "CLI artifact"
        run_logged "Set CLI executable permissions: ${binary:t}" chmod 755 "$binary"
        clear_quarantine "$binary" "built CLI artifact $(basename "$binary")"
        verify_universal_binary "$binary" "CLI artifact $(basename "$binary")"
        verify_cli_artifact "$binary"
        run_logged "Install CLI: ${binary:t}" cp "$binary" "$STORE_PATH"
        run_logged "Set installed CLI permissions: ${binary:t}" chmod 755 "$STORE_PATH/$(basename "$binary")"
        clear_quarantine "$STORE_PATH/$(basename "$binary")" "stored CLI artifact $(basename "$binary")"
        verify_universal_binary "$STORE_PATH/$(basename "$binary")" "stored CLI artifact $(basename "$binary")"
        verify_cli_artifact "$STORE_PATH/$(basename "$binary")"
    done
}

cleanup_gui_staging() {
    local staging_dir="$1"
    if [ -n "$staging_dir" ] && [ -d "$staging_dir" ]; then
        if ! run_logged "Remove temporary GUI staging directory" rm -rf -- "$staging_dir"; then
            ui_emit "$UI_WARN" "  ⚠ Temporary GUI staging directory remains: $staging_dir" >&2
            return 1
        fi
    fi
    if [[ "$GUI_STAGING_DIR" == "$staging_dir" ]] && [ ! -e "$staging_dir" ]; then
        GUI_STAGING_DIR=""
        GUI_STAGING_PARENT=""
    fi
    return 0
}

# This helper is intentionally nonfatal; every fallible operation is guarded.
install_gui_bundle() {
    local gui_app="$1"
    local destination_app="$GUI_INSTALL_DIR/$GUI_INSTALL_APP_NAME"
    local staging_dir="" staged_app="" staged_exec=""

    if [ ! -d "$GUI_INSTALL_DIR" ]; then
        GUI_INSTALL_NOTE="GUI destination is not a directory: $GUI_INSTALL_DIR"
        return 1
    fi
    if [ ! -w "$GUI_INSTALL_DIR" ]; then
        GUI_INSTALL_NOTE="GUI destination is not writable: $GUI_INSTALL_DIR"
        return 1
    fi
    if ! GUI_STAGING_PARENT="$(cd "$GUI_INSTALL_DIR" && pwd -P)"; then
        GUI_INSTALL_NOTE="Unable to resolve the GUI destination directory"
        return 1
    fi
    if ! staging_dir="$(mktemp -d "$GUI_STAGING_PARENT/.apollo_patcher_gui.XXXXXX" 2>> "$LOG_FILE")"; then
        GUI_INSTALL_NOTE="Unable to create a GUI staging directory in $GUI_INSTALL_DIR"
        return 1
    fi
    GUI_STAGING_DIR="$staging_dir"
    if [ -z "$staging_dir" ] || [ ! -d "$staging_dir" ]; then
        GUI_INSTALL_NOTE="GUI staging directory was not created"
        return 1
    fi
    staged_app="$staging_dir/$GUI_INSTALL_APP_NAME"
    staged_exec="$staged_app/Contents/MacOS/apollo_patcher_gui"

    if ! run_logged "Stage verified GUI bundle" cp -R -- "$gui_app" "$staged_app"; then
        GUI_INSTALL_NOTE="Unable to copy the GUI into its staging directory"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if ! run_logged "Set staged GUI executable permissions" chmod 755 "$staged_exec"; then
        GUI_INSTALL_NOTE="Unable to set staged GUI executable permissions"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if ! clear_quarantine "$staged_exec" "staged GUI executable" || ! clear_quarantine "$staged_app" "staged GUI app"; then
        GUI_INSTALL_NOTE="Staged GUI quarantine checks failed"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if ! verify_universal_binary "$staged_exec" "staged GUI executable"; then
        GUI_INSTALL_NOTE="Staged GUI Universal2 verification failed"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if [ ! -x "$staged_exec" ]; then
        GUI_INSTALL_NOTE="Staged GUI executable is missing or not executable"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if ! verify_gui_app "$staged_app"; then
        GUI_INSTALL_NOTE="Staged GUI signature verification failed"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi

    if [ -e "$destination_app" ] || [ -L "$destination_app" ]; then
        if ! run_logged "Remove previous installed GUI bundle" rm -rf -- "$destination_app"; then
            GUI_INSTALL_NOTE="Unable to replace the existing GUI bundle"
            cleanup_gui_staging "$staging_dir" || true
            return 1
        fi
    fi
    if ! run_logged "Install staged GUI bundle" mv -- "$staged_app" "$destination_app"; then
        GUI_INSTALL_NOTE="Unable to move the GUI into its destination"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if ! run_logged "Set installed GUI executable permissions" chmod 755 "$destination_app/Contents/MacOS/apollo_patcher_gui"; then
        GUI_INSTALL_NOTE="Unable to set installed GUI executable permissions"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if ! clear_quarantine "$destination_app" "installed GUI app" || ! clear_quarantine "$destination_app/Contents/MacOS/apollo_patcher_gui" "installed GUI executable"; then
        GUI_INSTALL_NOTE="Installed GUI quarantine checks failed"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if ! verify_universal_binary "$destination_app/Contents/MacOS/apollo_patcher_gui" "installed GUI executable"; then
        GUI_INSTALL_NOTE="Installed GUI Universal2 verification failed"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi
    if ! verify_gui_app "$destination_app"; then
        GUI_INSTALL_NOTE="Installed GUI signature verification failed"
        cleanup_gui_staging "$staging_dir" || true
        return 1
    fi

    cleanup_gui_staging "$staging_dir" || true
    GUI_INSTALL_RESULT="installed"
    if ! run_logged "Register installed GUI with LaunchServices" "$LSREGISTER_BIN" -f "$destination_app"; then
        GUI_INSTALL_RESULT="registration-warning"
        ui_emit "$UI_WARN" "  ⚠ GUI installed and verified; LaunchServices registration failed.
    Installed app: $destination_app
    CLI installation will continue." >&2
        return 0
    fi
    ui_done "GUI installed, verified and registered" || true
    return 0
}

store_gui_bundle() {
    local gui_app="$gui_build_root/build/gui/$GUI_BUILD_APP_NAME"
    local gui_exec="$gui_app/Contents/MacOS/apollo_patcher_gui"
    local resource

    ensure_artifact_exists "$gui_app" "GUI bundle"
    ensure_artifact_exists "$gui_exec" "GUI executable"
    for resource in apollo-patches.zip NotoSansJP-Medium.otf OFL.txt; do
        if [ ! -f "$gui_app/Contents/Resources/$resource" ]; then
            ui_emit "$UI_ERROR" "Error: GUI bundle is missing required resource: $gui_app/Contents/Resources/$resource" >&2
            return 1
        fi
    done
    run_logged "Set built GUI executable permissions" chmod 755 "$gui_exec"
    clear_quarantine "$gui_exec" "built GUI executable"
    clear_quarantine "$gui_app" "built GUI app"
    verify_universal_binary "$gui_exec" "built GUI executable"
    sign_gui_app "$gui_app"
    verify_gui_app "$gui_app"
    GUI_BUILD_APP_PATH="$gui_app"
    if (( CLI_BUILD_READY )); then BUILD_OUTPUTS_READY=1; fi
    GUI_INSTALL_RESULT="manual"

    if install_gui_bundle "$gui_app"; then
        return 0
    fi
    ui_emit "$UI_WARN" "  ⚠ GUI installation failed: $GUI_INSTALL_NOTE
    Copy this signed, verified app manually in Finder:
    $GUI_BUILD_APP_PATH
    Destination: $GUI_INSTALL_DIR/$GUI_INSTALL_APP_NAME
    CLI installation will continue. Full log: $LOG_FILE" >&2
    return 0
}

physical_path() {
    "$PYTHON3_BIN" -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

path_is_within() {
    local candidate="${1%/}"
    local ancestor="$2"

    [ -n "$candidate" ] || candidate=/
    while true; do
        # File identity also catches case aliases on case-insensitive macOS disks.
        if [[ "$candidate" == "$ancestor" || "$candidate" -ef "$ancestor" ]]; then
            return 0
        fi
        [ "$candidate" != / ] || return 1
        candidate="${candidate:h}"
    done
}

validate_build_workspace() {
    local build_root source_root managed_root managed_name marker_contents expected_marker
    local -a source_roots=()

    build_root="$(physical_path "$BUILD_DIR")" || return 1
    for source_root in "$repo_root" "$gui_repo_root" "$patches_repo_root"; do
        source_root="$(physical_path "$source_root")" || return 1
        source_roots+=("$source_root")
    done

    for source_root in "${source_roots[@]}"; do
        if path_is_within "$build_root" "$source_root"; then
            ui_emit "$UI_ERROR" "Error: BUILD_DIR must be outside source checkouts: $build_root" >&2
            return 1
        fi
    done

    # Check BOTH disposable children before removing either of them.
    for managed_name in apollo-lib apollo-patcher; do
        managed_root="${build_root%/}/$managed_name"
        if [ -L "$managed_root" ]; then
            ui_emit "$UI_ERROR" "Error: refusing symlink build workspace: $managed_root" >&2
            return 1
        fi
        for source_root in "${source_roots[@]}"; do
            if path_is_within "$source_root" "$managed_root"; then
                ui_emit "$UI_ERROR" "Error: build workspace overlaps a source checkout: $managed_root" >&2
                return 1
            fi
        done

        if [ -e "$managed_root" ]; then
            if [ ! -d "$managed_root" ] || [ ! -f "$managed_root/$BUILD_OWNER_MARKER" ] || [ -L "$managed_root/$BUILD_OWNER_MARKER" ]; then
                ui_emit "$UI_ERROR" "Error: refusing existing workspace without a regular ownership marker: $managed_root" >&2
                return 1
            fi
            # Preserve trailing newlines so only the exact marker contents match.
            if ! marker_contents="$(cat "$managed_root/$BUILD_OWNER_MARKER" && print -n x)"; then
                ui_emit "$UI_ERROR" "Error: unable to read workspace ownership marker: $managed_root" >&2
                return 1
            fi
            expected_marker="${BUILD_OWNER_CONTENT}:${managed_name}"$'\n'x
            if [[ "$marker_contents" != "$expected_marker" ]]; then
                ui_emit "$UI_ERROR" "Error: refusing workspace with an unrecognized ownership marker: $managed_root" >&2
                return 1
            fi
        fi
    done

    BUILD_DIR="$build_root"
    lib_build_root="${BUILD_DIR%/}/apollo-lib"
    gui_build_root="${BUILD_DIR%/}/apollo-patcher"
}

prepare_build_workspace() {
    local managed_name managed_root copied_dir copied_root
    local -a copy_excludes=(
        --exclude=.git --exclude=.tmp/ --exclude=tmp/
        --exclude=build/ --exclude=dist/ '--exclude=mbedtls-*/'
        '--exclude=*.o' '--exclude=*.d' --exclude="$BUILD_OWNER_MARKER"
        --exclude=/tools/patcher --exclude=/tools/dumper --exclude=/tools/patcher-bigendian
        --exclude=/tools/patcher.exe --exclude=/tools/dumper.exe --exclude=/tools/patcher-bigendian.exe
        --exclude=/gui/src/type_icons.h
    )

    validate_build_workspace || return 1
    mkdir -p "$BUILD_DIR" || return 1
    validate_build_workspace || return 1
    for managed_name in apollo-lib apollo-patcher; do
        managed_root="${BUILD_DIR%/}/$managed_name"
        if [ -e "$managed_root" ]; then
            run_logged "Remove previous $managed_name build copy" rm -rf -- "$managed_root" || return 1
        fi
        mkdir "$managed_root" || return 1
        # Mark before copying, so a partial/interrupted copy can be replaced.
        (setopt noclobber; print -r -- "${BUILD_OWNER_CONTENT}:${managed_name}" > "$managed_root/$BUILD_OWNER_MARKER") || return 1
    done

    run_logged "Copy current library sources" "$RSYNC_BIN" -a "${copy_excludes[@]}" "$repo_root/" "$lib_build_root/" || return 1
    run_logged "Copy current GUI sources" "$RSYNC_BIN" -a "${copy_excludes[@]}" "$gui_repo_root/" "$gui_build_root/" || return 1

    # rsync preserves symlinks; build-output directories must remain in the copies.
    for copied_dir in "$lib_build_root/tools" "$lib_build_root/source" "$gui_build_root/gui/src"; do
        copied_root="$(physical_path "$copied_dir")" || return 1
        if [[ "$copied_dir" == "$lib_build_root/"* ]]; then
            managed_root="$lib_build_root"
        else
            managed_root="$gui_build_root"
        fi
        if ! path_is_within "$copied_root" "$managed_root" || [[ "$copied_root" -ef "$managed_root" ]]; then
            ui_emit "$UI_ERROR" "Error: copied build-output directory escapes its workspace: $copied_dir" >&2
            return 1
        fi
    done
}

# Resolve Apple toolchain and required build tools.
trap 'handle_signal SIGINT 130' SIGINT
trap 'handle_signal SIGTERM 143' SIGTERM
trap 'stop_work_indicator' EXIT
resolve_developer_dir
discover_build_tools
ensure_homebrew_build_tools
discover_build_tools

if [ ! -x "$GIT_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: git is required to clone/pull apollo-lib and was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$MAKE_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: make is required to build Apollo CLI tools and was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$CURL_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: curl is required to fetch external dependencies and was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$TAR_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: tar is required to unpack external dependencies and was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$CMAKE_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: cmake is required and still not installed after attempting Homebrew fallback." >&2
    exit 1
fi

if [ ! -x "$PYTHON3_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: python3 is required to generate GUI patch data and icons but was not found." >&2
    exit 1
fi

if [ ! -x "$RSYNC_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: rsync is required to copy sources into BUILD_DIR but was not found." >&2
    exit 1
fi

if [ ! -x "$XATTR_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: xattr is required to clear quarantine but was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$CODESIGN_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: codesign is required for artifact signing but was not found on PATH." >&2
    exit 1
fi

if [ ! -x "$XCRUN_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: xcrun is required for Apple toolchain discovery but was not found on PATH." >&2
    exit 1
fi

resolve_lsregister_bin
if [ ! -x "$LSREGISTER_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: lsregister is required to register the installed Apollo GUI bundle but was not found on PATH or at: $LSREGISTER_SYSTEM_BIN" >&2
    ui_emit "$UI_ERROR" "Provide an executable lsregister on PATH or restore Apple's LaunchServices tool, then rerun." >&2
    exit 1
fi

APPLE_CLANG_BIN="$("$XCRUN_BIN" --sdk macosx --find clang 2>/dev/null || true)"
if [ ! -x "$APPLE_CLANG_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: Apple clang was not found via xcrun --sdk macosx --find clang: $APPLE_CLANG_BIN" >&2
    exit 1
fi

APPLE_CLANGPP_BIN="$("$XCRUN_BIN" --sdk macosx --find clang++ 2>/dev/null || true)"
if [ ! -x "$APPLE_CLANGPP_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: Apple clang++ was not found via xcrun --sdk macosx --find clang++: $APPLE_CLANGPP_BIN" >&2
    exit 1
fi

LIPO_BIN="$("$XCRUN_BIN" --find lipo 2>/dev/null || true)"
if [ ! -x "$LIPO_BIN" ]; then
    ui_emit "$UI_ERROR" "Error: lipo was not found via xcrun --find lipo: $LIPO_BIN" >&2
    exit 1
fi

MACOS_SDK_PATH="$("$XCRUN_BIN" --sdk macosx --show-sdk-path 2>/dev/null || true)"
if [ ! -d "$MACOS_SDK_PATH" ]; then
    ui_emit "$UI_ERROR" "Error: failed to resolve macOS SDK path via xcrun --sdk macosx --show-sdk-path: ${MACOS_SDK_PATH:-<empty>}" >&2
    exit 1
fi

UNIVERSAL_CC="${(q)APPLE_CLANG_BIN} -isysroot ${(q)MACOS_SDK_PATH} -arch ${UNIVERSAL_CMAKE_ARCHITECTURES%%;*} -arch ${UNIVERSAL_CMAKE_ARCHITECTURES##*;} -mmacosx-version-min=${MACOS_DEPLOYMENT_TARGET}"

ui_done "Build tools ready"
apollo_repo_dir="$WORKSPACE_DIR/apollo-lib"
ui_section 2 "🔄" "Source repositories"
resolve_repo_root
resolve_gui_repo_root
resolve_patches_repo_root

cd "$repo_root"

pull_latest_source "$repo_root" "apollo-lib"
pull_latest_source "$gui_repo_root" "apollo-patcher"
pull_latest_source "$patches_repo_root" "apollo-patches"
validate_repository_layout "$repo_root" "apollo-lib" tools/Makefile include/apollo.h
validate_repository_layout "$gui_repo_root" "apollo-patcher" \
    CMakeLists.txt gui/CMakeLists.txt core/apollo_ctrl.c \
    tools/make-bundle.py tools/make-type-icons.py \
    gui/assets/fonts/NotoSansJP-Medium.otf gui/assets/fonts/OFL.txt gui/assets/icon.icns
validate_repository_layout "$patches_repo_root" "apollo-patches" PSP/gamekeys.txt
if [ ! -d "$patches_repo_root/python" ]; then
    ui_emit "$UI_ERROR" "Error: apollo-patches repository is missing required directory: $patches_repo_root/python" >&2
    exit 1
fi
load_mbedtls_settings_from_workflow
ui_done "Source layouts and desktop resources validated"
ui_section 3 "📁" "Disposable build workspace"
BUILD_WORKSPACE_ACTIVE=1
prepare_build_workspace
log_detail "Library build workspace: $lib_build_root" "GUI build workspace: $gui_build_root"
cd "$lib_build_root"

ui_section 4 "🧱" "mbedTLS $MBEDTLS_VERSION"
download_mbedtls

cd "$MBEDTLS_DIR"

if [ -d "build" ]; then
    log_detail "Removing extracted mbedTLS build directory"
    rm -rf build
fi

mkdir build
cd build

run_logged --animate "Configure Universal2 mbedTLS" "$CMAKE_BIN" .. \
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

run_logged --animate "Build Universal2 mbedcrypto" "$CMAKE_BIN" --build . --parallel --target mbedcrypto
ensure_artifact_exists "$lib_build_root/$MBEDTLS_DIR/build/library/libmbedcrypto.a" "mbedTLS static library"
verify_universal_binary "$lib_build_root/$MBEDTLS_DIR/build/library/libmbedcrypto.a" "mbedTLS static library"

cd "$lib_build_root"

ui_section 5 "🔧" "CLI build, signing & verification"
cd tools

# Build patcher + dumper
run_logged --animate "Clean copied CLI build output" "$MAKE_BIN" clean
run_logged --animate "Build Universal2 patcher and dumper" "$MAKE_BIN" CC="$UNIVERSAL_CC"
ensure_artifact_exists "$lib_build_root/tools/patcher" "CLI artifact patcher"
ensure_artifact_exists "$lib_build_root/tools/dumper" "CLI artifact dumper"
run_logged "Set built CLI executable permissions" chmod 755 "$lib_build_root/tools/patcher" "$lib_build_root/tools/dumper"
clear_quarantine "$lib_build_root/tools/patcher" "built CLI patcher"
clear_quarantine "$lib_build_root/tools/dumper" "built CLI dumper"
verify_universal_binary "$lib_build_root/tools/patcher" "CLI patcher"
verify_universal_binary "$lib_build_root/tools/dumper" "CLI dumper"
sign_cli_artifact "$lib_build_root/tools/patcher"
sign_cli_artifact "$lib_build_root/tools/dumper"
verify_cli_artifact "$lib_build_root/tools/patcher"
verify_cli_artifact "$lib_build_root/tools/dumper"
CLI_BUILD_READY=1
cd "$lib_build_root"

ui_section 6 "💻" "GUI build & bundled database"
run_logged --animate "Configure Universal2 GUI and resources" "$CMAKE_BIN" -S "$gui_build_root" -B "$gui_build_root/build" \
    -DAPOLLO_ROOT="$lib_build_root" \
    -DAPOLLO_PATCHES="$patches_repo_root" \
    -DGIT_EXECUTABLE="$GIT_BIN" \
    -DPython3_EXECUTABLE="$PYTHON3_BIN" \
    -DAPOLLO_BUILD_GUI=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$APPLE_CLANG_BIN" \
    -DCMAKE_CXX_COMPILER="$APPLE_CLANGPP_BIN" \
    -DCMAKE_OSX_ARCHITECTURES="$UNIVERSAL_CMAKE_ARCHITECTURES" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_SYSROOT="$MACOS_SDK_PATH"
run_logged --animate "Build GUI, database, font and icons" "$CMAKE_BIN" --build "$gui_build_root/build" --parallel

ui_section 7 "🔏" "GUI signing, installation & registration"
store_gui_bundle

# Call the function to store binaries
ui_section 8 "📦" "CLI installation"
store_binaries
case "$GUI_INSTALL_RESULT" in
    installed)
        completion_message="Apollo build and installation complete"
        gui_summary="$GUI_INSTALL_DIR/$GUI_INSTALL_APP_NAME"
        ;;
    registration-warning)
        completion_message="Apollo build complete · GUI registration warning"
        gui_summary="$GUI_INSTALL_DIR/$GUI_INSTALL_APP_NAME (installed; registration failed)"
        ;;
    *)
        completion_message="Apollo build complete · GUI needs manual installation"
        gui_summary="$GUI_BUILD_APP_PATH (copy manually)"
        ;;
esac
ui_emit "$UI_OK" "
+----------------------------------------------------------------+
  ✓ $completion_message
+----------------------------------------------------------------+
  GUI: $gui_summary
  CLI: $STORE_PATH
  Log: $LOG_FILE
"
