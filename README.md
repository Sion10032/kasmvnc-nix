# kasmvnc-nix

从源码构建的 [KasmVNC](https://github.com/kasmtech/KasmVNC) Nix 包，以及一个
`services.kasmvnc` NixOS 模块（systemd 系统服务）。

## 快速开始

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kasmvnc-nix.url = "github:Sion10032/kasmvnc-nix";
  };

  outputs = { self, nixpkgs, kasmvnc-nix, ... }: {
    nixosConfigurations.host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit kasmvnc-nix; };
      modules = [
        ./configuration.nix
        {
          imports = [ kasmvnc-nix.nixosModules.default ];
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
`passwordFile` 中的口令登录。默认使用自签证书，浏览器会提示证书不受信任。完整示例见
[`examples/minimal.nix`](examples/minimal.nix)。

不想用模块时，也可以用 overlay 或直接取包：

```nix
# overlay
nixpkgs.overlays = [ inputs.kasmvnc-nix.overlays.default ];
environment.systemPackages = [ pkgs.kasmvnc ];
# 或者
nix build github:Sion10032/kasmvnc-nix#kasmvnc
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

`windowManager` 是 `kasmvnc-session.service` 运行的桌面命令（独立单元 + 登录语义会话，见
[ARCHITECTURE.md](ARCHITECTURE.md)）。注意三点：

1. **按空白切分，裸名按登录 `PATH` 解析。** 不是 shell 命令行（管道、重定向、`&&`、`exec`
   需写包装脚本）。第一个词由 wrapper 用 `command -v` 在登录 `PATH` 里解析：用户 profile、
   `/run/current-system/sw/bin`、本模块的包都在其中；其余程序用 store 路径。
2. **D-Bus 会话总线由 PAM 会话提供**，通常不需要 `dbus-run-session`；同一用户还有别的
   图形会话时应保留该前缀，见
   [桌面无限重启](TROUBLESHOOTING.md#桌面无限重启-deactivated-successfully-循环)。
3. **`windowManager = null` 时没有会话服务**，Xvnc 带空桌面运行（`xstartup` 只 `exit 0`）。

```nix
# 1) 裸名（程序需在登录 PATH 中，如 services.xserver.desktopManager.xfce）
services.kasmvnc.windowManager = "xfce4-session";

# 2) store 路径：不依赖系统/用户 profile
services.kasmvnc.windowManager = "${pkgs.xfce.xfce4-session}/bin/xfce4-session";

# 3) 不需要会话总线的窗口管理器，store 路径即可
services.kasmvnc.windowManager = "${pkgs.icewm}/bin/icewm-session";
```

## 输入法

系统层启用输入法框架即可，模块不需要额外配置：

```nix
# 系统 profile 里出现 fcitx5 与 GTK/Qt immodule 及其 immodules.cache
{
  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5.addons = with pkgs; [ fcitx5-rime fcitx5-chinese-addons ];
  };
}
```

生效需要**两层**机制：`NIX_PROFILES` 让 GTK 找得到 immodules 缓存，`GTK_IM_MODULE` /
`QT_IM_MODULE` / `XMODIFIERS` 让应用（含不查 GTK 默认值的 Chromium / Electron 系）真的
启用 IME 桥。前者来自 `/etc/profile`，后者由模块写进会话单元 `Environment=`（输入法进程仍需
自己启动）。细节见[输入法不工作](TROUBLESHOOTING.md#输入法不工作)。

## 上游版本

| 组件 | 版本 / commit | 许可证 |
|---|---|---|
| kasmtech/KasmVNC | `v1.5.2`（`b3ab9ac88e5283e986c65236cf0ed7462ec1505e`） | GPLv2 |
| kasmtech/noVNC（`kasmweb` 子模块） | `402c0c59d62424ff110bad8f14682deec7d4c780` | MPL-2.0 |
| xorg-server（取自 nixpkgs） | `21.1.24` | MIT |

本仓库自身（nix 表达式、NixOS 模块、测试、文档）采用 [MIT](LICENSE)；对上游源码的
构建补丁（`packages/kasmvnc/*.patch`）同样以 MIT 授权，可自由并入 GPLv2 上游；构建产物
遵循上游各自许可。

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

## 文档

设计与实现细节（单元拆分、登录语义环境、PATH 与应用发现、构建期覆盖、与 xrdp 的
对照、限制与非目标）在 [`ARCHITECTURE.md`](ARCHITECTURE.md)；故障排查在
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)：

- 每 2 秒一轮 `Deactivated successfully`、`ExecMainStatus` 为 `0` → [D-Bus 单实例冲突](TROUBLESHOOTING.md#桌面无限重启-deactivated-successfully-循环)
- xrdp 关卡后仍起不来（孤儿会话占着名字）→ [清理孤儿会话](TROUBLESHOOTING.md#清理-xrdp-孤儿会话)
- 升级后环境值对不上 → [从旧配置迁移](TROUBLESHOOTING.md#从旧配置迁移)
- 输入法装了却打不出字 → [输入法不工作](TROUBLESHOOTING.md#输入法不工作)
- 要核对会话 / 总线 / 环境 → [诊断速查](TROUBLESHOOTING.md#诊断速查)
