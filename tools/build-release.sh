#!/bin/sh
# Builds the four release binaries of rambit, checks them and writes their
# SHA256SUMS:
#
#     tools/build-release.sh OUTDIR
#
# OUTDIR must not exist or be empty. It receives rambit-<arch>-<os> for
# x86_64/aarch64 Linux (static, musl) and macOS (13.0 or later), and
# SHA256SUMS. ZIG selects the compiler (default: zig).
#
# CI and the release workflow both run this script, and the release
# workflow runs it on a Linux and a macOS host and requires the same
# SHA256SUMS from both: the build is reproducible across hosts, checkout
# paths and caches. This script never signs anything; only the release
# workflow does.
#
# The binaries are copied exactly as the linker wrote them. ReleaseSmall
# already strips them, and the arm64 Mach-O carries the linker's ad-hoc
# code signature, which any later edit (strip, codesign_allocate, ...)
# would invalidate; macOS kills an arm64 binary whose signature is broken.
set -eu

# triple:name pairs. The macOS minimum and the CPU are explicit, although
# they are Zig's defaults, so that a Zig upgrade cannot change them silently.
targets='
x86_64-linux-musl:x86_64-linux
aarch64-linux-musl:aarch64-linux
x86_64-macos.13.0:x86_64-macos
aarch64-macos.13.0:aarch64-macos
'

max_size=5000000

say() { printf 'build-release: %s\n' "$*"; }
die() { printf 'build-release: error: %s\n' "$*" >&2; exit 1; }

cleanup() { [ -z "${work:-}" ] || rm -rf "$work"; }

usage() {
    printf 'usage: %s OUTDIR\n' "$0" >&2
    exit 2
}

# Prints the absolute path of OUTDIR, creating it; dies if it is not empty.
prepare_out() {
    [ ! -e "$1" ] || [ -d "$1" ] || die "$1 exists and is not a directory"
    mkdir -p "$1"
    [ -z "$(ls -A "$1")" ] || die "$1 is not empty"
    (cd -P "$1" && pwd)
}

read_version() {
    v=$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' build.zig.zon)
    [ -n "$v" ] || die "no version in build.zig.zon"
    printf '%s\n' "$v"
}

build_one() { # triple, name
    say "building rambit-$2 ($1)"
    "$ZIG" build -Dtarget="$1" -Dcpu=baseline -Doptimize=ReleaseSmall \
        --prefix "$work/$2" --summary none
    cp "$work/$2/bin/rambit" "$out/rambit-$2"
}

# Checks the format of a binary with file(1), whose wording differs between
# Linux and macOS, so only pieces both have are matched.
check_format() { # name
    f="$out/rambit-$1"
    desc=$(file -b "$f")
    case $1 in
        x86_64-linux) want='ELF 64-bit|x86-64' ;;
        aarch64-linux) want='ELF 64-bit|aarch64' ;;
        x86_64-macos) want='Mach-O 64-bit|x86_64' ;;
        aarch64-macos) want='Mach-O 64-bit|arm64' ;;
        *) die "unknown target $1" ;;
    esac
    old_ifs=$IFS
    IFS='|'
    for piece in $want; do
        case $desc in
            *"$piece"*) ;;
            *) die "rambit-$1 is not $piece: $desc" ;;
        esac
    done
    IFS=$old_ifs
    case $1 in
        *-linux)
            case $desc in
                *'dynamically linked'* | *interpreter*)
                    die "rambit-$1 is dynamically linked: $desc" ;;
                *'statically linked'* | *'static-pie linked'*) ;;
                *) die "rambit-$1 is not statically linked: $desc" ;;
            esac
            ;;
    esac
    size=$(wc -c < "$f")
    size=$((size + 0))
    if [ "$size" -le 0 ] || [ "$size" -ge "$max_size" ]; then
        die "rambit-$1 has an implausible size: $size bytes"
    fi
    say "rambit-$1: $size bytes, $desc"
}

# Prints the name of the target the host can run, if any.
native_target() {
    case $(uname -s):$(uname -m) in
        Linux:x86_64 | Linux:amd64) echo x86_64-linux ;;
        Linux:aarch64 | Linux:arm64) echo aarch64-linux ;;
        Darwin:x86_64) echo x86_64-macos ;;
        Darwin:arm64) echo aarch64-macos ;;
    esac
}

smoke_test() { # version
    native=$(native_target)
    if [ -z "$native" ]; then
        say "no release binary runs on this host; skipping the smoke test"
    else
        got=$("$out/rambit-$native" --version) ||
            die "rambit-$native --version failed"
        [ "$got" = "rambit $1" ] ||
            die "rambit-$native --version printed '$got', not 'rambit $1'"
        say "rambit-$native --version: $got"
    fi
    if [ "$(uname -s)" = Darwin ]; then
        codesign --verify --strict --verbose=2 "$out/rambit-aarch64-macos" ||
            die "rambit-aarch64-macos has no valid code signature"
    fi
}

write_sums() {
    (
        cd "$out"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum rambit-* > SHA256SUMS
        else
            shasum -a 256 rambit-* > SHA256SUMS
        fi
    )
}

main() {
    if [ $# -ne 1 ] || [ -z "$1" ]; then usage; fi
    ZIG=${ZIG:-zig}
    command -v "$ZIG" >/dev/null 2>&1 || die "no Zig compiler '$ZIG' (set ZIG)"

    work=
    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    out=$(prepare_out "$1")
    cd -P "$(dirname "$0")/.."
    version=$(read_version)
    work=$(mktemp -d 2>/dev/null || mktemp -d -t rambit-release)

    say "rambit $version with $("$ZIG" version) into $out"
    for pair in $targets; do
        build_one "${pair%%:*}" "${pair#*:}"
    done
    for pair in $targets; do
        check_format "${pair#*:}"
    done
    smoke_test "$version"
    write_sums
    cat "$out/SHA256SUMS"
}

main "$@"
