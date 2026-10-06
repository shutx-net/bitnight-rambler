{
  description = "Tiny pixel-art ramblers that roam your terminal";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      forAllSystems =
        f:
        lib.genAttrs [
          "x86_64-linux"
          "aarch64-linux"
          "aarch64-darwin"
        ] (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenv.mkDerivation {
          pname = "rambit";
          version = "0.1.0";

          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./build.zig
              ./build.zig.zon
              ./src
              ./ramblers
            ];
          };

          # Runs `zig build`, `zig build test` and `zig build install`.
          nativeBuildInputs = [ pkgs.zig_0_16.hook ];
          doCheck = true;

          meta = {
            description = "Tiny pixel-art ramblers that roam your terminal";
            homepage = "https://github.com/shutx-net/bitnight-rambler";
            license = lib.licenses.mit;
            mainProgram = "rambit";
            platforms = lib.platforms.unix;
          };
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = [
            pkgs.zig_0_16
            pkgs.zls_0_16
          ];
        };
      });

      checks = forAllSystems (pkgs: {
        rambit = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
        devShell = self.devShells.${pkgs.stdenv.hostPlatform.system}.default;
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
