#!/bin/sh
# shellcheck shell=sh
#
# Hermetic tests of install.sh against a fake, signed release:
#
#     tools/test-install.sh
#
# Generates a throwaway release key in a temporary directory, embeds it in a
# temporary copy of install.sh, builds fake releases (good ones and broken
# ones) under file:// URLs and pipes the copy into every POSIX shell found,
# as curl | sh would. Commands that install.sh looks at (uname, id, sysctl,
# sw_vers, gh, curl) are shims, so other platforms, root and gh are
# simulated; PATH holds only the tools install.sh needs. No network, no
# real HOME, nothing written outside the temporary directory.
#
# Environment:
#   TEST_INSTALL_SCRIPT=FILE  test FILE instead of the repository's install.sh
#   TEST_SHELLS="dash bash"   shells to use, from sh dash bash zsh
#                             (default: each of them that is installed)
#   RAMBIT_TEST_DIST=DIR      also install the real binaries in DIR (the
#                             output of tools/build-release.sh), unshimmed
#
# Needs openssl and one of sha256sum, shasum or openssl. Prints one line per
# case and shell, and the output of each failing run; exits 1 on any FAIL.

set -eu

assets='x86_64-linux aarch64-linux x86_64-macos aarch64-macos'
farm_tools='curl uname mktemp mkdir cp chmod mv rm grep awk sed cut wc id cat head tr sort env sha256sum shasum perl openssl sysctl sw_vers'
begin_marker='# BEGIN RELEASE PUBLIC KEY'
end_marker='# END RELEASE PUBLIC KEY'
W=
passed=0
failed=0

die() {
    printf 'test-install: error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$W" ]; then
        rm -rf "$W"
    fi
}

# q STRING: STRING quoted for sh.
q() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# sha256 FILE: lowercase hex SHA-256, with install.sh's tool fallback.
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        h=$(sha256sum <"$1")
    elif command -v shasum >/dev/null 2>&1; then
        h=$(shasum -a 256 <"$1")
    else
        h=$(openssl dgst -sha256 -r <"$1")
    fi
    printf '%s\n' "${h%%[!0-9a-f]*}"
}

write_sums() { # DIR
    for f in "$1"/rambit-*; do
        printf '%s  %s\n' "$(sha256 "$f")" "${f##*/}"
    done >"$1/SHA256SUMS"
}

sign() { # DIR KEYDIR
    openssl dgst -sha256 -sign "$2/rambit-release.key" \
        -out "$1/SHA256SUMS.sig" "$1/SHA256SUMS"
}

tamper_assets() { # DIR
    for a in $assets; do
        printf '# tampered\n' >>"$1/rambit-$a"
    done
}

# make_release NAME [MUTATION]: $W/rel-NAME/v9.9.9 with the four fake
# binaries, SHA256SUMS and SHA256SUMS.sig, then broken as MUTATION says.
make_release() {
    r=$W/rel-$1/v9.9.9
    mkdir -p "$r"
    v=9.9.9
    [ "${2:-}" != oldver ] || v=0.0.1
    for a in $assets; do
        printf "#!/bin/sh\necho 'rambit %s'\n" "$v" >"$r/rambit-$a"
        chmod 755 "$r/rambit-$a"
    done
    if [ "${2:-}" = substr ]; then
        for a in $assets; do
            mv "$r/rambit-$a" "$r/rambit-$a.bak"
        done
    fi
    write_sums "$r"
    case ${2:-} in
        dup) cat "$r/SHA256SUMS" "$r/SHA256SUMS" >"$r/x" && mv "$r/x" "$r/SHA256SUMS" ;;
        malformed) printf 'junk line\n' >>"$r/SHA256SUMS" ;;
        crlf) awk '{ printf "%s\r\n", $0 }' "$r/SHA256SUMS" >"$r/x" && mv "$r/x" "$r/SHA256SUMS" ;;
    esac
    if [ "${2:-}" = otherkey ]; then
        sign "$r" "$W/other"
    else
        sign "$r" "$W/key"
    fi
    case ${2:-} in
        tbin) tamper_assets "$r" ;;
        tsums) tamper_assets "$r" && write_sums "$r" ;;
        emptysig) : >"$r/SHA256SUMS.sig" ;;
        nosig) rm "$r/SHA256SUMS.sig" ;;
    esac
}

# make_farm NAME [EXCLUDED...]: $W/path/NAME, symlinks to the tools.
make_farm() {
    d=$W/path/$1
    shift
    mkdir -p "$d"
    for t in $farm_tools; do
        case " $* " in
            *" $t "*) continue ;;
        esac
        p=$(command -v "$t" 2>/dev/null) || continue
        case $p in
            /*) ln -s "$p" "$d/$t" ;;
        esac
    done
}

# shim NAME BODY: $W/shim/NAME runs BODY, then the real NAME (if any).
shim() {
    real=$(command -v "$1" 2>/dev/null) || real=
    {
        printf '#!/bin/sh\n%s\n' "$2"
        case $real in
            /*) printf 'exec %s "$@"\n' "$(q "$real")" ;;
            *) printf 'echo "%s: not found" >&2\nexit 127\n' "$1" ;;
        esac
    } >"$W/shim/$1"
    chmod 755 "$W/shim/$1"
}

make_shims() {
    mkdir -p "$W/shim" "$W/ghshim" "$W/trunc"
    # shellcheck disable=SC2016 # the shims expand these, not this script
    shim uname '
case ${1-} in
    -s) [ -z "${FAKE_UNAME_S-}" ] || { printf "%s\n" "$FAKE_UNAME_S"; exit 0; } ;;
    -m) [ -z "${FAKE_UNAME_M-}" ] || { printf "%s\n" "$FAKE_UNAME_M"; exit 0; } ;;
esac'
    # shellcheck disable=SC2016
    shim id '[ "$*" != -u ] || [ -z "${FAKE_UID-}" ] || { printf "%s\n" "$FAKE_UID"; exit 0; }'
    # shellcheck disable=SC2016
    shim sysctl '[ "$*" != "-n hw.optional.arm64" ] || [ -z "${FAKE_ARM64-}" ] || { printf "%s\n" "$FAKE_ARM64"; exit 0; }'
    # shellcheck disable=SC2016
    shim sw_vers '[ "$*" != -productVersion ] || [ -z "${FAKE_MACOS-}" ] || { printf "%s\n" "$FAKE_MACOS"; exit 0; }'
    shim curl "printf '%s\\n' \"\$*\" >>$(q "$W/curl.log")"
    cat >"$W/ghshim/gh" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" >>$(q "$W/gh.log")
case "\$* \${GH_MODE-}" in
    'auth status unauth') echo 'You are not logged into any GitHub hosts.' >&2; exit 1 ;;
    'auth status '*) exit 0 ;;
    *' --help '*) echo 'Flags: --repo --signer-workflow --source-ref --deny-self-hosted-runners'; exit 0 ;;
    'attestation verify '*' ok') echo 'Verification succeeded!'; exit 0 ;;
    'attestation verify '*) echo 'Error: no attestation matches' >&2; exit 1 ;;
esac
echo "gh shim: unexpected call: \$*" >&2
exit 1
EOF
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>%s\nexit 22\n' "$(q "$W/curl.log")" >"$W/trunc/curl"
    chmod 755 "$W/ghshim/gh" "$W/trunc/curl"
}

find_shells() {
    shells=
    for s in ${TEST_SHELLS:-sh dash bash zsh}; do
        p=$(command -v "$s" 2>/dev/null) || p=
        case $p in
            /*) ;;
            *)
                [ -z "${TEST_SHELLS:-}" ] || die "shell not found: $s"
                continue
                ;;
        esac
        case $s in
            sh) sh_sh=$p ;;
            dash) sh_dash=$p ;;
            bash) sh_bash=$p ;;
            zsh) mkdir -p "$W/zsh" && ln -s "$p" "$W/zsh/sh" ;;
            *) die "unsupported shell in TEST_SHELLS: $s" ;;
        esac
        shells="$shells $s"
    done
    [ -n "$shells" ] || die "no shell to test with"
}

# invoke SHELL VAR=VALUE...: run SHELL (reading stdin) in a clean environment.
invoke() {
    lbl=$1
    shift
    case $lbl in
        sh) env -i "$@" "$sh_sh" ;;
        dash) env -i "$@" "$sh_dash" ;;
        bash) env -i "$@" "$sh_bash" --posix ;;
        zsh) env -i "$@" "$W/zsh/sh" ;;
    esac
}

# Settings of the next case; reset after each.
reset_case() {
    rel=good pathv=full gh=absent script=$W/install.sh idir='' setdir=1
    ver=v9.9.9 base='' seed=1 nodl='' want=9.9.9 post='' uid=1000
}

# run_install SHELL [VAR=VALUE...]: one install, piped in like curl | sh.
run_install() {
    lbl=$1
    shift
    rm -rf "$idir" "${W:?}/home" "$W/tmp" "$W/cwd"
    mkdir -p "$W/home" "$W/tmp" "$W/cwd"
    : >"$W/curl.log"
    : >"$W/gh.log"
    if [ -n "$seed" ]; then
        mkdir -p "$idir"
        printf '#!/bin/sh\necho old rambit\n' >"$idir/rambit"
        cp "$idir/rambit" "$W/seed"
    fi
    p=$W/shim:$W/path/$pathv
    [ "$gh" = absent ] || p=$W/ghshim:$p
    set -- "PATH=$p" "HOME=$W/home" "TMPDIR=$W/tmp" "GH_MODE=$gh" "FAKE_UID=$uid" \
        "RAMBIT_VERSION=$ver" "RAMBIT_DOWNLOAD_BASE=${base:-file://$W/rel-$rel}" "$@"
    [ -z "$setdir" ] || set -- "RAMBIT_INSTALL_DIR=$idir" "$@"
    status=0
    (cd "$W/cwd" && invoke "$lbl" "$@") <"$script" >"$W/out" 2>"$W/err" || status=$?
}

# verdict: set why to the first failed assertion of the last run, if any.
verdict() {
    why=
    if [ "$expect" = ok ]; then
        if [ "$status" != 0 ]; then
            why="exit status $status"
        elif [ ! -f "$idir/rambit" ]; then
            why="$idir/rambit missing"
        elif [ -z "$(find "$idir/rambit" -prune -perm 755)" ]; then
            why="mode is not 755"
        elif [ "$("$idir/rambit" --version 2>&1)" != "rambit $want" ]; then
            why="installed rambit does not report rambit $want"
        elif ! grep -Fq -e "$pattern" "$W/out" "$W/err"; then
            why="output lacks: $pattern"
        fi
    elif [ "$status" = 0 ]; then
        why="exit status 0"
    elif ! grep -Fq -e "$pattern" "$W/err"; then
        why="stderr lacks: $pattern"
    elif [ -n "$seed" ] && ! cmp -s "$W/seed" "$idir/rambit"; then
        why="the old $idir/rambit was changed"
    elif [ -z "$seed" ] && [ -e "$idir" ]; then
        why="$idir was created"
    fi
    for f in "$idir"/.rambit.*; do
        if [ -z "$why" ] && [ -e "$f" ]; then
            why="leftover $f"
        fi
    done
    if [ -z "$why" ] && [ -n "$(ls -A "$W/tmp")" ]; then
        why="leftover in TMPDIR: $(ls -A "$W/tmp")"
    fi
    if [ -z "$why" ] && [ -n "$nodl" ] && [ -s "$W/curl.log" ]; then
        why="curl ran: $(cat "$W/curl.log")"
    fi
    if [ -z "$why" ] && [ -n "$post" ]; then
        "$post"
    fi
}

report() { # SHELL NAME
    if [ -z "$why" ]; then
        passed=$((passed + 1))
        printf 'ok    %-5s %s\n' "$1" "$2"
        return 0
    fi
    failed=$((failed + 1))
    printf 'FAIL  %-5s %s: %s\n' "$1" "$2" "$why"
    for f in out err; do
        printf '      std%s:\n' "$f"
        sed 's/^/      | /' "$W/$f"
    done
}

# t NAME ok|fail PATTERN [VAR=VALUE...]: run a case under every shell. ok:
# installs rambit $want and prints PATTERN; fail: exits non-zero with
# PATTERN on stderr and leaves the install directory as it was.
t() {
    name=$1 expect=$2 pattern=$3
    shift 3
    [ -n "$idir" ] || idir=$W/bin-$name
    for s in $shells; do
        run_install "$s" "$@"
        verdict
        report "$s" "$name"
    done
    reset_case
}

check_gh_args() {
    for a in '--repo shutx-net/bitnight-rambler' \
        '--signer-workflow shutx-net/bitnight-rambler/.github/workflows/release.yml' \
        '--source-ref refs/tags/v9.9.9' '--deny-self-hosted-runners'; do
        grep -Fq -e "attestation verify $W/tmp/" "$W/gh.log" && grep -Fq -e " $a" "$W/gh.log" ||
            why="gh was not called with $a: $(cat "$W/gh.log")"
    done
}

check_no_relative_dir() {
    [ -z "$(ls -A "$W/cwd")" ] || why="created $(ls -A "$W/cwd") in the working directory"
}

release_cases() {
    t happy ok 'signature: verified with the embedded release key'
    ver=9.9.9
    t pin-without-v ok 'installed rambit 9.9.9'
    idir="$W/sp ace/new/bin" seed=''
    t dir-with-space ok "path: $W/sp ace/new/bin/rambit"
    t path-hint-zsh ok "echo 'export PATH=\"$W/bin-path-hint-zsh:\$PATH\"' >> ~/.zshrc" SHELL=/bin/zsh
    gh=unauth
    t gh-unauth ok 'provenance: not checked'
    rel=tbin
    t tampered-binary fail 'SHA-256 mismatch'
    rel=tsums
    t tampered-sums fail 'does NOT verify'
    rel=otherkey
    t other-key fail 'does NOT verify'
    rel=emptysig
    t empty-sig fail 'does NOT verify'
    rel=nosig
    t missing-sig fail 'SHA256SUMS.sig'
    rel=dup
    t duplicate-line fail 'exactly once'
    rel=substr
    t substring-only fail 'exactly once'
    rel=malformed
    t malformed-line fail 'malformed'
    rel=crlf
    t crlf-sums fail 'malformed'
    rel=oldver
    t old-version fail "reports 'rambit 0.0.1', expected 'rambit 9.9.9'"
}

override_cases() {
    pathv=no-openssl nodl=1
    t no-openssl fail 'RAMBIT_INSECURE_SKIP_SIGNATURE=1'
    pathv=no-openssl
    t no-openssl-override ok 'WARNING: the release signature will NOT be verified' RAMBIT_INSECURE_SKIP_SIGNATURE=1
    pathv=no-openssl rel=tbin
    t no-openssl-override-tampered fail 'SHA-256 mismatch' RAMBIT_INSECURE_SKIP_SIGNATURE=1
    rel=otherkey
    t override-ignored fail 'does NOT verify' RAMBIT_INSECURE_SKIP_SIGNATURE=1
    pathv=no-hash nodl=1
    t no-hash-tool fail 'no SHA-256 tool' RAMBIT_INSECURE_SKIP_SIGNATURE=1
    pathv=openssl-hash
    t openssl-hash ok 'signature: verified'
    if [ -e "$W/path/full/shasum" ]; then
        pathv=shasum-hash
        t shasum-hash ok 'signature: verified'
    fi
}

platform_cases() {
    nodl=1
    t freebsd fail 'unsupported OS: FreeBSD' FAKE_UNAME_S=FreeBSD FAKE_UNAME_M=amd64
    nodl=1
    t riscv64 fail 'unsupported CPU architecture: riscv64' FAKE_UNAME_S=Linux FAKE_UNAME_M=riscv64
    t linux-aarch64 ok 'downloading rambit-aarch64-linux' FAKE_UNAME_S=Linux FAKE_UNAME_M=aarch64
    t rosetta ok 'downloading rambit-aarch64-macos' FAKE_UNAME_S=Darwin FAKE_UNAME_M=x86_64 FAKE_ARM64=1 FAKE_MACOS=14.5
    t intel-mac ok 'downloading rambit-x86_64-macos' FAKE_UNAME_S=Darwin FAKE_UNAME_M=x86_64 FAKE_ARM64=0 FAKE_MACOS=13.0
    nodl=1
    t macos-12 fail 'requires macOS 13' FAKE_UNAME_S=Darwin FAKE_UNAME_M=arm64 FAKE_MACOS=12.7.4
    setdir='' seed='' idir=$W/home/.local/bin nodl=1 uid=0
    t sudo fail 'do not run this with sudo' SUDO_USER=u
    uid=0
    t sudo-with-dir ok 'running as root' SUDO_USER=u
    setdir='' seed='' idir=$W/home/.local/bin uid=0
    t plain-root ok "PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc" SHELL=/bin/zsh
}

input_cases() {
    for v in v1.2 'v1.2.3;id' ../v1 "v9.9.9$(printf '\nx')"; do
        ver=$v nodl=1
        t "bad-version-$(printf '%s' "$v" | tr -c 'A-Za-z0-9.;' _)" fail 'invalid RAMBIT_VERSION'
    done
    base=http://example.invalid/rel nodl=1
    t http-base fail 'must start with https:// or file://'
    setdir='' nodl=1 post=check_no_relative_dir
    t relative-dir fail 'must be an absolute path' RAMBIT_INSTALL_DIR=rel/bin
}

gh_cases() {
    gh=ok post=check_gh_args
    t gh-ok ok 'provenance: verified (GitHub artifact attestation, Sigstore)'
    gh=fail
    t gh-fail fail 'gh attestation verify failed'
    gh=fail
    t gh-fail-skip ok 'provenance: skipped (RAMBIT_SKIP_ATTESTATION=1)' RAMBIT_SKIP_ATTESTATION=1
}

key_cases() {
    # A key from the environment must not fill the placeholder.
    pub=$(cat "$W/key/rambit-release.pub")
    if sh "$repo/tools/release-key.sh" check "$SCRIPT" >/dev/null 2>&1; then
        script=$SCRIPT
        t repo-key fail 'does NOT verify'
        awk -v b="$begin_marker" -v e="$end_marker" -v q="'" '
            $0 == b { print; print "release_public_key=" q q; skip = 1; next }
            $0 == e { skip = 0 }
            !skip
        ' "$SCRIPT" >"$W/placeholder.sh"
        script=$W/placeholder.sh
    else
        script=$SCRIPT nodl=1
        t repo-key-placeholder fail 'has no release key'
        script=$SCRIPT
    fi
    nodl=1
    t env-key-ignored fail 'has no release key' "release_public_key=$pub"
    if [ "$(uname -s)" = Darwin ] && /usr/bin/openssl version 2>/dev/null | grep -q LibreSSL; then
        make_farm libressl openssl
        ln -s /usr/bin/openssl "$W/path/libressl/openssl"
        pathv=libressl
        t libressl ok 'signature: verified'
    fi
}

dist_case() {
    dist=${RAMBIT_TEST_DIST:-}
    [ -n "$dist" ] || return 0
    v=$(sed -n 's/^    \.version = "\([^"]*\)",$/\1/p' "$repo/build.zig.zon")
    [ -n "$v" ] || die "no version in build.zig.zon"
    r=$W/rel-dist/v$v
    mkdir -p "$r"
    for a in $assets; do
        cp "$dist/rambit-$a" "$r/" || die "RAMBIT_TEST_DIST lacks rambit-$a"
    done
    write_sums "$r"
    if [ -f "$dist/SHA256SUMS" ] && ! cmp -s "$dist/SHA256SUMS" "$r/SHA256SUMS"; then
        failed=$((failed + 1))
        printf 'FAIL  -     dist: %s/SHA256SUMS does not match the binaries\n' "$dist"
    fi
    sign "$r" "$W/key"
    rel=dist ver=v$v want=$v
    t real-binaries ok "installed rambit $v"
}

# truncation: every prefix of install.sh, piped into sh, must download and
# install nothing, except the cuts right after "main" or "main ", which
# run main without arguments just like the whole script.
truncation() {
    tsh=$(command -v sh)
    n=$(wc -l <"$W/install.sh")
    n=$((n + 0))
    last=$(sed -n "${n}p" "$W/install.sh")
    tdir=$W/bin-trunc
    set -- "PATH=$W/trunc:$W/shim:$W/path/full" "HOME=$W/home" "TMPDIR=$W/tmp" \
        FAKE_UID=1000 RAMBIT_VERSION=v9.9.9 "RAMBIT_DOWNLOAD_BASE=file://$W/rel-good" "RAMBIT_INSTALL_DIR=$tdir"
    rm -rf "$W/tmp" "$tdir" && mkdir -p "$W/tmp" "$W/cwd"
    : >"$W/curl.log"
    rs=0
    (cd "$W/cwd" && env -i "$@" "$tsh") <"$W/install.sh" >"$W/ref.out" 2>"$W/ref.err" || rs=$?
    [ -s "$W/curl.log" ] || die "truncation: the whole script did not call curl"
    k=1
    bad=0
    count=0
    while [ "$k" -le "$n" ]; do
        if [ "$k" -lt "$n" ]; then
            head -n "$k" "$W/install.sh" >"$W/cut.sh"
            what=$k
            j=0
        else
            j=$((j + 1))
            pre=$(printf '%s\n' "$last" | cut -b "1-$j")
            [ "$pre" != "$last" ] || break
            { head -n $((n - 1)) "$W/install.sh" && printf '%s' "$pre"; } >"$W/cut.sh"
            what="$((n - 1)) lines + '$pre'"
        fi
        : >"$W/curl.log"
        st=0
        # A pipe on purpose, as in curl | sh: the shell cannot seek in it.
        # shellcheck disable=SC2002
        (cd "$W/cwd" && cat "$W/cut.sh" | env -i "$@" "$tsh") >"$W/out" 2>"$W/err" || st=$?
        why=
        if [ "$k" = "$n" ] && { [ "$pre" = main ] || [ "$pre" = 'main ' ]; }; then
            [ "$st" = "$rs" ] && cmp -s "$W/out" "$W/ref.out" && cmp -s "$W/err" "$W/ref.err" ||
                why="differs from the whole script"
        elif [ -s "$W/curl.log" ]; then
            why="curl ran: $(head -n 1 "$W/curl.log")"
        elif [ -e "$tdir" ]; then
            why="created $tdir"
        elif [ -n "$(ls -A "$W/tmp")" ]; then
            why="left files in TMPDIR"
        fi
        count=$((count + 1))
        if [ -n "$why" ]; then
            bad=$((bad + 1))
            report sh "truncated after $what"
        fi
        [ "$k" = "$n" ] || k=$((k + 1))
    done
    why=
    [ "$bad" = 0 ] || why="$bad of $count prefixes"
    report sh "truncation ($count prefixes, $tsh)"
}

main() {
    [ $# -eq 0 ] || {
        printf 'usage: %s (no arguments; see the comment at the top)\n' "$0" >&2
        exit 2
    }
    repo=$(cd "$(dirname "$0")/.." && pwd -P)
    SCRIPT=${TEST_INSTALL_SCRIPT:-$repo/install.sh}
    [ -f "$SCRIPT" ] || die "no such file: $SCRIPT"
    SCRIPT=$(cd "$(dirname "$SCRIPT")" && pwd -P)/${SCRIPT##*/}
    for c in openssl curl awk sed cmp head cut; do
        command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"
    done

    trap cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    W=$(mktemp -d "${TMPDIR:-/tmp}/test-install.XXXXXX")
    W=$(cd "$W" && pwd -P)
    case $W in
        *[!A-Za-z0-9/._-]*) die "unsafe temporary directory name: $W (set TMPDIR)" ;;
    esac

    sh "$repo/tools/release-key.sh" generate "$W/key" >/dev/null
    sh "$repo/tools/release-key.sh" generate "$W/other" >/dev/null
    cp "$SCRIPT" "$W/install.sh"
    sh "$repo/tools/release-key.sh" embed "$W/key/rambit-release.pub" "$W/install.sh" >/dev/null
    for m in good tbin tsums otherkey emptysig nosig dup substr malformed crlf oldver; do
        make_release "$m" "$m"
    done
    make_farm full
    for c in curl uname id mktemp mkdir cp chmod mv rm grep awk tr openssl; do
        [ -e "$W/path/full/$c" ] || die "required command not found: $c"
    done
    make_farm no-openssl openssl
    make_farm no-hash openssl sha256sum shasum
    make_farm openssl-hash sha256sum shasum
    make_farm shasum-hash sha256sum
    make_shims
    find_shells

    started=$(date +%s)
    reset_case
    release_cases
    override_cases
    platform_cases
    input_cases
    gh_cases
    key_cases
    dist_case
    truncation
    printf '\n%d passed, %d failed (shells:%s; %ss)\n' "$passed" "$failed" "$shells" \
        "$(($(date +%s) - started))"
    [ "$failed" = 0 ]
}

main "$@"
