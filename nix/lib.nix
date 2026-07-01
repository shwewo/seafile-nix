# Version and patched source trees.
#
# Default: flake inputs (shwewo forks).
# Local dev: NIX_SEAFILE_LOCAL=1 nix build --impure  (reads ../seafile-src, ../seafile-client via $PWD)
{
  lib,
  version ? "9.0.20-mtls",
  seadriveVersion ? "3.0.23-mtls",
  seafileSrc,
  seafileClientSrc,
}:

let
  useLocal = builtins.getEnv "NIX_SEAFILE_LOCAL" != "";
  pwd = builtins.getEnv "PWD";

  sibling =
    name:
    if pwd == "" then
      throw "NIX_SEAFILE_LOCAL=1 needs PWD; run nix build from the flake directory"
    else
      builtins.path {
        path = builtins.toPath "${pwd}/../${name}";
        name = "${name}-mtls";
        filter =
          path: type:
          let
            base = baseNameOf path;
          in
          !(
            base == ".git"
            || base == "result"
            || lib.hasSuffix ".o" base
            || lib.hasSuffix ".lo" base
            || lib.hasSuffix ".patch" base
          );
      };

in
{
  inherit version seadriveVersion;
  seafileSrc = if useLocal then sibling "seafile-src" else seafileSrc;
  seafileClientSrc = if useLocal then sibling "seafile-client" else seafileClientSrc;
}
