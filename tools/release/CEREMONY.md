# The pylond release ceremony

Pylon pushes `pylond` to a server only when that build is signed by enough
release keys, recorded in the transparency log, and not older than one it
has already accepted (SPEC 8.2.1). Until keys are pinned, every build of
Pylon refuses to push `pylond`. This is how the keys are made and how each
release is signed. `tools/release/ceremony.sh` runs every step, and
`tools/release/release.sh` runs all of them at once on one machine.

## The keys

| Key | How many | Needed per release | Kept |
|---|---|---|---|
| Release keys | 3 | any 2 | each on a different device or with a different person, offline |
| Log key | 1 | 1 | apart from the release keys |

Two of three means one lost or stolen release key neither stops releases
nor lets anyone ship a `pylond` alone. Suggested holders when one person
runs the project: your everyday machine, a second device, and an offline
backup (an encrypted USB stick in a safe). Never put a private key in this
repository, in CI, or on the machine that builds the APK.

A `.key` file is the whole private key, in hex, readable only by its owner.
Keep it on an encrypted volume, and keep an offline copy: a lost release key
is replaced only with a new set of roots in a new Pylon release.

## Once: making and pinning the keys

Every holder needs a checkout of Pylon and the Resid toolchain (`residc`).

1. **Each holder**, in a directory outside the repository (keygen refuses to
   write inside it):

   ```sh
   tools/release/ceremony.sh keygen rel1      # rel2, rel3 for the others; log1 for the log key
   ```

   It prints the public key and its key id. Send only the `.pub` file to the
   maintainer, and read the key id out to them over a second channel (in
   person, or a call), so a swapped file is caught.

2. **The maintainer**, in the repository:

   ```sh
   tools/release/ceremony.sh roots 2 rel1.pub rel2.pub rel3.pub --log 1 log1.pub
   ```

   This writes the public keys into `core/release_roots.resid`. Check each
   key id against what its holder read out, then commit and push. Every Pylon
   built from that commit on trusts these keys and no others.

## A release in one command

When one person holds the keys, `tools/release/release.sh` runs every step
below on one machine:

```sh
tools/release/release.sh 0.1.4             # asks once, then does everything
tools/release/release.sh 0.1.4 --no-push   # prepare and verify only, to look first
```

It checks the machine first (a clean `master` equal to origin's, docker, `gh`
logged in, the pinned Resid compiler, the keys), then: sets the app's version
(version code one higher) and commits it; builds both `pylond` with the
pinned toolchain; rebuilds them independently and signs only if the code
images match, with every release key it finds; appends the release to a copy
of the log, signs the head, writes the proof and verifies all of it against
the keys this commit pins. Only then does it push `master`, the `pylond-log`
branch and the tag `v0.1.4`, create the GitHub release with the four `pylond`
files, publish it, and follow the APK workflow until the APK is attached.

Nothing leaves the machine before everything verifies. If a run stops (a
network error, a closed laptop), run the same command again: finished steps
are recognized and skipped. `--notes FILE` gives the release notes (the
default lists the commits since the last tag), `--yes` skips the question,
`--no-wait` does not wait for the APK.

### The release machine and its keys

The release machine is the one you run `release.sh` on. It needs docker,
`gh` (`gh auth login`), push access over SSH, and the Resid compiler that
`tools/release/toolchain.env` pins (`./install.sh` in a Resid checkout at
that commit; `release.sh` says so when the installed one differs).

To put the keys on it:

1. Make a directory for them **outside any repository**, on an encrypted
   volume. Best is an encrypted USB drive that is plugged in only for a
   release; an encrypted home directory will do:

   ```sh
   mkdir -m 700 /run/media/$USER/pylon-keys/release   # or: mkdir -m 700 ~/.local/share/pylon-release-keys
   ```

2. Copy into it the release keys (`rel1.key`, `rel2.key`, and `rel3.key` if
   you have it: at least two) and the log key (`log1.key`), from wherever
   `ceremony.sh keygen` made them. Keep the names: `release.sh` takes every
   `rel*.key` as a release key and the one `log*.key` as the log key.

3. Make them readable only by you; `release.sh` refuses keys that others can
   read:

   ```sh
   chmod 600 /run/media/$USER/pylon-keys/release/*.key
   ```

4. Tell `release.sh` where they are, each time with `--keys DIR`, or once in
   your shell's profile:

   ```sh
   export PYLON_RELEASE_KEYS=/run/media/$USER/pylon-keys/release
   ```

5. Keep a second copy of every key offline, elsewhere (a second drive in a
   different place). A lost release key can be replaced only by new roots in
   a new Pylon release; a lost log key means a new log.

A key that is not one of the keys the commit pins is caught when the release
is verified, before anything is pushed (`ceremony.sh pinned-roots` prints the
pinned key ids; `ceremony.sh keygen` printed each key's id when it was made).

What this gives up: with two release keys and the log key on one machine,
that machine can sign a release alone. Two of three still protects against
losing one key, but not against that machine being compromised while the
keys are on it. Keep the drive unplugged except while `release.sh` runs, and
never put a key in CI or in a repository. When the keys are held by
different people, use the steps below instead.

## Each release, step by step

The builds must be reproducible: each signer rebuilds `pylond` and signs only
if their build matches, and the APK workflow rebuilds it again before packing
it. Everyone works from the same commit, the same Resid compiler and the same
clang, lld and aarch64 compiler-rt builtins (Resid links with them, so the code
images depend on their exact build as much as on the compiler's). The
`BUILDINFO` file names all three.

`tools/release/build-pylond.sh` makes every `pylond` build: it refuses any
Resid compiler but the one `tools/release/toolchain.env` pins (install that
Resid commit), and runs clang, lld and the builtins from the container image
in `tools/release/toolchain/`, so every builder needs docker (the first build
makes the image, which downloads the Android NDK once). Change the pins only
between releases: a release built with the old ones no longer reproduces.

1. **The maintainer** builds both `pylond` and the manifest. COUNTER is a whole
   number higher than the last release's (1 for the first):

   ```sh
   tools/release/ceremony.sh build 0.1.1 1
   ```

2. **Two release key holders**, each on their own machine, at that commit:

   ```sh
   tools/release/ceremony.sh check-sign release/0.1.1 /path/to/rel1.key
   ```

   This rebuilds `pylond`, compares code hashes for both architectures, and
   signs only if they match. Signatures are appended to
   `release/0.1.1/pylond.release`, so pass that file from one signer to the
   next.

3. **The log key holder** appends the release to the log, signs the new tree
   head, writes the proof, and verifies everything against the pinned keys:

   ```sh
   tools/release/ceremony.sh publish release/0.1.1 /path/to/pylond-log /path/to/log1.key
   ```

   The log refuses a counter that is not above its highest. Commit the log
   directory to the `pylond-log` branch: it is append-only, and never rewritten.

4. **Publish.** Create the GitHub release as a draft, attach the four files
   `publish` lists (`pylond-x86_64`, `pylond-aarch64`, `pylond.release`,
   `pylond.proof`), then publish it. The APK workflow downloads them, checks
   that its own build reproduces them, and packs them into the app.

## If something goes wrong

- **`check-sign` says NOT signing:** the build differs. Check the commit,
  compiler and toolchain image in `BUILDINFO`. Never sign a build you could not reproduce.
- **A release key is lost:** two remain, and releases continue. Replace it
  soon: new roots, committed, in a new Pylon release.
- **A release key may be stolen:** one key alone cannot sign a release. Make
  new roots without it and release Pylon with them, so updated clients stop
  trusting it.
