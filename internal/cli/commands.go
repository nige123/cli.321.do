package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"cli.321.do/internal/digest"
	"cli.321.do/internal/protocol"
	"cli.321.do/internal/trust"
	"cli.321.do/internal/wire"
)

func cmdAgents(env Env, g global) int {
	cfg, err := env.trust()
	if err != nil {
		fmt.Fprintln(env.Stderr, "321:", err)
		return wire.ExitInternal
	}
	list := cfg.Configured()
	if len(list) == 0 {
		fmt.Fprintf(env.Stdout, "No agents are configured in %s.\n", cfg.Path())
		fmt.Fprintln(env.Stdout, "Add a pinned publisher package or a local package there, or use --package-dir <dir> for an unsigned local package.")
		return 0
	}
	for _, r := range list {
		alias := ""
		if r.Alias != "" {
			alias = "  alias " + r.Alias
		}
		version := ""
		if r.Pin != nil {
			version = "  " + r.Pin.Version
		}
		fmt.Fprintf(env.Stdout, "%-32s %-12s%s%s\n", r.ID, r.Level, version, alias)
	}
	return 0
}

func cmdPackages(env Env, args []string) int {
	if len(args) < 2 {
		fmt.Fprintln(env.Stderr, "usage: 321 packages validate <dir> | digest <dir> [--write] | show <id>")
		return wire.ExitUsage
	}
	switch args[0] {
	case "validate":
		m, d, err := trust.ValidatePackage(args[1])
		if err != nil {
			fmt.Fprintln(env.Stdout, "INVALID:", err)
			return wire.ExitFailed
		}
		fmt.Fprintf(env.Stdout, "OK %s %s %s\n", m.ID, m.Version, d)
		return 0
	case "digest":
		d, entries, err := digest.Compute(args[1])
		if err != nil {
			fmt.Fprintln(env.Stderr, "321:", err)
			return wire.ExitFailed
		}
		write := len(args) > 2 && args[2] == "--write"
		if write {
			if err := digest.WriteDigestFile(args[1], d); err != nil {
				fmt.Fprintln(env.Stderr, "321:", err)
				return wire.ExitFailed
			}
		}
		fmt.Fprintf(env.Stdout, "%s (%d files)\n", d, len(entries))
		return 0
	case "show":
		cfg, err := env.trust()
		if err != nil {
			fmt.Fprintln(env.Stderr, "321:", err)
			return wire.ExitInternal
		}
		res, err := cfg.Resolve(args[1])
		if err != nil {
			fmt.Fprintln(env.Stderr, "321:", err)
			return wire.ExitDenied
		}
		l, err := trust.LoadResolved(res)
		if err != nil {
			fmt.Fprintln(env.Stderr, "321:", err)
			return wire.ExitDenied
		}
		m := l.Manifest
		fmt.Fprintf(env.Stdout, "%s  %s  %s\n", m.ID, m.Version, l.Digest)
		fmt.Fprintf(env.Stdout, "trust:      %s\n", l.Label)
		fmt.Fprintf(env.Stdout, "publisher:  %s   owner: %s   licence: %s\n", m.Publisher.Domain, m.Owner.LegalName, strings.TrimSpace(m.Licence.SPDX+" "+m.Licence.URL))
		fmt.Fprintf(env.Stdout, "role:       %s\n", m.Identity.Role)
		fmt.Fprintf(env.Stdout, "requires:   %s\n", strings.Join(m.Capabilities.Required, ", "))
		fmt.Fprintf(env.Stdout, "optional:   %s\n", strings.Join(m.Capabilities.Optional, ", "))
		fmt.Fprintf(env.Stdout, "denied:     %s\n", strings.Join(m.Capabilities.Denied, ", "))
		fmt.Fprintf(env.Stdout, "enforce:    %s\n", strings.Join(m.Harness.Requires, ", "))
		fmt.Fprintf(env.Stdout, "placement:  %s\n", strings.Join(m.Placement.Allowed, ", "))
		if len(m.Procedures) > 0 {
			var names []string
			for _, p := range m.Procedures {
				names = append(names, p.Name)
			}
			fmt.Fprintf(env.Stdout, "procedures: %s\n", strings.Join(names, ", "))
		}
		return 0
	}
	fmt.Fprintln(env.Stderr, "usage: 321 packages validate <dir> | digest <dir> [--write] | show <id>")
	return wire.ExitUsage
}

func cmdTrust(env Env, args []string) int {
	cfg, err := env.trust()
	if err != nil {
		fmt.Fprintln(env.Stderr, "321:", err)
		return wire.ExitFailed
	}
	sub := "show"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "show":
		fmt.Fprintf(env.Stdout, "trust file: %s\n", cfg.Path())
		doms := make([]string, 0, len(cfg.Publishers))
		for d := range cfg.Publishers {
			doms = append(doms, d)
		}
		sort.Strings(doms)
		for _, d := range doms {
			p := cfg.Publishers[d]
			fmt.Fprintf(env.Stdout, "publisher %s: %d key(s)\n", d, len(p.Keys))
			for _, k := range p.Keys {
				fmt.Fprintf(env.Stdout, "  key %s %s\n", k.KeyID, k.Note)
			}
			names := make([]string, 0, len(p.Packages))
			for n := range p.Packages {
				names = append(names, n)
			}
			sort.Strings(names)
			for _, n := range names {
				pin := p.Packages[n]
				level := pin.Trust
				if level == "" {
					level = trust.LevelVerified
				}
				fmt.Fprintf(env.Stdout, "  %s/%s %s %s %s\n", d, n, pin.Version, level, pin.Path)
			}
		}
		names := make([]string, 0, len(cfg.Local))
		for n := range cfg.Local {
			names = append(names, n)
		}
		sort.Strings(names)
		for _, n := range names {
			fmt.Fprintf(env.Stdout, "local/%s %s\n", n, cfg.Local[n].Path)
		}
		aliases := make([]string, 0, len(cfg.Aliases))
		for a := range cfg.Aliases {
			aliases = append(aliases, a)
		}
		sort.Strings(aliases)
		for _, a := range aliases {
			fmt.Fprintf(env.Stdout, "alias %s -> %s\n", a, cfg.Aliases[a])
		}
		return 0
	case "check":
		problems := 0
		for _, r := range cfg.Configured() {
			rr := r
			if _, err := trust.LoadResolved(&rr); err != nil {
				fmt.Fprintf(env.Stdout, "FAIL %s: %v\n", r.ID, err)
				problems++
				continue
			}
			fmt.Fprintf(env.Stdout, "ok   %s (%s)\n", r.ID, r.Level)
		}
		if problems > 0 {
			return wire.ExitFailed
		}
		return 0
	}
	fmt.Fprintln(env.Stderr, "usage: 321 trust show | check")
	return wire.ExitUsage
}

func cmdDoctor(env Env) int {
	fmt.Fprintln(env.Stdout, "adapters and what each actually enforces:")
	features := protocol.Features()
	for _, a := range env.Adapters.All() {
		det := a.Detect()
		state := "unavailable: " + det.Reason
		if det.Available {
			state = "available " + det.Version
		}
		fmt.Fprintf(env.Stdout, "  %-12s %s\n", a.Name(), state)
		enf := a.Enforcement()
		var yes, no []string
		for _, f := range features {
			if enf.Enforces(f) {
				yes = append(yes, f)
			} else {
				no = append(no, f)
			}
		}
		fmt.Fprintf(env.Stdout, "      enforces:     %s\n", strings.Join(yes, ", "))
		if len(no) > 0 {
			fmt.Fprintf(env.Stdout, "      not enforced: %s\n", strings.Join(no, ", "))
		}
	}
	cfg, err := env.trust()
	if err != nil {
		fmt.Fprintln(env.Stdout, "trust:", err)
		return wire.ExitFailed
	}
	if _, statErr := os.Stat(cfg.Path()); statErr != nil {
		fmt.Fprintf(env.Stdout, "trust: no file at %s (only --package-dir packages can run)\n", cfg.Path())
	} else {
		fmt.Fprintf(env.Stdout, "trust: %s, %d configured package(s)\n", cfg.Path(), len(cfg.Configured()))
	}
	if b, err := json.Marshal(cfg.Policy); err == nil {
		fmt.Fprintf(env.Stdout, "policy: %s\n", b)
	}
	return 0
}
