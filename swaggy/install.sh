#!/bin/sh
# shellcheck shell=dash
#
# Swaggy installer
# Usage:
#   curl -sSL https://pkgs.julian-siebert.de/swaggy/install.sh | sh
#
# Environment variables:
#   SWAGGY_VERSION    Version to install (default: latest)
#   SWAGGY_INSTALL_DIR  Install location (default: $HOME/.local/bin)
#   SWAGGY_NO_MODIFY_PATH  Set to any value to skip PATH modification

set -eu

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BASE_URL="${SWAGGY_BASE_URL:-https://pkgs.julian-siebert.de/swaggy}"
VERSION="${SWAGGY_VERSION:-latest}"
INSTALL_DIR="${SWAGGY_INSTALL_DIR:-$HOME/.local/bin}"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    BOLD=$(printf '\033[1m')
    DIM=$(printf '\033[2m')
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    RESET=$(printf '\033[0m')
else
    BOLD='' DIM='' RED='' GREEN='' YELLOW='' RESET=''
fi

info()  { printf '%s==>%s %s\n' "$BOLD" "$RESET" "$1"; }
warn()  { printf '%swarning:%s %s\n' "$YELLOW$BOLD" "$RESET" "$1" >&2; }
err()   { printf '%serror:%s %s\n' "$RED$BOLD" "$RESET" "$1" >&2; }
done_() { printf '%s✓%s %s\n' "$GREEN$BOLD" "$RESET" "$1"; }

die() { err "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------

need_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "required command '$1' not found in PATH"
    fi
}

check_prerequisites() {
    need_cmd uname
    need_cmd mkdir
    need_cmd chmod
    need_cmd mktemp

    if command -v curl >/dev/null 2>&1; then
        DOWNLOADER="curl"
    elif command -v wget >/dev/null 2>&1; then
        DOWNLOADER="wget"
    else
        die "neither curl nor wget found; install one of them and retry"
    fi

    if command -v sha256sum >/dev/null 2>&1; then
        SHA_TOOL="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        SHA_TOOL="shasum -a 256"
    else
        warn "no sha256 tool found; checksum verification will be skipped"
        SHA_TOOL=""
    fi
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

detect_target() {
    os=$(uname -s)
    arch=$(uname -m)

    case "$os" in
        Linux)
            case "$arch" in
                x86_64|amd64)         echo "x86_64-unknown-linux-gnu" ;;
                aarch64|arm64)        echo "aarch64-unknown-linux-gnu" ;;
                *) die "unsupported Linux architecture: $arch" ;;
            esac ;;
        Darwin)
            case "$arch" in
                x86_64)               echo "x86_64-apple-darwin" ;;
                arm64)                echo "aarch64-apple-darwin" ;;
                *) die "unsupported macOS architecture: $arch" ;;
            esac ;;
        MINGW*|MSYS*|CYGWIN*)
            case "$arch" in
                x86_64)               echo "x86_64-pc-windows-msvc" ;;
                *) die "unsupported Windows architecture: $arch" ;;
            esac ;;
        *)
            die "unsupported operating system: $os" ;;
    esac
}

# ---------------------------------------------------------------------------
# Download with retries
# ---------------------------------------------------------------------------

download() {
    url="$1"
    output="$2"
    attempts=3

    i=1
    while [ "$i" -le "$attempts" ]; do
        if [ "$DOWNLOADER" = "curl" ]; then
            if curl --proto '=https' --tlsv1.2 \
                    --fail --silent --show-error --location \
                    --connect-timeout 10 --max-time 300 \
                    --output "$output" "$url"; then
                return 0
            fi
        else
            if wget --https-only --quiet \
                    --timeout=300 --tries=1 \
                    --output-document="$output" "$url"; then
                return 0
            fi
        fi

        if [ "$i" -lt "$attempts" ]; then
            warn "download failed, retrying ($i/$attempts)..."
            sleep 2
        fi
        i=$((i + 1))
    done

    die "failed to download $url after $attempts attempts"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify_sha256() {
    file="$1"
    expected="$2"

    if [ -z "$SHA_TOOL" ]; then
        return 0
    fi

    actual=$($SHA_TOOL "$file" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        err "checksum mismatch for $file"
        err "  expected: $expected"
        err "  actual:   $actual"
        die "refusing to install a binary that failed verification"
    fi
}

# ---------------------------------------------------------------------------
# JSON parsing (without jq)
# ---------------------------------------------------------------------------

# Extracts a string value for a given key path from a flat-ish JSON manifest.
# Usage: json_get <file> <target> <field>
# Example: json_get manifest.json x86_64-unknown-linux-gnu sha256
json_get() {
    file="$1"
    target="$2"
    field="$3"

    # Find the target block, then extract the field within it.
    # Works for our manifest structure: {"targets": {"<target>": {"sha256": "..."}}}
    awk -v target="\"$target\"" -v field="\"$field\"" '
        $0 ~ target { in_block = 1; next }
        in_block && $0 ~ field {
            match($0, /"[^"]+"[[:space:]]*:[[:space:]]*"[^"]+"/)
            value = substr($0, RSTART, RLENGTH)
            gsub(/.*:[[:space:]]*"/, "", value)
            gsub(/".*/, "", value)
            print value
            exit
        }
        in_block && /\}/ { in_block = 0 }
    ' "$file"
}

# ---------------------------------------------------------------------------
# PATH handling
# ---------------------------------------------------------------------------

is_in_path() {
    case ":$PATH:" in
        *":$1:"*) return 0 ;;
        *)        return 1 ;;
    esac
}

detect_shell_profile() {
    # Use $SHELL as the source of truth, fall back to inspecting files.
    case "${SHELL:-}" in
        */zsh)  echo "$HOME/.zshrc" ;;
        */bash)
            if [ -f "$HOME/.bashrc" ]; then
                echo "$HOME/.bashrc"
            else
                echo "$HOME/.bash_profile"
            fi ;;
        */fish) echo "$HOME/.config/fish/config.fish" ;;
        *)      echo "" ;;
    esac
}

suggest_path_setup() {
    profile=$(detect_shell_profile)
    echo
    warn "$INSTALL_DIR is not in your PATH"
    echo
    if [ -n "$profile" ]; then
        case "$profile" in
            *fish*)
                echo "  Add this line to ${BOLD}$profile${RESET}:"
                echo
                echo "    fish_add_path $INSTALL_DIR"
                ;;
            *)
                echo "  Add this line to ${BOLD}$profile${RESET}:"
                echo
                echo "    export PATH=\"$INSTALL_DIR:\$PATH\""
                ;;
        esac
        echo
        echo "  Then reload your shell or run: ${BOLD}source $profile${RESET}"
    else
        echo "  Add ${BOLD}$INSTALL_DIR${RESET} to your shell's PATH."
    fi
    echo
}

# ---------------------------------------------------------------------------
# Main installation flow
# ---------------------------------------------------------------------------

main() {
    info "Swaggy installer"
    check_prerequisites

    target=$(detect_target)
    info "Detected platform: ${BOLD}$target${RESET}"

    tmp=$(mktemp -d 2>/dev/null || mktemp -d -t swaggy-install)
    trap 'rm -rf "$tmp"' EXIT INT TERM

    manifest_url="$BASE_URL/$VERSION/manifest.json"
    info "Fetching manifest: ${DIM}$manifest_url${RESET}"
    download "$manifest_url" "$tmp/manifest.json"

    resolved_version=$(json_get "$tmp/manifest.json" "version" "" 2>/dev/null || true)
    # Fallback parser for top-level version field
    if [ -z "$resolved_version" ]; then
        resolved_version=$(awk '
            /"version"[[:space:]]*:/ {
                match($0, /"version"[[:space:]]*:[[:space:]]*"[^"]+"/)
                value = substr($0, RSTART, RLENGTH)
                gsub(/.*:[[:space:]]*"/, "", value)
                gsub(/".*/, "", value)
                print value
                exit
            }
        ' "$tmp/manifest.json")
    fi

    if [ -z "$resolved_version" ]; then
        die "could not parse version from manifest"
    fi

    binary_name=$(json_get "$tmp/manifest.json" "$target" "binary")
    expected_sha=$(json_get "$tmp/manifest.json" "$target" "sha256")

    if [ -z "$binary_name" ]; then
        die "no binary available for target '$target' in version $resolved_version"
    fi

    info "Installing swaggy ${BOLD}v$resolved_version${RESET}"

    binary_url="$BASE_URL/$VERSION/$target/$binary_name"
    info "Downloading binary: ${DIM}$binary_url${RESET}"
    download "$binary_url" "$tmp/$binary_name"

    if [ -n "$expected_sha" ]; then
        info "Verifying checksum"
        verify_sha256 "$tmp/$binary_name" "$expected_sha"
    fi

    info "Installing to $INSTALL_DIR/$binary_name"
    mkdir -p "$INSTALL_DIR"
    mv "$tmp/$binary_name" "$INSTALL_DIR/$binary_name"
    chmod +x "$INSTALL_DIR/$binary_name"

    done_ "swaggy v$resolved_version installed to $INSTALL_DIR/$binary_name"

    if ! is_in_path "$INSTALL_DIR" && [ -z "${SWAGGY_NO_MODIFY_PATH:-}" ]; then
        suggest_path_setup
    else
        echo
        echo "Run ${BOLD}swaggy --help${RESET} to get started."
    fi
}

main "$@"
