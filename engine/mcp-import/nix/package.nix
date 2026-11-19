{ self, ... }:
{
  perSystem =
    {
      inputs',
      lib,
      pkgs,
      self',
      ...
    }:
    let
      version = self.shortRev or self.dirtyShortRev or "dev";
    in
    {
      packages = {
        notmuch-mcp = (pkgs.buildGoModule.override { go = inputs'.devtools.packages.go; }) {
          pname = "notmuch-mcp";
          inherit version;
          src = lib.fileset.toSource {
            root = ../.;
            fileset = lib.fileset.difference (lib.fileset.gitTracked ../.) (
              lib.fileset.unions [
                ../flake.nix
                ../flake.lock
                ../nix
              ]
            );
          };

          # go-sum: b6abb22818cb57b7c897b171bc15d2493409d3fd778c5d34a365d4978f8483d3
          vendorHash = "sha256-Hf4JtUiu7YW/hpcOo7y7B0cwJK1dXE8t/E5nharBeVM=";

          ldflags = [
            "-s"
            "-w"
            "-X main.Version=${version}"
            "-X main.Commit=${self.shortRev or self.dirtyShortRev or "dirty"}"
            "-X main.BuildDate=1970-01-01T00:00:00Z"
          ];

          # The server shells out to the system `notmuch` binary at runtime —
          # propagate it so `nix run` users get a working install.
          propagatedBuildInputs = [ pkgs.notmuch ];

          meta = {
            description = "MCP server for reading and tagging mail with notmuch";
            homepage = "https://github.com/stubbedev/notmuch-mcp";
            mainProgram = "notmuch-mcp";
          };
        };

        default = self'.packages.notmuch-mcp;
      };
    };
}
