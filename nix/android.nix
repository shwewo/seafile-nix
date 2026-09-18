# Android SDK toolchain, and the patched seadroid source, for building the
# Seafile Android client.
#
# The APK itself is never a hermetic `nix build`: Gradle resolves its own
# dependencies from Maven at build time, which needs network access the Nix
# sandbox doesn't allow for a regular derivation. `debugApk` below is a
# `nix run`-able script instead (network happens at run time, outside the
# sandbox) — see ../.github/workflows/build.yml for how CI does the same for
# a signed release build. The source itself (fetch + patch) is still fully
# reproducible via `nix build` — only the Gradle step isn't.
{
  pkgs,
  lib,
  seadroidSrc,
}:

let
  # Keep in sync with seadroid's app/build.gradle (compileSdk/targetSdk,
  # sourceCompatibility). seadroid itself has no native code, but AGP still
  # wants an NDK at this exact version to strip .so files bundled in some
  # dependency AARs (e.g. the Firebase Crashlytics / libheif deps) — without
  # it present, AGP tries to auto-install into the (read-only) Nix store SDK
  # and fails.
  androidComposition = pkgs.androidenv.composeAndroidPackages {
    platformVersions = [ "36" ];
    buildToolsVersions = [ "35.0.0" ];
    includeNDK = true;
    ndkVersions = [ "27.0.12077973" ];
    includeCmake = true;
    cmakeVersions = [ "3.22.1" ];
    includeEmulator = false;
    includeSystemImages = false;
  };

  androidSdk = androidComposition.androidsdk;
  sdkRoot = "${androidSdk}/libexec/android-sdk";
  jdk = pkgs.jdk17;

  gradleEnv = ''
    export JAVA_HOME=${jdk.home}
    export ANDROID_HOME=${sdkRoot}
    export ANDROID_SDK_ROOT=${sdkRoot}
    export GRADLE_OPTS="-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkRoot}/build-tools/35.0.0/aapt2"
    export PATH=${jdk}/bin:${androidComposition.platform-tools}/bin:"$PATH"
  '';

  # `nix run .#seadroid-debug-apk` — builds an unsigned-for-distribution
  # debug APK with zero secrets needed (debug signing config is empty; AGP
  # debug-signs it automatically). This still needs network for Gradle to
  # resolve Maven dependencies, so it's `nix run`, not a hermetic `nix
  # build` — see the file header. A *release* APK needs a real signing key
  # and is CI-only; there's deliberately no local one-liner for it. See
  # README.md's Android section.
  debugApk = pkgs.writeShellApplication {
    name = "seadroid-debug-apk";
    runtimeInputs = [
      pkgs.coreutils
      jdk
    ];
    text = ''
      work="$(mktemp -d)"
      trap 'rm -rf "$work"' EXIT
      cp -rL ${seadroidSrc} "$work/src"
      chmod -R u+w "$work/src"
      cd "$work/src"

      ${gradleEnv}

      # app/build.gradle loads app/key.properties unconditionally at
      # configuration time (even for `assembleDebug`), because the release
      # signingConfig block reads it eagerly. A throwaway keystore here is
      # fine — the debug variant self-signs regardless of this file; it just
      # needs to exist and parse.
      keytool -genkeypair -v \
        -keystore app/ci-debug.keystore -alias ci -keyalg RSA -keysize 2048 \
        -validity 10000 -storepass ci-debug-pass -keypass ci-debug-pass \
        -dname "CN=Local Debug Build, OU=dev, O=dev, L=dev, S=dev, C=US"
      cat > app/key.properties <<EOF
      keyStore=ci-debug.keystore
      keyStorePassword=ci-debug-pass
      keyAlias=ci
      keyAliasPassword=ci-debug-pass
      EOF

      ./gradlew assembleDebug --console=plain

      apk=$(find app/build/outputs/apk/debug -name '*.apk' | head -1)
      cp "$apk" "$OLDPWD/"
      echo "Built: $OLDPWD/$(basename "$apk")"
    '';
  };

in
{
  src = seadroidSrc;
  inherit debugApk;

  devShell = pkgs.mkShell {
    packages = [
      androidSdk
      androidComposition.platform-tools
      jdk
    ];

    JAVA_HOME = jdk.home;
    ANDROID_HOME = sdkRoot;
    ANDROID_SDK_ROOT = sdkRoot;

    # Use the SDK's own aapt2 instead of letting AGP fetch one from Maven.
    GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkRoot}/build-tools/35.0.0/aapt2";
  };
}
