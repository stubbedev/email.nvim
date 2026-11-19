{
  perSystem =
    {
      lib,
      pkgs,
      self',
      ...
    }:
    let
      goBuilder = pkgs.buildGoModule.override { go = pkgs.go_latest; };
      version = lib.fileContents ../engine/VERSION;
      meta = {
        homepage = "https://github.com/stubbedev/email.nvim";
        license = lib.licenses.mit;
        platforms = lib.platforms.unix;
      };
    in
    {
      packages = {
        default = self'.packages.vim-plugin;

        email-engine = goBuilder {
          pname = "email-engine";
          inherit version;
          src = ../engine;
          vendorHash = null;
          buildInputs = [ pkgs.notmuch ];
          nativeCheckInputs = [ pkgs.notmuch ];
          doCheck = true;
          checkFlags = [ "-race" ];
          meta = meta // {
            description = "The engine behind email.nvim: notmuch, mail rendering and sending, and an MCP server";
            mainProgram = "email-engine";
          };
        };

        vim-plugin = pkgs.vimUtils.buildVimPlugin {
          pname = "email.nvim";
          inherit version;
          src = lib.fileset.toSource {
            root = ../.;
            fileset = lib.fileset.unions [
              ../lua
              ../engine/VERSION
              ../LICENSE
              ../README.md
            ];
          };
          postInstall = ''
            install -Dm755 ${lib.getExe self'.packages.email-engine} "$out/bin/email-engine"
          '';
          meta = meta // {
            description = "A notmuch mail client for Neovim, with its engine bundled";
          };
        };
      };

      checks = {
        inherit (self'.packages) email-engine vim-plugin;
      };
    };
}
