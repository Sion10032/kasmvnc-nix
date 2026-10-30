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

  # `NIX_PROFILES` only makes the input-method *modules* discoverable; an
  # application still has to bridge to them. GTK and Qt do that by themselves
  # (GTK picks the best locale match from the immodules cache, see
  # `_gtk_im_module_get_default_context_id`), but Chromium/Electron (WeChat, VS
  # Code, ...) and plain Qt applications only enable their IME bridge when
  # `GTK_IM_MODULE` / `QT_IM_MODULE` is set, and XIM clients need
  # `XMODIFIERS`. A login session gets these from `environment.variables` (that
  # is where `i18n.inputMethod` writes them).
  #
  # `NIX_PROFILES` itself is *not* injected any more: the session wrapper sources
  # `/etc/profile`, which exports it with `$HOME`/`$USER` expanded by a shell (see
  # `sessionWrapper`). These three are the exception, because `pam_env` writes
  # them with `DEFAULT=` semantics for a login session only when
  # `environment.variables` defines them, and `waylandFrontend = true` makes
  # `i18n.inputMethod` leave them out. They are set on the unit, and `pam_env`'s
  # `DEFAULT=` never overwrites an already set variable, so the inherited value
  # is simply confirmed and the fcitx5 fallback survives.
  #
  # Inheritance first: whatever the system defines for a login session is used
  # verbatim, so the two environments agree. When the system asks for fcitx5 but
  # does not define the variables - `i18n.inputMethod.fcitx5.waylandFrontend =
  # true` makes `i18n.inputMethod` skip `GTK_IM_MODULE`/`QT_IM_MODULE` - the
  # fcitx5 values are defaulted, otherwise those applications would lose their
  # IME bridge. Any other framework (ibus, ...) is left to the system: the module
  # never picks an input method on its own.
  sessionInputMethodEnvironment =
    let
      # `environment.variables` is already normalised to strings by the option's
      # `apply` (lists joined with `:`, `null` entries dropped), so a missing
      # entry means "the login session has no such variable".
      systemVariable = name: config.environment.variables.${name} or null;

      fcitx5 =
        (config.i18n.inputMethod.enable or false) && (config.i18n.inputMethod.type or null) == "fcitx5";

      fcitx5Defaults = {
        GTK_IM_MODULE = "fcitx";
        QT_IM_MODULE = "fcitx";
        XMODIFIERS = "@im=fcitx";
      };

      value =
        name:
        if systemVariable name != null then
          systemVariable name
        else if fcitx5 then
          fcitx5Defaults.${name}
        else
          null;

      inject = name: lib.mkDefault (value name);
    in
    lib.genAttrs (builtins.filter (name: value name != null) [
      "GTK_IM_MODULE"
      "QT_IM_MODULE"
      "XMODIFIERS"
    ]) inject;

  # The X server unit runs no user session (the desktop lives in
  # `kasmvnc-session.service`, which gets its environment from the PAM session),
  # so `HOME` - `~/.vnc` for `preStart` and `vncserver` - is all it needs.
  sessionEnvironment = {
    HOME = userHome;
  };

  # The desktop session's own `PATH` entries, prepended by `sessionWrapper` to
  # the login `PATH`: the user profiles (they are part of the login `PATH`
  # already, but not in front of the system profile) and the module's own
  # package (`kasmvncpasswd`, ...).
  wrapperPath = [
    "${userHome}/.nix-profile/bin"
    "/etc/profiles/per-user/${cfg.user}/bin"
    "${cfg.package}/bin"
  ];

  # `kasmvnc.service` needs the module's own packages (`vncserver`,
  # `kasmvncpasswd`, `openssl`) and is the `PATH` that `Xvnc` exports to the X
  # session (`~/.vnc/xstartup`); the desktop session's `PATH` comes from the
  # login environment instead (see `wrapperPath` and `sessionWrapper`).
  #
  # Setting `path` on a unit *replaces* its whole PATH, it does not append to it,
  # hence the system profile is listed explicitly. Every entry gets `/bin`
  # appended, so the entry is the profile root and the resulting PATH element is
  # `/run/current-system/sw/bin`.
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
    "/etc/profiles/per-user/${cfg.user}"
    "${userHome}/.nix-profile"
  ];

  # `pam_systemd` does not just *tell* the processes about a session, it
  # registers them as one: it moves them out of the unit's cgroup into
  # `user.slice/user-<uid>.slice/session-<id>.scope`. That is what makes the
  # desktop a real user session (`$XDG_RUNTIME_DIR`, user manager, user bus), but
  # it also means the unit's own `KillMode=` cannot reach them. A session whose
  # leader process exited while other clients are still running is left
  # `active (abandoned)` by logind - the old desktop (panel, window manager,
  # settings daemon, ...) keeps running, and `Restart=always` would stack a second
  # desktop on top of it. Terminating the session is what a display manager does
  # on logout, so this unit does the same when it stops - which includes the stop
  # that precedes a restart.
  sessionCleanup = pkgs.writeShellScript "kasmvnc-session-cleanup" ''
    # Runs as root (`ExecStopPost=+...`): killing another user's session goes
    # through polkit otherwise.
    loginctl=/run/current-system/systemd/bin/loginctl

    "$loginctl" list-sessions --no-legend 2>/dev/null |
      while read -r session _uid user _rest; do
        [ "$user" = ${lib.escapeShellArg cfg.user} ] || continue
        # `PAMName=` applies to *every* command of the unit, so this script itself
        # runs in a session of `kasmvnc-session`; never kill that one.
        [ "$session" = "''${XDG_SESSION_ID:-}" ] && continue
        [ "$("$loginctl" show-session "$session" -p Service --value 2>/dev/null)" = "kasmvnc-session" ] || continue
        # The desktop's processes live in the session's scope instead of the
        # unit's cgroup, and logind leaves a session whose leader exited
        # `active (abandoned)` instead of terminating it - `terminate-session`
        # alone is a no-op on such a session, killing it is not.
        "$loginctl" kill-session "$session" || true
        ${pkgs.coreutils}/bin/sleep 0.5
        "$loginctl" kill-session "$session" --signal=SIGKILL || true
        "$loginctl" terminate-session "$session" || true
      done
  '';

  # The desktop session is started the way a graphical login starts one - in two
  # layers, instead of reproducing the login environment declaratively:
  #
  # 1. `PAMName=` (on `kasmvnc-session.service`) opens a PAM session with
  #    `/etc/pam.d/kasmvnc-session`, which has the same generic stack
  #    `xrdp-sesman` or `systemd --user` get: `pam_env` (layer 1 - `PATH` with
  #    `/run/wrappers/bin`, `XDG_*`, `GTK_PATH`, `LOCALE_ARCHIVE`, ... from
  #    `/etc/pam/environment`) and `pam_systemd` (a logind session, i.e.
  #    `$XDG_RUNTIME_DIR`, the user manager and the user bus).
  # 2. This wrapper sources `/etc/profile` (layer 2 - `NIX_PROFILES` and every
  #    `environment.variables` entry, with `$HOME`/`$USER` expanded by a *real*
  #    shell), prepends the paths the module needs, aligns the user manager and
  #    the D-Bus activation environment with the session, and execs the desktop.
  #    That is what nixpkgs' `xsession-wrapper`
  #    (`nixos/modules/services/x11/display-managers/default.nix`) does for a
  #    display manager session.
  sessionWrapper = pkgs.writeShellScript "kasmvnc-session-wrapper" ''
    # Layer 2: the login shell environment. `/etc/profile` is *sourced*, exactly
    # like a login shell does it, so its `return` ("only execute once") is fine.
    # This *replaces* the `PATH` that `pam_env` provided.
    . /etc/profile

    # Prepend what the module guarantees: the user profiles (they are part of the
    # login `PATH`, but this keeps them in front of the system profile) and the
    # module's own package.
    export PATH=${lib.escapeShellArg (lib.concatStringsSep ":" wrapperPath)}:"$PATH"

    # A `SESSION_MANAGER` inherited from another session would make the desktop's
    # clients join the wrong X session manager (`~/.vnc/xstartup` used to unset
    # it).
    unset SESSION_MANAGER

    # `pam_systemd` starts `user@<uid>.service` asynchronously, so the user bus
    # socket can appear a moment after the session does. Wait for it (30s), but
    # never fail the session over it: without a bus the desktop still has to come
    # up.
    bus=""
    if [ -n "''${XDG_RUNTIME_DIR:-}" ]; then
      bus="$XDG_RUNTIME_DIR/bus"
      tries=0
      while [ ! -S "$bus" ] && [ "$tries" -lt 150 ]; do
        ${pkgs.coreutils}/bin/sleep 0.2
        tries=$((tries + 1))
      done
    fi

    if [ -n "$bus" ] && [ -S "$bus" ]; then
      # The user bus of this PAM session: what the desktop of a login session
      # talks to as well.
      export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus"

      # Make the user manager and the D-Bus activation environment agree with the
      # session about the display and its `PATH` (`xsession-wrapper` does the
      # same). The variable list is the default of
      # `services.xserver.displayManager.importedVariables`
      # (`nixos/modules/services/x11/display-managers/default.nix`), plus `PATH`
      # so that user units start with the login `PATH`.
      /run/current-system/systemd/bin/systemctl --user import-environment \
        DBUS_SESSION_BUS_ADDRESS DISPLAY PATH XAUTHORITY XDG_SESSION_ID || true
      ${lib.getBin pkgs.dbus}/bin/dbus-update-activation-environment --systemd --all || true
    else
      echo "kasmvnc-session: no user D-Bus session bus (XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR:-}), starting the desktop without one" >&2
    fi

    # Resolve the desktop command through the login `PATH`, so a bare name
    # behaves like in a login shell (`windowManager` is split on whitespace, so
    # only the first word is looked up).
    command_name="$1"
    shift
    if ! command_path="$(command -v "$command_name")"; then
      echo "kasmvnc-session: cannot find '$command_name' in PATH=$PATH" >&2
      exit 127
    fi
    exec "$command_path" "$@"
  '';

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
      example = "xfce4-session";
      description = ''
        Command the desktop session runs, e.g.
        `"''${pkgs.icewm}/bin/icewm-session"`.

        The session is supervised: if the window manager exits (a crash, or the
        user logging out of the desktop) systemd starts it again, so the desktop
        comes back on its own while the X server keeps running - the same
        behaviour as the watchdog loop of the reference container image. It is
        stopped together with `kasmvnc.service`, so
        `systemctl stop kasmvnc` is the way to shut the session down for good.

        The command line is split on whitespace and its words are handed to the
        session wrapper, so shell syntax (pipes, redirections, `&&`, `exec`) does
        not work. Use a wrapper script if you need that.

        The session is started like a **login session** (see the README): it runs
        in a PAM session (`pam_env` + `pam_systemd`, i.e. logind session,
        `$XDG_RUNTIME_DIR` and the user D-Bus bus are there before the desktop
        starts) and the wrapper sources `/etc/profile` first. A bare command name
        therefore resolves through the login `PATH`, exactly as in a login shell:
        the user profiles, `/run/current-system/sw/bin` (i.e. programs installed
        through the system profile such as
        `services.xserver.desktopManager.xfce` or
        `environment.systemPackages`) and the module's own package. Everything
        else needs an absolute store path such as
        `"''${pkgs.icewm}/bin/icewm-session"`.

        Desktop environments (and window managers that use a session bus) get the
        user's D-Bus session bus from the PAM session, so `dbus-run-session` is no
        longer needed (it still works and simply starts another bus). They also
        get the XDG session environment (`XDG_DATA_DIRS`, `XDG_CONFIG_DIRS`, ...)
        from the login environment, which is what their D-Bus activation files and
        default configuration are found through.

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

    # The PAM service the desktop session is started with (`PAMName=`). An empty
    # definition gets the generic NixOS stack - the same one
    # `/etc/pam.d/xrdp-sesman` and `/etc/pam.d/systemd-user` build on - i.e.
    # `pam_env` (session variables from `/etc/pam/environment`), `pam_unix`,
    # `pam_limits`, `pam_loginuid` and `pam_systemd`. `startSession` is what
    # pulls in `pam_systemd` (`systemd` special-cases it to provide
    # `$XDG_RUNTIME_DIR` and to register the logind session; both `xrdp-sesman`
    # and `systemd-user` set it), so this is not literally an empty attrset.
    security.pam.services.kasmvnc-session = {
      startSession = true;
    };

    networking.firewall.allowedTCPPorts =
      optional cfg.openFirewall cfg.websocketPort ++ optional cfg.openFirewall vncPort;

    systemd.services.kasmvnc = {
      description = "KasmVNC remote desktop server (${cfg.display})";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      # See `sessionEnvironment`: `HOME` for the user's `~/.vnc`. The desktop
      # session gets the rest of its environment from a PAM session; the X
      # server itself needs none of it.
      environment = sessionEnvironment;

      # The X server itself only needs the module's own packages, but the X
      # session inherits this PATH (Xvnc exports it to `~/.vnc/xstartup`): see
      # `sessionPath`.
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

      # A PAM session, exactly like a graphical login: `pam_env` provides the
      # system-wide session variables and `pam_systemd` registers the logind
      # session (which creates `$XDG_RUNTIME_DIR` and starts the user manager
      # with the user bus). systemd only calls `pam_open_session` here - it never
      # authenticates the service (that is how `user@.service` uses `PAMName=`
      # too), so the `auth` rules of the stack are not exercised; `User=` is what
      # `PAMName=` requires.
      #
      # `environment` below is not dropped by that: systemd merges the PAM
      # environment in, and `pam_env`'s `DEFAULT=` entries do not override
      # variables that are already set.

      environment =
        sessionEnvironment
        // {
          # `vncserver` sets this for the X session; this unit has to be told
          # explicitly which display to connect to.
          DISPLAY = cfg.display;
        }
        # `GTK_IM_MODULE`, `QT_IM_MODULE`, `XMODIFIERS`; see
        # `sessionInputMethodEnvironment`.
        // sessionInputMethodEnvironment;

      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        # See above: the PAM session is what provides the login environment.
        PAMName = "kasmvnc-session";
        WorkingDirectory = userHome;
        # `kasmvnc.service` is `Type=forking`: being ordered after it does not
        # mean Xvnc is listening yet. Wait for the X socket, so the window
        # manager cannot race the server.
        ExecStartPre = "${waitForDisplay}";
        # The login-style wrapper (see `sessionWrapper`): it sources
        # `/etc/profile`, aligns the user manager / session bus and execs the
        # `windowManager` command line, whose words are passed as arguments.
        # A bare command name is resolved through the *login* `PATH` there, so
        # no `ExecSearchPath=` is involved (and it could not be: systemd only
        # resolves the first word of an `ExecStart=`, which is the wrapper).
        ExecStart = lib.escapeShellArgs ([ "${sessionWrapper}" ] ++ lib.splitString " " cfg.windowManager);
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
        # `pam_systemd` moved the desktop's processes into the logind session
        # scope, so the unit's cgroup holds only the main process; `mixed` signals
        # exactly that one (`control-group` would signal nothing, the cgroup is
        # empty). The processes of the session are terminated by `ExecStopPost`,
        # see `sessionCleanup`.
        KillMode = "mixed";
        # Runs as root (the `+`), see `sessionCleanup`: this is what keeps a
        # restart from stacking a second desktop on the leftovers of the old
        # logind session.
        ExecStopPost = "+${sessionCleanup}";
        TimeoutStopSec = 30;
      }
      // lib.optionalAttrs (userGroup != "") {
        Group = userGroup;
      };
    };
  };
}
