{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.kasmvnc;
  inherit (lib)
    mkIf
    mkOption
    mkEnableOption
    optionalString
    optional
    types
    ;

  displayNumber = lib.removePrefix ":" cfg.display;
  vncPort = 5900 + lib.toInt displayNumber;

  userHome = config.users.users.${cfg.user}.home;
  userGroup = config.users.users.${cfg.user}.group;

  # Certificate paths: either declared by the user, or the self-signed
  # certificate that the pre-start script generates inside the user's ~/.vnc.
  selfSignedPem = "${userHome}/.vnc/self.pem";
  certPath = if cfg.ssl.certFile != null then toString cfg.ssl.certFile else selfSignedPem;
  keyPath = if cfg.ssl.keyFile != null then toString cfg.ssl.keyFile else selfSignedPem;

  resolution = lib.splitString "x" cfg.resolution;
  resolutionWidth = lib.toInt (lib.elemAt resolution 0);
  resolutionHeight = lib.toInt (lib.elemAt resolution 1);

  # Basic auth is only meaningful with a password file; without one the
  # password is generated at random and web authentication is switched off
  # (KasmVNC still refuses to start without at least one user entry).
  basicAuthDisabled = cfg.passwordFile == null;

  preStart = pkgs.writeShellScript "kasmvnc-pre-start" ''
    set -eu
    export PATH=${
      lib.makeBinPath [
        cfg.package
        pkgs.openssl
        pkgs.coreutils
        pkgs.bash
      ]
    }:$PATH

    mkdir -p "$HOME/.vnc"

    # Stale locks and PID files left behind by an unclean shutdown make the
    # next start fail; only this display's files are touched.
    rm -f "/tmp/.X${displayNumber}-lock"
    rm -f "/tmp/.X11-unix/X${displayNumber}"
    rm -f "$HOME/.vnc/"*.pid

    ${optionalString (cfg.ssl.certFile == null) ''
      if [ ! -s "$HOME/.vnc/self.pem" ]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
          -keyout "$HOME/.vnc/self.pem" -out "$HOME/.vnc/self.pem" \
          -subj "/C=US/ST=VA/L=None/O=None/OU=DoFu/CN=kasm/emailAddress=none@none.none"
        chmod 600 "$HOME/.vnc/self.pem"
      fi
    ''}

    ${optionalString (cfg.passwordFile != null) ''
      password="$(cat ${cfg.passwordFile})"
      printf '%s\n%s\n' "$password" "$password" |
        kasmvncpasswd -u ${lib.escapeShellArg cfg.vncUsername} -w -o
    ''}
    ${optionalString (cfg.passwordFile == null) ''
      if [ ! -s "$HOME/.kasmpasswd" ]; then
        password="$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
        printf '%s\n%s\n' "$password" "$password" |
          kasmvncpasswd -u ${lib.escapeShellArg cfg.vncUsername} -w -o
      fi
    ''}
    chmod 600 "$HOME/.kasmpasswd"

    cat > "$HOME/.vnc/xstartup" <<'XSTARTUP'
    #!/bin/sh
    unset SESSION_MANAGER
    unset DBUS_SESSION_BUS_ADDRESS
    ${optionalString (cfg.windowManager != null) "exec ${cfg.windowManager}"}
    ${optionalString (cfg.windowManager == null) ''
      # services.kasmvnc.windowManager is unset: keep the X session alive with
      # an xterm if one is available, otherwise just idle.
      if command -v xterm >/dev/null 2>&1; then
        exec xterm
      fi
      exec sleep infinity
    ''}
    XSTARTUP
    chmod 755 "$HOME/.vnc/xstartup"
  '';

  kasmvncYaml = ''
    network:
      ssl:
        pem_certificate: ${certPath}
        pem_key: ${keyPath}
    runtime_configuration:
      allow_override_standard_vnc_server_settings: true
      allow_override_list:
        - pointer.enabled
    server:
      allow_environment_variables_to_override_config_settings: true
    command_line:
      prompt: false
    desktop:
      resolution:
        width: ${toString resolutionWidth}
        height: ${toString resolutionHeight}
      pixel_depth: ${toString cfg.colorDepth}
    ${cfg.extraConfig}
  '';
in
{
  options.services.kasmvnc = {
    enable = mkEnableOption "the KasmVNC web-based remote desktop server";

    package = mkOption {
      type = types.package;
      default = pkgs.callPackage ../packages/kasmvnc { };
      defaultText = lib.literalExpression "kasmvnc built from this flake";
      description = "The KasmVNC package to use.";
    };

    user = mkOption {
      type = types.str;
      default = "kasm-user";
      description = ''
        User the VNC session (and the systemd service) runs as. If the user is
        not declared elsewhere, this module creates it with
        `isNormalUser = true`, i.e. home directory `/home/<name>`.
      '';
    };

    display = mkOption {
      type = types.strMatching "^:[1-9][0-9]*$";
      default = ":1";
      example = ":2";
      description = "X display to start, in `:N` notation.";
    };

    websocketPort = mkOption {
      type = types.port;
      default = 6901;
      description = "HTTPS/WebSocket port the web client is served on.";
    };

    resolution = mkOption {
      type = types.strMatching "[0-9]+x[0-9]+";
      default = "1280x720";
      example = "1920x1080";
      description = "Desktop resolution.";
    };

    colorDepth = mkOption {
      type = types.enum [
        16
        24
        32
      ];
      default = 24;
      description = "Desktop colour depth in bits per pixel.";
    };

    frameRate = mkOption {
      type = types.ints.positive;
      default = 24;
      description = "Maximum frame rate of the VNC stream.";
    };

    vncUsername = mkOption {
      type = types.str;
      default = "kasm_user";
      description = "User name used for web (HTTP basic) authentication.";
    };

    passwordFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/kasmvnc-password";
      description = ''
        File containing the cleartext password for {option}`vncUsername`. It is
        hashed into `~/.kasmpasswd` on every start.

        When `null`, a random password is generated once and web authentication
        is disabled (`-DisableBasicAuth`): anyone who can reach
        {option}`websocketPort` gets a desktop, which is only appropriate behind
        an authenticating reverse proxy.
      '';
    };

    windowManager = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = lib.literalExpression ''"''${pkgs.icewm}/bin/icewm-session"'';
      description = ''
        Command executed by the generated `~/.vnc/xstartup`, e.g.
        `"''${pkgs.icewm}/bin/icewm-session"`. When `null`, the session runs an
        `xterm` if one is available and otherwise just idles.
      '';
    };

    interface = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Address the VNC server listens on.";
    };

    ssl = {
      certFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Certificate (PEM) used for HTTPS. If `null`, a self-signed
          certificate is generated at `~/.vnc/self.pem`. Must be set together
          with {option}`ssl.keyFile`.
        '';
      };

      keyFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Private key (PEM) used for HTTPS. Must be set together with
          {option}`ssl.certFile`.
        '';
      };
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open {option}`websocketPort` and the VNC port (`5900 + N`) in the
        firewall.
      '';
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      example = ''
        network:
          udp:
            public_ip: 127.0.0.1
      '';
      description = ''
        Extra YAML merged into the end of `/etc/kasmvnc/kasmvnc.yaml`. See
        `kasmvnc_defaults.yaml` in the package for the available settings.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = (cfg.ssl.certFile == null) == (cfg.ssl.keyFile == null);
        message = "services.kasmvnc: ssl.certFile and ssl.keyFile must be set together.";
      }
    ];

    # Make `services.kasmvnc.enable = true` self-sufficient: declare the session
    # account as a regular user (home `/home/<name>`) unless the caller already
    # declares it. This is a default, so an explicit `users.users.<name>.*`
    # definition still wins; declaring the very same account with
    # `isSystemUser = true` is not supported (use another account name or
    # `services.kasmvnc.user`).
    users.users.${cfg.user} = lib.mkDefault {
      isNormalUser = true;
    };

    environment.etc."kasmvnc/kasmvnc.yaml".text = kasmvncYaml;

    networking.firewall.allowedTCPPorts = optional cfg.openFirewall cfg.websocketPort ++ optional cfg.openFirewall vncPort;

    systemd.services.kasmvnc = {
      description = "KasmVNC remote desktop server (${cfg.display})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment.HOME = userHome;

      path = [
        cfg.package
        pkgs.coreutils
        pkgs.bash
        pkgs.gnugrep
        pkgs.gnused
        pkgs.procps
        pkgs.xset
        pkgs.xrandr
        pkgs.xrdb
        pkgs.xterm
        pkgs.openssl
      ];

      serviceConfig = {
        Type = "forking";
        User = cfg.user;
        WorkingDirectory = userHome;
        ExecStartPre = "${preStart}";
        ExecStart = lib.escapeShellArgs (
          [
            "${cfg.package}/bin/vncserver"
            cfg.display
            "-depth"
            (toString cfg.colorDepth)
            "-geometry"
            cfg.resolution
            "-websocketPort"
            (toString cfg.websocketPort)
            "-httpd"
            "${cfg.package}/share/kasmvnc/www"
            "-sslOnly"
            "-FrameRate"
            (toString cfg.frameRate)
            "-interface"
            cfg.interface
          ]
          ++ optional basicAuthDisabled "-DisableBasicAuth"
        );
        ExecStop = "${cfg.package}/bin/vncserver -kill ${cfg.display}";
        # vncserver names its PID file after the host and the display:
        #   ~/.vnc/<hostname>:<N>.pid
        # `%h` would be root's home here, and `uname -n` is the configured
        # host name, so both parts are spelled out literally.
        PIDFile = "${userHome}/.vnc/${config.networking.hostName}${cfg.display}.pid";
        Restart = "on-failure";
        RestartSec = 5;
        # Xvnc is the long-lived process, but the session (window manager)
        # lives in the same cgroup; stop everything together.
        KillMode = "control-group";
        TimeoutStopSec = 30;
      }
      // lib.optionalAttrs (userGroup != "") {
        Group = userGroup;
      };
    };
  };
}
