{
  description = "Driver and example apps for the Whisplay HAT";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    # nixosModules is system-independent — export it outside eachDefaultSystem.
    {
      nixosModules.default = import ./modules/whisplay.nix;
    }
    //
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.python3
            pkgs.uv
          ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
            # libgpiod is the C library that the gpiod Python package links against
            pkgs.libgpiod
            # alsa-utils provides aplay, used in example/run_test.sh
            pkgs.alsa-utils
          ];

          shellHook = ''
            # Point uv at the Nix-provided Python so it doesn't pull its own
            export UV_PYTHON="${pkgs.python3}/bin/python3"
            echo "whisplay devshell — run 'uv sync' to install Python deps"
          '';
        };
      });
}
