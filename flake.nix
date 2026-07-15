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
      url = "github:shwewo/seadrive-fuse";
      flake = false;
    };

    seadrive-gui = {
      url = "github:shwewo/seadrive-gui";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, seafile, seafile-client, seadrive-fuse, seadrive-gui }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
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
            seadriveFuseSrc = seadrive-fuse;
            seadriveGuiSrc = seadrive-gui;
          };
        in
        packages
        // { default = packages.seafile-client; };
    in
    {
      packages = lib.genAttrs systems forSystem;
    };
}
