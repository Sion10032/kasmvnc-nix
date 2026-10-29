{
  pkgs,
  kasmvncModule,
}:

let
  # Settings every test node needs: a bootable headless VM with enough
  # resources to run an X server plus a window manager.
  common =
    { ... }:
    {
      system.stateVersion = "25.11";

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        graphics = false;
      };

      documentation.enable = false;
      documentation.nixos.enable = false;
    };

  # A real desktop environment, installed through the system profile only (no
  # `services.xserver`, no display manager). XFCE is the environment the
  # reference container image ships, and it is the one whose session manager
  # exits when the user logs out - the case the session unit has to survive.
  #
  # `xfce4-session` plus the clients of its failsafe session (`xfwm4`,
  # `xfsettingsd`, `xfce4-panel`, ...) are needed for a complete desktop.
  xfceNode =
    { pkgs, ... }:
    {
      imports = [
        kasmvncModule
        common
      ];

      environment.systemPackages = with pkgs; [
        xfce4-session
        xfconf
        xfwm4
        xfdesktop
        xfce4-panel
        xfce4-settings
      ];

      services.kasmvnc = {
        enable = true;
        windowManager = "dbus-run-session xfce4-session";
      };
    };

  # Node for the input-method regression test: the XFCE desktop of `xfceNode`
  # plus a system-wide fcitx5 installation (`i18n.inputMethod`), which is what
  # puts fcitx5's GTK3 immodule and the generated `immodules.cache` into the
  # system profile. Rime is added as an engine to show that a real Chinese input
  # method is configured; nothing in the test depends on the engine itself.
  imeNode =
    { config, pkgs, ... }:
    {
      imports = [ xfceNode ];

      i18n.inputMethod = {
        enable = true;
        type = "fcitx5";
        fcitx5.addons = [ pkgs.fcitx5-rime ];
      };

      # `fcitx5-gtk3-immodule-probing` (shipped by `fcitx5-with-addons`, which
      # is what `i18n.inputMethod.package` resolves to) is the oracle of the
      # test below: it prints which GTK3 input-method module GTK resolves in the
      # current environment. Listing the package explicitly makes the binary
      # reachable as /run/current-system/sw/bin/fcitx5-gtk3-immodule-probing.
      environment.systemPackages = [ config.i18n.inputMethod.package ];
    };

  # Node for the launcher regression test: the XFCE desktop of `xfceNode` plus
  # PyGObject, so that the test can ask GLib itself whether it accepts a
  # `.desktop` file (`Gio.DesktopAppInfo`). The application the test installs is
  # not part of the system profile on purpose - it simulates a home-manager /
  # `nix profile install` application that only exists in the *user* profile.
  launcherNode =
    { pkgs, ... }:
    {
      imports = [ xfceNode ];

      environment.systemPackages = [
        (pkgs.python3.withPackages (ps: [ ps.pygobject3 ]))
      ];
    };

  # Typelibs the PyGObject probe needs: `Gio` comes from GLib itself, which also
  # ships the `GIRepository` typelib PyGObject loads first.
  giTypelibPath = pkgs.lib.makeSearchPath "lib/girepository-1.0" [ pkgs.glib ];

  # Asks GLib how it judges a `.desktop` file whose bare `Exec=` only exists in
  # the user profile: `GDesktopAppInfo` returns NULL there when the program is
  # not found in `PATH` (PyGObject raises `TypeError` instead of returning None).
  desktopAppInfoProbe = pkgs.writeText "kasmvnc-desktop-app-info-probe.py" ''
    import warnings

    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio

    warnings.simplefilter("ignore")
    try:
        info = Gio.DesktopAppInfo.new_from_filename(
            "/home/kasm-user/.local/share/applications/kasmvnc-test-app.desktop"
        )
    except TypeError:
        info = None
    print("DESKTOP_APP_INFO=" + (info.get_name() if info is not None else "NULL"))
  '';
in
{
  # Full scenario: declared password, declared window manager.
  kasmvnc = pkgs.testers.runNixOSTest {
    name = "kasmvnc";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          kasmvncModule
          common
        ];

        services.kasmvnc = {
          enable = true;
          passwordFile = pkgs.writeText "kasmvnc-password" "testpassword";
          windowManager = "${pkgs.icewm}/bin/icewm-session";
        };
      };

    testScript = ''
      start_all()

      machine.wait_for_unit("kasmvnc.service", timeout=300)
      machine.wait_for_open_port(6901)

      # Unauthenticated requests are rejected (KasmVNC closes the connection
      # right after the 401, so curl exits non-zero; only the code matters).
      machine.wait_until_succeeds(
          "(curl -sk -o /dev/null -w '%{http_code}' --max-time 30 https://localhost:6901/vnc.html "
          "|| true) | grep -q 401",
          timeout=120,
      )
      # ...authenticated ones get the web client.
      machine.succeed(
          "curl -skf --max-time 30 -u kasm_user:testpassword https://localhost:6901/vnc.html "
          "| grep -qi '<html'"
      )
      machine.succeed(
          "curl -skf --max-time 30 -u kasm_user:testpassword https://localhost:6901/ "
          "| grep -qi '<html'"
      )

      # The password was converted into the KasmVNC password file.
      machine.succeed("grep -q '^kasm_user:' /home/kasm-user/.kasmpasswd")

      # The self-signed certificate was generated on first start.
      machine.succeed("test -s /home/kasm-user/.vnc/self.pem")

      # The X server is up on the VNC port as well.
      machine.succeed("test -e /tmp/.X11-unix/X1")
      machine.succeed("pgrep -f 'Xvnc :1' >/dev/null")

      # Restarting must not trip over stale locks/PID files.
      machine.succeed("systemctl restart kasmvnc.service")
      machine.wait_for_unit("kasmvnc.service", timeout=300)
      machine.wait_for_open_port(6901)
      machine.succeed(
          "curl -skf --max-time 30 -u kasm_user:testpassword https://localhost:6901/vnc.html "
          "| grep -qi '<html'"
      )
    '';
  };

  # Default scenario: nothing but `enable`, no password file, no certificate.
  kasmvnc-no-password = pkgs.testers.runNixOSTest {
    name = "kasmvnc-no-password";

    nodes.machine =
      { ... }:
      {
        imports = [
          kasmvncModule
          common
        ];

        services.kasmvnc.enable = true;
      };

    testScript = ''
      start_all()

      machine.wait_for_unit("kasmvnc.service", timeout=300)
      machine.wait_for_open_port(6901)

      # No credentials configured: the web client is reachable without auth.
      machine.succeed(
          "curl -skf --max-time 30 https://localhost:6901/vnc.html | grep -qi '<html'"
      )
      machine.succeed(
          "curl -skf --max-time 30 https://localhost:6901/ | grep -qi '<html'"
      )

      # The self-signed certificate and a KasmVNC user record are still required
      # by the server, and are generated by the pre-start script.
      machine.succeed("test -s /home/kasm-user/.vnc/self.pem")
      machine.succeed("test -s /home/kasm-user/.kasmpasswd")
    '';
  };

  # A bare command name (no store path) has to resolve through the system
  # profile: the module's `systemd.services.kasmvnc.path` replaces the unit's
  # whole PATH, so /run/current-system/sw/bin has to be appended explicitly.
  kasmvnc-path-wm = pkgs.testers.runNixOSTest {
    name = "kasmvnc-path-wm";

    nodes.machine =
      { pkgs, ... }:
      let
        # Pseudo window manager that just keeps running. It is only installed
        # through `environment.systemPackages`, i.e. it is reachable as a bare
        # command name via /run/current-system/sw/bin and nowhere else.
        # No `exec`: exec'ing would replace this process image, so the bare
        # command name would vanish from the process table and `pgrep` could not
        # observe that resolution actually worked.
        testWm = pkgs.runCommand "kasmvnc-test-wm" { } ''
          install -d "$out/bin"
          printf '#!/bin/sh\nsleep infinity\n' > "$out/bin/kasmvnc-test-wm"
          chmod 755 "$out/bin/kasmvnc-test-wm"
        '';
      in
      {
        imports = [
          kasmvncModule
          common
        ];

        environment.systemPackages = [ testWm ];

        services.kasmvnc = {
          enable = true;
          windowManager = "kasmvnc-test-wm";
        };
      };

    testScript = ''
      start_all()

      machine.wait_for_unit("kasmvnc.service", timeout=300)

      # The generated xstartup execs the bare command name, so the name has to
      # be resolvable through the service's PATH and the window manager has to
      # be running afterwards. The bracket in the pattern keeps the test
      # driver's own `bash -c ...` wrapper (whose argv contains the pattern)
      # from matching itself.
      machine.wait_until_succeeds("pgrep -f '[k]asmvnc-test-wm'", timeout=120)
      machine.succeed("pgrep -af '[k]asmvnc-test-wm' | grep -q /run/current-system/sw/bin")
    '';
  };

  # Regression test for the XDG session environment. The service starts a
  # desktop *session* but gets none of the login session's environment, so
  # `XDG_DATA_DIRS` (D-Bus activation of `org.xfce.Xfconf.service` -> xfconfd)
  # and `XDG_CONFIG_DIRS` (default xfconf channels) have to be injected by the
  # module. Without them xfce4-session finds neither xfconfd's activation file
  # nor its failsafe session definition: it comes up with no clients at all, and
  # on some versions aborts with "unable to determine failsafe session name.
  # xfconfd isn't running. $XDG_CONFIG_DIRS is set incorrectly". A fake window
  # manager cannot observe any of this, hence a real desktop environment.
  # No `services.xserver`: no display manager, everything comes from the
  # system profile plus what the module injects.
  kasmvnc-xfce = pkgs.testers.runNixOSTest {
    name = "kasmvnc-xfce";

    nodes.machine = xfceNode;

    testScript = ''
      start_all()

      machine.wait_for_unit("kasmvnc.service", timeout=300)

      # The session manager has to stay alive. The brackets in the patterns keep
      # the test driver's own `bash -c ...` wrapper from matching itself.
      machine.wait_until_succeeds("pgrep -f '[x]fce4-session'", timeout=60)
      # ...and xfconfd has to have been D-Bus activated by it, which needs the
      # system profile's XDG data directories to be reachable.
      machine.wait_until_succeeds("pgrep -f '[x]fconfd'", timeout=60)

      # The failsafe session (window manager, panel, ...) is described by
      # xfce4-session's default xfconf channel, which lives in the package's
      # etc/xdg and is only found when XDG_CONFIG_DIRS points at the system
      # profile. Without it the session manager comes up with no clients at all
      # (an empty desktop) and, depending on the version, aborts with "unable
      # to determine failsafe session name".
      machine.wait_until_succeeds("pgrep -f '[x]fwm4'", timeout=120)
      machine.wait_until_succeeds("pgrep -f '[x]fce4-panel'", timeout=120)

      # The session also has to *see* the variables, not just benefit from them
      # indirectly. `-z` makes grep split the NUL-separated /proc environ, and
      # `^...$` anchors the pattern on the exec'ed command name so that neither
      # the driving `bash -c` wrapper nor the `dbus-run-session` parent matches.
      session_env = "/proc/$(pgrep -f '^xfce4-session$' | head -n1)/environ"
      machine.succeed(f"grep -zq '^XDG_DATA_DIRS=.*/run/current-system/sw/share$' {session_env}")
      machine.succeed(f"grep -zq '^XDG_CONFIG_DIRS=.*/run/current-system/sw/etc/xdg$' {session_env}")
    '';
  };

  # Regression test for input methods inside the desktop session. Two layers are
  # needed and both are missing from a system service's environment:
  #
  # 1. `NIX_PROFILES` makes the immodules *discoverable*. GTK's NixOS patch looks
  #    the immodules cache up as `<profile>/etc/gtk-3.0/immodules.cache` for every
  #    entry of `NIX_PROFILES`; without the variable GTK only finds
  #    `gtk-im-context-simple` and falls back to dumb, non-IME input, so fcitx5,
  #    ibus etc. are installed and configured but dead inside the session.
  # 2. `GTK_IM_MODULE` / `QT_IM_MODULE` (plus `XMODIFIERS`) make applications
  #    *use* the module. GTK and Qt select on their own, but Chromium/Electron
  #    (WeChat, VS Code, ...) and plain Qt applications only enable their IME
  #    bridge when the variable is set - so without it a discoverable module is
  #    still never loaded by them.
  #
  # The oracle is `fcitx5-gtk3-immodule-probing`: it asks GTK3 which IM module it
  # resolves and prints e.g. `GTK_IM_MODULE=fcitx5` (or
  # `GTK_IM_MODULE=gtk-im-context-simple` when no module is found), so it
  # observes the actual selection instead of guessing from process names. It is
  # started with nothing but the session's own `NIX_PROFILES` - no
  # `GTK_IM_MODULE`, no `GTK_PATH` - because GTK auto-selects the best module by
  # locale when the variable is unset.
  #
  # Two nodes: `machine` is the ordinary fcitx5 configuration, where
  # `i18n.inputMethod` defines the input-method variables itself and the module
  # has to inherit them; `wayland` sets `fcitx5.waylandFrontend = true`, which
  # makes `i18n.inputMethod` leave `GTK_IM_MODULE`/`QT_IM_MODULE` out of the login
  # environment (that is the configuration the bug was reported from), so the
  # module has to supply the fcitx5 values on its own.
  kasmvnc-ime = pkgs.testers.runNixOSTest {
    name = "kasmvnc-ime";

    nodes = {
      machine = imeNode;

      wayland =
        { ... }:
        {
          imports = [ imeNode ];

          i18n.inputMethod.fcitx5.waylandFrontend = true;
        };
    };

    testScript = ''
      def check_session(node, im_variables_from_login_environment):
          node.wait_for_unit("kasmvnc.service", timeout=300)
          node.wait_until_succeeds("pgrep -f '[x]fce4-session'", timeout=120)

          # `i18n.inputMethod` put fcitx5's GTK3 module and the immodules cache
          # into the system profile. The cache is the only place GTK3 can learn
          # about the module.
          node.succeed("test -s /run/current-system/sw/etc/gtk-3.0/immodules.cache")
          node.succeed(
              "grep -q 'im-fcitx5' /run/current-system/sw/etc/gtk-3.0/immodules.cache"
          )

          # Layer 1: the session has to *see* `NIX_PROFILES`. It is read out of
          # the session's own environment (`/proc` is NUL separated, hence `tr`);
          # deliberately lenient, so that a missing variable is reported by the
          # oracle below instead of failing on the variable itself.
          session_pid = node.succeed("pgrep -f '^xfce4-session$' | head -n1").strip()
          session_env = f"/proc/{session_pid}/environ"
          session_profiles = node.succeed(
              f"tr '\\000' '\\n' < {session_env} | sed -n 's/^NIX_PROFILES=//p'"
          ).strip()

          # The oracle: as the session user, on the session's display, with the
          # session's `NIX_PROFILES` and nothing else (`env -i`: no
          # `GTK_IM_MODULE`, no `GTK_PATH`, no `XMODIFIERS`), GTK3 has to resolve
          # the fcitx5 module. Without `NIX_PROFILES` it prints
          # `GTK_IM_MODULE=gtk-im-context-simple` and this assertion fails - that
          # is the first regression this test guards.
          probe = (
              "runuser -u kasm-user -- env -i HOME=/home/kasm-user DISPLAY=:1 "
              "XAUTHORITY=/home/kasm-user/.Xauthority"
          )
          out = node.succeed(
              f"{probe} NIX_PROFILES='{session_profiles}' "
              "/run/current-system/sw/bin/fcitx5-gtk3-immodule-probing"
          )
          assert "GTK_IM_MODULE=fcitx" in out, (
              f"GTK3 resolved no fcitx5 immodule in the session environment: {out!r}"
          )
          assert "gtk-im-context-simple" not in out, (
              f"GTK3 fell back to the dumb IM context: {out!r}"
          )

          # `NIX_PROFILES` has to be exactly the value a login shell exports, i.e.
          # the profile list of `/etc/set-environment` in the same order, with the
          # session user substituted.
          node.succeed(
              f"grep -zq '^NIX_PROFILES=.*/run/current-system/sw' {session_env}"
          )
          login_profiles = node.succeed(
              "su - kasm-user -c 'printf %s \"$NIX_PROFILES\"'"
          ).strip()
          assert session_profiles == login_profiles, (
              f"session NIX_PROFILES {session_profiles!r} != /etc/profile {login_profiles!r}"
          )

          # Layer 2: the variables Chromium/Electron/Qt need to enable their IME
          # bridge at all. Whenever the login environment defines
          # `GTK_IM_MODULE` the module has to inherit it, otherwise it has to
          # supply the fcitx5 value itself.
          defines_gtk_im_module = node.succeed(
              "grep -c '^export GTK_IM_MODULE=' /etc/set-environment || true"
          ).strip()
          assert (defines_gtk_im_module != "0") == im_variables_from_login_environment, (
              "/etc/set-environment defines GTK_IM_MODULE: expected "
              f"{im_variables_from_login_environment}, got {defines_gtk_im_module} matches"
          )
          for name, value in [
              ("GTK_IM_MODULE", "fcitx"),
              ("QT_IM_MODULE", "fcitx"),
              ("XMODIFIERS", "@im=fcitx"),
          ]:
              node.succeed(f"grep -zq '^{name}={value}$' {session_env}")

      start_all()

      check_session(machine, True)
      check_session(wayland, False)
    '';
  };

  # Regression test for the *session `PATH`*, i.e. for launcher entries.
  #
  # A login session's `PATH` is derived from `environment.profiles` and therefore
  # contains the *user* profiles (`/etc/profiles/per-user/<user>/bin`,
  # `~/.nix-profile/bin`, ...), which is where home-manager and
  # `nix profile install` put their packages. A system service gets none of
  # that. That matters beyond "a command cannot be found": GLib's
  # `GDesktopAppInfo` validates a `.desktop` file's `Exec[0]` *and* `TryExec` with
  # `g_find_program_for_path()` against `PATH` while loading the file and rejects
  # it (returns no GDesktopAppInfo at all) when the bare command name is not
  # found (`gio/gdesktopappinfo.c`, `g_desktop_app_info_load_keyfile`). Such an
  # application then disappears from every launcher - panel, whisker menu,
  # appfinder - while applications whose `Exec=` is an absolute store path keep
  # working, which is exactly the pattern that was reported.
  #
  # The oracle is GLib itself: a `.desktop` file with a bare `Exec=` whose binary
  # exists only in the per-user profile is loaded with
  # `Gio.DesktopAppInfo.new_from_filename()` in the session's own `PATH`, as the
  # session user, on the session's display. Without the user profiles in `PATH`
  # GLib returns NULL and the test fails.
  kasmvnc-launcher = pkgs.testers.runNixOSTest {
    name = "kasmvnc-launcher";

    nodes.machine = launcherNode;

    testScript = ''
      start_all()

      machine.wait_for_unit("kasmvnc.service", timeout=300)
      machine.wait_until_succeeds("pgrep -f '[x]fce4-session'", timeout=120)

      session_pid = machine.succeed("pgrep -f '^xfce4-session$' | head -n1").strip()
      session_env = f"/proc/{session_pid}/environ"

      # The session's `PATH` is read out of its own environment (`/proc` is NUL
      # separated, hence `tr`); deliberately lenient, so that a missing user
      # profile is reported by the oracle below instead of failing on the
      # extraction itself.
      session_path = machine.succeed(
          f"tr '\\000' '\\n' < {session_env} | sed -n 's/^PATH=//p'"
      ).strip()

      # A home-manager style application: the program exists only in the user
      # profile, its `.desktop` file names it with a bare `Exec=`.
      machine.succeed(
          "install -D -m 0755 /run/current-system/sw/bin/true "
          "/etc/profiles/per-user/kasm-user/bin/kasmvnc-test-app"
      )
      machine.succeed(
          "mkdir -p /home/kasm-user/.local/share/applications && "
          "printf '[Desktop Entry]\\nType=Application\\nName=KasmVNC Test App\\n"
          "Exec=kasmvnc-test-app\\n' "
          "> /home/kasm-user/.local/share/applications/kasmvnc-test-app.desktop && "
          "chown -R kasm-user /home/kasm-user/.local"
      )

      # GLib's own verdict, in the session's own `PATH` (`env -i` keeps anything
      # from the test driver's environment out of it). Without the user profiles
      # in `PATH` GLib returns NULL here and this assertion fails.
      probe = (
          "runuser -u kasm-user -- env -i HOME=/home/kasm-user DISPLAY=:1 "
          "XAUTHORITY=/home/kasm-user/.Xauthority "
          "GI_TYPELIB_PATH=${giTypelibPath} "
          f"PATH='{session_path}'"
      )
      out = machine.succeed(
          f"{probe} python3 ${desktopAppInfoProbe}"
      )
      assert "DESKTOP_APP_INFO=KasmVNC Test App" in out, (
          f"GLib rejected the launcher entry (GDesktopAppInfo is NULL): {out!r}"
      )

      # ...and the reason is visible in the session's `PATH` itself: it has to
      # contain the user profiles, like a login session's `PATH` does.
      for profile in ["/etc/profiles/per-user/kasm-user", "/home/kasm-user/.nix-profile"]:
          assert f"{profile}/bin" in session_path.split(":"), (
              f"session PATH lacks {profile}/bin: {session_path}"
          )
    '';
  };

  # Regression test for the *lifecycle* of the desktop session.
  #
  # The window manager used to be exec'ed from `~/.vnc/xstartup`, i.e. it was a
  # child of the X session started by `vncserver`. When it exited - XFCE's "log
  # out" makes `xfce4-session` terminate every client and exit, a crashing
  # window manager does the same - nothing brought it back: Xvnc keeps running
  # (`auto_shutdown` is `never` by default), so the web client showed an empty
  # black desktop until someone ran `systemctl restart kasmvnc`.
  #
  # The session now lives in its own unit (`kasmvnc-session.service`) that runs
  # the window manager as its main process, restarts it when it dies and is
  # bound to the server unit in both directions (start/stop/restart).
  kasmvnc-session-restart = pkgs.testers.runNixOSTest {
    name = "kasmvnc-session-restart";

    nodes.machine = xfceNode;

    testScript = ''
      start_all()

      machine.wait_for_unit("kasmvnc.service", timeout=300)
      machine.wait_for_unit("kasmvnc-session.service", timeout=300)
      machine.wait_until_succeeds("pgrep -f '[x]fce4-session'", timeout=120)
      machine.wait_until_succeeds("pgrep -f '[x]fce4-panel'", timeout=120)

      # The session is not a child of the X server any more: it is a unit of its
      # own, and that unit's main process is the window manager / session
      # manager (`dbus-run-session` forks it and waits for it).
      machine.succeed("systemctl is-active kasmvnc-session.service")
      session_main = int(
          machine.succeed("systemctl show -p MainPID --value kasmvnc-session.service")
      )
      machine.succeed(
          f"[ \"$(ps -o ppid= -p {session_main} | tr -d ' ')\" = 1 ]"
      )

      # ...while Xvnc stays in the server unit's cgroup and the desktop
      # processes are in the session unit's cgroup.
      machine.succeed("grep -q '/kasmvnc.service' /proc/$(pgrep -f 'Xvnc :1' | head -n1)/cgroup")
      machine.succeed(
          "grep -q 'kasmvnc-session.service' "
          "/proc/$(pgrep -f '^xfce4-session$' | head -n1)/cgroup"
      )

      # Lifecycle supervision, clean exit: SIGTERM is what a plain `pkill`
      # sends, and `xfce4-session` handles it by ending the session and exiting
      # *successfully* - which is exactly what "log out" does (exit code 0).
      # `Restart=on-failure` would leave the desktop dead here, so this is the
      # assertion that covers the reported log-out case.
      machine.succeed("pkill -TERM -f '[x]fce4-session'")
      machine.wait_until_fails("pgrep -f '[x]fce4-session'", timeout=60)
      machine.wait_until_succeeds("pgrep -f '[x]fce4-session'", timeout=60)
      # The restarted session is complete again, i.e. the X server was never
      # torn down and the desktop is usable without a manual restart.
      machine.wait_until_succeeds("pgrep -f '[x]fce4-panel'", timeout=120)
      machine.succeed("pgrep -f 'Xvnc :1' >/dev/null")
      machine.succeed("systemctl is-active kasmvnc-session.service")

      # Lifecycle supervision, crash: an uncleanly dying window manager has to
      # be restarted as well.
      machine.succeed("pkill -KILL -f '[x]fce4-session'")
      machine.wait_until_fails("pgrep -f '[x]fce4-session'", timeout=60)
      machine.wait_until_succeeds("pgrep -f '[x]fce4-session'", timeout=60)
      machine.wait_until_succeeds("pgrep -f '[x]fce4-panel'", timeout=120)
      machine.succeed("systemctl is-active kasmvnc-session.service")

      # Restarting the server unit has to carry the session along (PartOf), and
      # the session must wait for the new X socket instead of crashing on a
      # display that is not there yet.
      machine.succeed("systemctl restart kasmvnc.service")
      machine.wait_for_unit("kasmvnc.service", timeout=300)
      machine.wait_for_unit("kasmvnc-session.service", timeout=300)
      machine.wait_until_succeeds("pgrep -f '[x]fce4-session'", timeout=120)
      machine.wait_until_succeeds("pgrep -f '[x]fwm4'", timeout=120)

      # Stopping the server must stop everything: the session first (ordering),
      # then Xvnc. A supervised session must not survive its server, and it must
      # not be pulled back up by Restart= either.
      machine.succeed("systemctl stop kasmvnc.service")
      machine.fail("systemctl is-active kasmvnc-session.service")
      machine.fail("systemctl is-active kasmvnc.service")
      machine.fail("pgrep -f '[x]fce4-session'")
      machine.fail("pgrep -f 'Xvnc :1'")
      machine.fail("test -e /tmp/.X11-unix/X1")
      # Nothing comes back on its own after the stop.
      machine.sleep(10)
      machine.fail("systemctl is-active kasmvnc-session.service")
      machine.fail("pgrep -f '[x]fce4-session'")
    '';
  };
}
