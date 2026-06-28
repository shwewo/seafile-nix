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

    seadrive-fuse = {
      url = "github:haiwen/seadrive-fuse/v3.0.22";
      flake = false;
    };

    seadrive-gui = {
      url = "github:haiwen/seadrive-gui/v3.0.22";
      flake = false;
    };
  };

  outputs =
    inputs@{ self, nixpkgs, seafile, seafile-client, seadrive-fuse, seadrive-gui }:
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

          base = import ./nix/default.nix {
            inherit pkgs lib;
            seafileSrc = seafile;
            seafileClientSrc = seafile-client;
            seadriveFuseSrc = seadrive-fuse;
            seadriveGuiSrc = seadrive-gui;
          };
        in
        if !pkgs.stdenv.isDarwin then
          base // { default = base.seafile-client; }
        else
          let
            universal = base.mkUniversalPkg {
              appAarch64 = self.packages.aarch64-darwin.seafile-app;
              appX86_64 = self.packages.x86_64-darwin.seafile-app;
            };
          in
          {
            inherit (base) seafile-shared seafile-client seafile-app seafile-pkg
                           seadrive-fuse seadrive-gui seadrive-app seadrive-pkg;
            seafile-pkg-universal = universal;
            default = base.seafile-client;
          };
    in
    {
      packages = lib.genAttrs systems forSystem;
    };
}