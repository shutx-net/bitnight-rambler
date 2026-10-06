# Releasing rambit

A release is a GitHub Release with six files:

- `rambit-x86_64-linux`, `rambit-aarch64-linux`: static (musl) binaries
  for Linux 5.10 or newer;
- `rambit-x86_64-macos`, `rambit-aarch64-macos`: binaries for macOS 13 or
  newer;
- `SHA256SUMS`: their SHA-256 hashes;
- `SHA256SUMS.sig`: an ECDSA P-256 signature of `SHA256SUMS` (DER, SHA-256
  digest), made with the release key.

`install.sh` carries the public half of the release key and refuses any
release whose `SHA256SUMS.sig` does not verify with it. GitHub also
stores a Sigstore build-provenance attestation for each binary and for
`SHA256SUMS`, which `install.sh` checks when `gh` is installed and logged
in.

The [Release workflow](../.github/workflows/release.yml) does all of the
building, signing and publishing. The private key is the secret
`RAMBIT_SIGNING_KEY` of the `release` environment (tag rule `v*`); only
the workflow's signing step can read it. For each release a maintainer
bumps the version and pushes a tag.

## Cutting a release

1. **Set the version.** Change `.version` in `build.zig.zon` and
   `version` in `flake.nix` to the new version, say `0.2.0`, and merge
   the change to `main`. `rambit --version` reports it, and the workflow
   requires the tag to be `v` followed by this version. A version with a
   suffix, such as `0.2.0-rc.1`, becomes a GitHub prerelease, which
   `install.sh` only installs when `RAMBIT_VERSION` names it.
2. **Do a dry run.** In Actions > Release, "Run workflow" on `main`. A
   run started by hand uses no secret and publishes nothing. It runs the
   build, reproduce and dry-run jobs: the macOS rebuild must equal the
   Linux build byte for byte, and the real x86_64 Linux binary is
   installed through `install.sh` with a throwaway key.
3. **Tag the commit and push the tag.**

   ```sh
   git fetch origin
   git tag -s v0.2.0 <the merged commit on main>   # or git tag, unsigned
   git push origin v0.2.0
   ```

   If the `release` environment has required reviewers, approve the
   deployment when the sign job asks.

The tag starts the workflow. Its jobs:

- **build** checks that the tag is `v<version>` of `build.zig.zon`, that
  `flake.nix` has the same version and that the commit is on `main`, then
  runs `zig build validate` and `zig build test` and builds the binaries
  and `SHA256SUMS` with `tools/build-release.sh`.
- **reproduce** rebuilds them on macOS and requires the same
  `SHA256SUMS`, so a tampered build host is caught before anything is
  signed. It also checks the code signature of the arm64 macOS binary.
- **sign** signs `SHA256SUMS` with `RAMBIT_SIGNING_KEY` and verifies the
  signature with the key in `install.sh` at the tag and on `main`, which
  must be the same key.
- **attest** creates the build-provenance attestations for the binaries
  and `SHA256SUMS`.
- **publish** creates the release as a draft with all six files, then
  publishes it. It fails if a release for the tag already exists; it
  never overwrites one.
- **smoke** installs the published release with `install.sh` on Linux
  x86_64, Linux arm64 and macOS, and requires the attestation check to
  pass and `rambit --version` to print the version.

### When a job fails

Before publish, nothing has been released. If the failure was GitHub's,
re-run the failed jobs. If the code needs fixing, fix it on `main` and
release the next patch version; do not move the tag.

If smoke fails, the release is out and something is wrong with it.
Re-run smoke if the failure was a runner or network problem. Otherwise
delete the release, so that `install.sh` falls back to the previous one
as the latest, fix the problem and release the next patch version:

```sh
gh release delete v0.2.0 --repo shutx-net/bitnight-rambler
```

Never reuse a version number.

### macOS and Gatekeeper

The macOS binaries are not notarized. The arm64 one carries the ad-hoc
code signature the linker gives it, which Apple silicon requires.
`curl` does not mark downloaded files as quarantined, so Gatekeeper does
not stop a binary that `install.sh` installed. A binary downloaded with
a browser is quarantined; `xattr -d com.apple.quarantine <file>` lets it
run.

## Rotating the key

1. On a trusted machine, outside any git work tree, generate a new key
   pair: `tools/release-key.sh generate ~/rambit-release-key-2`. It
   writes the private key `rambit-release.key` (mode 600) and
   `rambit-release.pub`.
2. Replace the secret with the new private key:
   `gh secret set RAMBIT_SIGNING_KEY --env release --repo shutx-net/bitnight-rambler < ~/rambit-release-key-2/rambit-release.key`.
3. Embed the new public key and check it, then merge `install.sh` to
   `main`:

   ```sh
   tools/release-key.sh embed ~/rambit-release-key-2/rambit-release.pub
   tools/release-key.sh check install.sh
   sh tools/test-install.sh
   ```

4. Keep the private key only in an offline, encrypted backup
   (`openssl ec -aes256 -in rambit-release.key -out rambit-release.key.enc`)
   and delete the plain copy.

Do all of this before the next release. Between steps 2 and 3 a tagged
release fails in the sign job, since the secret and `install.sh` no
longer match; nothing is published.

Releases signed with the old key no longer install through the
`install.sh` on `main`: their signature does not verify with the new key.
The `install.sh` of their own tag still has the old key and installs
them:

```sh
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/v0.1.0/install.sh | RAMBIT_VERSION=v0.1.0 sh
```

To make an old release install with the current `install.sh` too,
re-sign its `SHA256SUMS` with the new key and replace its
`SHA256SUMS.sig`. That is only possible if releases are not immutable;
otherwise, cut a new release instead.

```sh
gh release download v0.1.0 --repo shutx-net/bitnight-rambler --pattern SHA256SUMS --pattern SHA256SUMS.sig
openssl dgst -sha256 -verify ~/rambit-release-key/rambit-release.pub -signature SHA256SUMS.sig SHA256SUMS   # the old key: Verified OK
openssl dgst -sha256 -sign ~/rambit-release-key-2/rambit-release.key -out SHA256SUMS.sig SHA256SUMS
openssl dgst -sha256 -verify ~/rambit-release-key-2/rambit-release.pub -signature SHA256SUMS.sig SHA256SUMS   # the new key: Verified OK
gh release upload v0.1.0 SHA256SUMS.sig --clobber --repo shutx-net/bitnight-rambler
```

`SHA256SUMS` itself does not change, so its attestation still holds.

## If the key is compromised

1. **Delete the secret at once**, so that no release can be signed with
   the key:

   ```sh
   gh secret delete RAMBIT_SIGNING_KEY --env release --repo shutx-net/bitnight-rambler
   ```

2. **Rotate the key** as above, and merge the new public key to `main`
   quickly: from then on, `install.sh` on `main` rejects anything signed
   with the old key.
3. **Audit every release.** The attestations do not depend on the key.
   For each release, check every binary and `SHA256SUMS`:

   ```sh
   gh release download v0.1.0 --repo shutx-net/bitnight-rambler --dir audit-v0.1.0
   cd audit-v0.1.0
   sha256sum -c SHA256SUMS
   for f in rambit-* SHA256SUMS; do
     gh attestation verify "$f" --repo shutx-net/bitnight-rambler \
       --signer-workflow shutx-net/bitnight-rambler/.github/workflows/release.yml \
       --source-ref refs/tags/v0.1.0 --deny-self-hosted-runners
   done
   ```

   The builds are reproducible, so `tools/build-release.sh` on a checkout
   of the tag, with the same Zig, must also give the same `SHA256SUMS`.
   Look at the history of `install.sh` and `.github/workflows/` as well,
   in case more than the key was taken.
4. **Delete every release that fails**, with `gh release delete`, and
   re-sign the genuine ones with the new key if releases are not
   immutable.
5. **Announce it**, in a GitHub security advisory or the release notes:
   which key was compromised (its fingerprint), the new key's
   fingerprint, which releases were affected, and that users should
   reinstall with the current `install.sh`.
