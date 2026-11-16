# The pylond release ceremony

Pylon pushes `pylond` to a server only when that build is signed by enough
release keys, recorded in the transparency log, and not older than one it
has already accepted (SPEC 8.2.1). Until keys are pinned, every build of
Pylon refuses to push `pylond`. This is how the keys are made and how each
release is signed. `tools/release/ceremony.sh` runs every step.

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

## Each release

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
