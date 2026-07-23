#!/usr/bin/env bash
#
# build-musl.sh — build a fully-static, portable chafa binary linked against musl libc.
#
# Result: a single x86_64 ELF with NO dynamic dependencies that runs on old machines
# (any x86_64 Linux, regardless of the host's glibc version). chafa does runtime CPU
# feature detection, so it safely falls back on CPUs lacking AVX2/SSE4.1.
#
# Works the same locally and in GitHub Actions. System packages (Debian/Ubuntu):
#   sudo apt-get install -y musl-tools meson ninja-build cmake pkg-config \
#     autoconf automake libtool curl
#
# Override locations with env vars (defaults shown):
#   SRC=/tmp/chafa-musl-src   PREFIX=/opt/chafa-musl   CHAFA_SRC=<script's dir>
#
# Idempotent: a dependency whose .a/.pc is already in $PREFIX is skipped, so $PREFIX
# can be cached (e.g. actions/cache) to speed up repeated runs.
#
set -euo pipefail

CHAFA_SRC="${CHAFA_SRC:-$(cd "$(dirname "$0")" && pwd)}"
SRC="${SRC:-/tmp/chafa-musl-src}"
PREFIX="${PREFIX:-/opt/chafa-musl}"
JOBS="${JOBS:-$(nproc)}"

echo "==> chafa source : $CHAFA_SRC"
echo "==> deps workdir : $SRC"
echo "==> deps prefix  : $PREFIX"
echo "==> jobs         : $JOBS"

[ -f "$CHAFA_SRC/chafa/Makefile.am" ] || { echo "Not a chafa source tree: $CHAFA_SRC" >&2; exit 1; }

mkdir -p "$PREFIX/lib/pkgconfig" "$SRC"
cd "$SRC"

# ---- shared toolchain environment ---------------------------------------------
export CC=musl-gcc
export CXX=false
# Kernel UAPI headers (linux/, asm/, asm-generic/) are kernel-neutral but live under
# /usr/include, which musl-gcc does NOT search. Assemble them into one -isystem dir.
KH="$PREFIX/kheaders"; mkdir -p "$KH"
[ -e "$KH/linux" ]       || ln -s /usr/include/linux "$KH/linux"
[ -e "$KH/asm-generic" ] || ln -s /usr/include/asm-generic "$KH/asm-generic"
[ -e "$KH/asm" ]         || ln -s /usr/include/x86_64-linux-gnu/asm "$KH/asm"
export CFLAGS="-O2 -fPIC"
# Kernel UAPI headers are needed ONLY by libffi (tramp.c -> linux/limits.h). Applying
# them globally breaks pcre2 (glibc's features.h leaks in via the linux/ symlink chain).
FFI_CFLAGS="-O2 -fPIC -isystem $KH"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig"
export PKG_CONFIG="pkg-config --static"
export PATH="$PREFIX/bin:$PATH"

have_lib() { [ -f "$PREFIX/lib/$1" ] || [ -f "$PREFIX/lib/x86_64-linux-gnu/$1" ]; }
have_pc()  { "$PKG_CONFIG" --exists "$1" 2>/dev/null; }
# dl <out-name> <url> [<fallback-url>...]
dl() { local out="$1"; shift; local u; for u in "$@"; do [ -f "$out" ] && return 0; curl -fsSL -o "$out" "$u" && return 0; done; return 1; }

# ---- 1. zlib ------------------------------------------------------------------
if ! have_lib libz.a; then
  echo "==> [1/7] zlib"
  dl zlib-1.3.1.tar.gz \
    https://zlib.net/zlib-1.3.1.tar.gz \
    https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz
  rm -rf zlib-1.3.1 && tar xzf zlib-1.3.1.tar.gz && cd zlib-1.3.1
  ./configure --prefix="$PREFIX" --static
  make -j"$JOBS" && make install
  cd "$SRC"
fi

# ---- 2. libpng (needs zlib) ---------------------------------------------------
if ! have_lib libpng16.a; then
  echo "==> [2/7] libpng"
  dl libpng-1.6.43.tar.gz https://download.sourceforge.net/libpng/libpng-1.6.43.tar.gz
  rm -rf libpng-1.6.43 && tar xzf libpng-1.6.43.tar.gz
  cmake -S libpng-1.6.43 -B pngb -G Ninja \
    -DCMAKE_C_COMPILER=musl-gcc -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF \
    -DZLIB_ROOT="$PREFIX" -DCMAKE_C_FLAGS="$CFLAGS"
  cmake --build pngb -j"$JOBS" && cmake --install pngb
fi

# ---- 3. pcre2 (needs only libc; glib dep) ------------------------------------
if ! have_lib libpcre2-8.a; then
  echo "==> [3/7] pcre2"
  dl pcre2-10.43.tar.bz2 \
    https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.43/pcre2-10.43.tar.bz2
  rm -rf pcre2-10.43 && tar xjf pcre2-10.43.tar.bz2
  cmake -S pcre2-10.43 -B pcreb -G Ninja \
    -DCMAKE_C_COMPILER=musl-gcc -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DPCRE2_BUILD_PCPGREP=OFF -DPCRE2_BUILD_TESTS=OFF \
    -DPCRE2_SUPPORT_LIBZ=OFF -DPCRE2_SUPPORT_LIBBZ2=OFF -DPCRE2_SUPPORT_JIT=ON \
    -DCMAKE_C_FLAGS="$CFLAGS"
  cmake --build pcreb -j"$JOBS" && cmake --install pcreb
fi

# ---- 4. libffi (gobject dep; glib's meson compiles the whole suite) -----------
if ! have_lib libffi.a; then
  echo "==> [4/7] libffi"
  dl libffi-3.4.6.tar.gz \
    https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz
  rm -rf libffi-3.4.6 && tar xzf libffi-3.4.6.tar.gz && cd libffi-3.4.6
  # Build without -static in LDFLAGS so its internal self-tests link; the .a is still static.
  ( unset LDFLAGS
    ./configure --prefix="$PREFIX" --enable-static --disable-shared CC=musl-gcc CFLAGS="$FFI_CFLAGS"
    make -j"$JOBS" && make install )
  cd "$SRC"
fi

# ---- 5. freetype (needs zlib, png; brotli/bzip2 codecs disabled to slim deps) -
if ! have_lib libfreetype.a; then
  echo "==> [5/7] freetype"
  dl freetype-2.13.3.tar.xz https://downloads.sourceforge.net/freetype/freetype-2.13.3.tar.xz
  rm -rf freetype-2.13.3 && tar xf freetype-2.13.3.tar.xz
  cmake -S freetype-2.13.3 -B ftb -G Ninja \
    -DCMAKE_C_COMPILER=musl-gcc -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_BROTLI=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_HARFBUZZ=ON \
    -DFT_REQUIRE_ZLIB=ON -DFT_REQUIRE_PNG=ON -DCMAKE_PREFIX_PATH="$PREFIX" \
    -DCMAKE_C_FLAGS="$CFLAGS"
  cmake --build ftb -j"$JOBS" && cmake --install ftb
fi

# ---- 6. glib (needs pcre2 + libffi) -------------------------------------------
if ! have_pc glib-2.0; then
  echo "==> [6/7] glib"
  dl glib-2.78.4.tar.xz https://download.gnome.org/sources/glib/2.78/glib-2.78.4.tar.xz
  rm -rf glib-2.78.4 && tar xf glib-2.78.4.tar.xz && cd glib-2.78.4
  meson setup _build --prefix="$PREFIX" --default-library=static --buildtype=release \
    -Dnls=disabled -Dselinux=disabled -Dlibmount=disabled -Dsysprof=disabled \
    -Dlibelf=disabled -Dgtk_doc=false -Dman=false -Dtests=false
  meson compile -C _build -j"$JOBS"
  meson install -C _build
  cd "$SRC"
  # glib installs into the multiarch libdir lib/x86_64-linux-gnu; its .pc files are
  # self-consistent (libdir is baked in) and PKG_CONFIG_PATH above already covers it.
fi

# ---- 7. chafa (static executable) ---------------------------------------------
echo "==> [7/7] chafa"
cd "$CHAFA_SRC"
# Generate configure/Makefile.in if absent (fresh checkout); don't run configure here.
[ -x ./configure ] || NOCONFIGURE=1 ./autogen.sh

# Configure with -static in LDFLAGS for the probes; -static is *eaten by libtool*
# at link time, so the real static link uses -all-static at make time (see below).
./configure --prefix="$PREFIX" --enable-static --disable-shared CC=musl-gcc \
  CFLAGS="$CFLAGS" PKG_CONFIG="$PKG_CONFIG" \
  GLIB_CFLAGS="$($PKG_CONFIG --cflags glib-2.0)" \
  GLIB_LIBS="$($PKG_CONFIG --libs --static glib-2.0)" \
  FREETYPE_CFLAGS="$($PKG_CONFIG --cflags freetype2)" \
  FREETYPE_LIBS="$($PKG_CONFIG --libs --static freetype2)" \
  LDFLAGS="-static -L$PREFIX/lib -L$PREFIX/lib/x86_64-linux-gnu"

# -all-static is a libtool flag (safe at make time, NOT at configure time) that
# forces the final executable to be fully statically linked.
make -j"$JOBS" LDFLAGS="-all-static -L$PREFIX/lib -L$PREFIX/lib/x86_64-linux-gnu"

# ---- emit stripped distribution binary ---------------------------------------
cp tools/chafa/chafa chafa-musl-static
strip chafa-musl-static

echo
echo "=== Built: $CHAFA_SRC/chafa-musl-static ==="
file chafa-musl-static
ls -lh chafa-musl-static
