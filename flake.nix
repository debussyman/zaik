{
  description = "Zaik - Personal AI Agent Runtime";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            elixir
            erlang
            git
          ];

          # Set environment variables for Elixir
          shellHook = ''
            echo "Entering Zaik development shell with Elixir and Mix"
            echo "Elixir version: $(elixir --version)"
            echo "Mix version: $(mix --version)"
          '';
        };
      });
}