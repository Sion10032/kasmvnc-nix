# kasmvnc-nix

从源码构建的 [KasmVNC](https://github.com/kasmtech/KasmVNC) Nix 包，以及一个
`services.kasmvnc` NixOS 模块（systemd 系统服务）。

## 动机

本仓库把一套基于 KasmVNC 的 Docker 桌面镜像（从 Kasm S3 拉取预编译 deb）在 Nix
生态中原生化：

1. **`kasmvnc` 包**：`Xvnc`、`vncserver`、`kasmvncpasswd` 等二进制与 Perl 脚本由
   源码构建，Web 前端（`www`）由 kasmtech/noVNC 源码构建（`buildNpmPackage`）。
   构建过程不依赖任何官方预编译制品（deb / tgz / S3）。
2. **`services.kasmvnc` 模块**：声明式 options + systemd 服务，替代镜像中
   `vnc_startup.sh` 的手工流程（自签证书、口令设置、`vncserver` 参数、WM 启动与
   守护、stale lock 清理）。

## 快速开始

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kasmvnc-nix.url = "github:<you>/kasmvnc-nix"; # 或 path:/path/to/kasmvnc-nix
  };

  outputs = { self, nixpkgs, kasmvnc-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit kasmvnc-nix; };
      modules = [
        ./configuration.nix
        # 或者直接 imports = [ kasmvnc-nix.nixosModules.default ];
        {
          services.kasmvnc = {
            enable = true;
            passwordFile = "/run/secrets/kasmvnc-password";
            windowManager = "${pkgs.icewm}/bin/icewm-session";
            openFirewall = true;
          };
        }
      ];
    };
  };
}
```

浏览器访问 `https://<host>:6901/`，用 `vncUsername`（默认 `kasm_user`）与
`passwordFile` 中的口令登录。默认使用自签证书，浏览器会提示证书不受信任。

完整示例见 [`examples/minimal.nix`](examples/minimal.nix)。

不想用模块时，也可以用 overlay 或直接取包：

```nix
# overlay
nixpkgs.overlays = [ inputs.kasmvnc-nix.overlays.default ];
environment.systemPackages = [ pkgs.kasmvnc ];

# 或者
nix build github:<you>/kasmvnc-nix#kasmvnc
```

## Options

| Option | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `enable` | bool | `false` | 启用 `kasmvnc.service` |
| `package` | package | 本 flake 构建的 kasmvnc | 使用的 KasmVNC 包 |
| `user` | str | `"kasm-user"` | 运行服务的用户；未声明时自动创建为普通用户 |
| `display` | `^:[1-9][0-9]*$` | `":1"` | X display |
| `websocketPort` | port | `6901` | HTTPS / WebSocket 端口 |
| `resolution` | `WxH` | `"1280x720"` | 桌面分辨率 |
| `colorDepth` | `16 \| 24 \| 32` | `24` | 色深 |
| `frameRate` | int > 0 | `24` | 最大帧率 |
| `vncUsername` | str | `"kasm_user"` | Web 登录用户名 |
| `passwordFile` | path \| null | `null` | 明文口令文件，preStart 用 `kasmvncpasswd` 转换 |
| `windowManager` | str \| null | `null` | 会话命令（交给登录语义 wrapper）；裸名按登录 `PATH` 解析 |
| `interface` | str | `"0.0.0.0"` | 监听地址 |
| `ssl.certFile` | path \| null | `null` | HTTPS 证书；`null` 时自动生成自签证书 |
| `ssl.keyFile` | path \| null | `null` | HTTPS 私钥；必须与 `certFile` 同时设置 |
| `openFirewall` | bool | `false` | 放行 `websocketPort` 与 `5900 + N` |
| `extraConfig` | lines | `""` | 追加到 `/etc/kasmvnc/kasmvnc.yaml` 的 YAML |

### `passwordFile = null` 的语义

KasmVNC 必须有至少一条用户记录才能启动，因此 `passwordFile = null` 时模块会生成一个
**随机口令**条目（写入 `~/.kasmpasswd`）并给服务加 `-DisableBasicAuth`：能访问
`websocketPort` 的人可以直接拿到桌面。请只在有鉴权反向代理（SSO / mTLS）时这样用，
否则请设置 `passwordFile`。

### 证书

不设置 `ssl.certFile` / `ssl.keyFile` 时，preStart 会生成合并式自签证书
`~/.vnc/self.pem`（`openssl req -x509 -nodes -days 3650 -newkey rsa:2048`，subject 与
原 Docker 镜像一致）。两者只设置一个是配置错误，模块会通过 assertion 拒绝。

### `windowManager`

`windowManager` 是 `kasmvnc-session.service` 运行的桌面命令：`kasmvnc.service` 只负责 X
服务器，桌面会话由独立单元运行并被守护（见下面的「会话生命周期」），而该单元运行在一个
**登录语义的会话**里（见下面的「会话环境」）。四点需要注意：

1. **按空白切分，裸名按登录 `PATH` 解析。** 命令不是 shell 命令行：按空白切分，不支持
   管道、重定向、`&&`、`exec` 等 shell 语法（需要时写包装脚本）。第一个词由 wrapper 在
   登录 `PATH` 里解析（`command -v`），与登录 shell 的行为一致：用户 profile、
   `/run/current-system/sw/bin`（即通过系统 profile 安装的程序，如
   `services.xserver.desktopManager.xfce` 或 `environment.systemPackages`）以及本模块
   自己的包都在其中。其余程序用 store 路径。
2. **D-Bus 会话总线由 PAM 会话提供。** `pam_systemd` 注册 logind 会话时会启动 user
   manager 和用户总线，wrapper 等它就绪并导出 `DBUS_SESSION_BUS_ADDRESS`，所以
   `dbus-run-session` 不再是必需的（保留也可以，只是再起一条会话总线）。**例外**：同一
   用户同时还跑着别的图形会话（xrdp、显示管理器）时，XFCE 这类单实例桌面环境会在共享
   的 user bus 上撞名，这时必须保留 `dbus-run-session` 前缀，见
   「多桌面并存与 D-Bus 单实例」。
3. **XDG 会话环境来自 `/etc/profile`。** 桌面环境依赖 `XDG_DATA_DIRS`（决定会话总线的
   D-Bus activation 能否找到 `share/dbus-1/services/*.service`，例如
   `org.xfce.Xfconf.service` → `xfconfd`）与 `XDG_CONFIG_DIRS`（默认配置位置，例如
   `etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`，`xfce4-session` 靠它得到 failsafe 会话
   定义）；wrapper 会 source `/etc/profile`，两者随之与登录会话完全一致，模块不再单独
   声明。
4. **`windowManager = null` 时没有会话服务。** Xvnc 会带着一个空桌面（占位的
   `~/.vnc/xstartup` 只 `exit 0`）运行，没有 `kasmvnc-session.service`。

```nix
# 1) 裸名（程序需在登录 PATH 中，如 services.xserver.desktopManager.xfce）
services.kasmvnc.windowManager = "xfce4-session";

# 2) store 路径：不依赖系统/用户 profile
services.kasmvnc.windowManager = "${pkgs.xfce.xfce4-session}/bin/xfce4-session";

# 3) 不需要会话总线的窗口管理器，store 路径即可
services.kasmvnc.windowManager = "${pkgs.icewm}/bin/icewm-session";
```

## 与 Docker 镜像用法的映射

| 镜像（`vnc_startup.sh`） | 本模块 |
|---|---|
| `VNC_PW` + `echo pw \| kasmvncpasswd -u $VNC_USER -wo` | `passwordFile` + `vncUsername` |
| `VNC_USER` | `vncUsername` |
| `VNC_RESOLUTION` | `resolution` |
| `VNC_COL_DEPTH` | `colorDepth` |
| `MAX_FRAME_RATE` | `frameRate` |
| `NO_VNC_PORT` | `websocketPort` |
| `-httpd ${KASM_VNC_PATH}/www` | 固定为包内的 `share/kasmvnc/www` |
| `openssl req -x509 ... self.pem` | preStart 自动生成（或 `ssl.certFile` / `ssl.keyFile`） |
| `rm -rf /tmp/.X*-lock /tmp/.X11-unix ~/.vnc/*.pid` | preStart 清理本 display 的 stale lock / pid |
| `echo "exit 0" > xstartup` | preStart 写入占位的 `~/.vnc/xstartup`（仅 `exit 0`） |
| `icewm-session &` + 看门狗循环 | `kasmvnc-session.service`（`Restart=always` + `RestartSec=2`） |
| `src/kasmvnc.yaml`（`/etc/kasmvnc/kasmvnc.yaml`） | 模块生成；额外内容用 `extraConfig` |
| `tail -f` + 进程守护循环 | systemd（`Restart=on-failure` / `Restart=always`、会话终止） |

## 会话生命周期

X 服务器与桌面会话是**两个单元**：

| 单元 | 职责 |
|---|---|
| `kasmvnc.service` | `vncserver` / `Xvnc`、TLS、Web 前端；生成的 `~/.vnc/xstartup` 只 `exit 0` |
| `kasmvnc-session.service`（仅 `windowManager != null` 时存在） | 运行并守护 `windowManager`（桌面会话） |

`kasmvnc-session.service` 的主进程就是窗口管理器 / 会话管理器，`Restart=always`，
`RestartSec=2`：

- **注销或崩溃后自动重启。** 在 XFCE 里注销会让 `xfce4-session` 终止全部会话程序并
  **以 0 退出**，窗口管理器崩溃则可能是任意退出码。两种情况 systemd 都会把会话拉回来
  （等效于镜像 `vnc_startup.sh` 里「Window manager crashed, restarting」的看门狗循环），
  而 Xvnc 不受影响、Web 端重新拿到可用桌面。注意这里必须是 `always` 而不是
  `on-failure`：注销是「成功退出」，`on-failure` 不会重启，桌面会停在黑屏。
- **彻底停止用 `systemctl stop kasmvnc`。** 会话单元带 `PartOf=kasmvnc.service`，主服务
  停止/重启时会话跟随；`After=kasmvnc.service` 保证停止时**先停会话、再 `vncserver -kill`**。
  显式 `stop` 不会触发 `Restart=`（systemd 对 stop job 从不自动重启），所以停完就真的停了。
- **会话启动前等 X socket。** 主服务是 `Type=forking`，`After=` 不代表 Xvnc 已经开始监听，
  所以会话单元的 `ExecStartPre` 会循环等 `/tmp/.X11-unix/X<N>`（最长 60s），避免窗口管理器
  把 X 服务器“拉死”在启动阶段。
- **`windowManager = null` 时没有会话单元。** Xvnc 只提供一个空桌面。
- **停止时终止 logind 会话。** `pam_systemd` 会把桌面进程**移出单元 cgroup**，放到
  `user.slice/user-<uid>.slice/session-<id>.scope`（这正是它们成为“真会话”的原因）。
  因此单元的 `KillMode=` 拉不到它们，而且 logind 对「leader 已退出但客户端还在」的会话
  只标为 `active (abandoned)`、不会主动清理——`Restart=always` 就会在旧桌面上再叠一个。
  所以会话单元的 `ExecStopPost`（**同样也是「先停再启」的路径**）会以 root 身份
  `loginctl kill-session`（必要时 SIGKILL）+ `terminate-session` 终止本服务的 logind
  会话；`KillMode=mixed` 只负责给主进程（窗口管理器）发 SIGTERM。

## 会话环境：登录语义

`kasmvnc-session.service` 不是「systemd 服务 + 手写环境变量」，而是按**登录会话**的方式
启动桌面。环境全部来自 NixOS 自己的机制，模块只做三件事：

| 层 | 机制 | 提供什么 |
|---|---|---|
| 1 · PAM | `PAMName=kasmvnc-session` + `security.pam.services.kasmvnc-session`（`startSession = true`）| `pam_env`：`/etc/pam/environment` 的 session 变量（`PATH` 含 `/run/wrappers/bin`、`XDG_*`、`GTK_PATH`、`LOCALE_ARCHIVE`、`LANG`…）；`pam_unix`；`pam_limits`；`pam_loginuid`；`pam_systemd`：logind 会话 → `$XDG_RUNTIME_DIR` / user manager / user bus |
| 2 · 登录 shell | wrapper 里 source `/etc/profile` | `/etc/set-environment` 的全量导出：`NIX_PROFILES`、全部 `environment.variables` / `environment.sessionVariables`、profile 派生的搜索路径（`PATH`/`GTK_PATH`/`XDG_DATA_DIRS`/`INFOPATH`…）；`$HOME`/`$USER` 由**真 shell** 展开 |
| 3 · 对齐 | wrapper 里 `systemctl --user import-environment` + `dbus-update-activation-environment --systemd --all` | 让 user manager 与 D-Bus activation 环境与会话一致（D-Bus 激活的服务、后启动的 user unit 拿到正确的 `DISPLAY`/`PATH`/`DBUS_SESSION_BUS_ADDRESS`）|

wrapper 额外做的三件事：

- **前置 `PATH`**：`~/.nix-profile/bin`、`/etc/profiles/per-user/<user>/bin`、本模块的包
  （登录 `PATH` 里本来就有用户 profile，这里只是保证它们在系统 profile 之前）。
- **等 user bus**：轮询 `$XDG_RUNTIME_DIR/bus`（0.2s × 150 = 30s，`pam_systemd` 拉起
  user manager 有竞态），就绪后导出
  `DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus`；超时只告警，会话照旧启动。
- **清 `SESSION_MANAGER`**（来自其它会话的 X session manager 会把桌面客户端拉到错误
  的会话上），然后 `exec` 桌面命令。

与 xrdp / 显示管理器的对照：

| 机制 | xrdp（`xrdp-sesman`）| 显示管理器（nixpkgs `xsession-wrapper`）| 本模块 |
|---|---|---|---|
| PAM 服务 | `xrdp-sesman`（`startSession = true`）| 各 DM 自己的服务（`gdm-launch-environment` 等）| `kasmvnc-session`（`startSession = true`）|
| logind 会话 / user bus | `pam_systemd` | `pam_systemd` | `pam_systemd` |
| 登录 shell 环境 | `startwm.sh` 里 `. /etc/profile` | wrapper 里 `. /etc/profile` | wrapper 里 `. /etc/profile` |
| D-Bus 激活环境 | `dbus-update-activation-environment` | `systemctl --user import-environment <importedVariables>` | 两者都做 |
| 会话总线 | `dbus-run-session` 或已有 user bus | 系统 user bus | 系统 user bus（PAM 会话提供）|
| 会话守护 | `sesman` + `xrdp-sesman` | DM 自己 | `kasmvnc-session.service`（`Restart=always`）|
| 会话清理 | `sesman` 注销时关闭 PAM 会话 | DM 注销时关闭 PAM 会话（+ kill） | `ExecStopPost` 里 `loginctl kill-session` + `terminate-session`（见「会话生命周期」）|

验证方式（在运行中的系统上）：

```bash
# 会话存在，且是 kasmvnc-session 的 PAM 服务
loginctl list-sessions
loginctl show-session <id> -p Service --value   # kasmvnc-session
loginctl show-session <id> -p Type --value      # unspecified（系统服务没有 tty/display）

# 会话进程的 environ 与登录 shell 逐字一致
pid=$(systemctl show -p MainPID --value kasmvnc-session)
tr '\0' '\n' < /proc/$pid/environ | grep -E '^(NIX_PROFILES|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR)='
su - <user> -c 'printenv NIX_PROFILES'
```

### 从旧配置迁移

旧版本（commit `41869e9` 及以前）用手写注入模拟登录环境。升级后下面这些应急配置可以
删掉——它们与新的登录会话值冲突时只会造成困惑：

| 删除 | 原因 |
|---|---|
| `environment.sessionVariables.NIX_PROFILES`（或 `environment.variables.NIX_PROFILES`）| `/etc/profile` 导出 |
| `systemd.services.kasmvnc-session.environment.NIX_PROFILES` / `.XDG_DATA_DIRS` / `.XDG_CONFIG_DIRS` | 同上 |
| `systemd.services.kasmvnc-session.path` 里的用户 profile（`/etc/profiles/per-user/<user>`、`~/.nix-profile`）| wrapper 前置追加 |
| `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS` 的手工设置 | 系统 `i18n.inputMethod` 已定义时由登录会话提供（`waylandFrontend = true` 时保留模块默认值）|
| `windowManager` 外层的 `dbus-run-session` | PAM 会话已提供 user bus（保留也仍然能工作；**同一用户还有别的图形会话时应保留**，见「多桌面并存与 D-Bus 单实例」）|

迁移后需要验证的四项：注销/重启后桌面回来、`loginctl list-sessions` 里有 `kasm-user`
会话、rime 能输入、launcher（panel / whisker menu）里 home-manager 安装的应用仍在。

## 多桌面并存与 D-Bus 单实例

上一节的登录语义把会话挂到了**用户的** D-Bus 会话总线上（`DBUS_SESSION_BUS_ADDRESS`
= `unix:path=/run/user/<uid>/bus`）。这条总线是**每个用户一条**，不是每个桌面一条，
于是同一用户的多个图形会话会在上面互相碰撞。

### 现象

同一用户已经有一个 XFCE 图形会话（xrdp、另一个显示管理器，或它们的残留进程）时，
kasmvnc 的桌面起不来，而且几乎不留下任何线索：

- `journalctl -u kasmvnc-session` 里每 ~2 秒一轮
  `kasmvnc-session.service: Deactivated successfully.`，restart counter 很快破百；
- **没有任何** wrapper 或窗口管理器的错误输出（不是缺库，也不是 display 打不开）；
- `systemctl show kasmvnc-session -p ExecMainStatus` 为 `0`，所以 `Restart=always`
  每轮都会把它重新拉起；
- `/tmp/.ICE-unix/` 里每轮留下一个以 pid 命名的 socket，说明 `xfce4-session` 初始化到
  ICE 阶段才退出；
- `busctl --user list | grep -i xfce` 能看到 `org.xfce.SessionManager` 被**另一个**会话
  的 `xfce4-session` 持有。

### 根因

`xfce4-session` 是单实例服务：它在会话总线上申请 `org.xfce.SessionManager` 这个名字。
第二个实例启动时先完成初始化（建 ICE socket、拉起 `xfwm4` 等），然后在总线上发现名字
已被占用 → **静默退出，状态码 0**。`Restart=always`（见「会话生命周期」，注销本来就会
以 0 退出，所以这里必须是 `always`）于是每 `RestartSec=2` 把这个「成功退出」的会话再拉
一遍，形成快速重启循环。

这是 XFCE 的单实例设计与「同一用户多个桌面」需求之间的固有矛盾，不是本模块引入的
缺陷：nixpkgs 的 `xrdp` 模块对 D-Bus 没有任何处理（`startwm.sh` 只有
`. /etc/profile; $WM`），同用户的第二个 XFCE 会话同样会这样死。

### 受影响场景

- 同一用户同时（或先后）跑着 xrdp / 显示管理器的 XFCE 桌面。
- **「我以为已经停掉了」的孤儿会话。** `systemctl stop xrdp xrdp-sesman` 只停单元；
  xrdp 的桌面进程早已被 `pam_systemd` 迁进 logind session scope
  （`user.slice/user-<uid>.slice/session-<id>.scope`），不在单元的 cgroup 里，停单元杀不
  到它们。`xfce4-session` 于是成为孤儿，继续持有 `org.xfce.SessionManager`，logind 会话
  也仍然是 active（leader 已退出 → `active (abandoned)`），kasmvnc 照旧秒退循环。

### 解法

给每个桌面一条**自己的**会话总线，即在 `windowManager` 前加 `dbus-run-session`：

```nix
services.kasmvnc.windowManager = "dbus-run-session xfce4-session";
```

`dbus-run-session` 为这条命令新起一条 session bus（并覆盖 `DBUS_SESSION_BUS_ADDRESS`），
`xfce4-session` 在私有总线上的单实例名字不再与别人冲突，桌面正常常驻，xrdp 与 kasmvnc
互不干扰。这也是上游生态里的通行解法。需要注意的几点：

- **登录环境不受影响。** wrapper 仍然 source `/etc/profile`，`XDG_DATA_DIRS` /
  `XDG_CONFIG_DIRS` / `NIX_PROFILES` / `$XDG_RUNTIME_DIR` 照旧；`dbus-run-session` 只替换
  `DBUS_SESSION_BUS_ADDRESS`（wrapper 里的 `systemctl --user import-environment` 走的是
  logind 的 user manager，也不受影响）。
- **输入法不受影响。** fcitx5 的 GTK/Qt immodule 通过 `NIX_PROFILES` 里的 immodules 缓存
  与 `GTK_IM_MODULE`/`QT_IM_MODULE`/`XMODIFIERS` 生效，输入法进程本身通过自己的 socket
  被客户端发现，不依赖会话总线上的名字（见「输入法」）。
- **跨桌面共享的 user 服务会分叉。** 只在 user bus 上暴露名字的东西（通知守护、只装了
  user unit 的服务）此后每个桌面各有一份；需要全局唯一时请改用系统级服务。

### 排错

按顺序确认是「名字被占」而不是别的启动失败：

```bash
# 1. 是不是「成功退出」的循环：0 = 会话自己 exit 0，不是崩溃
systemctl show kasmvnc-session -p ExecMainStatus -p NRestarts
journalctl -u kasmvnc-session --no-pager -n 50   # 每 ~2s 一条 Deactivated successfully.

# 2. 名字在谁手里；顺便看 ICE socket 残留
busctl --user list | grep -i xfce.session        # org.xfce.SessionManager  <pid>  ...
ls -l /tmp/.ICE-unix/                            # 每轮一个 pid 命名的 socket

# 3. 占名者是谁：正常会话 / 孤儿 / 另一个桌面
pgrep -a xfce4-session                           # 注意：xfce4-session 会把 comm 改成 .xfce4-session-
loginctl list-sessions                           # 有没有残留会话（Service 可能是 xrdp-sesman / kasmvnc-session）
```

清理孤儿会话有个坑：对 leader 已退出的 abandoned 会话，`loginctl terminate-session <id>`
是**空操作**（返回成功但什么都没杀，真机实测），必须

```bash
loginctl kill-session <id> --signal=SIGKILL
# 或者直接 kill 掉 pgrep -a xfce4-session 里的那个进程
```

杀掉后 `kasmvnc-session` 的 `Restart=always` 下一轮就会自己恢复正常，不需要手动
`systemctl restart`。对比：本模块的 `kasmvnc-session.service` 自带 `ExecStopPost` 会话
清理（见「会话生命周期」），停止时不会留下这种孤儿；nixpkgs 的 `xrdp` 模块没有。

## 输入法

输入法在会话里能用，需要**两层**机制：

1. **`NIX_PROFILES`：让 GTK 找得到 immodules。** nixpkgs 给 GTK3 打的补丁会遍历
   `NIX_PROFILES` 里的每个 profile，查找 `<profile>/etc/gtk-3.0/immodules.cache`
   （即 `im-fcitx5.so` 等模块的清单）。丢失它的后果是 GTK 只认 `gtk-im-context-simple`
   （哑输入上下文），系统里装好的输入法在桌面会话内**完全失效**，而且没有任何报错。
   该变量由 `/etc/profile` 导出，wrapper source 它，因此会话与登录 shell 逐字相同。
2. **`GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS`：让应用真的启用 IME 桥。**
   GTK 与 Qt 自身会按 locale 从 immodules 缓存里自动选模块，但
   **Chromium / Electron 系应用（微信、VS Code、Discord 等）不查 GTK 的默认选择，而是
   显式读 `GTK_IM_MODULE` 决定是否接上输入法桥**；纯 Qt 应用同理看 `QT_IM_MODULE`；
   XIM 客户端看 `XMODIFIERS`。

`pam_env` 只会用 `DEFAULT=` 给这些变量提供**默认值**（已设置的变量不会被覆盖），而
`waylandFrontend = true` 时 `i18n.inputMethod` 根本不会在登录环境里导出
`GTK_IM_MODULE`/`QT_IM_MODULE`。所以这三件套依然由模块显式写在单元的 `Environment=`
里：

- 系统在 `environment.variables` 里定义过（`i18n.inputMethod` 就写在这里）时，继承同一个
  值，与登录会话一致；
- 系统没定义、但 `i18n.inputMethod.enable = true` 且 `type = "fcitx5"` 时（即
  `waylandFrontend = true`），用 `mkDefault` 注入 `GTK_IM_MODULE=fcitx`、
  `QT_IM_MODULE=fcitx`、`XMODIFIERS=@im=fcitx`；
- 其余情况不注入（模块不替用户选输入法框架）。

`NIX_PROFILES`、`XDG_DATA_DIRS`、`XDG_CONFIG_DIRS` 等不再由模块声明，全部来自
`/etc/profile`；如果确实需要覆盖，用
`systemd.services.kasmvnc-session.environment.<NAME>`（比如想强制一个与登录会话不同的
`NIX_PROFILES`）。

使用方法是**系统层启用输入法框架**，模块不需要额外配置：

```nix
# 系统 profile 里就会出现 fcitx5 与其 GTK/Qt immodule，
# 并生成 /run/current-system/sw/etc/gtk-3.0/immodules.cache
{
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [ fcitx5-rime fcitx5-chinese-addons ];
  };
}
```

验证方式：对第一个机制，`fcitx5-gtk3-immodule-probing` 在会话环境里报告
`GTK_IM_MODULE=fcitx5`，去掉 `NIX_PROFILES` 则退回 `gtk-im-context-simple`；对第二个机制，
看会话进程的 environ 里是否有 `GTK_IM_MODULE` / `QT_IM_MODULE`（`kasmvnc-ime` 测试同时
覆盖两层）。

需要注意的点：

- **`GTK_PATH` 不需要注入。** `environment.profileRelativeSessionVariables` 里的
  `GTK_PATH` 只影响登录 shell，GTK 靠 `NIX_PROFILES` 已经能定位缓存（不过 wrapper
  source `/etc/profile` 后会一并带上它，与登录会话一致）。
- **`waylandFrontend = true` 会让登录会话反而缺三件套。** `i18n.inputMethod` 在该选项下
  只设置 `XMODIFIERS`（Wayland 下不需要 `GTK_IM_MODULE`/`QT_IM_MODULE`），但 X11 会话
  （本模块）仍然依赖它们。模块会因此在会话里补上 fcitx5 的默认值；如果希望会话环境与
  登录会话完全一致，可以把 `i18n.inputMethod.fcitx5.waylandFrontend` 关掉。
- **输入法进程本身仍要自己启动。** 本模块只负责让程序找得到并被允许使用 immodule；
  fcitx5 守护进程可通过 `i18n.inputMethod` 的 autostart（桌面环境）或自己的 systemd user
  service 启动。

## 实现要点

- **会话 `PATH` 来自登录环境（并额外前置用户 profile），launcher 才能列出 home-manager
  安装的应用。** wrapper source `/etc/profile`，`/etc/set-environment` 的 `PATH` 以
  `/run/wrappers/bin` 开头、并包含 `environment.profiles` 派生的用户 profile
  （`/etc/profiles/per-user/<user>/bin`、`~/.nix-profile/bin`…）；wrapper 又把这两个用户
  profile 和模块自己的包装到最前面，所以它们优先于系统 profile。这不只是「命令能找到」
  的问题：GLib 的 `GDesktopAppInfo` 在加载 `.desktop` 文件时会用
  `g_find_program_for_path()` 在进程 `PATH` 里校验 `Exec[0]`（以及 `TryExec`），找不到就
  构造失败并返回 NULL，于是该应用从所有 launcher（panel、whisker menu、appfinder）里
  **静默消失**——这正是 home-manager 安装的、`Exec=` 写裸命令名的应用（如 `zen-beta`、
  `btm`、`zeditor`）在 kasmvnc 会话里不显示、而 `Exec=` 为绝对 store 路径的应用（如
  `wechat`）能显示的原因。
- **裸命令名由 wrapper 在登录 `PATH` 里解析。** `windowManager` 的单词作为参数交给
  wrapper，wrapper 用 `command -v` 在登录 `PATH` 中解析第一个词再 `exec` 绝对路径——
  与登录 shell 的行为一致（因此不需要 `ExecSearchPath=`）。
- **Xvnc 是一个 X server DDX**（`unix/xserver/hw/vnc`），只能通过给 xorg-server 打
  patch 并一起编译得到，不能简单地链接 nixpkgs 的 `xorgserver`。因此构建时解包
  nixpkgs `xorg-server` 的源码（21.1.24）到 `unix/xserver`，应用上游
  `unix/xserver21.patch`，再用 autotools 编译（与上游 `builder/build.sh` 同流程）。
- **turbojpeg 静态链接**：上游用 `-Wl,-Bstatic -lturbojpeg`，因此 `libjpeg-turbo`
  以 `enableStatic = true` 覆盖。
- **SHA-256 crypt**：`kasmvncpasswd` 与 Web 认证使用 `$5$kasm$`，nixpkgs 的
  `libxcrypt` 默认只启用 "strong" 方案集，需要额外打开 `sha256crypt`。
- **ffmpeg（h264 编码）**：上游在运行时扫描 `/usr/lib` 找到并 `dlopen` ffmpeg 的
  `libavformat.so` 等库。NixOS 没有 `/usr/lib`，因此构建时把 `${ffmpeg}/lib` 加入
  该扫描列表，并在 `Xvnc` 的 RUNPATH 中补上同一个目录（这些库不在 `DT_NEEDED` 里，
  不会自动进 RUNPATH）。
- **Perl 依赖**：`vncserver` 是 Perl 脚本，shebang 指向
  `perl.withPackages`（`ListMoreUtils`、`Switch`、`TryTiny`、`DateTime`、
  `DateTimeTimeZone`、`YAMLTiny`、`HashMergeSimple`），`KasmVNC::*` 模块通过
  `PERL5LIB` 提供。
- **前端**：kasmtech/noVNC 上游没有 `package-lock.json`，本仓库维护一份生成的
  lockfile（`packages/kasmvnc/package-lock.json`，lockfileVersion 3）。

## 上游版本

| 组件 | 版本 / commit |
|---|---|
| kasmtech/KasmVNC | `v1.5.2`（`b3ab9ac88e5283e986c65236cf0ed7462ec1505e`） |
| kasmtech/noVNC（`kasmweb` 子模块） | `402c0c59d62424ff110bad8f14682deec7d4c780` |
| xorg-server（取自 nixpkgs） | `21.1.24` |

## 限制与非目标

- 单实例、单 display（模块内部结构可按 display 扩展，但不提供多实例 options）。
- **logind 会话类型是 `unspecified`，不是真正的「login」。** 系统服务没有 tty/display
  会话类型，`pam_systemd` 也无从得知；这不影响 `$XDG_RUNTIME_DIR`、user manager 与 user
  bus（`loginctl` 里会话正常可见），但依赖 seat / session type 的功能（如某些
  `loginctl lock-session` 集成、音频的 seat 策略）不会被激活。
- 不打包 kasmweb 容器编排平台；不复刻镜像里的 icewm / 字体栈，会话内容由使用者通过
  `windowManager` 提供。输入法不由本模块安装（用 `i18n.inputMethod`），模块只保证会话
  环境能让程序找到**并且真的启用**已装好的 immodule（见上面的「输入法」）。
- 不提供 VNC viewer 传统客户端协议（`BUILD_VIEWER=OFF`，与上游一致）。
- GLX 会话依赖运行环境自带的 DRI 驱动；本包把 mesa 的 DRI 驱动链接到
  `$out/lib/dri`，但未做端到端 GL 客户端测试。
- `PIDFile` 使用 `networking.hostName` 拼出 `~/.vnc/<hostname>:<N>.pid`，若在运行时
  修改 transient hostname，需要重启服务。

## 开发

```bash
nix build .#kasmvnc          # 构建包
nix flake check              # 包含全部 NixOS VM 测试
nix develop                  # nil + nixfmt
```

VM 测试：

- `checks.<sys>.kasmvnc`：声明口令 + icewm 的完整场景（含 TLS、BasicAuth、重启）
- `checks.<sys>.kasmvnc-no-password`：仅 `enable = true` 的默认场景（无会话单元）
- `checks.<sys>.kasmvnc-path-wm`：只在系统 profile 中的裸命令名 WM 能否被会话单元拉起
  （解析走登录 `PATH`）
- `checks.<sys>.kasmvnc-login-parity`：登录语义本体——logind 会话、`/run/user/<uid>/bus`、
  `DBUS_SESSION_BUS_ADDRESS`/`XDG_RUNTIME_DIR`，以及会话 environ 的
  `NIX_PROFILES`/`XDG_*`/`GTK_PATH`/`LOCALE_ARCHIVE`/`LANG` 与 `su -` 逐字相等；还断言
  session `PATH` = wrapper 前置项 + 登录 `PATH`
- `checks.<sys>.kasmvnc-xfce`：XDG 会话环境（xfconfd、failsafe 会话、面板）
- `checks.<sys>.kasmvnc-multi-session`：多桌面并存时的 D-Bus 单实例冲突——第一个桌面
  在 user bus 上持有 `org.xfce.SessionManager` 时，裸 `xfce4-session` 秒退 0，
  `dbus-run-session` 包裹的同一命令持续存活，且第一个桌面不受影响
- `checks.<sys>.kasmvnc-launcher`：会话 `PATH` 含用户 profile（用 PyGObject 调
  `Gio.DesktopAppInfo` 验证 GLib 能加载 `Exec=` 为裸命令名、程序只在用户 profile 里的
  `.desktop` 文件）
- `checks.<sys>.kasmvnc-ime`：两层输入法机制（`NIX_PROFILES` + IM 三件套，`i18n.inputMethod`
  + fcitx5，用 `fcitx5-gtk3-immodule-probing` 断言 GTK 选中 fcitx5 而不是
  `gtk-im-context-simple`，并断言会话 environ 里有 `GTK_IM_MODULE` / `QT_IM_MODULE`；
  两个节点覆盖「继承系统变量」与 `waylandFrontend = true` 时的「模块补默认值」）
- `checks.<sys>.kasmvnc-session-restart`：会话生命周期（注销 / 崩溃后自动重启、`systemctl
  restart kasmvnc` 级联、`systemctl stop kasmvnc` 全部退出且不复活；同时断言 PAM 会话在
  每次重启后是新的一条、停止后关闭）
