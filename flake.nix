{
  description = "Emacs utility packages for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.claude-code-utils = pkgs.emacsPackages.trivialBuild {
          pname = "claude-code-utils";
          version = "0.1.0";
          src = ./.;
          packageRequires = [ pkgs.emacsPackages.perspective ];
        };
      }
    );
}
