{
  description = "Driver, daemon, and example apps for the PiSugar Whisplay HAT";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    {
      # Adds `whisplay` to pkgs. Mirrors the eventual nixpkgs package.
      overlays.default = final: prev: {
        whisplay = final.callPackage ./package.nix { };
      };

      # Self-contained NixOS module. Applies the overlay so hardware.whisplay's
      # `package` default (pkgs.whisplay) resolves with no consumer wiring.
      nixosModules.default = { ... }: {
        imports = [ ./modules/whisplay.nix ];
        nixpkgs.overlays = [ self.overlays.default ];
      };
    }
    // flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.whisplay = pkgs.callPackage ./package.nix { };
      packages.default  = pkgs.callPackage ./package.nix { };

      # Local Python dev (lint/run against the working tree). The packaged build
      # uses nixpkgs Python directly — uv is only for the dev loop here.
      devShells.default = pkgs.mkShell {
        packages =
          [ pkgs.python3 pkgs.uv ]
          ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            pkgs.libgpiod
            pkgs.alsa-utils
          ];
        shellHook = ''
          export UV_PYTHON="${pkgs.python3}/bin/python3"
          echo "whisplay devshell — run 'uv sync' to install Python deps"
        '';
      };
    });
}
