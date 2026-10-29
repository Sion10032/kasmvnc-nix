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

## 实现要点

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
- 不打包 kasmweb 容器编排平台；不复刻镜像里的 icewm / fcitx5 / rime / 字体栈，
  会话内容由使用者通过 `windowManager` 提供。
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
- `checks.<sys>.kasmvnc-session-restart`：会话生命周期（注销 / 崩溃后自动重启、`systemctl
  restart kasmvnc` 级联、`systemctl stop kasmvnc` 全部退出且不复活）
