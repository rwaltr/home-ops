{ ... }:
{
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs = {
    forceImportRoot = false;
  };
  networking.hostId = "1e1719e4";

}
