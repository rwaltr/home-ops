{ pkgs, unstable, ... }:
{
  imports = [
    ./hardware-configuration.nix
    ./zfs.nix
    ./minio.nix
  ];


  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernel.sysctl = { "net.ipv4.ip_forward" = 1; "net.ipv6.conf.all.forwarding" = 1; };

  nixpkgs.config.allowUnfree = true;


  networking.hostName = "mouse";
  networking.networkmanager.enable = true;
  time.timeZone = "America/Chicago";

  nix.settings.experimental-features = [ "nix-command" "flakes" "repl-flake" ];
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.warn-dirty = false;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than +5";
  };

  users.users.rwaltr = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    # shell = pkgs.fish;
  };

  services.fstrim.enable = true;
  services.openssh.enable = true;
  networking.firewall.allowedTCPPorts = [ 22 2049 19999 8384 22000 ];
  networking.firewall.allowedUDPPorts = [ 22000 21027 ];
  services.tailscale.enable = true;

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
      workstation = true;
    };
    nssmdns = true;
  };

  services.smartd.enable = true;

  environment.systemPackages = with pkgs; [
    rclone
    curl
    restic
    wget
    git
    gh
    age
    sops
    croc
  ];


  services.nfs.server.enable = true;

  services.syncthing.enable = true;
  services.syncthing.dataDir = "/tank/services/syncthing/data";
  services.syncthing.configDir = "/tank/services/syncthing/config";
  services.syncthing.guiAddress = "0.0.0.0:8384";

  services.navidrome = {
    enable = true;
    openFirewall = true;
    settings = {
      Address = "0.0.0.0";
      MusicFolder = "/tank/nas/library/music";
    };
  };


  # TODO: Switch to prometheus when prometheus
  services.netdata.enable = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?
}
