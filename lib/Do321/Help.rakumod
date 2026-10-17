unit module Do321::Help;

#| Help a person can hold in their head, and the "what now" line every
#| command ends with.
#|
#| One screen per topic, a handful of lines per screen, one example each,
#| and every screen ends with `Next:` and an `e.g.` that can be typed as
#| it stands.  The whole reference still exists (`321 help all`); it is
#| simply not the first thing anyone sees.
#|
#| Examples are built from what is configured on this machine (the first
#| alias in the trust file) so they are the person's own commands.  When
#| nothing is configured the examples use `helper`, the unbranded fixture
#| name, never an official agent: the runtime hard-codes no agent name.

#| The topics `321 help <topic>` knows, in the order they are offered.
constant TOPICS = (
    ('ask',      'the request line, its options, steering a run'),
    ('receipt',  'reading the result: statuses, Next lines, exit codes'),
    ('agents',   'configuring agents: ~/.321/trust.json, aliases, --package-dir'),
    ('deploy',   'deployments: the dp tool, plans, approvals, DP_EXECUTE'),
    ('run',      'machine invocation: 321 run over NDJSON'),
    ('harness',  'IZ4 inside a harness: 321 iz4, 321 harness, 321 hook'),
    ('packages', 'checking and digesting agent packages'),
    ('options',  'every option that goes before the agent name'),
    ('all',      'the whole reference on one screen'),
);

#| The longest a help screen may be, in lines.  A test holds every topic
#| to it; the limit is what a person can take in at once, not a layout.
constant SCREEN-LINES is export = 24;

sub topic-names(--> List) is export { TOPICS.map(*[0]).List }

#| "Next: <advice>" on one line and "e.g.  <command>" indented beneath it.
sub next-text(Str $advice, Str $example --> Str) is export {
    "Next: $advice\n      e.g.  $example";
}

#| The agent name used in examples: the first configured alias, else the
#| first configured id, else the unbranded `helper`.
sub example-agent(%ctx --> Str) is export {
    my @a = @(%ctx<agents> // []);
    @a ?? @a[0].Str !! 'helper';
}

#| The full reference, kept whole for `321 help all` and for anyone who
#| prefers one long screen.  Everything shorter is drawn from it.
constant REFERENCE is export = q:to/END/;
    321 - run an agent

      321 <agent> <request...>            ask a configured agent to do something here
      321 <publisher>/<agent> <request>   the same, by canonical id
      321 <agent> -                       the request from standard input, to its end

    Options before the agent:
      --workspace <dir>       where the work happens (default: the enclosing git repo, else none)
      --package-dir <dir>     load an unsigned local package from a directory (identity local/<name>)
      --attach <file>         make a file available to the agent (repeatable)
      --done <condition>      a completion condition, in order (repeatable)
      --grant <capability>    grant an optional capability within local policy (repeatable)
      --placement client|server|either
      --network none|provider_only|open
                              the agent's own network access (default: local policy, else provider_only).
                              shell.run does not imply network: with a shell granted and no open
                              network, no adapter that cannot deny the network will be selected
      --adapter <name>        insist on one adapter
      --non-interactive       never read steering from the terminal
      --json                  print events as JSON lines instead of a transcript
      --trust <file>          trust configuration (default ~/.321/trust.json)

    Machine invocation:
      321 run --package <file|-> [--workspace <dir>] [--receipt <file>] [--events <file>]
              [--run-id <id>] [--history-dir <dir>] [--adapter <name>] [--package-dir <dir>]
              [--continue <receipt.json>]   continue a blocked run of the SAME package: cost and
                                            attempts carry forward, the old receipt is linked
          stdin:  the work package (when --package -), then work directives, one JSON object per line
          stdout: run events, then exactly one run receipt; a protocol error when no package can be identified

    Inspection:
      321 agents                    configured packages, their trust and aliases
      321 packages validate <dir>   check a package directory against agent-package.v1
      321 packages digest <dir> [--write]
      321 packages builtin prompt   write the built-in prompt-only package under ~/.321/packages and print its path
      321 trust show | check
      321 doctor [--json]           installed adapters and what each actually enforces, and bound tools
      321 key [new]                 this 321's receipt-signing key: show it, or make one
      321 receipt verify <file> [--key <base64>]
                                    a receipt's digest against its content, its signature against a key

    Harnesses and what protects the work in them:
      321 harness detect [--workspace <dir>] [--json]
                                    the agent environments 321 knows, whether each is here,
                                    and the controls it lets a controller operate
      321 iz4 status  [--workspace <dir>] [--harness <name>] [--json]
                                    how strongly the project's IZ4 is enforced in a harness
      321 iz4 install [--workspace <dir>] [--harness <name>] [--advisory] [--json]
                                    wire IZ4 into the harness, as strongly as it allows, and
                                    verify the wiring; installing again changes nothing.
                                    --advisory wires only the context: nothing is refused
      321 iz4 remove  [--workspace <dir>] [--harness <name>] [--json]
                                    take out only what 321 installed for IZ4
      321 hook <harness> <controller> <control>
                                    the glue a harness calls: native event in, the
                                    controller's verdict out in the harness's own terms

    Harness hooks, the older form (for a hook command such as 'iz4 hook'):
      321 hooks status|remove --workspace <dir> --command <cmd> [--json]   (older direct wiring; install is refused)
                                    wire <cmd> session-start|pre-edit|stop into every harness
                                    321 knows, in that workspace; --strict wires the two that refuse
      321 hooks status  --workspace <dir> --command <cmd> [--json]
      321 hooks remove  --workspace <dir> --command <cmd> [--json]

    Tool bindings (procedures only, by explicit path, never by PATH lookup):
      DP_BIN             the deployment engine entry point a package's dp
                                    tool steps may call: status (deploy.read), plan (deploy.plan)
                                    and execute (deploy.invoke)
      DP_EXECUTE         comma-separated targets on which an approved execute may run;
                                    unset, execute is not performed
      321 version | help [<topic>]

    Exit codes: 0 completed or no change, 2 blocked, 3 stopped, 4 failed, 5 denied,
    64 usage, 65 malformed input, 70 internal error.
    END

#| The first screen: what 321 is in one line, the three commands most days
#| need, and where the rest of the help is.
sub overview(%ctx --> Str) {
    my $a = example-agent(%ctx);
    my @l;
    @l.push('321 - ask an agent to do something here, and get a receipt');
    @l.push('');
    @l.push("  321 <agent> <request...>          e.g.  321 $a status");
    @l.push('');
    @l.push('Most days you need three commands:');
    @l.push('  321 agents                        who you can ask on this machine');
    @l.push('  321 <agent> <request...>          hand them the work; the receipt says what happened');
    @l.push('  321 doctor                        what this machine can run, and what it enforces');
    @l.push('');
    @l.push('More help, one topic at a time:');
    @l.push(sprintf('  321 help %-10s %s', .[0], .[1])) for TOPICS;
    @l.push('');
    @l.push(overview-next(%ctx));
    @l.join("\n") ~ "\n";
}

sub overview-next(%ctx --> Str) {
    return next-text('see who you can ask here', '321 agents') if @(%ctx<agents> // []);
    return next-text('no agent is configured on this machine yet; set one up', '321 help agents')
        unless %ctx<trust-exists>;
    next-text('the trust file names no agent yet; add one', '321 help agents');
}

sub page-ask(%ctx --> Str) {
    my $a = example-agent(%ctx);
    qq:to/END/;
    Asking an agent

      321 <agent> <request...>            e.g.  321 $a note: remember the milk
      321 <publisher>/<agent> <request>   the same agent, by its full id
      321 <agent> -                       a long request from standard input, to its end

    While it runs at a terminal: type to steer, /pause, /resume, /stop; Ctrl-C stops.
    The request is text. It becomes the work's objective and is never handed to a shell.

    Options go before the agent name (321 help options has them all):
      --workspace <dir>     where the work happens (default: the git repo you are in)
      --done <condition>    what must be true when it finishes (repeatable, in order)
      --attach <file>       a file the agent may read (repeatable)
      --non-interactive     never read steering from the terminal

    {next-text("try a small request and read the receipt", "321 $a note: remember the milk")}
    END
}

sub page-receipt(%ctx --> Str) {
    my $body = q:to/END/;
    Reading the result

    Every run ends with one word in capitals, the detail, then a Next line:
      COMPLETED  done; the conditions you gave are ticked ✓ or crossed ✗
      BLOCKED    it needs an answer from you, or a step it may not take itself
      FAILED     it tried and could not; the ! lines say why
      DENIED     local policy or the package refused before anything ran
      STOPPED    you stopped it, or a signal did

    Lines you will see:
      Changed:   files the agent edited; it never commits, you do
      Tool:      an external call, with the exact arguments used
      Proposal:  a deployment plan; a plan is not an approval
      Cost:      what the harness reported; "none" means no model was used
      Receipt:   the whole record, as JSON, for anyone who needs to check;
                 signed over its digest when this 321 has a key (321 key new)

    Exit codes: 0 completed, 2 blocked, 3 stopped, 4 failed, 5 denied,
                64 usage, 65 malformed input, 70 internal error

    END
    $body ~ next-text('open the receipt of your last run', 'ls -t ~/.321/runs | head -1') ~ "\n";
}

sub page-agents(%ctx --> Str) {
    my $body = q:to/END/;
    Configuring agents          (~/.321/trust.json, or --trust <file>)

    An agent is <publisher-domain>/<name>. Short names are aliases you choose.
    Three ways an agent may run here:
      verified     a pinned publisher package whose digest and signature check out
      development  pinned with "trust": "development"; digest checked, no signature
      local        an unsigned local/<name> package, by path

    The smallest trust file:
      { "schema": "trust-config.v1",
        "local":   { "helper": { "path": "/opt/agents/helper" } },
        "aliases": { "helper": "local/helper" } }

    Without a trust file at all:   321 --package-dir <dir> <name> <request...>
    Check what you have:           321 trust check        List it:   321 agents

    END
    $body ~ next-text('check the trust file loads every agent it names', '321 trust check') ~ "\n";
}

sub page-deploy(%ctx --> Str) {
    my $a = example-agent(%ctx);
    my $bound = %ctx<dp-bound> ?? "bound here ({%ctx<dp-bin>})" !! 'not bound here, so every deploy step will fail saying so';
    my $exec = (%ctx<dp-execute> // '') ne '' ?? "enabled for {%ctx<dp-execute>}" !! 'unset, so nothing deploys from this machine';
    qq:to/END/;
    Deployments          (an agent's procedures call the dp tool; nothing is found by PATH lookup)

      DP_BIN=/path/to/dp       the deployment engine
      DP_EXECUTE=dev,live      targets where a go may actually run
    On this machine: dp is $bound;
                     execute is $exec.

    What the tool can do, and the grant each operation needs:
      status    deploy.read     what is running
      plan      deploy.plan     an exact, checkable plan; a plan is not an approval
      execute   deploy.invoke   the deployment itself, only against an approved plan

    At a terminal, typing the go IS your approval: 321 plans first, binds an approval
    to that exact plan, checks nothing moved since, then executes where DP_EXECUTE allows.

      e.g.  321 $a plan app.web live        then, if the plan is what you want:
            321 $a go app.web live

    {next-text("look before anything moves", "321 $a status")}
    END
}

sub page-run(%ctx --> Str) {
    my $body = q:to/END/;
    Machine invocation          (for a work system; a person types 321 <agent> <request...>)

      321 run --package <file|->  [--workspace <dir>] [--receipt <file>] [--events <file>]
              [--run-id <id>] [--history-dir <dir>] [--adapter <name>] [--package-dir <dir>]
        stdin:   the WorkPackage (with --package -), then directives, one JSON object per line
        stdout:  run events, then exactly one RunReceipt

      321 run --continue <receipt.json> --package <the same package>
               continue a blocked run: cost and attempts carry forward, the old receipt is linked

    The package is immutable once issued; a material change is a new package that
    names the old one. Schemas: schemas/*.v1.json in the runtime repository.

    END
    $body ~ next-text('validate a package before issuing it', '321 packages validate ./my-package') ~ "\n";
}

sub page-harness(%ctx --> Str) {
    my $body = q:to/END/;
    IZ4 inside a harness

      321 harness detect [--workspace <dir>]       the agent environments 321 knows, which are here
      321 iz4 status  [--workspace <dir>]          how strongly the project's IZ4 is enforced there
      321 iz4 install [--workspace <dir>]          wire IZ4 in, as strongly as the harness allows
      321 iz4 remove  [--workspace <dir>]          take out only what 321 installed
      321 hook <harness> <controller> <control>    the glue a harness calls; not typed by hand

    Add --json to any of them for a machine-readable answer.
    (321 hooks ... is the older direct wiring; only status and remove remain.)

    END
    $body ~ next-text('see which harnesses are on this machine first', '321 harness detect') ~ "\n";
}

sub page-packages(%ctx --> Str) {
    my $body = q:to/END/;
    Agent packages          (a directory with agent.json, a DIGEST, and optionally a SIGNATURE)

      321 packages validate <dir>          check it against agent-package.v1
      321 packages digest <dir>            print its content digest
      321 packages digest <dir> --write    write the DIGEST file
      321 packages show <id>               what a configured package declares
      321 packages builtin prompt          write the built-in prompt-only package; print its path

    Loading a package never runs anything in it and never installs anything.

    END
    $body ~ next-text('validate the package you are working on', '321 packages validate ./my-package') ~ "\n";
}

sub page-options(%ctx --> Str) {
    my $a = example-agent(%ctx);
    qq:to/END/;
    Options          (all of them go before the agent name)

      --workspace <dir>       where the work happens (default: the enclosing git repo, else none)
      --package-dir <dir>     an unsigned local package from a directory (identity local/<name>)
      --attach <file>         make a file available to the agent (repeatable)
      --done <condition>      a completion condition, in order (repeatable)
      --grant <capability>    grant an optional capability, within local policy (repeatable)
      --placement client|server|either
      --network none|provider_only|open
                              the agent's own network access; shell.run never implies it
      --adapter <name>        insist on one adapter
      --non-interactive       never read steering from the terminal
      --json                  events as JSON lines instead of a transcript
      --trust <file>          trust configuration (default ~/.321/trust.json)

    {next-text("name a condition and let the receipt tick it", "321 --done 'a note exists' $a note: remember the milk")}
    END
}

sub page-all(%ctx --> Str) {
    REFERENCE ~ "\n" ~ next-text('come back to one topic at a time', '321 help') ~ "\n";
}

#| The screen for a topic, or the overview for none.  An unknown topic
#| gets the list of topics, not a wall.
sub help-page(Str $topic, %ctx --> Str) is export {
    given $topic {
        when ''         { overview(%ctx) }
        when 'ask'      { page-ask(%ctx) }
        when 'receipt'  { page-receipt(%ctx) }
        when 'agents'   { page-agents(%ctx) }
        when 'deploy'   { page-deploy(%ctx) }
        when 'run'      { page-run(%ctx) }
        when 'harness'  { page-harness(%ctx) }
        when 'packages' { page-packages(%ctx) }
        when 'options'  { page-options(%ctx) }
        when 'all'      { page-all(%ctx) }
        default         { Str }
    }
}

#| What `321 help <unknown>` says: the topics, and the way back.
sub unknown-topic(Str $topic --> Str) is export {
    my @l = "321 help: no topic \"$topic\". The topics are:";
    @l.push(sprintf('  321 help %-10s %s', .[0], .[1])) for TOPICS;
    @l.push('');
    @l.push(next-text('start from the first screen', '321 help'));
    @l.join("\n") ~ "\n";
}

# ------------------------------------------------------------ after a run

#| The Next line for a finished run, from the receipt and what was typed.
#| It names a real next step for this outcome, in the person's own terms:
#| their agent alias, their request, the service and target the tool saw.
#| It never claims more than the receipt shows: a plan stays a plan, and
#| execution that is not enabled here is said to be not enabled here.
sub next-after-run(%r, Str :$invocation, Str :$prefix, Str :$workspace = '', Bool :$dp-bound = False, Str :$dp-execute = '' --> Str) is export {
    my $status = %r<status> // '';
    my @calls = @(%r<evidence><toolCalls> // []);
    my %p = (%r<evidence><proposal> // {}).Hash;
    my ($service, $target) = ((%p<service> // ''), (%p<target> // ''));
    my @allowed = $dp-execute.split(',').map(*.trim).grep(* ne '');
    my $deployed = %r<evidence><externalAction>.defined;
    my $not-performed = so @calls.grep({ (.<unavailable> // '') ne '' });

    if $status eq 'completed' || $status eq 'no_change' {
        my @files = @(%r<evidence><filesChanged> // []);
        if @files && $workspace ne '' {
            return next-text('review the changes, then commit them yourself; 321 never commits', "git -C $workspace diff");
        }
        if $deployed && $service ne '' {
            return next-text('check it is serving as you expect', "$prefix status $service $target");
        }
        if %p && %p<status> eq 'planned' && $service ne '' {
            return $target ∈ @allowed
                ?? next-text('if this plan is what you want deployed, type the go; typing it is your approval', "$prefix go $service $target")
                !! next-text("nothing will deploy from here: $target is not in DP_EXECUTE on this machine", "DP_EXECUTE=$target $prefix go $service $target");
        }
        if @calls.grep({ .<tool> eq 'dp' && .<op> eq 'status' && .<ok> }) {
            return next-text('name a service and a target to get an exact plan', "$prefix plan <service> <target>");
        }
        return next-text('ask for the next step the same way', "$prefix <request...>");
    }
    if $status eq 'blocked' {
        if $not-performed {
            return $target ne ''
                ?? next-text("nothing was deployed: executing on $target is not enabled on this machine (DP_EXECUTE)", "DP_EXECUTE=$target $invocation")
                !! next-text('nothing was performed: that step is not enabled on this machine', '321 help deploy');
        }
        my $q = (%r<blockedOn> // '').Str;
        return next-text("answer it in a new request: $q", "$invocation <answer>") if $q ne '';
        return next-text('it needs something it may not take itself; the lines above say what', '321 help receipt');
    }
    if $status eq 'failed' {
        my @errs = @(%r<evidence><errors> // []);
        return next-text('bind the deployment engine, then ask again', "DP_BIN=/path/to/dp $invocation")
            if @errs.grep(*.contains('DP_BIN'));
        return next-text('fix what the ! lines name, then ask again', $invocation);
    }
    if $status eq 'denied' {
        return next-text('see what this machine enforces against what the package needs', '321 doctor');
    }
    if $status eq 'stopped' {
        return next-text('ask again when ready', $invocation);
    }
    next-text('read the receipt', '321 help receipt');
}
