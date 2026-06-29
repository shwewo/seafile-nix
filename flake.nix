{
  description = "Seafile desktop client with mTLS — Linux and macOS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    seafile = {
      url = "github:shwewo/seafile";
      flake = false;
    };

    seafile-client = {
      url = "github:shwewo/seafile-client";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, seafile, seafile-client }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      lib = nixpkgs.lib;

      forSystem =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnsupportedSystem = true;
          };

          packages = import ./nix/default.nix {
            inherit pkgs lib;
            seafileSrc = seafile;
            seafileClientSrc = seafile-client;
          };
        in
        packages
        // { default = packages.seafile-client; }
        // lib.optionalAttrs pkgs.stdenv.isDarwin {
          seafile-pkg-universal = packages.mkUniversalPkg {
            appAarch64 = self.packages.aarch64-darwin.seafile-app;
            appX86_64 = self.packages.x86_64-darwin.seafile-app;
          };
        };
    in
    {
      packages = lib.genAttrs systems forSystem;
    };
}