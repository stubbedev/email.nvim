{
  perSystem =
    { pkgs, self', ... }:
    {
      devShells.default = pkgs.mkShell {
        inputsFrom = [ self'.packages.email-engine ];
        packages = with pkgs; [
          gopls
          gotools
          golangci-lint
          just
          neovim
          stylua
          lua-language-server
        ];
      };
    };
}
