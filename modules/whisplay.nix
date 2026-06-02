# NixOS module for the Whisplay HAT — hardware bring-up + the daemon service,
# pre-configured so a consumer only needs:
#
#   imports = [ whisplay.nixosModules.default ];
#   hardware.whisplay.enable = true;
#
# Standalone-importable: the daemon binary comes from `cfg.package`
# (pkgs.whisplay via the flake overlay, or nixpkgs once upstreamed), with a
# callPackage fallback so importing just this file still works.
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.whisplay;

  # JSON for one app entry, matching the daemon's on-disk schema.
  appJson = name: app: builtins.toJSON {
    app_id         = name;
    display_name   = app.displayName;
    icon           = if app.icon != "" then app.icon
                     else lib.toUpper (builtins.substring 0 2 name);
    launch_command = app.launchCommand;
    cwd            = app.cwd;
    env            = app.env;
    exit_gesture   = app.exitGesture;
    priority       = app.priority;
    use_daemon_default_log = true;
  };

  # A store dir holding one <app_id>.json per declared app, seeded at preStart.
  appFiles = lib.mapAttrsToList
    (name: app: pkgs.writeTextDir "${name}.json" (appJson name app))
    cfg.apps;
  appsDir = pkgs.symlinkJoin { name = "whisplay-apps"; paths = appFiles; };

  appModule = { name, ... }: {
    options = {
      displayName  = lib.mkOption { type = lib.types.str; description = "Name shown on the desktop menu."; };
      icon         = lib.mkOption { type = lib.types.str; default = ""; description = "1–2 char glyph; defaults to the first letters of the id."; };
      launchCommand = lib.mkOption { type = lib.types.str; description = "Command the daemon spawns (resolved on the daemon's PATH)."; };
      cwd          = lib.mkOption { type = lib.types.str; default = "/tmp"; description = "Working directory for the launched command."; };
      env          = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = {}; description = "Extra environment for the launched command."; };
      exitGesture  = lib.mkOption { type = lib.types.enum [ "quad_click" "long_press" ]; default = "quad_click"; description = "Button gesture that exits the app."; };
      priority     = lib.mkOption { type = lib.types.int; default = 50; description = "Menu ordering; higher sorts first."; };
    };
  };
in {
  options.hardware.whisplay = {
    enable = lib.mkEnableOption "Whisplay HAT hardware support";

    package = lib.mkOption {
      type        = lib.types.package;
      default     = pkgs.whisplay or (pkgs.callPackage ../package.nix {});
      defaultText = lib.literalExpression "pkgs.whisplay";
      description = "The whisplay package providing whisplay-daemon and the example/test apps.";
    };

    platform = lib.mkOption {
      type    = lib.types.enum [ "raspberry-pi" "radxa-zero3w" ];
      default = if (config.hardware.rockchip.rk3566.enable or false)
                then "radxa-zero3w" else "raspberry-pi";
      defaultText = lib.literalExpression ''
        if config.hardware.rockchip.rk3566.enable then "radxa-zero3w" else "raspberry-pi"
      '';
      description = ''
        Target SBC. Auto-detected from NixOS config signals (Rockchip RK3566 ⇒
        radxa-zero3w, otherwise raspberry-pi); set explicitly to override.
        Selects kernel modules, device-tree overlays, and boot settings.

        Note: detection reads the NixOS configuration, not the target's
        /proc/device-tree (evaluation happens on the build host). The daemon's
        whisplay.py separately auto-detects GPIO pin mappings at runtime.
      '';
    };

    daemon = {
      enable   = lib.mkOption { type = lib.types.bool; default = true; description = "Run the Whisplay background daemon (LCD, buttons, app launcher)."; };
      user     = lib.mkOption { type = lib.types.str; default = "pi"; description = "System user that owns the daemon process and its state."; };
      stateDir = lib.mkOption { type = lib.types.str; default = "/var/lib/whisplay-daemon"; description = "Writable state directory for app configs and logs."; };
    };

    apps = lib.mkOption {
      type    = lib.types.attrsOf (lib.types.submodule appModule);
      default = {};
      description = ''
        Desktop apps the daemon offers. The attribute name is the app_id.
        Authoritatively seeded into <stateDir>/app at service start: the dir is
        cleared and rewritten to match exactly, so removed apps don't linger.
        Ships sensible defaults (hardware self-test + example games); consumers
        add their own.
      '';
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [

    # ── Common (every platform) ─────────────────────────────────────────────
    {
      boot.kernelModules = [ "i2c-dev" "snd-soc-wm8960" ];

      # NixOS doesn't create these by default; the daemon's SupplementaryGroups
      # reference them, and systemd refuses to start a service with a missing
      # group (exit 216/GROUP).
      users.groups.gpio = {};
      users.groups.spi  = {};
      users.groups.i2c  = {};

      users.users.${cfg.daemon.user} = {
        isNormalUser = lib.mkDefault true;
        extraGroups  = lib.mkAfter [ "audio" "video" "gpio" "input" "spi" "i2c" ];
      };

      # Device-node permissions for unprivileged hardware access.
      services.udev.extraRules = lib.mkAfter ''
        SUBSYSTEM=="spidev", GROUP="spi", MODE="0660"
        SUBSYSTEM=="i2c-dev", GROUP="i2c", MODE="0660"
        SUBSYSTEM=="gpio", GROUP="gpio", MODE="0660"
        KERNEL=="gpiochip*", GROUP="gpio", MODE="0660"
      '';

      # The daemon's Bluetooth pairing agent / BT app need the stack present.
      hardware.bluetooth.enable = lib.mkDefault true;

      # Default ALSA to the WM8960 card (sound.enable was removed in 25.05).
      hardware.alsa.enable = lib.mkDefault true;
      environment.etc."asound.conf".text = lib.mkDefault ''
        pcm.!default {
          type hw
          card wm8960soundcard
        }
        ctl.!default {
          type hw
          card wm8960soundcard
        }
      '';

      # The whisplay-* CLIs (daemon, test, games) on the system PATH.
      environment.systemPackages = [ cfg.package ];

      # The WM8960 powers up muted; unmute and route the DAC at every boot.
      systemd.services.wm8960-mixer-init = {
        description = "Initialize WM8960 ALSA mixer";
        wantedBy    = [ "multi-user.target" ];
        after       = [ "local-fs.target" ];
        path        = [ pkgs.alsa-utils pkgs.gawk pkgs.coreutils ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = ''
          card=""
          for _ in $(seq 1 30); do
            card=$(awk '/wm8960soundcard/ {print $1}' /proc/asound/cards | head -n1)
            [ -n "$card" ] && break
            sleep 0.5
          done
          if [ -z "$card" ]; then
            echo "wm8960 sound card not found; skipping mixer init" >&2
            exit 0
          fi
          amx() { amixer -c "$card" -q -- "$@" || true; }
          amx sset 'Headphone' 100% unmute
          amx sset 'Speaker' 100% unmute
          amx sset 'Playback' 100% unmute
          amx sset 'Left Output Mixer PCM' on
          amx sset 'Right Output Mixer PCM' on
          amx sset 'Capture' 75% cap
          amx sset 'ADC PCM' 100%
          amx sset 'Left Input Mixer Boost' on
          amx sset 'Right Input Mixer Boost' on
          amx sset 'Left Boost Mixer LINPUT1' 100%
          amx sset 'Right Boost Mixer RINPUT1' 100%
        '';
      };

      # Default app menu: the hardware self-test and the bundled example games.
      hardware.whisplay.apps = {
        whisplay-run-test    = lib.mkDefault { displayName = "HW Self-Test"; icon = "TS"; launchCommand = "whisplay-test";        exitGesture = "quad_click"; priority = 85; };
        whisplay-flappy-bird = lib.mkDefault { displayName = "Flappy Bird";  icon = "F";  launchCommand = "whisplay-flappy-bird"; exitGesture = "long_press"; priority = 20; };
        whisplay-jump        = lib.mkDefault { displayName = "Jump Game";    icon = "J";  launchCommand = "whisplay-jump";        exitGesture = "quad_click"; priority = 25; };
        whisplay-play-mp4    = lib.mkDefault { displayName = "Play MP4";     icon = "V";  launchCommand = "whisplay-play-mp4";    exitGesture = "quad_click"; priority = 10; };
      };
    }

    # ── Raspberry Pi (Zero 2W / any 40-pin BCM board) ───────────────────────
    (lib.mkIf (cfg.platform == "raspberry-pi") {
      # These land in /boot/firmware/config.txt (needs the rpi bootloader, which
      # nixos-hardware's raspberry-pi modules set up).
      boot.loader.raspberryPi.firmwareConfig = lib.mkAfter ''
        dtparam=i2c_arm=on
        dtparam=i2s=on
        dtparam=spi=on
        dtoverlay=i2s-mmap
        dtoverlay=wm8960-soundcard
      '';
      # RPi-specific machine-driver shim.
      boot.kernelModules = [ "snd-soc-wm8960-soundcard" ];
      # NOTE: wm8960-soundcard.dtbo ships inside audio/WM8960-Audio-HAT.zip and
      # must be deployed to /boot/firmware/overlays/ for the overlay to load.
    })

    # ── Radxa ZERO 3W (RK3566) ──────────────────────────────────────────────
    (lib.mkIf (cfg.platform == "radxa-zero3w") {
      hardware.deviceTree.enable = true;
      # Compiled to .dtbo at build time and merged into the device tree.
      hardware.deviceTree.overlays = [
        # WM8960 codec on I2C3 / I2S3.
        { name = "wm8960-radxa-zero3"; dtsFile = ../audio/wm8960-radxa-zero3.dts; }
        # SPI3 (M1, CS0) + spidev node — the LCD bus. whisplay.py opens
        # /dev/spidev3.0 on this board; mainline rk3566 ships SPI3 disabled,
        # so without this the daemon's display init fails.
        { name = "radxa-spi3-m1-spidev"; dtsFile = ../overlays/radxa-spi3-m1-spidev.dts; }
      ];
    })

    # ── Daemon service ──────────────────────────────────────────────────────
    (lib.mkIf cfg.daemon.enable {
      systemd.services.whisplay-daemon = {
        description = "Whisplay HAT daemon";
        wantedBy    = [ "multi-user.target" ];
        after       = [ "sound.target" "network.target" "local-fs.target" "wm8960-mixer-init.service" ];
        # whisplay-* launch commands must resolve on the daemon's PATH so it can
        # spawn the apps seeded below.
        path        = [ cfg.package ];

        # The app dir is declarative: it always reflects `apps` exactly. Clear
        # and re-seed each start so removed/renamed apps don't linger.
        preStart = ''
          install -d -m 750 -o ${cfg.daemon.user} ${cfg.daemon.stateDir}/app
          rm -f ${cfg.daemon.stateDir}/app/*.json
          cp -f ${appsDir}/*.json ${cfg.daemon.stateDir}/app/
          [ -e ${cfg.daemon.stateDir}/settings.json ] || \
            echo '{"apps_dir":"${cfg.daemon.stateDir}/app"}' > ${cfg.daemon.stateDir}/settings.json
        '';

        serviceConfig = {
          Type                = "simple";
          User                = cfg.daemon.user;
          Group               = "audio";
          SupplementaryGroups = "audio video gpio input spi i2c";
          StateDirectory      = "whisplay-daemon";
          StateDirectoryMode  = "0750";
          ExecStart           = "${cfg.package}/bin/whisplay-daemon";
          Environment         = [
            "WHISPLAY_DAEMON_APPS_DIR=${cfg.daemon.stateDir}/app"
            "WHISPLAY_DAEMON_SETTINGS_PATH=${cfg.daemon.stateDir}/settings.json"
          ];
          PrivateDevices      = "no";   # real /dev nodes required for hardware
          Restart             = "always";
          RestartSec          = "2";
          StandardOutput      = "journal";
          StandardError       = "journal";
          SyslogIdentifier    = "whisplay-daemon";
        };
      };
    })
  ]);
}
