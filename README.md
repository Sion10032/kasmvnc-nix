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
| `windowManager` | str \| null | `null` | 会话命令（`kasmvnc-session.service` 的 `ExecStart`）；裸名要求程序在系统 profile 中 |
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

`windowManager` 是 `kasmvnc-session.service` 的 `ExecStart`：`kasmvnc.service` 只负责 X
服务器，桌面会话由独立单元运行并被守护（见下面的「会话生命周期」）。四点需要注意：

1. **裸命令名按单元的查找路径解析。** 这是 systemd 的 `ExecStart`，不是 shell 命令
   行：按空白切分，不支持管道、重定向、`&&`、`exec` 等 shell 语法（需要时写包装脚本）。
   裸名由 `ExecSearchPath=` 解析，模块把与单元 `PATH` 相同的目录填进去（模块自己的包 +
   `/run/current-system/sw/bin`）。给单元设置 `path` 会**整体替换**它的 `PATH`，所以系统
   profile 是显式加上的。这意味着裸名只有对**通过系统 profile 可达**的程序才有效，例如
   `services.xserver.desktopManager.xfce` 或
   `environment.systemPackages = [ pkgs.xfce.xfce4-session ]`。没有装到系统 profile
   的程序必须写 store 路径。
2. **桌面环境需要 D-Bus 会话总线。** `xfce4-session` 等在没有会话总线时会拒绝启动
   （会话单元会 unset `DBUS_SESSION_BUS_ADDRESS`，对应原先 xstartup 的做法），因此要用
   `dbus-run-session` 包裹；`dbus` 已在单元查找路径中，可以裸名调用。
3. **桌面环境所需的 XDG 会话环境由模块注入。** 系统服务拿不到登录会话的环境
   （`/etc/set-environment`），而桌面环境依赖它：`XDG_DATA_DIRS` 决定会话总线的
   D-Bus activation 能否找到 `share/dbus-1/services/*.service`（例如
   `org.xfce.Xfconf.service` → `xfconfd`），`XDG_CONFIG_DIRS` 决定默认配置从哪里读
   （例如 `etc/xdg/xfce4/xfconf/xfce-perchannel-xml/`，`xfce4-session` 靠它得到
   failsafe 会话定义）。模块为这两个变量提供默认值，**继承自系统的 session 变量**
   （`environment.sessionVariables` 加上 `environment.profileRelativeSessionVariables`
   对 `environment.profiles` 的展开，与登录会话的算法一致）；系统自定义过 session
   环境时服务会一并跟上。需要覆盖时用
   `systemd.services.kasmvnc-session.environment.XDG_DATA_DIRS` /
   `.XDG_CONFIG_DIRS`（模块用的是 `mkDefault`）。
4. **`windowManager = null` 时没有会话服务。** Xvnc 会带着一个空桌面（占位的
   `~/.vnc/xstartup` 只 `exit 0`）运行，没有 `kasmvnc-session.service`。

```nix
# 1) 裸名 + D-Bus 会话总线（程序需系统级安装，如 services.xserver.desktopManager.xfce）
services.kasmvnc.windowManager = "dbus-run-session xfce4-session";

# 2) store 路径：不依赖系统 profile；DE 仍需 dbus-run-session 包裹
services.kasmvnc.windowManager =
  "dbus-run-session ${pkgs.xfce.xfce4-session}/bin/xfce4-session";

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
| `tail -f` + 进程守护循环 | systemd（`Restart=on-failure` / `Restart=always`、`KillMode=control-group`） |

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

## 输入法

输入法在会话里能用，需要**两层**机制，而 systemd 服务两层都拿不到（它们都只由登录会话
的环境提供）：

1. **`NIX_PROFILES`：让 GTK 找得到 immodules。** nixpkgs 给 GTK3 打的补丁会遍历
   `NIX_PROFILES` 里的每个 profile，查找 `<profile>/etc/gtk-3.0/immodules.cache`
   （即 `im-fcitx5.so` 等模块的清单）。该变量只由 `/etc/profile` 在登录 shell 里导出。
   丢失它的后果是 GTK 只认 `gtk-im-context-simple`（哑输入上下文），系统里装好的输入法
   在桌面会话内**完全失效**，而且没有任何报错。
2. **`GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS`：让应用真的启用 IME 桥。**
   GTK 与 Qt 自身会按 locale 从 immodules 缓存里自动选模块，但
   **Chromium / Electron 系应用（微信、VS Code、Discord 等）不查 GTK 的默认选择，而是
   显式读 `GTK_IM_MODULE` 决定是否接上输入法桥**；纯 Qt 应用同理看 `QT_IM_MODULE`；
   XIM 客户端看 `XMODIFIERS`。只注入 `NIX_PROFILES` 时，probe 会报 `fcitx5`，但微信里
   依然打不出字，原因就在这里。

`kasmvnc-session.service` 是 systemd 系统服务、没有登录 shell，所以模块为两个单元
注入这些变量：

- **`NIX_PROFILES`**：取值与 `/etc/profile` 完全一致（`environment.profiles` 的逆序、
  空格分隔，`$HOME` / `$USER` 替换为会话用户，未设置的变量按 shell 语义展开为空），
  用 `mkDefault` 包裹。
- **IM 三件套**：优先**继承** `environment.variables` 里系统已定义的值（`i18n.inputMethod`
  就写在这里，因此会话环境与登录会话一致）；系统没有定义、但 `i18n.inputMethod.enable =
  true` 且 `type = "fcitx5"` 时，用 `mkDefault` 注入 `GTK_IM_MODULE=fcitx`、
  `QT_IM_MODULE=fcitx`、`XMODIFIERS=@im=fcitx`；其余情况不注入（模块不替用户选输入法
  框架）。

四个变量都可以用 `systemd.services.kasmvnc-session.environment.<NAME>` 覆盖。

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
  `GTK_PATH` 只影响登录 shell，GTK 靠 `NIX_PROFILES` 已经能定位缓存。
- **`waylandFrontend = true` 会让登录会话反而缺三件套。** `i18n.inputMethod` 在该选项下
  只设置 `XMODIFIERS`（Wayland 下不需要 `GTK_IM_MODULE`/`QT_IM_MODULE`），但 X11 会话
  （本模块）仍然依赖它们。模块会因此在会话里补上 fcitx5 的默认值；如果希望会话环境与
  登录会话完全一致，可以把 `i18n.inputMethod.fcitx5.waylandFrontend` 关掉。
- **输入法进程本身仍要自己启动。** 本模块只负责让程序找得到并被允许使用 immodule；
  fcitx5 守护进程可通过 `i18n.inputMethod` 的 autostart（桌面环境）或自己的 systemd user
  service 启动。

## 实现要点

- **会话 `PATH` 包含用户 profile，launcher 才能列出 home-manager 安装的应用。** 模块为
  两个单元的 `path` 在系统 profile（`/run/current-system/sw`）之后追加
  `/etc/profiles/per-user/<user>` 与 `~/.nix-profile`（systemd 会为每一项加上 `/bin`、
  `/sbin`），与登录会话的 `PATH` 语义一致。这不只是「命令能找到」的问题：GLib 的
  `GDesktopAppInfo` 在加载 `.desktop` 文件时会用 `g_find_program_for_path()` 在进程
  `PATH` 里校验 `Exec[0]`（以及 `TryExec`），找不到就构造失败并返回 NULL，于是该应用从
  所有 launcher（panel、whisker menu、appfinder）里**静默消失**——这正是 home-manager
  安装的、`Exec=` 写裸命令名的应用（如 `zen-beta`、`btm`、`zeditor`）在 kasmvnc 会话里
  不显示、而 `Exec=` 为绝对 store 路径的应用（如 `wechat`）能显示的原因。补上用户 profile
  后它们全部正常出现。
- **裸命令名靠 `ExecSearchPath`**：systemd 本身**不会**用单元的 `PATH` 解析相对
  `ExecStart`（`PATH` 只影响它拉起的进程），因此模块用 `ExecSearchPath=` 把同样的目录
  交给 systemd 查找，`windowManager` 里的裸命令名（如
  `dbus-run-session xfce4-session`）才能生效。
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
- `checks.<sys>.kasmvnc-xfce`：XDG 会话环境注入（xfconfd、failsafe 会话、面板）
- `checks.<sys>.kasmvnc-launcher`：会话 `PATH` 含用户 profile（用 PyGObject 调
  `Gio.DesktopAppInfo` 验证 GLib 能加载 `Exec=` 为裸命令名、程序只在用户 profile 里的
  `.desktop` 文件）
- `checks.<sys>.kasmvnc-ime`：两层输入法机制（`NIX_PROFILES` + IM 三件套，`i18n.inputMethod`
  + fcitx5，用 `fcitx5-gtk3-immodule-probing` 断言 GTK 选中 fcitx5 而不是
  `gtk-im-context-simple`，并断言会话 environ 里有 `GTK_IM_MODULE` / `QT_IM_MODULE`；
  两个节点覆盖「继承系统变量」与 `waylandFrontend = true` 时的「模块补默认值」）
- `checks.<sys>.kasmvnc-session-restart`：会话生命周期（注销 / 崩溃后自动重启、`systemctl
  restart kasmvnc` 级联、`systemctl stop kasmvnc` 全部退出且不复活）
