{
  description = "Rwaltr's Home-ops";
  inputs = {

    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.05";

    unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    hardware.url = "github:nixos/nixos-hardware";

    nixos-generators.url = "github:nix-community/nixos-generators";
    nixos-generators.inputs.nixpkgs.follows = "nixpkgs";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    talhelper.url = "github:budimanjojo/talhelper";

    treefmt-nix.url = "github:numtide/treefmt-nix";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
  };

  outputs = inputs @ { flake-parts, ... }:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      imports = [
        inputs.treefmt-nix.flakeModule
        # .nix/lib
        ./infra/nix/hosts
      ];

      perSystem = { pkgs, inputs', ... }: {
        devShells.default = pkgs.mkShell {
          name = "Deployment";
          packages = with pkgs; [
            age
            flux
            git
            kubectl
            clusterctl
            nix
            sops
            talosctl
            opentofu
            inputs'.talhelper.packages.default
          ];
        };
        treefmt = {
          projectRootFile = "flake.nix";
          programs.alejandra.enable = true;
          programs.deadnix.enable = true;
        };
      };
    };
}
