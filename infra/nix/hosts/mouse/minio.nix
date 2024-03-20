{ ... }: {

  services.minio.enable = true;
  services.minio = {
    configDir = "/tank/services/minio/cfg";
    dataDir = "/tank/services/minio/data";
    region = "us-kyz-0";
  };

  networking.firewall.allowedTCPPorts = [ 9000 9001 ];
}
