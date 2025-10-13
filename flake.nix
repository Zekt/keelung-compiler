{
  description = "Build Keelung compiler with old Nixpkgs and GHC 9.2.8";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=24.05";
  };

  outputs = { self, nixpkgs }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };
    packageName = "keelung-compiler";
    galois-field-src = (pkgs.fetchFromGitHub {
      owner = "Zekt";
      repo = "galois-field";
      rev = "c4a6445aa7d1f73098a5f5c4a98aec8f0f679c1c";
      sha256 = "sha256-xG1L9erSivihqpOt8j2i6D13cZCZJmVD6cFfRBy0V2E=";
    });
    keelung-src = (pkgs.fetchFromGitHub {
      owner = "Zekt";
      repo = "keelung";
	    rev = "735fc9bdaa63964feb6a312258e8499aec497133";
      sha256 = "sha256-ZxvQVGIwAFDnf+K+z0xrb8H3X8V52Gvtw13qCrmzMO4=";
    });
	  h = pkgs.haskell.packages.ghc928.extend (self: super: {
        poly = pkgs.haskell.lib.dontCheck super.poly;
        galois-field = pkgs.haskell.lib.doJailbreak (self.callCabal2nix "galois-field" galois-field-src {});
        keelung = pkgs.haskell.lib.dontCheck (self.callCabal2nix "keelung" keelung-src {});
      });
    keelung-compiler = pkgs.haskell.lib.dontCheck (h.callCabal2nix packageName ./. {});
	  x = h.callCabal2nix packageName rec {};
  in {
    pacakges.default = self.packages.${system}.default;
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = [
        (h.ghcWithPackages (hpkgs: [ keelung-compiler ]))
        h.haskell-language-server
        h.cabal-install
      ];
    shellHook = ''
      zsh
    '';
    };
  };
}
