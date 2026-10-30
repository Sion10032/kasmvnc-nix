# Troubleshooting

排错流程与诊断命令。设计与实现细节（单元拆分、登录语义、构建期覆盖、与 xrdp 的对照）在
[ARCHITECTURE.md](ARCHITECTURE.md)。索引：

- [桌面无限重启](#桌面无限重启-deactivated-successfully-循环)——`Deactivated successfully`
  循环、D-Bus 单实例冲突、xrdp 孤儿会话
- [从旧配置迁移](#从旧配置迁移)——升级后可以删掉的应急配置
- [输入法不工作](#输入法不工作)——两层机制与 `waylandFrontend`
- [诊断速查](#诊断速查)——journal、`busctl`、ICE socket、logind、与登录 shell 对比

## 桌面无限重启 Deactivated successfully 循环

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

### 背景：会话挂在哪条总线上

登录语义的会话环境（[ARCHITECTURE.md](ARCHITECTURE.md)）把会话挂到了**用户的** D-Bus 会话总线上
（`DBUS_SESSION_BUS_ADDRESS` = `unix:path=/run/user/<uid>/bus`）。这条总线是**每个用户
一条**，不是每个桌面一条，于是同一用户的多个图形会话会在上面互相碰撞。

### 根因

`xfce4-session` 是单实例服务：它在会话总线上申请 `org.xfce.SessionManager` 这个名字。
第二个实例启动时先完成初始化（建 ICE socket、拉起 `xfwm4` 等），然后在总线上发现名字
已被占用 → **静默退出，状态码 0**。`Restart=always`（注销本来就会以 0 退出，所以必须
是 `always`，见 [ARCHITECTURE.md](ARCHITECTURE.md)）于是每 `RestartSec=2` 把这个「成功退出」的会话再拉
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
  被客户端发现，不依赖会话总线上的名字（见[输入法不工作](#输入法不工作)）。
- **跨桌面共享的 user 服务会分叉。** 只在 user bus 上暴露名字的东西（通知守护、只装了
  user unit 的服务）此后每个桌面各有一份；需要全局唯一时请改用系统级服务。

### 排错：先确认是「名字被占」

命令集中在[诊断速查](#诊断速查)，其余线索的判读要点：

- `ExecMainStatus` 为 `0` 而 restart counter 在涨 → 会话自己 exit 0，不是崩溃；
- `org.xfce.SessionManager` 的持有者 pid 不是 `kasmvnc-session.service` 的主进程 →
  占名者在别的会话里；
- `pgrep -a xfce4-session` 的输出里，`xfce4-session` 会把 `comm` 改成
  `.xfce4-session-`（前缀有点，`pgrep` 按 comm 匹配，别被名字唬住）；
- `loginctl list-sessions` 里若有 `Service` 为 `xrdp-sesman` / `kasmvnc-session` 的残留
  会话，先按下一节清理。

### 清理 xrdp 孤儿会话

对 leader 已退出的 abandoned 会话，`loginctl terminate-session <id>` 是**空操作**
（返回成功但什么都没杀，真机实测），必须

```bash
loginctl kill-session <id> --signal=SIGKILL
# 或者直接 kill 掉 pgrep -a xfce4-session 里的那个进程
```

杀掉后 `kasmvnc-session` 的 `Restart=always` 下一轮就会自己恢复正常，不需要手动
`systemctl restart`。对比：本模块的 `kasmvnc-session.service` 自带 `ExecStopPost` 会话
清理（见 [ARCHITECTURE.md](ARCHITECTURE.md) 的「单元拆分与会话守护」），停止时不会留下这种孤儿；nixpkgs 的 `xrdp` 模块没有。

## 从旧配置迁移

旧版本（commit `41869e9` 及以前）用手写注入模拟登录环境。升级后下面这些应急配置可以
删掉——它们与新的登录会话值冲突时只会造成困惑：

| 删除 | 原因 |
|---|---|
| `environment.sessionVariables.NIX_PROFILES`（或 `environment.variables.NIX_PROFILES`）| `/etc/profile` 导出 |
| `systemd.services.kasmvnc-session.environment.NIX_PROFILES` / `.XDG_DATA_DIRS` / `.XDG_CONFIG_DIRS` | 同上 |
| `systemd.services.kasmvnc-session.path` 里的用户 profile（`/etc/profiles/per-user/<user>`、`~/.nix-profile`）| wrapper 前置追加 |
| `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS` 的手工设置 | 系统 `i18n.inputMethod` 已定义时由登录会话提供（`waylandFrontend = true` 时保留模块默认值）|
| `windowManager` 外层的 `dbus-run-session` | PAM 会话已提供 user bus（保留也仍然能工作；**同一用户还有别的图形会话时应保留**，见[桌面无限重启](#桌面无限重启-deactivated-successfully-循环)）|

迁移后需要验证的四项：注销/重启后桌面回来、`loginctl list-sessions` 里有 `kasm-user`
会话、rime 能输入、launcher（panel / whisker menu）里 home-manager 安装的应用仍在。

## 输入法不工作

系统层的启用方法（`i18n.inputMethod`）见 README「输入法」；本节讲机制与排错。

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
`GTK_IM_MODULE`/`QT_IM_MODULE`。所以这三件套依然由模块显式写在会话单元的 `Environment=`
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

验证方式：对第一个机制，`fcitx5-gtk3-immodule-probing` 在会话环境里报告
`GTK_IM_MODULE=fcitx5`，去掉 `NIX_PROFILES` 则退回 `gtk-im-context-simple`；对第二个机制，
看会话进程的 environ 里是否有 `GTK_IM_MODULE` / `QT_IM_MODULE`（`kasmvnc-ime` 测试同时
覆盖两层）。

## 诊断速查

### 会话在重启循环吗

```bash
# 0 = 会话自己 exit 0，不是崩溃
systemctl show kasmvnc-session -p ExecMainStatus -p NRestarts
journalctl -u kasmvnc-session --no-pager -n 50   # 每 ~2s 一条 Deactivated successfully.
```

### 单实例名字在谁手里

```bash
# 名字在谁手里；顺便看 ICE socket 残留
busctl --user list | grep -i xfce.session        # org.xfce.SessionManager  <pid>  ...
ls -l /tmp/.ICE-unix/                            # 每轮一个 pid 命名的 socket

# 占名者是谁：正常会话 / 孤儿 / 另一个桌面
pgrep -a xfce4-session                           # 注意：xfce4-session 会把 comm 改成 .xfce4-session-
loginctl list-sessions                           # 有没有残留会话（Service 可能是 xrdp-sesman / kasmvnc-session）
```

### 会话环境是否与登录 shell 一致

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
