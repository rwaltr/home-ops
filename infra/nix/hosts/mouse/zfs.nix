{ ... }:
{
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs = {
    forceImportRoot = false;
    extraPools = [ "tank" ];
  };
  networking.hostId = "1e1719e4";

}
