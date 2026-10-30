# 架构与实现

## 单元拆分与会话守护

X 服务器与桌面会话是**两个单元**：`kasmvnc.service` 跑 `vncserver` / `Xvnc`、TLS、Web 前端
（`xstartup` 只 `exit 0`）；`kasmvnc-session.service`（仅 `windowManager != null` 时存在）
运行并守护窗口管理器本身：

- **注销或崩溃后自动重启**（`Restart=always` + `RestartSec=2`）：注销以 0 退出、崩溃是
  任意退出码，两种都会拉回来（等效于镜像的看门狗循环），Xvnc 不受影响。必须是
  `always`：`on-failure` 会让注销后的桌面停在黑屏。
- **彻底停止用 `systemctl stop kasmvnc`**：`PartOf=` / `After=` 保证先停会话再
  `vncserver -kill`，显式 `stop` 不触发 `Restart=`。启动前 `ExecStartPre` 循环等
  `/tmp/.X11-unix/X<N>`（最长 60s：`Type=forking` 的 `After=` 不代表已监听）。
- **停止时终止 logind 会话**：`pam_systemd` 把桌面进程移进
  `user.slice/user-<uid>.slice/session-<id>.scope`，`KillMode=` 拉不到，logind 对
  「leader 已退出」的会话只标 `active (abandoned)` 不清理，`Restart=always` 就会在旧桌面上
  再叠一个；故 `ExecStopPost`（**也是「先停再启」路径**）以 root 身份
  `loginctl kill-session`（必要时 SIGKILL）+ `terminate-session`，`KillMode=mixed` 只管主进程。

## 登录语义的会话环境

桌面按**登录会话**启动，环境全部来自 NixOS 自己的机制：

- **PAM**（`PAMName=kasmvnc-session` + 同名 `security.pam.services`，
  `startSession = true`）：`pam_env` 的 session 变量（`PATH` 含 `/run/wrappers/bin`、
  `XDG_*`、`GTK_PATH`、`LOCALE_ARCHIVE`、`LANG`…）、`pam_unix`、`pam_limits`、`pam_loginuid`，
  以及 `pam_systemd`（logind 会话 → `$XDG_RUNTIME_DIR` / user manager / user bus）。
- **登录 shell**：wrapper source `/etc/profile`，拿到 `/etc/set-environment` 的全量导出
  （`NIX_PROFILES`、`environment.*Variables`、派生搜索路径；XDG 细节见
  [XDG 会话环境从哪来](#xdg-会话环境从哪来)）。
- **对齐**：`systemctl --user import-environment` +
  `dbus-update-activation-environment --systemd --all`，让 user manager 与 D-Bus
  activation 环境与会话一致。

wrapper 另外前置用户 profile 与模块自己的包、等 `$XDG_RUNTIME_DIR/bus` 就绪（0.2s × 150 =
30s，`pam_systemd` 拉起 user manager 有竞态）后导出 `DBUS_SESSION_BUS_ADDRESS`（超时只
告警）、清掉 `SESSION_MANAGER`（别的会话的 manager 会把客户端拉到错误会话），再 `exec`
桌面命令。会话 environ 因此与登录 shell 逐字一致（验证见
[TROUBLESHOOTING 的诊断速查](TROUBLESHOOTING.md#诊断速查)；旧配置的应急注入见
[从旧配置迁移](TROUBLESHOOTING.md#从旧配置迁移)）。

## 多桌面并存

登录语义把会话挂到**每个用户一条**的 D-Bus 会话总线上，同一用户多个图形会话会撞名
（XFCE 的 `xfce4-session` 在总线上是单实例）；此时给每个桌面一条自己的总线：

```nix
services.kasmvnc.windowManager = "dbus-run-session xfce4-session";
```

完整的现象、根因与排错流程见
[桌面无限重启](TROUBLESHOOTING.md#桌面无限重启-deactivated-successfully-循环)。

## PATH 与应用发现

- **会话 `PATH` 来自登录环境（并额外前置用户 profile），launcher 才能列出 home-manager
  安装的应用。** GLib 的 `GDesktopAppInfo` 用进程 `PATH` 校验 `.desktop` 的 `Exec[0]` /
  `TryExec`，找不到就静默丢弃：`Exec=` 写裸命令名、且程序只在用户 profile 里的（`zen-beta`、
  `btm`）从 launcher 消失；`Exec=` 用 store 路径的（`wechat`）正常。
- **裸命令名由 wrapper 在登录 `PATH` 里解析**（`command -v` + `exec` 绝对路径），与登录
  shell 一致，不需要 `ExecSearchPath=`。

## XDG 会话环境从哪来

wrapper 里 source `/etc/profile`，`/etc/set-environment` 的全量导出随之进入会话：

- `XDG_DATA_DIRS` 决定会话总线上的 D-Bus activation 能否找到
  `share/dbus-1/services/*.service`（例如 `org.xfce.Xfconf.service` → `xfconfd`）；
- `XDG_CONFIG_DIRS` 决定默认配置位置（例如
  `etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`，`xfce4-session` 靠它得到 failsafe 会话
  定义）。

两者与登录会话完全一致，模块不再单独声明（这也是旧配置里手写
`systemd.services.kasmvnc-session.environment.XDG_*` 可以删掉的原因）。

## 构建期覆盖

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

## 与 xrdp 和显示管理器的登录语义对照

| 机制 | xrdp（`xrdp-sesman`）| 显示管理器（nixpkgs `xsession-wrapper`）| 本模块 |
|---|---|---|---|
| PAM 服务 | `xrdp-sesman`（`startSession = true`）| 各 DM 自己的服务（`gdm-launch-environment` 等）| `kasmvnc-session`（`startSession = true`）|
| logind 会话 / user bus | `pam_systemd` | `pam_systemd` | `pam_systemd` |
| 登录 shell 环境 | `startwm.sh` 里 `. /etc/profile` | wrapper 里 `. /etc/profile` | wrapper 里 `. /etc/profile` |
| D-Bus 激活环境 | `dbus-update-activation-environment` | `systemctl --user import-environment <importedVariables>` | 两者都做 |
| 会话总线 | `dbus-run-session` 或已有 user bus | 系统 user bus | 系统 user bus（PAM 会话提供）|
| 会话守护 | `sesman` + `xrdp-sesman` | DM 自己 | `kasmvnc-session.service`（`Restart=always`）|
| 会话清理 | `sesman` 注销时关闭 PAM 会话 | DM 注销时关闭 PAM 会话（+ kill） | `ExecStopPost` 里 `loginctl kill-session` + `terminate-session`（见[单元拆分与会话守护](#单元拆分与会话守护)）|

## 限制与非目标

- 单实例、单 display（模块内部结构可按 display 扩展，但不提供多实例 options）。
- **logind 会话类型是 `unspecified`，不是真正的「login」。** 系统服务没有 tty/display
  会话类型，`pam_systemd` 也无从得知；这不影响 `$XDG_RUNTIME_DIR`、user manager 与 user
  bus（`loginctl` 里会话正常可见），但依赖 seat / session type 的功能（如某些
  `loginctl lock-session` 集成、音频的 seat 策略）不会被激活。
- 不打包 kasmweb 容器编排平台；不复刻镜像里的 icewm / 字体栈，会话内容由使用者通过
  `windowManager` 提供。输入法不由本模块安装（用 `i18n.inputMethod`），模块只保证会话
  环境能让程序找到**并且真的启用**已装好的 immodule（见 README「输入法」）。
- 不提供 VNC viewer 传统客户端协议（`BUILD_VIEWER=OFF`，与上游一致）。
- GLX 会话依赖运行环境自带的 DRI 驱动；本包把 mesa 的 DRI 驱动链接到 `$out/lib/dri`，但未做端到端 GL 客户端测试。
- `PIDFile` 使用 `networking.hostName` 拼出 `~/.vnc/<hostname>:<N>.pid`，若在运行时
  修改 transient hostname，需要重启服务。
