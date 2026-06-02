{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.whisplay;

  # Package the Python sources so the daemon service can reference them
  # from the immutable Nix store regardless of where the repo lives.
  whisplaySrc = pkgs.stdenv.mkDerivation {
    pname = "whisplay";
    version = "0.1.0";
    src = lib.cleanSource ./..;
    dontBuild = true;
    installPhase = ''
      mkdir -p $out/runtime $out/daemon/default_apps $out/daemon/img $out/daemon/internal_apps $out/daemon/skills
      cp -r runtime/*.py            $out/runtime/  2>/dev/null || true
      cp    *.py                    $out/runtime/  2>/dev/null || true
      cp -r daemon/*.py             $out/daemon/
      cp -r daemon/default_apps/*   $out/daemon/default_apps/  2>/dev/null || true
      cp -r daemon/img/*            $out/daemon/img/            2>/dev/null || true
      cp -r daemon/internal_apps/*  $out/daemon/internal_apps/  2>/dev/null || true
      cp -r daemon/skills/*         $out/daemon/skills/         2>/dev/null || true
    '';
  };

  # Python env for the daemon.
  # spidev and gpiod are Linux-only C extensions; gate them so the module
  # can be evaluated on non-Linux hosts (e.g. a macOS build machine) without error.
  daemonPythonEnv = pkgs.python3.withPackages (ps:
    [ ps.pillow ps.numpy ]
    ++ lib.optionals pkgs.stdenv.isLinux (
      [ ps.pygame ]
      # spidev and gpiod may not be in every nixpkgs channel — add them if
      # your channel has them, otherwise install via uv after boot.
      ++ lib.optional (ps ? spidev) ps.spidev
      ++ lib.optional (ps ? gpiod)  ps.gpiod
    )
  );

in {

  options.hardware.whisplay = {
    enable = lib.mkEnableOption "Whisplay HAT hardware support";

    platform = lib.mkOption {
      type    = lib.types.enum [ "raspberry-pi" "radxa-zero3w" ];
      example = "radxa-zero3w";
      description = ''
        Target SBC platform. Controls which kernel modules, device-tree overlays,
        and boot-loader settings are applied.
        - "raspberry-pi"  — Pi Zero 2W (and any 40-pin Pi with BCM SoC)
        - "radxa-zero3w"  — Radxa ZERO 3W (RK3566)
      '';
    };

    daemon = {
      enable = lib.mkOption {
        type    = lib.types.bool;
        default = true;
        description = "Run the Whisplay background daemon (LCD, buttons, app launcher).";
      };

      user = lib.mkOption {
        type        = lib.types.str;
        default     = "pi";
        description = "Existing system user that owns the daemon process and its state directory.";
      };

      stateDir = lib.mkOption {
        type        = lib.types.str;
        default     = "/var/lib/whisplay-daemon";
        description = "Writable state directory for app configs and logs.";
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [

    # ── Common ─────────────────────────────────────────────────────────────
    {
      # WM8960 codec driver + I2C userspace access — needed on every platform.
      boot.kernelModules = [ "i2c-dev" "snd-soc-wm8960" ];

      # Grant the daemon user access to hardware peripherals.
      users.users.${cfg.daemon.user}.extraGroups =
        lib.mkAfter [ "audio" "video" "gpio" "input" "spi" "i2c" ];

      # ALSA: default to the WM8960 sound card.
      sound.enable = true;
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
    }

    # ── Raspberry Pi (Zero 2W / any 40-pin BCM board) ──────────────────────
    (lib.mkIf (cfg.platform == "raspberry-pi") {
      # These appear in /boot/firmware/config.txt.
      # Requires boot.loader.raspberryPi.enable = true in your configuration.
      # If you use nixos-hardware, the rpi module sets that up already.
      boot.loader.raspberryPi.firmwareConfig = lib.mkAfter ''
        dtparam=i2c_arm=on
        dtparam=i2s=on
        dtparam=spi=on
        dtoverlay=i2s-mmap
        dtoverlay=wm8960-soundcard
      '';

      # The snd-soc-wm8960-soundcard shim is RPi-specific.
      boot.kernelModules = [ "snd-soc-wm8960-soundcard" ];

      # NOTE: wm8960-soundcard.dtbo is shipped inside audio/WM8960-Audio-HAT.zip.
      # The RPi firmware overlay loader expects it in /boot/firmware/overlays/.
      # To deploy it, add this to your image build:
      #
      #   boot.loader.raspberryPi.overlayDtbs = [
      #     (pkgs.runCommand "wm8960-soundcard-dtbo" {} ''
      #       ${pkgs.unzip}/bin/unzip -j ${../audio/WM8960-Audio-HAT.zip} \
      #         "*/wm8960-soundcard.dtbo" -d $out
      #     '')
      #   ];
      #
      # Uncomment and wire up once you've confirmed the zip contains that file.
    })

    # ── Radxa ZERO 3W (RK3566) ─────────────────────────────────────────────
    (lib.mkIf (cfg.platform == "radxa-zero3w") {
      hardware.deviceTree.enable = true;

      # The DTS source is in the repo; NixOS compiles it to a .dtbo at build
      # time using the kernel's dtc, then merges it into the device tree.
      hardware.deviceTree.overlays = [
        {
          name    = "wm8960-radxa-zero3";
          dtsFile = ../audio/wm8960-radxa-zero3.dts;
        }
      ];

      # SPI3 and I2C3 overlays are shipped with the Radxa vendor kernel.
      # Enable them by name — they are resolved from /boot/dtbo/ automatically.
      # If your image doesn't include them, add their .dts sources here too.
    })

    # ── Daemon systemd service ──────────────────────────────────────────────
    (lib.mkIf cfg.daemon.enable {
      systemd.services.whisplay-daemon = {
        description = "Whisplay HAT daemon";
        wantedBy    = [ "multi-user.target" ];
        after       = [ "sound.target" "network.target" "local-fs.target" ];

        # Seed the state directory with default app configs on first run.
        preStart = ''
          install -d -m 750 -o ${cfg.daemon.user} ${cfg.stateDir}/app
          for f in ${whisplaySrc}/daemon/default_apps/*.json; do
            dest=${cfg.stateDir}/app/$(basename "$f")
            [ -e "$dest" ] || cp "$f" "$dest"
          done
          if [ ! -e ${cfg.stateDir}/settings.json ]; then
            echo '{"apps_dir":"${cfg.stateDir}/app"}' > ${cfg.stateDir}/settings.json
          fi
        '';

        serviceConfig = {
          Type                 = "simple";
          User                 = cfg.daemon.user;
          Group                = "audio";
          SupplementaryGroups  = "audio video gpio input";
          WorkingDirectory     = "${whisplaySrc}/daemon";
          ExecStart            = "${daemonPythonEnv}/bin/python3 ${whisplaySrc}/daemon/whisplay_daemon.py";
          Environment          = [
            "PYTHONUNBUFFERED=1"
            # runtime/ (whisplay.py, whisplay_client.py) must be on the path.
            "PYTHONPATH=${whisplaySrc}/runtime"
          ];
          # Hardware access requires real device nodes — no private /dev.
          PrivateDevices       = "no";
          Restart              = "always";
          RestartSec           = "2";
          StandardOutput       = "journal";
          StandardError        = "journal";
          SyslogIdentifier     = "whisplay-daemon";
        };
      };
    })

  ]);
}
