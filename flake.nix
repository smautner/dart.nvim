{
  description = "dart.nvim";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/master";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs =
    inputs@{
      nixpkgs,
      ...
    }:
    let
      systems = builtins.attrNames nixpkgs.legacyPackages;
    in
    inputs.flake-utils.lib.eachSystem systems (
      system:
      let
        version = "0.1.0";
        pkgs = import nixpkgs {
          inherit system;
        };
        dart-nvim = pkgs.vimUtils.buildVimPlugin {
          pname = "dart.nvim";
          inherit version;
          src = pkgs.lib.cleanSourceWith {
            src = ./.;
            filter = path: type: (builtins.match ".*lua" (builtins.baseNameOf path) != null);
          };
        };
        shell = pkgs.mkShell {
          name = "dart-nvim-shell";
          buildInputs = with pkgs; [
            lua-language-server
            stylua
          ];
        };
      in
      {
        packages = {
          default = dart-nvim;
        };
        devShells = {
          default = shell;
        };
      }
    );
}
