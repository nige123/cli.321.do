// Command 321 is the harness-agnostic agent runtime.
package main

import (
	"os"

	"cli.321.do/internal/cli"
)

func main() {
	info, _ := os.Stdin.Stat()
	interactive := info != nil && info.Mode()&os.ModeCharDevice != 0
	os.Exit(cli.Main(cli.Env{
		Stdin:       os.Stdin,
		Stdout:      os.Stdout,
		Stderr:      os.Stderr,
		Args:        os.Args[1:],
		Interactive: interactive,
		Signals:     true,
	}))
}
