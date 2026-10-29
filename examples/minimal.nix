# 最小可用的 services.kasmvnc 配置
#
# 这是一个 NixOS 配置片段：把本 flake 作为 input 引入后，在 configuration.nix
# 里 import 这个文件（并让 `inputs` 可见，例如 flake.nix 里用
# `nixpkgs.lib.nixosSystem { specialArgs = { inherit inputs; }; ... }`）。
{
  pkgs,
  inputs,
  ...
}:
{
  imports = [ inputs.kasmvnc-nix.nixosModules.default ];

  services.kasmvnc = {
    enable = true;

    # 会话用户；未在 users.users 中声明时由 module 自动创建为普通用户
    # （home 为 /home/kasm-user）。
    user = "kasm-user";

    # 分辨率 / 色深 / 帧率，对应 Docker 镜像里的 VNC_RESOLUTION /
    # VNC_COL_DEPTH / MAX_FRAME_RATE。
    resolution = "1280x720";
    colorDepth = 24;
    frameRate = 24;

    # Web 登录口令。生产环境建议用 sops-nix / agenix 管理：
    #   passwordFile = config.sops.secrets."kasmvnc/password".path;
    passwordFile = pkgs.writeText "kasmvnc-password" "changeme";

    # 会话命令，替代镜像里手工启动 icewm 的逻辑。
    # 复杂场景（输入法、DBus 等）指向自己的启动脚本即可。
    windowManager = "${pkgs.icewm}/bin/icewm-session";

    openFirewall = true;

    # 追加到 /etc/kasmvnc/kasmvnc.yaml 的额外配置。
    extraConfig = ''
      network:
        udp:
          public_ip: 127.0.0.1
    '';
  };

  # 会话里需要的中文环境（由使用者自行提供，module 不代管），例如：
  environment.systemPackages = with pkgs; [
    firefox
    xterm
  ];
}
