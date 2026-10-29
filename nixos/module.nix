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

  # Unix socket Xvnc listens on; the session unit waits for it before handing
  # control to the window manager.
  displaySocket = "/tmp/.X11-unix/X${displayNumber}";

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

  # Rebuild a search-path-like session variable the same way NixOS does for a
  # login session (`/etc/set-environment`): the explicitly configured
  # `environment.sessionVariables.<name>` (a string or a list) followed by
  # `environment.profileRelativeSessionVariables.<name>` expanded over every
  # entry of `environment.profiles`. A system that customises its session
  # environment is thereby inherited instead of overridden; `fallback` is only
  # used when nothing at all is defined.
  #
  # `environment.profiles` mixes in PAM/shell-expandable entries such as
  # `$HOME/.nix-profile` or `${XDG_STATE_HOME}/nix/profile`. systemd does not
  # expand variables in `Environment=`, so `$HOME`/`$USER` are substituted for
  # the session user and entries using any other variable are dropped.
  sessionSearchPath =
    name: fallback:
    let
      expand =
        entry:
        let
          substituted =
            lib.replaceStrings [ "$HOME" "\${HOME}" "$USER" "\${USER}" ] [ userHome userHome cfg.user cfg.user ]
              entry;
        in
        lib.optional (!lib.hasInfix "$" substituted) substituted;

      entries = map toString (
        lib.toList (config.environment.sessionVariables.${name} or [ ])
        ++ lib.concatMap (
          profile:
          map (suffix: profile + suffix) (config.environment.profileRelativeSessionVariables.${name} or [ ])
        ) config.environment.profiles
      );
      value = lib.concatStringsSep ":" (lib.concatMap expand entries);
    in
    if value == "" then fallback else value;

  # Both units run parts of the same *user session*, so they share environment
  # and `PATH`. The session unit runs a *desktop session* (window manager,
  # desktop environment helpers), not just module-owned binaries, but as a system
  # service it starts without the environment a login session gets from
  # `/etc/set-environment`.
  #
  # Desktop environments rely on the XDG base directory variables:
  # `XDG_DATA_DIRS` is how the session bus finds D-Bus activation files
  # (`share/dbus-1/services/org.xfce.Xfconf.service` -> xfconfd) and
  # `XDG_CONFIG_DIRS` is where their default configuration lives
  # (`etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`). Without them an XFCE
  # session comes up with no window manager, or aborts with "unable to
  # determine failsafe session name. xfconfd isn't running."
  # The values are inherited from the system session environment and only
  # defaulted, so `systemd.services.<name>.environment.*` still wins.
  sessionEnvironment = {
    HOME = userHome;
    XDG_DATA_DIRS = lib.mkDefault (sessionSearchPath "XDG_DATA_DIRS" "/run/current-system/sw/share");
    XDG_CONFIG_DIRS = lib.mkDefault (
      sessionSearchPath "XDG_CONFIG_DIRS" "/etc/xdg:/run/current-system/sw/etc/xdg"
    );
  };

  # Setting `path` on a unit *replaces* its whole PATH, it does not append to it,
  # hence the system profile is listed explicitly, last, so the module's own
  # packages keep precedence. This is what makes a bare command name such as
  # `xfce4-session` (installed via `environment.systemPackages` / a desktop
  # module) resolvable. Every entry gets `/bin` appended, so the entry is the
  # profile root and the resulting PATH element is `/run/current-system/sw/bin`.
  # `dbus` provides `dbus-run-session` for desktop environments that need a
  # session bus.
  sessionPath = [
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
    pkgs.dbus
    "/run/current-system/sw"
  ];

  # `ExecSearchPath=` is how systemd resolves a *bare* `ExecStart=` command
  # name: the unit's `PATH` environment is only what the spawned processes see,
  # it is not consulted by systemd itself. Same directories as `sessionPath`.
  sessionSearchDirs = lib.concatStringsSep ":" (map (p: "${toString p}/bin") sessionPath);

  # `kasmvnc.service` is `Type=forking`, i.e. it is considered started as soon as
  # Xvnc has been forked, not when the server actually listens. The window
  # manager would then race the server and die with "cannot open display". Wait
  # (bounded) for the X socket before the session unit execs the WM.
  waitForDisplay = pkgs.writeShellScript "kasmvnc-wait-for-display" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}:$PATH

    timeout=60
    elapsed=0
    while [ ! -S ${displaySocket} ]; do
      if [ "$elapsed" -ge "$timeout" ]; then
        echo "timed out after ''${timeout}s waiting for ${displaySocket}" >&2
        exit 1
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
  '';

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
    # Xvnc runs this script for the X session; it has to return instead of
    # blocking so that the X server keeps running. The desktop itself is started
    # and supervised by kasmvnc-session.service (see services.kasmvnc.windowManager).
    # This mirrors the reference container image, which writes `exit 0` here and
    # runs the window manager from its own watchdog loop.
    exit 0
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
      example = "dbus-run-session xfce4-session";
      description = ''
        Command the desktop session runs, i.e. the `ExecStart=` of
        `kasmvnc-session.service`, e.g.
        `"''${pkgs.icewm}/bin/icewm-session"`.

        The session is supervised: if the window manager exits (a crash, or the
        user logging out of the desktop) systemd starts it again, so the desktop
        comes back on its own while the X server keeps running - the same
        behaviour as the watchdog loop of the reference container image. It is
        stopped together with `kasmvnc.service`, so
        `systemctl stop kasmvnc` is the way to shut the session down for good.

        This is a plain systemd `ExecStart=`, not a shell command line: it is
        split on whitespace, so shell syntax (pipes, redirections, `&&`, `exec`)
        does not work. Use a wrapper script if you need that.

        A bare command name is looked up in `ExecSearchPath=`, which the module
        fills with the same directories as the units' `PATH`: the packages this
        module needs plus `/run/current-system/sw/bin`. Setting `path` on a unit
        *replaces* its `PATH`, so the system profile is added explicitly; a bare
        name therefore only resolves for programs that are installed through the
        system profile (e.g.
        `services.xserver.desktopManager.xfce` or
        `environment.systemPackages`). Everything else needs an absolute store
        path such as `"''${pkgs.icewm}/bin/icewm-session"`.

        Desktop environments (and window managers that use a session bus) need
        a D-Bus session bus, so wrap them in `dbus-run-session` (`dbus` is on the
        units' `PATH`), e.g. `"dbus-run-session xfce4-session"`.

        They also need the XDG session environment to find their D-Bus
        activation files and default configuration; the module provides
        `XDG_DATA_DIRS` and `XDG_CONFIG_DIRS` for `kasmvnc-session.service` (and
        `kasmvnc.service`), inherited from the system's session variables and
        overridable through `systemd.services.kasmvnc-session.environment.*`.

        When `null`, there is no `kasmvnc-session.service` at all: Xvnc runs with
        an empty desktop that only a VNC client can use.
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

    networking.firewall.allowedTCPPorts =
      optional cfg.openFirewall cfg.websocketPort ++ optional cfg.openFirewall vncPort;

    systemd.services.kasmvnc = {
      description = "KasmVNC remote desktop server (${cfg.display})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # See `sessionEnvironment`: XDG base directories for the X session's
      # clients, HOME for the user's ~/.vnc.
      environment = sessionEnvironment;

      # The X server itself only needs the module's own packages, but the X
      # session inherits this PATH (Xvnc exports it to `~/.vnc/xstartup`), so it
      # is the same `PATH` the session unit gets: see `sessionPath`.
      path = sessionPath;

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
        # Xvnc is the long-lived process; the desktop lives in
        # `kasmvnc-session.service` now, which is stopped through `partOf`.
        # Stopping this unit therefore shuts the whole desktop down.
        KillMode = "control-group";
        TimeoutStopSec = 30;
      }
      // lib.optionalAttrs (userGroup != "") {
        Group = userGroup;
      };
    };

    # The desktop session used to be exec'ed from `~/.vnc/xstartup`, i.e. it was
    # a child of the X session. Killing it (a crash, or logging out of the
    # desktop) left Xvnc running - `auto_shutdown` is `never` by default - with
    # nothing to bring the window manager back, so the web client showed an empty
    # desktop until someone ran `systemctl restart kasmvnc`.
    #
    # It is its own unit now, which is the systemd equivalent of the reference
    # image's watchdog loop ("Window manager crashed, restarting").
    systemd.services.kasmvnc-session = lib.mkIf (cfg.windowManager != null) {
      description = "KasmVNC desktop session (${cfg.display})";
      wantedBy = [ "multi-user.target" ];

      # The session is a client of the X server: it is activated with it, never
      # started without it (`requires` + `after`) and follows stops and restarts
      # of it (`partOf`). Because of the `after` order, systemd stops this unit
      # *before* `kasmvnc.service`, so `ExecStop=vncserver -kill` runs on an X
      # server that no session client is talking to any more.
      requires = [ "kasmvnc.service" ];
      after = [ "kasmvnc.service" ];
      partOf = [ "kasmvnc.service" ];

      environment = sessionEnvironment // {
        # `vncserver` sets this for the X session; this unit has to be told
        # explicitly which display to connect to.
        DISPLAY = cfg.display;
      };

      path = sessionPath;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        WorkingDirectory = userHome;
        # `kasmvnc.service` is `Type=forking`: being ordered after it does not
        # mean Xvnc is listening yet. Wait for the X socket, so the window
        # manager cannot race the server.
        ExecStartPre = "${waitForDisplay}";
        # A plain systemd command line, resolved through `ExecSearchPath=`
        # (i.e. the same directories as the unit's `PATH`).
        ExecStart = cfg.windowManager;
        ExecSearchPath = sessionSearchDirs;
        # `~/.vnc/xstartup` used to unset these before exec'ing the window
        # manager; a stale bus address or session manager would make the desktop
        # clients talk to the wrong session.
        UnsetEnvironment = [
          "SESSION_MANAGER"
          "DBUS_SESSION_BUS_ADDRESS"
        ];
        # The session has to come back whenever it goes away, however it went
        # away: XFCE's "log out" makes `xfce4-session` terminate every client and
        # exit - successfully - and a crashing window manager may exit with any
        # status. That is why this is `always` and not `on-failure` (a clean
        # log-out exits 0 and would silently leave an empty desktop behind).
        # This is what the reference image's watchdog loop does with
        # "Window manager crashed, restarting", without the loop.
        # Deliberate stops are unaffected: systemd never restarts a unit after a
        # stop job, so `systemctl stop kasmvnc` / `systemctl stop
        # kasmvnc-session` shut the desktop down for good (see
        # `tests/kasmvnc.nix`).
        Restart = "always";
        RestartSec = 2;
        # The window manager forks the session's clients (panel, settings
        # daemon, ...); they all belong to this unit and must go away with it,
        # otherwise a restart would stack a second desktop on the leftovers.
        KillMode = "control-group";
        TimeoutStopSec = 30;
      }
      // lib.optionalAttrs (userGroup != "") {
        Group = userGroup;
      };
    };
  };
}
