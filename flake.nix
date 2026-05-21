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

          shellHook = ''
            parse_git_branch() {
              local branch
              branch=$(git branch --show-current 2>/dev/null)

              if [ -z "$branch" ]; then
                branch=$(git rev-parse --short HEAD 2>/dev/null)
              fi

              if [ -n "$branch" ]; then
                printf " [%s]" "$branch"
              fi
            }

            export PS1="(nix) \w\$(parse_git_branch) \\$ "

            echo "Entering Zaik development shell with Elixir and Mix"
            echo "Elixir version: $(elixir --version)"
            echo "Mix version: $(mix --version)"
            echo "To start the application: mix run"
            echo "To run tests: mix test"
          '';
        };
      });
}