{
  description = "Temporary Taiwan NHI card middleware for x86_64 NixOS";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = pkg: (pkg.pname or "") == "nhiicc";
      };
      nhiicc = pkgs.callPackage ./package { };
    in
    {
      packages.${system} = {
        inherit nhiicc;
        default = nhiicc;
      };
      apps.${system}.default = {
        type = "app";
        program = "${nhiicc}/bin/nhiicc";
        meta.description = "Start a temporary NHI card middleware session";
      };
      checks.${system} = nhiicc.tests;
      formatter.${system} = pkgs.nixfmt;
    };
}
