{
  description = "Seafile desktop + Android clients with mTLS, built from pristine upstream tags plus a small patch per component.";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      lib = nixpkgs.lib;

      # Upstream pins, one per component. This is the only place versions
      # live — bump `rev` to a new upstream tag and update `hash` (nix will
      # print the correct value on a failed build, or use
      # `nix-prefetch-github <owner> <repo> --rev <tag>`).
      #
      # Each component gets nix/patches/<name>-mtls.patch applied on top via
      # pkgs.applyPatches (see nix/default.nix). If a patch fails to apply
      # after a version bump, only look at the failing hunk — a `.rej` file,
      # or `<<<<<<<` markers left in the source tree — and reconcile just
      # those few lines, not the surrounding file.
      versions = {
        seafile = {
          owner = "haiwen";
          repo = "seafile";
          rev = "v9.0.20";
          hash = "sha256-PBoZDhY7GN8UuYUSXBCPZyBHBtlNcYK+0yS/rl66v9I=";
        };
        # Pinned to the same v9.0.20 as `seafile` (core) — the two are
        # released in lockstep upstream and seafile-client links against
        # libseafile's headers, so keeping both at the same tag avoids an
        # ABI/constant skew (e.g. a client-side error case referencing a
        # SYNC_ERROR_ID_* enum value the core headers don't have yet).
        seafile-client = {
          owner = "haiwen";
          repo = "seafile-client";
          rev = "v9.0.20";
          hash = "sha256-0idZCoTsuC32DolSLFDknQjvGWHGd4DQPCUyqocuuKA=";
        };
        seadrive-fuse = {
          owner = "haiwen";
          repo = "seadrive-fuse";
          rev = "v3.0.26";
          hash = "sha256-cX/cvEFvbk19kfnL83gxW3JMJpUnN7ycZACpCO2XQ/w=";
        };
        seadrive-gui = {
          owner = "haiwen";
          repo = "seadrive-gui";
          rev = "v3.0.22";
          hash = "sha256-1RvNJMMPqxsHJx61lvbdpuKgmyo0r66cAMj5uk58AT4=";
        };
        seadroid = {
          owner = "haiwen";
          repo = "seadroid";
          rev = "v4.0.13";
          hash = "sha256-eoPgCOOzkS4J31/j3UQOsrrJ+Duw2Irrd2Bez7QPWtM=";
        };
      };

      forSystem =
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnsupportedSystem = true;
            # The Android SDK license (for the seadroid dev shell, see nix/android.nix).
            config.allowUnfree = true;
            config.android_sdk.accept_license = true;
          };

          result = import ./nix/default.nix {
            inherit pkgs lib versions;
          };

          packages = result.packages // { default = result.packages.seafile-client; };
        in
        {
          inherit packages;
          devShells = result.devShells;
        };

      combined = lib.genAttrs systems forSystem;
    in
    {
      packages = lib.mapAttrs (_: v: v.packages) combined;
      devShells = lib.mapAttrs (_: v: v.devShells) combined;
    };
}
