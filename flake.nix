{
  inputs = {
    utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };
  outputs = { self, nixpkgs, utils }: utils.lib.eachDefaultSystem (system:
    let
      pkgs = import nixpkgs { inherit system; };
    in
    {
      devShell = pkgs.mkShell {
        buildInputs = with pkgs; [
	  # to view diagrams in markdown
	  mermaid-cli
	  # to dump/send over serial
	  tio
	  # bin/hex conversion
	  xxd
        ];
      };
    }
  );
}
