package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/stubbedev/email.nvim/engine"
	"github.com/stubbedev/email.nvim/engine/internal/mcpserver"
	"github.com/stubbedev/email.nvim/engine/internal/rpc"
)

const usage = `email-engine — the engine behind email.nvim

usage: email-engine <command> [args]

commands:
  serve     answer email.nvim's requests: JSON lines on stdin, responses on stdout
  convert   render one mail part from stdin (see email-engine convert --help)
  mcp       serve notmuch to AI agents over the Model Context Protocol (stdio)
  version   print the version
`

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		_, _ = fmt.Fprint(stderr, usage)
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	switch args[0] {
	case "serve":
		if err := rpc.Serve(ctx, engine.Version(), stdin, stdout); err != nil {
			_, _ = fmt.Fprintf(stderr, "email-engine: %v\n", err)
			return 1
		}
		return 0
	case "convert":
		return runConvert(args[1:], stdin, stdout, stderr)
	case "mcp":
		if err := mcpserver.Run(ctx, engine.Version()); err != nil {
			_, _ = fmt.Fprintf(stderr, "email-engine: %v\n", err)
			return 1
		}
		return 0
	case "version", "--version", "-V":
		_, _ = fmt.Fprintf(stdout, "email-engine %s\n", engine.Version())
		return 0
	case "help", "--help", "-h":
		_, _ = fmt.Fprint(stdout, usage)
		return 0
	default:
		_, _ = fmt.Fprintf(stderr, "email-engine: unknown command %q\n\n%s", args[0], usage)
		return 2
	}
}
