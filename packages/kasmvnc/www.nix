{
  lib,
  stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  nodejs_22,
}:

buildNpmPackage (finalAttrs: {
  pname = "kasmvnc-www";
  version = "2024-11-15";

  src = fetchFromGitHub {
    owner = "kasmtech";
    repo = "noVNC";
    rev = "402c0c59d62424ff110bad8f14682deec7d4c780";
    hash = "sha256-caDJStdPACcyC0MORV6U+HfnI3l3McTJAnTQZknHBVU=";
  };

  nodejs = nodejs_22;

  # Upstream carries no package-lock.json; this repository vendors one that is
  # pinned to the package.json of the revision above (see the neighboring
  # package-lock.json and its README note in docs/superpowers).
  postPatch = ''
    cp ${./package-lock.json} package-lock.json
  '';

  npmDepsHash = "sha256-GqgYn7XjJtp5mlj4e+JbS/mQ0yLtjEzFK0mxs4v+44o=";

  # `npm run build` runs `vite build` and then rearranges the output:
  # it copies app/locale and the QOI wasm module into dist/ and duplicates
  # index.html as vnc.html. Everything the `Xvnc -httpd` handler serves lives
  # in dist/.
  npmBuildScript = "build";

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/kasmvnc
    cp -a dist $out/share/kasmvnc/www

    runHook postInstall
  '';

  meta = {
    description = "KasmVNC web client (kasmtech fork of noVNC)";
    homepage = "https://github.com/kasmtech/noVNC";
    license = lib.licenses.mpl20;
    platforms = lib.platforms.linux;
  };
})
