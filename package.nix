# Whisplay HAT driver — daemon, hardware self-test, and example apps.
#
# Plain nixpkgs derivation (no flake/uv2nix machinery) so it can be submitted to
# nixpkgs as-is. The flake's overlay exposes this as `pkgs.whisplay`; the NixOS
# module references it through `hardware.whisplay.package`.
{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  dejavu_fonts,
  # Runtime tools the daemon's internal apps shell out to.
  alsa-utils,
  networkmanager,
  bluez,
  ffmpeg,
  coreutils,
  # PyGObject (GLib Bluetooth pairing agent) needs these typelibs at runtime.
  glib,
  gobject-introspection,
}:
let
  pythonEnv = python3.withPackages (ps: [
    ps.pillow
    ps.numpy
    ps.pygame
    ps.pygobject3
    ps.dbus-python
    ps.spidev
    ps.libgpiod
  ]);

  # Tools the wrapped apps invoke as subprocesses (amixer/aplay, nmcli,
  # bluetoothctl, ffmpeg). Put them on PATH regardless of how the bin is launched.
  runtimePath = lib.makeBinPath [ alsa-utils networkmanager bluez ffmpeg coreutils ];

  typelibPath = "${glib.out}/lib/girepository-1.0:${gobject-introspection}/lib/girepository-1.0";

  share = "$out/share/whisplay";

  # name -> { dir = subdir under share; script = python file; }
  bins = {
    whisplay-daemon       = { dir = "daemon";  script = "whisplay_daemon.py"; };
    whisplay-test         = { dir = "example"; script = "test.py"; };
    whisplay-flappy-bird  = { dir = "example"; script = "flappy_bird.py"; };
    whisplay-jump         = { dir = "example"; script = "jump_game.py"; };
    whisplay-play-mp4     = { dir = "example"; script = "play_mp4.py"; };
  };

  mkWrapper = name: { dir, script }: ''
    makeWrapper ${pythonEnv}/bin/python3 $out/bin/${name} \
      --add-flags ${share}/${dir}/${script} \
      --chdir ${share}/${dir} \
      --set PYTHONUNBUFFERED 1 \
      --prefix PYTHONPATH : ${share}/runtime \
      --prefix PATH : ${runtimePath} \
      --set GI_TYPELIB_PATH ${typelibPath}
  '';
in
stdenvNoCC.mkDerivation {
  pname = "whisplay";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  nativeBuildInputs = [ makeWrapper ];

  # No build step — just stage sources, rewrite hardcoded font paths, wrap bins.
  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p ${share} $out/bin
    cp -r runtime daemon example ${share}/

    # The Python hardcodes the Debian DejaVu path. Point it at the Nix store font
    # so text renders without a /usr/share symlink hack. (5 sites: renderer +
    # each example.) The store layout has no `dejavu/` subdir.
    # NB: substituteInPlace is a stdenv shell function, so it must be called
    # directly (not via `find -exec`, which can only exec real binaries).
    for f in \
      ${share}/daemon/daemon_renderer.py \
      ${share}/example/test.py \
      ${share}/example/flappy_bird.py \
      ${share}/example/jump_game.py \
      ${share}/example/play_mp4.py; do
      substituteInPlace "$f" \
        --replace-quiet /usr/share/fonts/truetype/dejavu ${dejavu_fonts}/share/fonts/truetype
    done

    ${lib.concatStrings (lib.mapAttrsToList mkWrapper bins)}

    runHook postInstall
  '';

  meta = {
    description = "Driver, daemon, and example apps for the PiSugar Whisplay HAT";
    homepage = "https://github.com/PiSugar/whisplay";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "whisplay-daemon";
  };
}
