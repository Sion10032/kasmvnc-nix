{
  lib,
  stdenv,
  callPackage,
  makeWrapper,
  runCommand,
  perl,
  coreutils,
  bash,
  procps,
  gnugrep,
  gnused,
  xauth,
  xdpyinfo,
  xsetroot,
  xrandr,
  xkbcomp,
  xterm,
}:

let
  kasmvnc-server = callPackage ./server.nix { };
  kasmvnc-www = callPackage ./www.nix { };

  # Runtime Perl modules of unix/vncserver (see the `use` statements in that
  # script and in unix/KasmVNC/*.pm, and the perl:Depends list in upstream's
  # debian/control).
  perlEnv = perl.withPackages (
    p: with p; [
      ListMoreUtils
      Switch
      TryTiny
      DateTime
      DateTimeTimeZone
      YAMLTiny
      HashMergeSimple
    ]
  );

  runtimePath = lib.makeBinPath [
    coreutils
    bash
    procps
    gnugrep
    gnused
    xauth
    xdpyinfo
    xsetroot
    xrandr
    xkbcomp
    xterm
  ];
in
stdenv.mkDerivation (finalAttrs: {
  pname = "kasmvnc";
  version = "1.5.2";

  # Nothing to compile: this derivation assembles the server and the web
  # frontend and adds the runtime wrappers.
  dontUnpack = true;
  dontPatch = true;
  dontConfigure = true;
  dontBuild = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/share/kasmvnc $out/lib

    for bin in Xvnc vncserver kasmvncpasswd vncpasswd vncconfig kasmxproxy; do
      ln -s ${kasmvnc-server}/bin/$bin $out/bin/$bin
    done

    # vncserver is patched below, so it must be a real file, not a symlink.
    rm $out/bin/vncserver
    install -m755 ${kasmvnc-server}/bin/vncserver $out/bin/vncserver

    # The build's patchShebangs points the script at the bare perl; it needs the
    # interpreter that carries the module set above.
    sed -i "1s|.*|#!${perlEnv}/bin/perl|" $out/bin/vncserver

    # Upstream hardcodes the default configuration at its Debian install
    # prefix, and expects the DE selection helper next to the source tree.
    substituteInPlace $out/bin/vncserver \
      --replace-fail "/usr/share/kasmvnc/kasmvnc_defaults.yaml" \
                     "$out/share/kasmvnc/kasmvnc_defaults.yaml" \
      --replace-fail '$dirname/../builder/startup/deb/select-de.sh' \
                     "$out/lib/kasmvnc/select-de.sh"

    ln -s ${kasmvnc-server}/share/kasmvnc/kasmvnc_defaults.yaml $out/share/kasmvnc/kasmvnc_defaults.yaml
    ln -s ${kasmvnc-server}/share/kasmvnc/perl5 $out/share/kasmvnc/perl5
    ln -s ${kasmvnc-server}/lib/kasmvnc $out/lib/kasmvnc
    ln -s ${kasmvnc-server}/lib/dri $out/lib/dri

    # The `-httpd` document root.
    ln -s ${kasmvnc-www}/share/kasmvnc/www $out/share/kasmvnc/www

    wrapProgram $out/bin/vncserver \
      --set PERL5LIB "$out/share/kasmvnc/perl5" \
      --prefix PATH : ${runtimePath}

    runHook postInstall
  '';

  passthru = {
    inherit kasmvnc-server kasmvnc-www;

    tests.smoke = runCommand "kasmvnc-smoke" { } ''
      for f in bin/vncserver bin/Xvnc bin/kasmvncpasswd bin/kasmxproxy \
               share/kasmvnc/www/index.html \
               share/kasmvnc/kasmvnc_defaults.yaml \
               share/kasmvnc/perl5/KasmVNC/Config.pm; do
        if ! test -e "${finalAttrs.finalPackage}/$f"; then
          echo "missing: $f" >&2
          exit 1
        fi
      done

      head -1 "${finalAttrs.finalPackage}/bin/vncserver" | grep -q nix/store

      touch $out
    '';
  };
})
