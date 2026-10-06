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
building, signing and publishing. A maintainer sets up the key once, then
bumps the version and pushes a tag for each release.

## First release checklist

Everything below is described in detail in the following sections.

1. [ ] Generate the release key on a trusted machine, outside any
   repository.
2. [ ] Create the `release` environment (tag rule `v*`) and store the
   private key in its secret `RAMBIT_SIGNING_KEY`.
3. [ ] Embed the public key in `install.sh`, check it, and merge it to
   `main`.
4. [ ] Back up the private key offline and delete the plain copy.
5. [ ] Recommended: a tag ruleset for `v*`, immutable releases, and
   reviews required on `main`.
6. [ ] Set the version in `build.zig.zon` and `flake.nix`, merge, and do
   a dry run of the Release workflow on `main`.
7. [ ] Tag the merged commit and push the tag; approve the `release`
   environment if it asks.
8. [ ] Once the smoke job has passed, install on a clean machine with
   the README's one-liner and check:

   ```sh
   tools/release-key.sh check install.sh   # release key OK, fingerprint sha256:...
   gh release view vX.Y.Z --repo shutx-net/bitnight-rambler   # four binaries, SHA256SUMS, SHA256SUMS.sig
   rambit --version
   gh attestation verify ~/.local/bin/rambit --repo shutx-net/bitnight-rambler \
     --signer-workflow shutx-net/bitnight-rambler/.github/workflows/release.yml
   ```

## One-time setup

### The key

Generate the key pair on a machine you trust, in a directory outside any
git work tree (`tools/release-key.sh` refuses one inside). It needs
`openssl`; LibreSSL works too.

```sh
tools/release-key.sh generate ~/rambit-release-key
```

This writes `~/rambit-release-key/rambit-release.key`, the private key
(mode 600), and `rambit-release.pub`, and prints the public key, its
fingerprint and the next steps. Never commit, paste or print the private
key: it belongs only in the secret below and in an offline backup.

### The release environment

In the repository's Settings > Environments, create an environment named
`release`. Under "Deployment branches and tags", choose "Selected
branches and tags" and add a tag rule with the pattern `v*`, so that only
a version tag can use it. Optionally add required reviewers: the sign job
then waits until one of them approves.

Store the private key as the environment's secret:

```sh
gh secret set RAMBIT_SIGNING_KEY --env release --repo shutx-net/bitnight-rambler < ~/rambit-release-key/rambit-release.key
```

The secret must be the unencrypted PEM file as `generate` wrote it. Only
the sign job names the `release` environment, and only its signing step
sees the secret; it goes to `openssl` through a pipe and never touches
the runner's disk.

### Embedding the public key

```sh
tools/release-key.sh embed ~/rambit-release-key/rambit-release.pub
tools/release-key.sh check install.sh
sh tools/test-install.sh
```

`embed` writes the key between the `# BEGIN RELEASE PUBLIC KEY` and
`# END RELEASE PUBLIC KEY` lines of `install.sh` and prints its
fingerprint, which must match the one `generate` printed. With a real
key in place, `tools/test-install.sh` also checks that the repository's
key rejects its own throwaway test signature. Commit only `install.sh`
(for example `feat(install): embed the release public key`), open a pull
request and merge it.

### Backing up the private key

Keep the private key offline, in a password manager or an encrypted
backup, then delete the plain copy:

```sh
openssl ec -aes256 -in ~/rambit-release-key/rambit-release.key -out rambit-release.key.enc   # asks for a passphrase
rm ~/rambit-release-key/rambit-release.key
```

To get the plain key back, for a rotation or to re-sign a release:

```sh
openssl ec -in rambit-release.key.enc -out rambit-release.key
```

The public key, `rambit-release.pub`, is not secret.

### Repository settings

Recommended, under Settings:

- **Rules > Rulesets:** a tag ruleset for `v*` that restricts creation to
  maintainers and blocks updates and deletions, so a release tag cannot
  be moved.
- **General > Releases:** enable release immutability, so the files of a
  published release cannot be replaced. The workflow uploads every file
  to a draft before publishing it, which immutable releases allow.
- **Rules or Branches:** require a reviewed pull request for `main`.
  Releases are only made from commits on `main`, and `main` holds the
  `install.sh` that users run.

### While install.sh has no key

Until a key is embedded, `install.sh` stops at once with "this
install.sh has no release key yet" and installs nothing. CI's
release-build job and the Release workflow's dry run only warn about it,
so CI stays green, but the sign job of a tagged release fails at
`tools/release-key.sh check install.sh`, before anything is published.

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

1. Generate a new key pair in a new directory:
   `tools/release-key.sh generate ~/rambit-release-key-2`.
2. Replace the secret with the new private key:
   `gh secret set RAMBIT_SIGNING_KEY --env release --repo shutx-net/bitnight-rambler < ~/rambit-release-key-2/rambit-release.key`.
3. Embed the new public key, check it and merge it to `main`, as in
   [Embedding the public key](#embedding-the-public-key).
4. Back up the new private key and delete the plain copy, as before.

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
