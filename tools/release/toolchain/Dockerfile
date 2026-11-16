# The toolchain every pylond release is built and reproduced with
# (tools/release/CEREMONY.md, tools/release/build-pylond.sh).
#
# Resid compiles to LLVM IR and links it with the host's clang and lld
# (-flto), so the code images depend on their exact build: the same source
# and the same Resid compiler give a different pylond under clang 18 than
# under clang 23, and lld writes its version into the binary. This image
# pins them: a base image by digest, and clang, lld and llvm-libs 23.1.3-4
# from the Arch Linux Archive's snapshot of 2026-10-23.
#
# Changing anything here changes every code image, so a release built with
# the old pin no longer reproduces: change it only between releases.
FROM archlinux@sha256:d4594bb2300cba11f41c2f27923eb56f63d9988909c402f9c95517d1e362c899

RUN echo 'Server = https://archive.archlinux.org/repos/2026/10/23/$repo/os/$arch' > /etc/pacman.d/mirrorlist \
 && pacman -Syyuu --noconfirm --needed clang lld \
 && pacman -Scc --noconfirm \
 && test "$(pacman -Q clang lld llvm-libs | tr '\n' ' ')" = "clang 23.1.3-4 lld 23.1.3-4 llvm-libs 23.1.3-4 "
