#!/bin/sh
# shellcheck shell=sh
#
# Install rambit, the bitnight-rambler CLI:
#
#   curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh | sh
#
# What it does:
#   1. picks the release binary for this machine: rambit-<arch>-<os> with
#      arch x86_64 or aarch64 and os linux or macos
#   2. downloads SHA256SUMS and SHA256SUMS.sig of the release and verifies the
#      ECDSA P-256 signature with the release public key embedded below
#   3. downloads the binary and checks its SHA-256 against the signed
#      SHA256SUMS
#   4. if gh is installed and logged in, checks the binary's GitHub artifact
#      attestation (Sigstore provenance from the release workflow)
#   5. checks that it reports the requested version and installs it
#      atomically as ~/.local/bin/rambit
#   Nothing is installed unless every check passes. Your shell startup files
#   are never edited; if the directory is not on PATH it says what to add.
#
# Run it as yourself, not with sudo: under sudo (SUDO_USER or DOAS_USER set)
# it refuses unless RAMBIT_INSTALL_DIR is set, e.g. to /usr/local/bin for a
# system-wide install. Plain root (containers, CI) installs to root's
# ~/.local/bin. It never prompts and never reads stdin.
#
# Environment:
#   RAMBIT_VERSION        release to install, e.g. 1.2.3 or v1.2.3
#                         (default: the latest release)
#   RAMBIT_INSTALL_DIR    absolute directory to install into
#                         (default: $HOME/.local/bin)
#   RAMBIT_INSECURE_SKIP_SIGNATURE=1
#                         only when openssl is not installed: install with
#                         the SHA-256 check alone. That detects corruption,
#                         not a tampered release. Ignored when openssl is
#                         present; a signature that fails is never skipped.
#   RAMBIT_SKIP_ATTESTATION=1
#                         skip the optional GitHub attestation check (it runs
#                         only when gh is installed and logged in; when it
#                         runs, a failure stops the install). The signature
#                         and SHA-256 checks still apply.
#   RAMBIT_DOWNLOAD_BASE  for testing: https:// or file:// URL used instead of
#                         https://github.com/shutx-net/bitnight-rambler/releases/download
#                         (requires RAMBIT_VERSION). Signatures are still
#                         checked against the embedded key only.
#
# Options (pass through sh: curl -fsSL ... | sh -s -- --help):
#   -h, --help            show this help
#
# Requires: curl uname id mktemp mkdir cp chmod mv rm grep awk tr, openssl,
# and one of sha256sum, shasum or openssl to compute SHA-256. Uses gh, and on
# macOS sysctl and sw_vers, when present.
#
# Everything below is a function definition until the last line, so a
# truncated download runs nothing.

set -eu

repo=shutx-net/bitnight-rambler
github=https://github.com/$repo
# The workflow that must have signed the GitHub artifact attestation.
signer_workflow=$repo/.github/workflows/release.yml

# Always assigned here, so the environment cannot supply a key.
# BEGIN RELEASE PUBLIC KEY
# Set with tools/release-key.sh embed; see docs/RELEASING.md.
release_public_key=''
# END RELEASE PUBLIC KEY

nl='
'

say() {
    printf 'rambit-install: %s\n' "$*"
}

warn() {
    printf 'rambit-install: %s\n' "$*" >&2
}

die() {
    printf 'rambit-install: error: %s\n' "$*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

usage() {
    cat <<'EOF'
Install rambit, the bitnight-rambler CLI, into ~/.local/bin.

  curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh | sh

The release's SHA256SUMS signature is verified with the release key embedded
in this script, then the binary's SHA-256 and version; nothing is installed
unless every check passes.

Environment:
  RAMBIT_VERSION=1.2.3          install this release instead of the latest
  RAMBIT_INSTALL_DIR=/abs/dir   install there instead of ~/.local/bin
  RAMBIT_INSECURE_SKIP_SIGNATURE=1
                                without openssl only: check the SHA-256 alone
                                (detects corruption, not tampering)
  RAMBIT_SKIP_ATTESTATION=1     skip the optional GitHub attestation check
                                (run when gh is installed and logged in)
  RAMBIT_DOWNLOAD_BASE=URL      testing: https:// or file:// release mirror
                                (needs RAMBIT_VERSION; same key checks)

Options (curl ... | sh -s -- --help):
  -h, --help                    show this help

Run it as yourself, not with sudo. For a system-wide install as root, set
RAMBIT_INSTALL_DIR=/usr/local/bin. Shell startup files are never edited.
EOF
}

cleanup() {
    if [ -n "$tmp_file" ]; then
        rm -f "$tmp_file"
    fi
    if [ -n "$tmp_dir" ]; then
        rm -rf "$tmp_dir"
    fi
}

check_release_key() {
    if [ -z "$release_public_key" ]; then
        die "this install.sh has no release key yet (release signing is not set up), so it cannot verify a release; nothing was installed"
    fi
}

detect_platform() {
    uname_s=$(uname -s) || die "uname -s failed"
    uname_m=$(uname -m) || die "uname -m failed"
    case $uname_s in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        *) die "unsupported OS: $uname_s; supported: Linux and macOS (x86_64, aarch64); WSL2 counts as Linux" ;;
    esac
    case $uname_m in
        x86_64 | amd64) arch=x86_64 ;;
        aarch64 | arm64) arch=aarch64 ;;
        *) die "unsupported CPU architecture: $uname_m; supported: x86_64 and aarch64 (arm64) on Linux and macOS" ;;
    esac
    case $os in
        macos) check_macos ;;
        linux) check_linux_kernel ;;
    esac
    asset=rambit-$arch-$os
}

# small_number STRING: true if STRING is 1 to 4 decimal digits, so that it is
# safe to compare with [ -lt ].
small_number() {
    case $1 in
        '' | *[!0-9]* | ?????*) return 1 ;;
    esac
}

check_macos() {
    # A Rosetta shell on Apple silicon reports x86_64; the native build fits.
    if [ "$arch" = x86_64 ] && command -v sysctl >/dev/null 2>&1 &&
        [ "$(sysctl -n hw.optional.arm64 2>/dev/null </dev/null)" = 1 ]; then
        arch=aarch64
        say "this shell runs under Rosetta on Apple silicon; installing the native aarch64 build"
    fi
    # The binaries require macOS 13 (their LC_BUILD_VERSION minos is 13.0).
    if command -v sw_vers >/dev/null 2>&1; then
        macos_version=$(sw_vers -productVersion 2>/dev/null </dev/null) || macos_version=
        macos_major=${macos_version%%.*}
        if small_number "$macos_major" && [ "$macos_major" -lt 13 ]; then
            die "rambit requires macOS 13 (Ventura) or newer; this is macOS $macos_version"
        fi
    fi
}

check_linux_kernel() {
    # Zig's default minimum Linux version for the static musl builds is 5.10.
    kernel=$(uname -r 2>/dev/null) || return 0
    case $kernel in
        *.*) ;;
        *) return 0 ;;
    esac
    kernel_major=${kernel%%.*}
    kernel_minor=${kernel#"$kernel_major".}
    kernel_minor=${kernel_minor%%[!0-9]*}
    small_number "$kernel_major" && small_number "$kernel_minor" || return 0
    if [ "$kernel_major" -lt 5 ] || { [ "$kernel_major" -eq 5 ] && [ "$kernel_minor" -lt 10 ]; }; then
        warn "warning: rambit is built for Linux 5.10 or newer; it may not run on $kernel"
    fi
}

resolve_install_dir() {
    if [ -n "${RAMBIT_INSTALL_DIR:-}" ]; then
        dir=$RAMBIT_INSTALL_DIR
    elif [ -n "${HOME:-}" ]; then
        dir=$HOME/.local/bin
    else
        die "HOME is not set; set RAMBIT_INSTALL_DIR to an absolute directory"
    fi
    case $dir in
        *"$nl"*) die "the install directory must not contain a newline" ;;
        /*) ;;
        *) die "the install directory must be an absolute path: $dir" ;;
    esac
    while :; do
        case $dir in
            / | *[!/]) break ;;
        esac
        dir=${dir%/}
    done
    target=${dir%/}/rambit
}

# check_root: under sudo or doas, HOME may still be the invoking user's, so
# the default would leave a root-owned ~/.local/bin in their home.
check_root() {
    uid=$(id -u) || die "id -u failed"
    [ "$uid" = 0 ] || return 0
    if [ -z "${RAMBIT_INSTALL_DIR:-}" ] && [ -n "${SUDO_USER:-}${DOAS_USER:-}" ]; then
        die "do not run this with sudo: it installs into your own ~/.local/bin. Run it as yourself, or set RAMBIT_INSTALL_DIR=/usr/local/bin to install system-wide as root."
    fi
    say "running as root; installing to $dir"
}

resolve_base() {
    if [ -z "${RAMBIT_DOWNLOAD_BASE:-}" ]; then
        base=$github/releases/download
        return 0
    fi
    base=$RAMBIT_DOWNLOAD_BASE
    case $base in
        *"$nl"*) die "RAMBIT_DOWNLOAD_BASE must not contain a newline" ;;
        https://?* | file://?*) ;;
        *) die "RAMBIT_DOWNLOAD_BASE must start with https:// or file://: $base" ;;
    esac
    while :; do
        case $base in
            */) base=${base%/} ;;
            *) break ;;
        esac
    done
    [ -n "${RAMBIT_VERSION:-}" ] || die "RAMBIT_DOWNLOAD_BASE requires RAMBIT_VERSION"
    warn "WARNING: downloading from $base, not GitHub (RAMBIT_DOWNLOAD_BASE)"
}

# pick_tools: the hash tool (never optional) and whether the signature can be
# checked.
pick_tools() {
    if command -v sha256sum >/dev/null 2>&1; then
        hash_tool=sha256sum
    elif command -v shasum >/dev/null 2>&1; then
        hash_tool=shasum
    elif command -v openssl >/dev/null 2>&1; then
        hash_tool=openssl
    else
        die "no SHA-256 tool found: install one of sha256sum (coreutils), shasum (perl) or openssl"
    fi
    if command -v openssl >/dev/null 2>&1; then
        verify_signature=1
        if [ "${RAMBIT_INSECURE_SKIP_SIGNATURE:-}" = 1 ]; then
            warn "note: openssl is installed, so RAMBIT_INSECURE_SKIP_SIGNATURE=1 is ignored and the signature is verified"
        fi
    elif [ "${RAMBIT_INSECURE_SKIP_SIGNATURE:-}" = 1 ]; then
        verify_signature=
        warn "WARNING: openssl is not installed and RAMBIT_INSECURE_SKIP_SIGNATURE=1 is set:"
        warn "WARNING: the release signature will NOT be verified. Only the SHA-256 hash"
        warn "WARNING: is checked, which detects a corrupted download but NOT a tampered"
        warn "WARNING: release. Install openssl and run this again to verify it."
    else
        die "openssl is required to verify the release signature. Install it (Debian/Ubuntu: apt-get install openssl; Fedora: dnf install openssl; Alpine: apk add openssl; Arch: pacman -S openssl) and run this again. To install without verifying the signature (the SHA-256 is still checked, which detects corruption but not a tampered release), set RAMBIT_INSECURE_SKIP_SIGNATURE=1."
    fi
}

# valid_tag TAG: vMAJOR.MINOR.PATCH with an optional -prerelease suffix.
valid_tag() {
    case $1 in
        *"$nl"*) return 1 ;;
    esac
    printf '%s\n' "$1" | grep -Eqx 'v[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(-[0-9A-Za-z.-]{1,64})?' || return 1
}

resolve_version() {
    if [ -n "${RAMBIT_VERSION:-}" ]; then
        case $RAMBIT_VERSION in
            v*) tag=$RAMBIT_VERSION ;;
            *) tag=v$RAMBIT_VERSION ;;
        esac
        valid_tag "$tag" || die "invalid RAMBIT_VERSION: '$RAMBIT_VERSION' (expected e.g. 1.2.3 or v1.2.3)"
        return 0
    fi
    say "looking up the latest release of $repo"
    latest_url=$(curl --proto '=https' --tlsv1.2 -fsS --connect-timeout 30 -o /dev/null -w '%{redirect_url}' "$github/releases/latest" </dev/null) ||
        die "cannot look up the latest release on GitHub; check your network, or set RAMBIT_VERSION"
    case $latest_url in
        "$github/releases/tag/"?*) tag=${latest_url#"$github/releases/tag/"} ;;
        "$github/releases" | "$github/releases/") die "no release has been published yet" ;;
        *) die "unexpected answer while looking up the latest release: '$latest_url'" ;;
    esac
    valid_tag "$tag" || die "the latest release has an unexpected tag: '$tag'"
}

make_tmp_dir() {
    tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t rambit) ||
        die "cannot create a temporary directory"
    [ -n "$tmp_dir" ] && [ -d "$tmp_dir" ] ||
        die "cannot create a temporary directory"
}

# fetch URL OUT
fetch() {
    case $base in
        file://*)
            curl --proto '=file' -fsS -o "$2" "$1" </dev/null || return 1
            ;;
        *)
            curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 3 --connect-timeout 30 --max-filesize 52428800 -o "$2" "$1" </dev/null || return 1
            ;;
    esac
}

# sha256_of FILE: print the file's lowercase hex SHA-256. The file is read
# from stdin, so its name never appears in the tool's output.
sha256_of() {
    case $hash_tool in
        sha256sum) sum=$(sha256sum <"$1") || return 1 ;;
        shasum) sum=$(shasum -a 256 <"$1") || return 1 ;;
        openssl) sum=$(openssl dgst -sha256 -r <"$1") || return 1 ;;
        *) return 1 ;;
    esac
    sum=${sum%%[!0-9a-f]*}
    printf '%s\n' "$sum" | grep -Eqx '[0-9a-f]{64}' || return 1
    printf '%s\n' "$sum"
}

# verify_sums_signature SUMS SIG
verify_sums_signature() {
    printf '%s\n' "$release_public_key" >"$tmp_dir/release-key.pem" || return 1
    verified=$(openssl dgst -sha256 -verify "$tmp_dir/release-key.pem" -signature "$2" "$1" </dev/null 2>/dev/null) ||
        return 1
    case $verified in
        *'Verified OK'*) ;;
        *) return 1 ;;
    esac
}

# expected_hash SUMS: print the hash listed for $asset. Every line must be
# "<64 lowercase hex>  <name>" and the asset must be listed exactly once.
expected_hash() {
    [ -s "$1" ] || return 1
    if grep -Evq '^[0-9a-f]{64}  [A-Za-z0-9._-]+$' "$1"; then
        return 1
    fi
    awk -v n="$asset" '$2 == n { c++; h = $1 } END { if (c != 1) exit 1; print h }' "$1" || return 1
}

download_and_verify() {
    say "downloading $asset ($tag) from $base/$tag/"
    sums=$tmp_dir/SHA256SUMS
    fetch "$base/$tag/SHA256SUMS" "$sums" ||
        die "cannot download $base/$tag/SHA256SUMS (does release $tag exist?)"
    if [ -n "$verify_signature" ]; then
        fetch "$base/$tag/SHA256SUMS.sig" "$tmp_dir/SHA256SUMS.sig" ||
            die "cannot download $base/$tag/SHA256SUMS.sig"
        verify_sums_signature "$sums" "$tmp_dir/SHA256SUMS.sig" ||
            die "the signature of SHA256SUMS does NOT verify with the release key embedded in this install.sh. The release may have been tampered with, or this install.sh is outdated. Nothing was installed."
        signature_status='verified with the embedded release key'
    else
        signature_status='SKIPPED (openssl missing, RAMBIT_INSECURE_SKIP_SIGNATURE=1): only the SHA-256 was checked'
    fi
    expected=$(expected_hash "$sums") ||
        die "SHA256SUMS of $tag is malformed or does not list $asset exactly once. Nothing was installed."
    fetch "$base/$tag/$asset" "$tmp_dir/$asset" ||
        die "cannot download $base/$tag/$asset"
    actual=$(sha256_of "$tmp_dir/$asset") ||
        die "cannot compute the SHA-256 of $asset with $hash_tool"
    [ "$actual" = "$expected" ] ||
        die "SHA-256 mismatch for $asset: expected $expected, got $actual. Nothing was installed."
}

# sanitize: copy stdin to stdout without control characters other than tab
# and newline, so tool output cannot drive the terminal.
sanitize() {
    LC_ALL=C tr -d '\000-\010\013-\037\177'
}

# verify_attestation FILE: the optional Sigstore provenance check. When it
# runs and fails, the file is not what the release workflow attested.
verify_attestation() {
    if [ "${RAMBIT_SKIP_ATTESTATION:-}" = 1 ]; then
        provenance_status='skipped (RAMBIT_SKIP_ATTESTATION=1)'
        return 0
    fi
    if ! command -v gh >/dev/null 2>&1 ||
        ! GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh auth status >/dev/null 2>&1 </dev/null; then
        provenance_status="not checked (gh not installed or not logged in); to check: gh attestation verify \"$target\" --repo $repo"
        return 0
    fi
    # An older gh without these flags would fail for its own reasons.
    gh_help=$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh attestation verify --help 2>&1 </dev/null) || gh_help=
    for flag in --signer-workflow --source-ref --deny-self-hosted-runners; do
        case $gh_help in
            *"$flag"*) ;;
            *)
                provenance_status="not checked (this gh is too old for gh attestation verify $flag; upgrade gh, then: gh attestation verify \"$target\" --repo $repo)"
                return 0
                ;;
        esac
    done
    say "checking the GitHub artifact attestation of $asset with gh"
    if GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh attestation verify "$1" \
        --repo "$repo" \
        --signer-workflow "$signer_workflow" \
        --source-ref "refs/tags/$tag" \
        --deny-self-hosted-runners \
        </dev/null >"$tmp_dir/gh.out" 2>&1; then
        provenance_status='verified (GitHub artifact attestation, Sigstore)'
        return 0
    fi
    sanitize <"$tmp_dir/gh.out" >&2 || :
    die "gh attestation verify failed for $asset ($tag): it does not match what the release workflow of $repo attested. Nothing was installed. If GitHub's attestation service is unavailable, set RAMBIT_SKIP_ATTESTATION=1 to skip this optional check (the release signature and SHA-256 are still verified)."
}

install_binary() {
    mkdir -p "$dir" || die "cannot create $dir"
    if [ -d "$target" ]; then
        die "$target is a directory; remove it and run this again"
    fi
    tmp_file=$(mktemp "$dir/.rambit.XXXXXX") ||
        die "cannot create a file in $dir"
    cp "$tmp_dir/$asset" "$tmp_file" || die "cannot write $tmp_file"
    chmod 755 "$tmp_file" || die "cannot make $tmp_file executable"
    # Binds the signed binary to the requested tag, so an older signed
    # release cannot be replayed under a newer tag.
    reported=$("$tmp_file" --version </dev/null 2>/dev/null) ||
        die "the downloaded rambit does not run on this machine (is $dir on a noexec filesystem?)"
    [ "$reported" = "rambit ${tag#v}" ] ||
        die "the downloaded binary reports '$reported', expected 'rambit ${tag#v}'. Nothing was installed."
    mv -f "$tmp_file" "$target" || die "cannot move the new binary to $target"
    tmp_file=
}

# shell_safe STRING: true if STRING can be shown inside a suggested shell
# command without quoting surprises.
shell_safe() {
    case $1 in
        '' | *[!A-Za-z0-9._/@+=,~-]*) return 1 ;;
    esac
}

# print_path_hint: say how to put $dir on PATH (rc files are never edited),
# or warn when another rambit comes first on PATH.
print_path_hint() {
    case ":$PATH:" in
        *":$dir:"* | *":$dir/:"*)
            found=$(command -v rambit 2>/dev/null) || found=
            if [ -n "$found" ] && [ "$found" != "$target" ]; then
                warn "warning: $found comes first on PATH and shadows the new $target; remove it or put $dir before it on PATH"
            fi
            return 0
            ;;
    esac
    found=$(command -v rambit 2>/dev/null) || found=
    if [ -n "$found" ] && [ "$found" != "$target" ]; then
        warn "warning: 'rambit' currently runs $found, not the new $target"
    fi
    home=${HOME:-}
    home=${home%/}
    shown=$dir
    tilde=$dir
    if [ -n "$home" ]; then
        case $dir in
            "$home"/*)
                shown=\$HOME/${dir#"$home"/}
                tilde=\~/${dir#"$home"/}
                ;;
        esac
    fi
    printf '\n'
    say "$dir is not on your PATH. To add it:"
    if ! shell_safe "$tilde"; then
        say "  add $dir to PATH in your shell's startup file, then open a new terminal"
        return 0
    fi
    case ${SHELL##*/} in
        zsh) rc=.zshrc ;;
        bash)
            if [ "$os" = macos ]; then
                rc=.bash_profile
            else
                rc=.bashrc
            fi
            ;;
        fish)
            say "  fish_add_path $tilde"
            return 0
            ;;
        *) rc=.profile ;;
    esac
    say "  echo 'export PATH=\"$shown:\$PATH\"' >> ~/$rc"
    say "then open a new terminal, or run: export PATH=\"$shown:\$PATH\""
}

print_summary() {
    printf '\n'
    say "installed rambit ${tag#v}"
    say "  path: $target"
    say "  signature: $signature_status"
    say "  sha256: $actual (matches SHA256SUMS)"
    say "  provenance: $provenance_status"
    if [ -z "$verify_signature" ]; then
        warn "WARNING: the release signature was NOT verified (openssl missing, RAMBIT_INSECURE_SKIP_SIGNATURE=1)"
    fi
    print_path_hint
    printf '\n'
    say "next steps: rambit cat, rambit --help"
    say "to uninstall: rm \"$target\" (rambit writes no other files)"
}

main() {
    if [ $# -gt 0 ]; then
        if [ $# -eq 1 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then
            usage
            exit 0
        fi
        usage >&2
        exit 2
    fi

    tmp_dir=
    tmp_file=
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    for cmd in curl uname id mktemp mkdir cp chmod mv rm grep awk tr; do
        need "$cmd"
    done
    check_release_key
    detect_platform
    resolve_install_dir
    check_root
    resolve_base
    pick_tools
    resolve_version
    make_tmp_dir
    download_and_verify
    verify_attestation "$tmp_dir/$asset"
    install_binary
    print_summary
}

main "$@"
