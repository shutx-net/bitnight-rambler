#!/bin/sh
# shellcheck shell=sh
#
# Manage the ECDSA P-256 key that signs rambit releases.
#
# install.sh carries the release public key between the marker lines
# "# BEGIN RELEASE PUBLIC KEY" and "# END RELEASE PUBLIC KEY" and verifies
# the signature of each release's SHA256SUMS with it.
#
# Usage: tools/release-key.sh <subcommand> [args]
#
#   generate DIR          create DIR/rambit-release.key (private, mode 600)
#                         and DIR/rambit-release.pub; DIR must be outside the
#                         repository
#   embed PUB [SCRIPT]    write the public key PUB into SCRIPT's key block
#                         (default: install.sh at the repository root)
#   extract [SCRIPT|-]    print the public key embedded in SCRIPT (- = stdin)
#   check [SCRIPT]        fail unless SCRIPT embeds a valid P-256 public key
#   fingerprint PUB       print sha256:<hex> of PUB's DER encoding
#
# The private key must never enter the repository, a CI log or an issue:
# it lives only in an offline backup and in the RAMBIT_SIGNING_KEY secret of
# the "release" environment. This tool never prints it. Only openssl's
# ecparam/ec/pkey/dgst commands are used, so LibreSSL (macOS) works too.

set -eu

prog=release-key.sh
begin_marker='# BEGIN RELEASE PUBLIC KEY'
end_marker='# END RELEASE PUBLIC KEY'
gh_repo=shutx-net/bitnight-rambler
tmp_dir=

say() { printf '%s\n' "$*"; }
die() { printf '%s: error: %s\n' "$prog" "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: tools/release-key.sh <subcommand> [args]

  generate DIR          create DIR/rambit-release.key and .pub (DIR outside the repo)
  embed PUB [SCRIPT]    embed public key PUB into SCRIPT (default: install.sh)
  extract [SCRIPT|-]    print the public key embedded in SCRIPT (- = stdin)
  check [SCRIPT]        verify SCRIPT embeds a valid P-256 public key
  fingerprint PUB       print the key's sha256 fingerprint
  -h, --help            show this help
EOF
}

cleanup() {
    if [ -n "$tmp_dir" ]; then
        rm -rf "$tmp_dir"
    fi
}

make_tmp_dir() {
    if [ -z "$tmp_dir" ]; then
        tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/release-key.XXXXXX") ||
            die "cannot create a temporary directory"
    fi
}

need_openssl() {
    command -v openssl >/dev/null 2>&1 || die "openssl is required"
}

repo_root() {
    cd "$(dirname "$0")/.." && pwd -P
}

default_script() {
    printf '%s/install.sh\n' "$(repo_root)"
}

# validate_pub IN OUT [NAME]: check IN is a P-256 public key and write its
# canonical PEM to OUT; NAME (default IN) names it in errors. The base64
# check guarantees no quote can reach a shell string.
validate_pub() {
    name=${3:-$1}
    if [ ! -f "$1" ] || [ ! -r "$1" ]; then die "cannot read $name"; fi
    if grep -q 'PRIVATE KEY' "$1"; then
        die "$name contains a PRIVATE KEY; pass the public key (.pub)"
    fi
    openssl ec -pubin -in "$1" -noout -text >"$tmp_dir/text" 2>/dev/null ||
        die "$name is not an EC public key"
    grep -q 'ASN1 OID: prime256v1' "$tmp_dir/text" ||
        die "$name is not a P-256 (prime256v1) key"
    openssl ec -pubin -in "$1" -pubout -out "$2" 2>/dev/null ||
        die "cannot canonicalize $name"
    awk '
        NR == 1 { if ($0 != "-----BEGIN PUBLIC KEY-----") bad = 1; next }
        $0 == "-----END PUBLIC KEY-----" { end++; next }
        end || $0 !~ /^[A-Za-z0-9+\/=]+$/ { bad = 1 }
        END { exit (bad || NR < 3 || end != 1) }
    ' "$2" || die "unexpected PEM layout for $name"
}

fingerprint_of() {
    openssl pkey -pubin -in "$1" -outform DER -out "$tmp_dir/key.der" 2>/dev/null ||
        openssl ec -pubin -in "$1" -outform DER -out "$tmp_dir/key.der" 2>/dev/null ||
        die "cannot read public key $1"
    hash=$(openssl dgst -sha256 -r "$tmp_dir/key.der") ||
        die "cannot hash public key"
    printf 'sha256:%s\n' "${hash%% *}"
}

# check_markers SCRIPT: each marker exactly once, BEGIN before END.
check_markers() {
    awk -v b="$begin_marker" -v e="$end_marker" '
        $0 == b { nb++; lb = NR }
        $0 == e { ne++; le = NR }
        END { exit !(nb == 1 && ne == 1 && lb < le) }
    ' "$1" || die "$1 needs exactly one '$begin_marker' line followed by exactly one '$end_marker' line"
}

# extract_to SCRIPT OUT: copy the single PEM inside the marker region to OUT.
extract_to() {
    check_markers "$1"
    awk -v b="$begin_marker" -v e="$end_marker" '
        $0 == b { region = 1; next }
        $0 == e { region = 0; next }
        !region { next }
        $0 == "-----BEGIN PUBLIC KEY-----" { pem = $0 "\n"; inpem = 1; next }
        inpem { pem = pem $0 "\n" }
        inpem && $0 == "-----END PUBLIC KEY-----" { inpem = 0; n++; out = pem }
        END { if (n != 1 || inpem) exit 1; printf "%s", out }
    ' "$1" >"$2"
}

cmd_generate() {
    [ $# -eq 1 ] || { usage >&2; exit 2; }
    need_openssl
    dir=$1
    root=$(repo_root)
    created=
    if [ ! -d "$dir" ]; then
        (umask 077 && mkdir -p "$dir") || die "cannot create $dir"
        created=1
    fi
    abs=$(cd "$dir" && pwd -P) || die "cannot enter $dir"
    inside=
    case "$abs/" in
        "$root/"*) inside=1 ;;
    esac
    if [ -z "$inside" ] && command -v git >/dev/null 2>&1 &&
        git -C "$abs" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        inside=1
    fi
    if [ -n "$inside" ]; then
        if [ -n "$created" ]; then
            rmdir "$abs" 2>/dev/null || :
        fi
        die "$dir is inside a git work tree; keep the private key outside any repository"
    fi
    key=$abs/rambit-release.key
    pub=$abs/rambit-release.pub
    for f in "$key" "$pub"; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            die "$f already exists; refusing to overwrite a key"
        fi
    done
    (
        umask 077
        openssl ecparam -name prime256v1 -genkey -noout -out "$key"
    ) || die "key generation failed"
    chmod 600 "$key"
    openssl ec -in "$key" -pubout -out "$pub" 2>/dev/null ||
        die "cannot derive the public key"
    chmod 644 "$pub"
    make_tmp_dir
    validate_pub "$pub" "$tmp_dir/canon.pem"
    fp=$(fingerprint_of "$pub")
    say "Generated a P-256 release signing key pair:"
    say "  private: $key (mode 600; never commit, paste or print it)"
    say "  public:  $pub"
    say ""
    cat "$pub"
    say "fingerprint: $fp"
    say ""
    say "Next steps:"
    say "  1. Store the private key as the release environment secret:"
    say "       gh secret set RAMBIT_SIGNING_KEY --env release --repo $gh_repo < $key"
    say "  2. Embed the public key in install.sh and commit it:"
    say "       tools/release-key.sh embed $pub"
    say "  3. Keep an offline backup of $key, then remove it from this machine."
}

cmd_embed() {
    [ $# -eq 1 ] || [ $# -eq 2 ] || { usage >&2; exit 2; }
    need_openssl
    pub=$1
    if [ $# -eq 2 ]; then script=$2; else script=$(default_script); fi
    if [ ! -f "$script" ] || [ ! -w "$script" ]; then die "cannot write $script"; fi
    validate_pub "$pub" "$tmp_dir/canon.pem"
    check_markers "$script"
    {
        printf '%s\n' "$begin_marker"
        printf '%s\n' '# Set with tools/release-key.sh embed; see docs/RELEASING.md.'
        printf '%s\n' "release_public_key='"
        cat "$tmp_dir/canon.pem"
        printf '%s\n' "'"
        printf '%s\n' "$end_marker"
    } >"$tmp_dir/block"
    {
        awk -v b="$begin_marker" '$0 == b { exit } { print }' "$script"
        cat "$tmp_dir/block"
        awk -v e="$end_marker" 'after { print } $0 == e { after = 1 }' "$script"
    } >"$tmp_dir/script" || die "cannot rewrite $script"
    if ! extract_to "$tmp_dir/script" "$tmp_dir/check.pem" ||
        ! cmp -s "$tmp_dir/check.pem" "$tmp_dir/canon.pem"; then
        die "internal error: rewritten key block does not round-trip"
    fi
    # cat > keeps the script's mode and inode.
    cat "$tmp_dir/script" >"$script" || die "cannot write $script"
    say "embedded release public key in $script"
    say "fingerprint: $(fingerprint_of "$tmp_dir/canon.pem")"
}

cmd_extract() {
    [ $# -le 1 ] || { usage >&2; exit 2; }
    script=${1:-$(default_script)}
    if [ "$script" = - ]; then
        cat >"$tmp_dir/stdin"
        src=$tmp_dir/stdin
        name='standard input'
    else
        if [ ! -f "$script" ] || [ ! -r "$script" ]; then die "cannot read $script"; fi
        src=$script
        name=$script
    fi
    extract_to "$src" "$tmp_dir/key.pem" ||
        die "no release public key embedded in $name (placeholder)"
    cat "$tmp_dir/key.pem"
}

cmd_check() {
    [ $# -le 1 ] || { usage >&2; exit 2; }
    need_openssl
    script=${1:-$(default_script)}
    if [ ! -f "$script" ] || [ ! -r "$script" ]; then die "cannot read $script"; fi
    extract_to "$script" "$tmp_dir/key.pem" ||
        die "no release public key embedded in $script (placeholder)"
    validate_pub "$tmp_dir/key.pem" "$tmp_dir/canon.pem" "the key in $script"
    cmp -s "$tmp_dir/key.pem" "$tmp_dir/canon.pem" ||
        die "the key in $script is not in canonical form; re-run embed"
    say "release key OK, fingerprint $(fingerprint_of "$tmp_dir/key.pem")"
}

cmd_fingerprint() {
    [ $# -eq 1 ] || { usage >&2; exit 2; }
    need_openssl
    validate_pub "$1" "$tmp_dir/canon.pem"
    fingerprint_of "$tmp_dir/canon.pem"
}

main() {
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [ $# -ge 1 ] || { usage >&2; exit 2; }
    sub=$1
    shift
    case "$sub" in
        -h | --help | help) usage; exit 0 ;;
        generate) cmd_generate "$@" ;;
        embed | extract | check | fingerprint)
            make_tmp_dir
            "cmd_$sub" "$@"
            ;;
        *)
            printf '%s: unknown subcommand: %s\n' "$prog" "$sub" >&2
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
