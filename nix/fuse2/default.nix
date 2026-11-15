# libfuse 2.9.9, for seadrive-fuse only (still fuse2-only upstream, FUSE_USE_VERSION 26).
#
# nixpkgs removed fuse2 on 2026-10-25 (end of life). This is its fuse_2 derivation
# (pkgs/os-specific/linux/fuse/common.nix as of nixpkgs b1b87598) with the fuse3
# branches dropped and the fetched patches vendored next to this file:
#   aarch64-fix.patch          libfuse 914871b2 (fuse_kernel.h: clean includes)
#   closefrom-glibc-2-34.patch libfuse 5a43d0f7 (fuse_2_9_bugfix branch)
#   Do-not-set-FUSERMOUNT_DIR.patch, gettext-0.25.patch  from nixpkgs
# Drop this once seadrive-fuse supports fuse3.
{
  lib,
  stdenv,
  fetchFromGitHub,
  util-linux,
  gettext,
  shadow,
  autoreconfHook,
  runtimeShell,
}:

stdenv.mkDerivation {
  pname = "fuse";
  version = "2.9.9";

  src = fetchFromGitHub {
    owner = "libfuse";
    repo = "libfuse";
    tag = "fuse-2.9.9";
    hash = "sha256-dgjM6M7xk5MHi9xPyCyvF0vq0KM8UCsEYBcMhkrdvfs=";
  };

  strictDeps = true;
  __structuredAttrs = true;

  patches =
    lib.optional (stdenv.hostPlatform.isAarch64 || stdenv.hostPlatform.isLoongArch64) ./aarch64-fix.patch
    ++ [
      ./Do-not-set-FUSERMOUNT_DIR.patch
      ./closefrom-glibc-2-34.patch
      ./gettext-0.25.patch
    ];

  nativeBuildInputs = [
    autoreconfHook
    gettext
  ];

  outputs = [
    "bin"
    "out"
    "dev"
    "man"
  ];

  # Call the setuid wrapper, not $out/bin/fusermount. It falls back to
  # fusermount in $PATH, so it also works on non-NixOS systems.
  env.NIX_CFLAGS_COMPILE = ''-DFUSERMOUNT_DIR="/run/wrappers/bin"'';

  preConfigure = ''
    substituteInPlace lib/mount_util.c \
      --replace-fail "/bin/mount" "${lib.getBin util-linux}/bin/mount" \
      --replace-fail "/bin/umount" "${lib.getBin util-linux}/bin/umount"
    substituteInPlace util/mount.fuse.c \
      --replace-fail "/bin/sh" "${runtimeShell}"

    export MOUNT_FUSE_PATH=$bin/bin
    # Not useful outside a system install.
    export INIT_D_PATH=$TMPDIR/etc/init.d
    export UDEV_RULES_PATH=$TMPDIR/etc/udev/rules.d

    substituteInPlace util/mount.fuse.c \
      --replace-fail '"su"' '"${lib.getBin shadow.su}/bin/su"'
  '';

  doCheck = false;

  # Don't pull the SUID fusermount binary into dependents' build environment.
  propagatedBuildOutputs = [ "out" ];

  meta = {
    description = "Library that allows filesystems to be implemented in user space (2.x)";
    homepage = "https://github.com/libfuse/libfuse";
    platforms = lib.platforms.linux;
    license = with lib.licenses; [
      gpl2Only
      lgpl21Only
    ];
    outputsToInstall = [ "bin" ];
  };
}
