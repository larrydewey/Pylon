# The toolchain every pylond release is built and reproduced with
# (tools/release/CEREMONY.md, tools/release/build-pylond.sh).
#
# Resid compiles to LLVM IR and links it with the host's clang and lld
# (-flto), so the code images depend on their exact build: the same source
# and the same Resid compiler give a different pylond under clang 18 than
# under clang 23, and lld writes its version into the binary. The aarch64
# build also links compiler-rt's builtins, which differ between NDK
# releases. This image pins all of them: a base image by digest; clang, lld
# and llvm-libs 23.1.3-4 from the Arch Linux Archive's snapshot of
# 2026-10-23; and the aarch64 builtins of Android NDK r30 (30.0.16248370),
# at /opt/pylon-toolchain/libclang_rt.builtins-aarch64-android.a.
#
# Changing anything here changes every code image, so a release built with
# the old pin no longer reproduces: change it only between releases.
FROM archlinux@sha256:d4594bb2300cba11f41c2f27923eb56f63d9988909c402f9c95517d1e362c899

RUN echo 'Server = https://archive.archlinux.org/repos/2026/10/23/$repo/os/$arch' > /etc/pacman.d/mirrorlist \
 && pacman -Syyuu --noconfirm --needed clang lld \
 && pacman -Scc --noconfirm \
 && test "$(pacman -Q clang lld llvm-libs | tr '\n' ' ')" = "clang 23.1.3-4 lld 23.1.3-4 llvm-libs 23.1.3-4 "

# The NDK is 780 MB; only the one archive is kept.
RUN cd /tmp \
 && curl -fsSL -o ndk.zip https://dl.google.com/android/repository/android-ndk-r30-linux.zip \
 && echo "753611f410d002cfcd3f3dc2ef49aad532089d3180b436c060a90bf0fcb64df2  ndk.zip" | sha256sum -c - \
 && mkdir -p /opt/pylon-toolchain \
 && bsdtar -xOf ndk.zip android-ndk-r30/toolchains/llvm/prebuilt/linux-x86_64/lib/clang/21/lib/linux/libclang_rt.builtins-aarch64-android.a \
      > /opt/pylon-toolchain/libclang_rt.builtins-aarch64-android.a \
 && rm ndk.zip \
 && echo "7e900bcdd0bb6f05824fd7e96c9309ee9c47c22751a1b3c98242d1f4902e4632  /opt/pylon-toolchain/libclang_rt.builtins-aarch64-android.a" | sha256sum -c -
