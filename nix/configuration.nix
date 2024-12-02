{ config, lib, pkgs, ... }:

let
  fake-gitea = pkgs.writeShellScriptBin "gitea" ''
ssh -p 2222 -o StrictHostKeyChecking=no git@127.0.0.1 "SSH_ORIGINAL_COMMAND=\"$SSH_ORIGINAL_COMMAND\" $0 $@"
  '';

in {
  imports =
    [
      ./hardware-configuration.nix
    ];

  sops.defaultSopsFile = ./secrets/secrets.yaml;
  sops.age.keyFile = "/root/.config/sops/age/keys.txt";
  sops.secrets."borg/crash" = { };
  sops.secrets."anki/cy" = { };
  sops.secrets."ntfy" = { };
  sops.secrets."rclone" = { };

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/vda";

  system.stateVersion = "24.05";

  networking.hostName = "chunk";
  networking.networkmanager.enable = true;
  networking.nftables.enable = true;
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 ];
    allowedUDPPorts = [ 443 ];
    extraInputRules = ''
      ip saddr 172.18.0.0/16 tcp dport 5432 accept
    '';
  };
  networking.interfaces.ens18 = {
    ipv6.addresses = [{
      address = "2a0f:85c1:840:2bfb::1";
      prefixLength = 64;
    }];
  };
  networking.defaultGateway6 = {
    address = "2a0f:85c1:840::1";
    interface = "ens18";
  };

  time.timeZone = "America/Toronto";

  i18n.defaultLocale = "en_US.UTF-8";
  console = {
    font = "Lat2-Terminus16";
    useXkbConfig = true;
  };

  users.users.yt = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "docker"];
    openssh.authorizedKeys.keys =
      [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPdhAQYy0+vS+QmyCd0MAbqbgzyMGcsuuFyf6kg2yKge yt@ytlinux" ];
    packages = with pkgs; [
      fzf
      eza
      zoxide
      delta
      lua-language-server
      vim-language-server
      python312Packages.python-lsp-server
      nixd
      gopls
      bash-language-server
      llvmPackages_19.clang-tools
      rust-analyzer
      pgloader
      sqlite
    ];
  };
  users.users.root.openssh.authorizedKeys.keys =
      [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPdhAQYy0+vS+QmyCd0MAbqbgzyMGcsuuFyf6kg2yKge yt@ytlinux" ];
  users.defaultUserShell = pkgs.zsh;
  programs.zsh.enable = true;

  users.users.git = {
    isNormalUser = true;
    packages = [ fake-gitea ];
  };

  environment.systemPackages = with pkgs; [
    vim
    neovim
    wget
    curl
    tree
    neofetch
    gnupg
    python3Full
    tmux
    borgbackup
    rclone
    restic
    htop
    btop
    file
    sops
    age
  ];

  environment.variables = {
    EDITOR = "nvim";
    VISUAL = "nvim";
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  security.sudo.enable = true;
  security.sudo.wheelNeedsPassword = false;

  programs.gnupg.agent.enable = true;
  programs.git.enable = true;

  services.anki-sync-server = {
    enable = true;
    port = 27701;
    users = [
      {
        username = "cy";
        passwordFile = /run/secrets/anki/cy;
      }
    ];
  };

  services.caddy = {
    enable = true;
    configFile = ../Caddyfile;
  };

  services.postgresql = {
    enable = true;
    settings.port = 5432;
    package = pkgs.postgresql_17;
    enableTCPIP = true;
    ensureDatabases = [
      "forgejo"
      "linkding"
      "freshrss"
    ];
    ensureUsers = [
      {
        name = "forgejo";
        ensureDBOwnership = true;
      }
      {
        name = "linkding";
        ensureDBOwnership = true;
      }
      {
        name = "freshrss";
        ensureDBOwnership = true;
      }
    ];
    authentication = lib.mkForce ''
      local all all trust
      host  all all 127.0.0.1/32 trust
      host  all all ::1/128 trust
      host  all all 172.18.0.0/16 trust
    '';
  };
  services.postgresqlBackup.enable = true;

  virtualisation.docker.enable = true;

  services.borgbackup.jobs = {
    crashRsync = {
      paths = [ "/root" "/home" "/var/backup" "/var/lib" "/var/log" "/opt" "/etc" "/vw-data" ];
      exclude = [ "**/.cache" "**/node_modules" "**/cache" "**/Cache" "/var/lib/docker" ];
      repo = "de3911@de3911.rsync.net:borg/crash";
      encryption = {
        mode = "repokey-blake2";
        passCommand = "cat /run/secrets/borg/crash";
      };
      environment = {
        BORG_RSH = "ssh -i /home/yt/.ssh/id_ed25519";
        BORG_REMOTE_PATH = "borg1";
      };
      compression = "auto,zstd";
      startAt = "hourly";
      extraCreateArgs = [ "--stats" ];
      # warnings are often not that serious
      failOnWarnings = false;
      postHook = ''
        ${pkgs.curl}/bin/curl -u $(cat /run/secrets/ntfy) -d "chunk: backup completed with exit code: $exitStatus
        $(journalctl -u borgbackup-job-crashRsync.service|tail -n 5)" \
        https://ntfy.cything.io/chunk
      '';
    };
  };

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  services.tor = {
    enable = true;
    openFirewall = true;
    relay = {
      enable = true;
      role = "relay";
    };
    settings = {
      ORPort = 9001;
      Nickname = "chunk";
    };
  };

  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    environmentFile = "/var/lib/vaultwarden.env";
    config = {
      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = "8081";
      DATA_FOLDER = "/vw-data";
      DATABASE_URL = "postgresql://vaultwarden:vaultwarden@127.0.0.1:5432/vaultwarden";
    };
  };

  services.ntfy-sh = {
    enable = true;
    settings = {
      listen-http = "127.0.0.1:8083";
      base-url = "https://ntfy.cything.io";
      upstream-base-url = "https://ntfy.sh";
      auth-default-access = "deny-all";
      behind-proxy = true;
    };
  };

  systemd.services.immich-mount = {
    enable = true;
    description = "Mount the immich data remote";
    after = [ "network-online.target" ];
    requires = [ "network-online.target" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "notify";
      ExecStartPre = "/usr/bin/env mkdir -p /mnt/photos";
      ExecStart = "${pkgs.rclone}/bin/rclone mount --config /home/yt/.config/rclone/rclone.conf --dir-cache-time 720h --poll-interval 0 --vfs-cache-mode writes photos: /mnt/photos ";
      ExecStop = "/bin/fusermount -u /mnt/photos";
      EnvironmentFile = "/run/secrets/rclone";
    };
  };
}

