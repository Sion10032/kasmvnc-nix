{
  description = "KasmVNC built from source, with a NixOS module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        kasmvnc = pkgs.callPackage ./packages/kasmvnc { };
      });

      checks = forAllSystems (
        pkgs:
        import ./tests/kasmvnc.nix {
          inherit pkgs;
          kasmvncModule = self.nixosModules.default;
        }
      );

      nixosModules.default = import ./nixos/module.nix;

      overlays.default = final: prev: {
        kasmvnc = final.callPackage ./packages/kasmvnc { };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nil
            pkgs.nixfmt
          ];
        };
      });
    };
}
