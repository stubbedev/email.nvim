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
    in
    {
      packages = {
        default = self'.packages.email-engine;
        email-engine = goBuilder {
          pname = "email-engine";
          version = "0.1.0";
          src = ../engine;
          vendorHash = null;
          subPackages = [ "cmd/email-engine" ];
          nativeBuildInputs = [ pkgs.pkg-config ];
          buildInputs = [ pkgs.notmuch ];
          nativeCheckInputs = [ pkgs.notmuch ];
          ldflags = [ "-X main.version=${self'.packages.email-engine.version}" ];
          doCheck = true;
          meta = {
            description = "The engine behind email.nvim: notmuch, mail rendering and sending";
            homepage = "https://github.com/stubbedev/email.nvim";
            license = lib.licenses.mit;
            mainProgram = "email-engine";
            platforms = lib.platforms.unix;
          };
        };
      };

      checks.email-engine = self'.packages.email-engine;
    };
}
