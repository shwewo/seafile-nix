# Version and patched source trees.
#
# Default: flake inputs (shwewo forks).
# Local dev: NIX_SEAFILE_LOCAL=1 nix build --impure  (reads sibling checkouts via $PWD:
#   ../seafile-src, ../seafile-client, ../seadrive-fuse, ../seadrive-gui)
#
# Package versions come from the Qt clients' CMakeLists.txt (SEAFILE_CLIENT_VERSION_*
# / SEADRIVE_GUI_VERSION_*), plus a packaging "-mtls" suffix. That is the same idea
# as seadroid grepping versionName out of app/build.gradle: the source tree is the
# source of truth, so bumping upstream no longer requires a matching edit here.
{
  lib,
  seafileSrc,
  seafileClientSrc,
  seadriveFuseSrc,
  seadriveGuiSrc,
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

  resolvedSeafileSrc = if useLocal then sibling "seafile-src" else seafileSrc;
  resolvedClientSrc = if useLocal then sibling "seafile-client" else seafileClientSrc;
  resolvedFuseSrc = if useLocal then sibling "seadrive-fuse" else seadriveFuseSrc;
  resolvedGuiSrc = if useLocal then sibling "seadrive-gui" else seadriveGuiSrc;

  # builtins.match is whole-string POSIX ERE and `.` does not match newlines,
  # so match one line at a time.
  firstMatch =
    re: path:
    let
      hits = builtins.filter (l: builtins.match re l != null) (
        lib.splitString "\n" (builtins.readFile path)
      );
    in
    if hits == [ ] then
      throw "no line matching ${re} in ${toString path}"
    else
      builtins.head (builtins.match re (builtins.head hits));

  # SET(<prefix>_VERSION_{MAJOR,MINOR,PATCH} N)
  cmakeVersion =
    prefix: src:
    let
      file = src + "/CMakeLists.txt";
      cap =
        name:
        firstMatch "SET\\(${prefix}_VERSION_${name}[[:space:]]+([0-9]+)\\)" file;
    in
    "${cap "MAJOR"}.${cap "MINOR"}.${cap "PATCH"}";

  suffix = "-mtls";

in
{
  version = cmakeVersion "SEAFILE_CLIENT" resolvedClientSrc + suffix;
  seadriveVersion = cmakeVersion "SEADRIVE_GUI" resolvedGuiSrc + suffix;
  seafileSrc = resolvedSeafileSrc;
  seafileClientSrc = resolvedClientSrc;
  seadriveFuseSrc = resolvedFuseSrc;
  seadriveGuiSrc = resolvedGuiSrc;
}
