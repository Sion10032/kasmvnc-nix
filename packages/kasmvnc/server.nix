{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  nasm,
  pkg-config,
  perl,

  # Main project (librfb + tools) dependencies
  openssl,
  libjpeg_turbo,
  ffmpeg,
  libva,
  libpng,
  libtiff,
  giflib,
  freetype,
  zlib,
  libwebp,
  libcpuid,
  fmt,
  tbb,
  libyuv,
  libdrm,
  mesa,
  libGL,
  libGLU,
  pam,

  # X11 libraries used by the main project and by the Xvnc DDX
  xorg,
  bdftopcf,
  mkfontscale,
  libxcrypt,
  libXtst,
  libXi,
  libXdamage,
  libxrandr,
  libxcursor,
  libxkbfile,
  libxfont_2,
  libpciaccess,
  pixman,
  libxkbcommon,

  # xorg-server source and its own build dependency set: Xvnc is an X server
  # DDX (unix/xserver/hw/vnc), so it can only be produced by building
  # xorg-server itself, patched with upstream's unix/xserver21.patch.
  xorg-server,
  util-macros,
  font-util,
  autoconf,
  automake,
  libtool,
  gettext,
  xorgproto,
  xtrans,
  xkeyboard_config,
  xkbcomp,
}:

let
  # Upstream links turbojpeg statically (`-Wl,-Bstatic -lturbojpeg`).
  libjpegTurbo = libjpeg_turbo.override { enableStatic = true; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "kasmvnc-server";
  version = "1.5.2";

  src = fetchFromGitHub {
    owner = "kasmtech";
    repo = "KasmVNC";
    tag = "v${finalAttrs.version}";
    hash = "sha256-4nPF7ahB6rKIGE8tTFM9XvxQ1EM+w8ciCjxYSaMIm1g=";
    # The kasmweb submodule is built separately (../www.nix) but CMake expects
    # the directory to exist, and the release tarball layout matches upstream.
    fetchSubmodules = false;
  };

  # CMake >= 4 refuses `cmake_policy(SET CMP0022 OLD)`, and the policy is only
  # there to keep the generated libtool control files in the old format.
  patches = [ ./drop-cmp0022-old-policy.patch ];

  # The Xvnc automake files resolve the KasmVNC libraries relative to the
  # source tree (KASMVNC_BUILDDIR=${KASMVNC_SRCDIR}), i.e. upstream only
  # supports an in-source build.
  dontUseCmakeBuildDir = true;

  nativeBuildInputs = [
    cmake
    ninja
    nasm
    pkg-config
    autoconf
    automake
    libtool
    gettext
    util-macros
    font-util
    bdftopcf
    mkfontscale
  ];

  buildInputs = [
    openssl
    libjpegTurbo
    ffmpeg
    libva
    libpng
    libtiff
    giflib
    freetype
    zlib
    libwebp
    libcpuid
    fmt
    tbb
    libyuv
    libdrm
    mesa
    libGL
    libGLU
    libxcrypt
    libXtst
    libXi
    libXdamage
    libxrandr
    libxcursor
    libxkbfile
    libxfont_2
    libpciaccess
    pixman
    libxkbcommon
    xorgproto
    xtrans
    perl
  ]
  ++ lib.optionals (pam != null) [ pam ]
  # Reuse the exact dependency set nixpkgs uses to build xorg-server itself.
  ++ xorg-server.buildInputs;

  propagatedBuildInputs = xorg-server.propagatedBuildInputs;

  cmakeFlags = [
    (lib.cmakeFeature "CMAKE_BUILD_TYPE" "RelWithDebInfo")
    (lib.cmakeBool "BUILD_VIEWER" false)
    (lib.cmakeBool "ENABLE_GNUTLS" false)
    (lib.cmakeFeature "CMAKE_POLICY_VERSION_MINIMUM" "3.5")
    # Upstream adds "$ENV{HOME}/.local/lib" to the link directories, which makes
    # CMake try to rewrite build rpaths at install time. Nix sets rpaths at
    # link time, so let CMake skip its own rpath handling entirely.
    (lib.cmakeBool "CMAKE_SKIP_RPATH" true)
  ];

  # The Xvnc DDX links `-lcrypt` and `-lwebp`/`-lsharpyuv` directly.
  NIX_LDFLAGS = "-lwebp -lsharpyuv";

  postBuild = ''
    kasmvncSrc="$(pwd)"

    # --- Build the Xvnc DDX -------------------------------------------------
    # Same procedure as upstream builder/build.sh: unpack xorg-server into
    # unix/xserver, apply the KasmVNC xserver patch, then autotools-build it.
    tar xf ${xorg-server.src}
    cp -R xorg-server-*/* unix/xserver/

    pushd unix/xserver

    patch -p1 < "$kasmvncSrc/unix/xserver21.patch"

    autoreconf -vfi

    ./configure $configureFlags \
      --disable-config-hal \
      --disable-config-udev \
      --disable-dmx \
      --disable-dri \
      --disable-dri2 \
      --disable-kdrive \
      --disable-static \
      --disable-xephyr \
      --disable-xinerama \
      --disable-xnest \
      --disable-xorg \
      --disable-xvfb \
      --disable-xwayland \
      --disable-xwin \
      --enable-glx \
      --without-dtrace \
      --with-sha1=libcrypto \
      --with-xkb-path=${xkeyboard_config}/share/X11/xkb \
      --with-xkb-bin-directory=${xkbcomp}/bin \
      --with-xkb-output=$out/share/X11/xkb/compiled \
      --prefix="$out"

    make -j"$NIX_BUILD_CORES"

    popd
  '';

  postInstall = ''
    # --- Install Xvnc -------------------------------------------------------
    pushd unix/xserver/hw/vnc
    make install
    popd

    # --- Perl modules used by bin/vncserver ---------------------------------
    # Upstream's packages put these into /usr/share/perl5 (a default @INC
    # entry on Debian); on Nix they are found via PERL5LIB, which the wrapper
    # in ../default.nix sets.
    mkdir -p $out/share/kasmvnc/perl5
    cp -R unix/KasmVNC $out/share/kasmvnc/perl5/

    # --- Runtime data -------------------------------------------------------
    install -Dm644 unix/kasmvnc_defaults.yaml $out/share/kasmvnc/kasmvnc_defaults.yaml

    # Selection helper referenced by vncserver when no DE is configured.
    mkdir -p $out/lib/kasmvnc
    install -Dm755 builder/startup/deb/select-de.sh $out/lib/kasmvnc/select-de.sh

    # GLX clients inside the session need mesa's software rasterizer.
    mkdir -p $out/lib/dri
    for dri in ${mesa}/lib/dri/*_dri.so; do
      ln -s "$dri" $out/lib/dri/
    done
  '';

  meta = {
    description = "KasmVNC server (Xvnc, vncserver, kasmvncpasswd) built from source";
    homepage = "https://github.com/kasmtech/KasmVNC";
    license = [
      lib.licenses.gpl2Only
      lib.licenses.mit
    ];
    platforms = lib.platforms.linux;
    mainProgram = "vncserver";
  };
})
