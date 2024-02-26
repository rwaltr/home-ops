{ inputs, ... }: {
  flake.nixosConfigurations =
    let
      inherit (inputs.nixpkgs.lib) nixosSystem;
    in
    {
      mouse = nixosSystem {
        system = "x86_64-linux";
        modules = [
          ./mouse
        ];
      };
    };
}
