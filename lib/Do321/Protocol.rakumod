unit module Do321::Protocol;

#| The public 321 protocols: schema names, vocabularies, identity
#| parsing, ULIDs, timestamps, the validators, and the digests every
#| other module relies on.  The JSON Schema documents under schemas/ are
#| the canonical human-facing definition; the validators here enforce the
#| same rules for the runtime and are pinned to those documents by tests.
#|
#| Nothing here knows about any work system.  Correlation references are
#| opaque strings that are echoed back verbatim.

use Data::Native;
use Do321::JSON;
use Do321::Shape;

# --------------------------------------------------------------- names

constant SCHEMA-AGENT-PACKAGE       is export = 'agent-package.v1';
constant SCHEMA-WORK-PACKAGE        is export = 'work-package.v1';
constant SCHEMA-WORK-DIRECTIVE      is export = 'work-directive.v1';
constant SCHEMA-RUN-EVENT           is export = 'run-event.v1';
constant SCHEMA-RUN-RECEIPT         is export = 'run-receipt.v1';
constant SCHEMA-PROTOCOL-ERROR      is export = 'protocol-error.v1';
constant SCHEMA-DEPLOYMENT-PROPOSAL is export = 'deployment-proposal.v1';
constant SCHEMA-TRUST-CONFIG        is export = 'trust-config.v1';

# Capability vocabulary.  deploy.read and deploy.plan are the read-only
# halves of deployment authority; only deploy.invoke performs one.
constant CAP-REPO-READ     is export = 'repo.read';
constant CAP-REPO-WRITE    is export = 'repo.write';
constant CAP-SHELL-RUN     is export = 'shell.run';
constant CAP-NET-FETCH     is export = 'net.fetch';
constant CAP-FILES-READ    is export = 'files.read';
constant CAP-FILES-WRITE   is export = 'files.write';
constant CAP-MODEL-TEXT    is export = 'model.text';
constant CAP-DEPLOY-INVOKE is export = 'deploy.invoke';
constant CAP-DEPLOY-READ   is export = 'deploy.read';
constant CAP-DEPLOY-PLAN   is export = 'deploy.plan';

sub capabilities(--> List) is export {
    (CAP-REPO-READ, CAP-REPO-WRITE, CAP-SHELL-RUN, CAP-NET-FETCH, CAP-FILES-READ, CAP-FILES-WRITE,
     CAP-MODEL-TEXT, CAP-DEPLOY-INVOKE, CAP-DEPLOY-READ, CAP-DEPLOY-PLAN);
}

# Enforcement features an adapter may honestly claim.
constant FEAT-TOOL-ALLOWLIST    is export = 'tool_allowlist';
constant FEAT-REPO-SCOPE        is export = 'repo_scope';
constant FEAT-NETWORK-DENY      is export = 'network_deny';
constant FEAT-STRUCTURED-OUTPUT is export = 'structured_output';
constant FEAT-TURN-LIMIT        is export = 'turn_limit';
constant FEAT-SPEND-LIMIT       is export = 'spend_limit';
constant FEAT-TIMEOUT           is export = 'timeout';
constant FEAT-EVENT-STREAM      is export = 'event_stream';
constant FEAT-LIVE-STEER        is export = 'live_steer';
constant FEAT-PAUSE             is export = 'pause';
constant FEAT-SESSION-CONTINUE  is export = 'session_continue';
constant FEAT-GRACEFUL-STOP     is export = 'graceful_stop';

sub features(--> List) is export {
    (FEAT-TOOL-ALLOWLIST, FEAT-REPO-SCOPE, FEAT-NETWORK-DENY, FEAT-STRUCTURED-OUTPUT, FEAT-TURN-LIMIT,
     FEAT-SPEND-LIMIT, FEAT-TIMEOUT, FEAT-EVENT-STREAM, FEAT-LIVE-STEER, FEAT-PAUSE,
     FEAT-SESSION-CONTINUE, FEAT-GRACEFUL-STOP);
}

constant NETWORK-NONE          is export = 'none';
constant NETWORK-PROVIDER-ONLY is export = 'provider_only';
constant NETWORK-OPEN          is export = 'open';

constant PLACEMENT-CLIENT is export = 'client';
constant PLACEMENT-SERVER is export = 'server';
constant PLACEMENT-EITHER is export = 'either';

constant DIRECTIVE-CLARIFY is export = 'clarify';
constant DIRECTIVE-STEER   is export = 'steer';
constant DIRECTIVE-PAUSE   is export = 'pause';
constant DIRECTIVE-RESUME  is export = 'resume';
constant DIRECTIVE-STOP    is export = 'stop';

constant STATUS-COMPLETED is export = 'completed';
constant STATUS-NO-CHANGE is export = 'no_change';
constant STATUS-BLOCKED   is export = 'blocked';
constant STATUS-FAILED    is export = 'failed';
constant STATUS-STOPPED   is export = 'stopped';
constant STATUS-DENIED    is export = 'denied';

constant EVENT-STARTED             is export = 'started';
constant EVENT-ADAPTER-SELECTED    is export = 'adapter_selected';
constant EVENT-PROCEDURE-SELECTED  is export = 'procedure_selected';
constant EVENT-ATTEMPT-STARTED     is export = 'attempt_started';
constant EVENT-ATTEMPT-ENDED       is export = 'attempt_ended';
constant EVENT-TOOL-CALL           is export = 'tool_call';
constant EVENT-TOOL-RESULT         is export = 'tool_result';
constant EVENT-PROGRESS            is export = 'progress';
constant EVENT-DIRECTIVE-RECEIVED  is export = 'directive_received';
constant EVENT-DIRECTIVE-APPLIED   is export = 'directive_applied';
constant EVENT-DIRECTIVE-REJECTED  is export = 'directive_rejected';
constant EVENT-DIRECTIVE-DUPLICATE is export = 'directive_duplicate';
constant EVENT-PAUSED              is export = 'paused';
constant EVENT-RESUMED             is export = 'resumed';
constant EVENT-STOPPING            is export = 'stopping';
constant EVENT-COST                is export = 'cost';
constant EVENT-DENIED              is export = 'denied';

constant COST-NONE       is export = 'none';
constant COST-HARNESS    is export = 'harness';
constant COST-UNREPORTED is export = 'unreported';
constant COST-MIXED      is export = 'mixed';

# ------------------------------------------------------------- identity

#| The pseudo-publisher for unsigned packages that belong to nobody in
#| particular: "local/helper".  Never a verified identity.
constant LOCAL-DOMAIN is export = 'local';

class X::Do321::Protocol is Exception is export {
    has Str $.message;
}

sub protocol-error(Str $m) { X::Do321::Protocol.new(message => $m).throw }

#| The directories on PATH, split on the platform's separator.
sub path-dirs(--> List) is export {
    (%*ENV<PATH> // '').split($*DISTRO.is-win ?? ';' !! ':').grep(* ne '').map(*.IO).List;
}

#| The executable of that name on PATH, or IO::Path:U.
sub on-path(Str $name --> IO::Path) is export {
    for path-dirs() -> $d {
        for ($name, |($*DISTRO.is-win ?? ("$name.exe", "$name.cmd", "$name.bat") !! ())) -> $n {
            my $f = $d.add($n);
            return $f if $f.f && ($*DISTRO.is-win || $f.x);
        }
    }
    IO::Path;
}

#| Whether $inner is $outer or lies below it, comparing resolved paths
#| with the platform's separator.
sub within(IO::Path $inner, IO::Path $outer --> Bool) is export {
    my $sep = $*SPEC.dir-sep;
    $inner.Str eq $outer.Str || $inner.Str.starts-with($outer.Str ~ $sep);
}

#| Membership without a junction: under Raku++, `$x eq any()` over an
#| empty list is True, so every membership test goes through this.
sub is-in($x, @list --> Bool) is export { so @list.grep({ $_ eq $x }) }

sub is-agent-name(Str $s --> Bool) is export { so $s ~~ m:P5/^[a-z0-9]{2,32}$/ }
sub is-domain(Str $s --> Bool) is export {
    so $s ~~ m:P5/^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;
}
sub is-version(Str $s --> Bool) is export { so $s ~~ m:P5/^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$/ }
sub is-digest(Str $s --> Bool) is export { so $s ~~ m:P5/^sha256:[0-9a-f]{64}$/ }
sub is-ulid(Str $s --> Bool) is export { so $s ~~ m:P5/^[0-9A-HJKMNP-TV-Z]{26}$/ }

#| A parsed canonical identity: publisher domain plus name.
class AgentID is export {
    has Str $.domain;
    has Str $.name;
    method Str { "$!domain/$!name" }
    method is-local(--> Bool) { $!domain eq LOCAL-DOMAIN }
}

#| Parse "<domain>/<name>".  The runtime is format-neutral: it checks
#| shape only.  Naming policy belongs to the systems that seat packages.
sub parse-agent-id(Str $s --> AgentID) is export {
    my $i = $s.rindex('/');
    protocol-error("agent id \"$s\" must be <publisher-domain>/<name>")
        unless $i.defined && $i > 0 && $i < $s.chars - 1;
    my ($dom, $name) = $s.substr(0, $i), $s.substr($i + 1);
    protocol-error("agent name \"$name\" must be 2 to 32 lowercase letters or digits") unless is-agent-name($name);
    protocol-error("publisher \"$dom\" is not a domain name") unless $dom eq LOCAL-DOMAIN || is-domain($dom);
    AgentID.new(:domain($dom), :$name);
}

# ------------------------------------------------------------- time

#| The current UTC time in the format every timestamp uses (RFC 3339 with
#| the fraction trimmed of trailing zeros, as Go's RFC3339Nano writes it).
sub now-stamp(--> Str) is export {
    my $s = DateTime.now.utc.Str;
    $s ~~ s/ (\.\d*?) 0+ Z $/$0Z/;
    $s ~~ s/ \. Z $/Z/;
    $s;
}

#| Parse a protocol timestamp; throws on anything that is not RFC 3339.
sub parse-time(Str $s --> DateTime) is export {
    protocol-error("empty timestamp") if $s eq '';
    protocol-error("must be an RFC 3339 timestamp")
        unless $s ~~ m:P5/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/;
    my $dt = try DateTime.new($s);
    protocol-error("must be an RFC 3339 timestamp") without $dt;
    $dt;
}

sub is-timestamp(Str $s --> Bool) is export { so try parse-time($s) }

#| Go duration strings ("30m", "1h30m", "500ms", "1.5s") in seconds.
#| Throws on anything else, including the empty string.
sub parse-duration(Str $s --> Numeric) is export {
    protocol-error("invalid duration \"$s\"") if $s eq '';
    return 0 if $s ~~ m:P5/^[-+]?0$/;
    my $neg = $s.starts-with('-');
    my $rest = $s.subst(/^<[-+]>/, '');
    protocol-error("invalid duration \"$s\"") if $rest eq '';
    my %unit = ns => 1e-9, us => 1e-6, 'µs' => 1e-6, 'μs' => 1e-6, ms => 1e-3, s => 1, m => 60, h => 3600;
    my $total = 0;
    while $rest ne '' {
        $rest ~~ m:P5/^([0-9]*(?:\.[0-9]*)?)(ns|us|µs|μs|ms|s|m|h)/
            or protocol-error("invalid duration \"$s\"");
        my ($num, $unit) = $0.Str, $1.Str;
        protocol-error("invalid duration \"$s\"") if $num eq '' || $num eq '.';
        $total += $num.Numeric * %unit{$unit};
        $rest = $rest.substr($/.chars);
    }
    $neg ?? -$total !! $total;
}

sub is-duration(Str $s --> Bool) is export { so try { parse-duration($s); True } }

# ------------------------------------------------------------- ULIDs

my constant CROCKFORD = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

#| A 26-character ULID: 48 bits of millisecond time and 80 bits of
#| randomness, so ids sort by creation and never collide in practice.
sub new-ulid(--> Str) is export {
    my Int $ms = (now-ms());
    my Int $n = $ms +& ((1 +< 48) - 1);
    my $rand = crypt_random_buf(10);
    for @$rand -> $b { $n = ($n +< 8) +| $b }
    my @out;
    for (0..25).reverse -> $i {
        @out[$i] = CROCKFORD.substr($n +& 31, 1);
        $n +>= 5;
    }
    @out.join;
}

sub now-ms(--> Int) { (DateTime.now.Instant.to-posix[0] * 1000).Int }

# ------------------------------------------------------------ problems

#| One validation finding, addressed by a JSON-pointer-ish path.
class Problem is export {
    has Str $.path;
    has Str $.message;
    method Str { "$!path: $!message" }
}

#| A list of findings that renders as one message.
class Problems is export {
    has Problem @.list;
    method add(Str $path, Str $message) { @!list.push(Problem.new(:$path, :$message)) }
    method elems { @!list.elems }
    method Bool { so @!list }
    method Str { @!list ?? @!list.map(*.Str).join('; ') !! 'valid' }
    method message { self.Str }
    method require(Str $path, Str $value --> Bool) {
        if $value.trim eq '' { self.add($path, 'is required'); return False }
        True;
    }
    method schema(Str $path, Str $got, Str $want) {
        self.add($path, "must be \"$want\" (got \"$got\")") unless $got eq $want;
    }
    method timestamp(Str $path, Str $value, Bool $required) {
        if $value eq '' { self.add($path, 'is required') if $required; return }
        self.add($path, 'must be an RFC 3339 timestamp') unless is-timestamp($value);
    }
    method vocab(Str $path, @values, @allowed) {
        my %set = @allowed.map({ $_ => True });
        for @values.kv -> $i, $v {
            self.add("$path\[$i]", "unknown value \"$v\"") unless %set{$v};
        }
    }
    method one-of(Str $path, Str $value, *@allowed) {
        return if is-in($value, @allowed);
        self.add($path, "must be one of {@allowed.join(', ')} (got \"$value\")");
    }
}

#| A path inside a package or workspace: relative, no backslashes, no "."
#| or ".." segments, no absolute prefix.
sub safe-rel-path(Str $p --> Bool) is export {
    return False if $p eq '' || $p.starts-with('/') || $p.starts-with('\\') || $p.contains('\\');
    for $p.split('/') -> $seg {
        return False if $seg eq '' || $seg eq '.' || $seg eq '..';
    }
    True;
}

#| Whether a Go regular expression compiles.  Raku++ compiles a Perl-style
#| pattern at match time, so a bad one shows up as a failed match attempt.
sub regex-compiles(Str $pat --> Bool) is export {
    my $ok = try { 'x' ~~ m:P5/$pat/; True };
    so $ok;
}

# ----------------------------------------------------------- validators

my @STEP-KINDS = <emit write assert blocked external_action no_change fail await_directive sleep tool>;

sub validate-step(Problems $c, Str $path, %s) {
    $c.one-of("$path.kind", %s<kind>, |@STEP-KINDS);
    given %s<kind> {
        when 'tool' {
            $c.require("$path.tool", %s<tool>);
            $c.require("$path.op", %s<op>);
            for (%s<params> // {}).kv -> $k, $v {
                $c.add("$path.params.$k", 'tool parameters are strings (a literal, or a {{capture}} from the objective)')
                    unless $v ~~ Str;
            }
        }
        when 'write' {
            $c.add("$path.path", 'must be a safe relative path inside the workspace') unless safe-rel-path(%s<path>);
        }
        when 'assert' {
            $c.add("$path.condition", 'must be a 1-based condition index') if %s<condition> < 1;
        }
        when 'blocked' { $c.require("$path.question", %s<question>) }
        when 'external_action' { $c.require("$path.action", %s<action>) }
        when 'sleep' {
            $c.add("$path.duration", 'must be a Go duration') unless is-duration(%s<duration>);
        }
    }
}

#| Check an agent-package.v1 manifest for shape.  It does not read files;
#| the package loader does that.
sub validate-agent-manifest(%m --> Problems) is export {
    my $c = Problems.new;
    $c.schema('schema', %m<schema>, SCHEMA-AGENT-PACKAGE);
    my $id = try parse-agent-id(%m<id>);
    $c.add('id', $!.message) if $!;
    if $c.require('name', %m<name>) && !is-agent-name(%m<name>) {
        $c.add('name', 'must be 2 to 32 lowercase letters or digits');
    }
    if $id && $id.name ne %m<name> {
        $c.add('name', "must equal the name part of id (\"{$id.name}\")");
    }
    $c.require('displayName', %m<displayName>);
    if $c.require('version', %m<version>) && !is-version(%m<version>) {
        $c.add('version', 'must be a semantic version');
    }
    if $id {
        if $id.is-local {
            $c.add('publisher.domain', 'a local package must not claim a publisher domain')
                if %m<publisher><domain> ne '' && %m<publisher><domain> ne LOCAL-DOMAIN;
        }
        elsif %m<publisher><domain> ne $id.domain {
            $c.add('publisher.domain', "must equal the publisher part of id (\"{$id.domain}\")");
        }
    }
    $c.add('licence', 'needs spdx or url') if %m<licence><spdx> eq '' && %m<licence><url> eq '';
    $c.require('identity.role', %m<identity><role>);
    my @prompts = @(%m<prompts> // []);
    $c.add('prompts', 'at least one prompt file is required') unless @prompts;
    for @prompts.kv -> $i, $p { $c.add("prompts[$i]", 'must be a safe relative path') unless safe-rel-path($p) }
    for @(%m<skills> // []).kv -> $i, $p { $c.add("skills[$i]", 'must be a safe relative path') unless safe-rel-path($p) }
    for @(%m<evaluations> // []).kv -> $i, $p { $c.add("evaluations[$i]", 'must be a safe relative path') unless safe-rel-path($p) }
    my @caps = capabilities();
    $c.vocab('capabilities.required', @(%m<capabilities><required> // []), @caps);
    $c.vocab('capabilities.optional', @(%m<capabilities><optional> // []), @caps);
    $c.vocab('capabilities.denied', @(%m<capabilities><denied> // []), @caps);
    for @(%m<capabilities><required> // []) -> $r {
        for @(%m<capabilities><denied> // []) -> $d {
            $c.add('capabilities', "\"$r\" is both required and denied") if $r eq $d;
        }
    }
    $c.vocab('harness.requires', @(%m<harness><requires> // []), features());
    for (%m<harness><overlays> // {}).kv -> $name, $file {
        $c.add("harness.overlays.$name", 'must be a safe relative path') unless safe-rel-path($file);
    }
    my @allowed = @(%m<placement><allowed> // []);
    $c.add('placement.allowed', 'at least one placement is required') unless @allowed;
    $c.vocab('placement.allowed', @allowed, (PLACEMENT-CLIENT, PLACEMENT-SERVER));
    if $c.require('outputSchemas.default', %m<outputSchemas><default>) && !safe-rel-path(%m<outputSchemas><default>) {
        $c.add('outputSchemas.default', 'must be a safe relative path');
    }
    for (%m<outputSchemas><byProcedure> // {}).kv -> $name, $file {
        $c.add("outputSchemas.byProcedure.$name", 'must be a safe relative path') unless safe-rel-path($file);
    }
    my %seen;
    for @(%m<procedures> // []).kv -> $i, %p {
        my $path = "procedures[$i]";
        if $c.require("$path.name", %p<name>) {
            $c.add("$path.name", "duplicate procedure name \"{%p<name>}\"") if %seen{%p<name>};
            %seen{%p<name>} = True;
        }
        if %p<matches><objectiveRegex> eq '' {
            $c.add("$path.matches", 'objectiveRegex is required');
        }
        elsif !regex-compiles(%p<matches><objectiveRegex>) {
            $c.add("$path.matches.objectiveRegex", 'does not compile');
        }
        $c.vocab("$path.requires", @(%p<requires> // []), @caps);
        my @steps = @(%p<steps> // []);
        $c.add("$path.steps", 'at least one step is required') unless @steps;
        for @steps.kv -> $j, %s { validate-step($c, "$path.steps[$j]", %s) }
    }
    $c;
}

#| Check a work-package.v1 document for shape.
sub validate-work-package(%w --> Problems) is export {
    my $c = Problems.new;
    $c.schema('schema', %w<schema>, SCHEMA-WORK-PACKAGE);
    $c.add('packageId', 'must be a ULID') if $c.require('packageId', %w<packageId>) && !is-ulid(%w<packageId>);
    $c.require('issuer.kind', %w<issuer><kind>);
    $c.require('issuer.id', %w<issuer><id>);
    $c.timestamp('issuedAt', %w<issuedAt>, True);
    $c.timestamp('expiresAt', %w<expiresAt>, False);
    $c.add('supersedesPackageId', 'must be a ULID') if %w<supersedesPackageId> ne '' && !is-ulid(%w<supersedesPackageId>);
    for @(%w<correlation><refs> // []).kv -> $i, %r {
        $c.require("correlation.refs[$i].kind", %r<kind>);
        $c.require("correlation.refs[$i].id", %r<id>);
    }
    if $c.require('agent.id', %w<agent><id>) {
        try parse-agent-id(%w<agent><id>);
        $c.add('agent.id', $!.message) if $!;
    }
    $c.add('agent.version', 'must be a semantic version') if %w<agent><version> ne '' && !is-version(%w<agent><version>);
    $c.add('agent.digest', 'must be sha256:<hex>') if %w<agent><digest> ne '' && !is-digest(%w<agent><digest>);
    $c.one-of('placement', %w<placement>, PLACEMENT-CLIENT, PLACEMENT-SERVER, PLACEMENT-EITHER);
    $c.one-of('workspace.kind', %w<workspace><kind>, 'git', 'none');
    $c.one-of('workspace.ownership', %w<workspace><ownership>, 'caller', 'runtime');
    $c.add('workspace.path', 'is required for a git workspace') if %w<workspace><kind> eq 'git' && %w<workspace><path> eq '';
    $c.require('objective', %w<objective>);
    for @(%w<context><attachments> // []).kv -> $i, %a { $c.require("context.attachments[$i].name", %a<name>) }
    if !%w<completion><conditions>.defined {
        $c.add('completion.conditions', 'is required (an empty list is allowed)');
    }
    for @(%w<completion><conditions> // []).kv -> $i, $cond { $c.require("completion.conditions[$i]", $cond) }
    $c.one-of('completion.landing', %w<completion><landing>, 'commit', 'none') if %w<completion><landing> ne '';
    if !%w<capabilities><granted>.defined {
        $c.add('capabilities.granted', 'is required (an empty list is allowed)');
    }
    $c.vocab('capabilities.granted', @(%w<capabilities><granted> // []), capabilities());
    my %l = %w<capabilities><limits>;
    $c.add('capabilities.limits.maxUsd', 'must not be negative') if %l<maxUsd> < 0;
    $c.add('capabilities.limits.maxTurns', 'must not be negative') if %l<maxTurns> < 0;
    $c.add('capabilities.limits.timeout', 'must be a Go duration') if %l<timeout> ne '' && !is-duration(%l<timeout>);
    $c.one-of('capabilities.limits.network', %l<network>, NETWORK-NONE, NETWORK-PROVIDER-ONLY, NETWORK-OPEN) if %l<network> ne '';
    for @(%w<authority><may> // []).kv -> $i, %g { $c.require("authority.may[$i].capability", %g<capability>) }
    with %w<approval> -> %a {
        $c.require('approval.proposalRef', %a<proposalRef>);
        $c.require('approval.approvalRef', %a<approvalRef>);
        $c.require('approval.approvedBy', %a<approvedBy>);
        $c.require('approval.action', %a<action>);
        if $c.require('approval.paramsHash', %a<paramsHash>) {
            if !is-digest(%a<paramsHash>) {
                $c.add('approval.paramsHash', 'must be sha256:<hex>');
            }
            elsif params-hash(%a<params>) ne %a<paramsHash> {
                $c.add('approval.paramsHash', 'does not match the canonical hash of approval.params');
            }
        }
        with %a<proposal> -> %p {
            for validate-deployment-proposal(%p).list -> $pr {
                $c.add('approval.proposal.' ~ $pr.path, $pr.message);
            }
            my $want = (%a<params> // {})<proposalDigest>;
            if $want ~~ Str && $want ne '' && $want ne %p<proposalDigest> {
                $c.add('approval.proposal.proposalDigest', "is not the digest the approval's params name");
            }
        }
    }
    $c;
}

#| Check a work-directive.v1 frame, including that its digest is the
#| digest of its own content.
sub validate-work-directive(%d --> Problems) is export {
    my $c = Problems.new;
    $c.schema('schema', %d<schema>, SCHEMA-WORK-DIRECTIVE);
    $c.require('directiveId', %d<directiveId>);
    $c.add('packageId', 'must be a ULID') if $c.require('packageId', %d<packageId>) && !is-ulid(%d<packageId>);
    $c.add('seq', 'must be a positive integer') if %d<seq> < 1;
    $c.require('issuer.kind', %d<issuer><kind>);
    $c.require('issuer.id', %d<issuer><id>);
    $c.timestamp('issuedAt', %d<issuedAt>, True);
    $c.one-of('kind', %d<kind>, DIRECTIVE-CLARIFY, DIRECTIVE-STEER, DIRECTIVE-PAUSE, DIRECTIVE-RESUME, DIRECTIVE-STOP);
    $c.require('payload.text', %d<payload><text>) if is-in(%d<kind>, [DIRECTIVE-CLARIFY, DIRECTIVE-STEER]);
    if $c.require('digest', %d<digest>) {
        $c.add('digest', "does not match the directive's content") if directive-digest(%d) ne %d<digest>;
    }
    $c;
}

#| Check a run-event.v1 frame.
sub validate-run-event(%e --> Problems) is export {
    my $c = Problems.new;
    $c.schema('schema', %e<schema>, SCHEMA-RUN-EVENT);
    $c.require('eventId', %e<eventId>);
    $c.require('packageId', %e<packageId>);
    $c.require('runId', %e<runId>);
    $c.add('seq', 'must be a positive integer') if %e<seq> < 1;
    $c.timestamp('at', %e<at>, True);
    $c.require('kind', %e<kind>);
    $c;
}

#| Check a run-receipt.v1 document, including that its digest is the
#| digest of its own content and that conditions are present.
sub validate-run-receipt(%r --> Problems) is export {
    my $c = Problems.new;
    $c.schema('schema', %r<schema>, SCHEMA-RUN-RECEIPT);
    $c.require('receiptId', %r<receiptId>);
    $c.add('packageId', 'must be a ULID') if $c.require('packageId', %r<packageId>) && !is-ulid(%r<packageId>);
    $c.require('runId', %r<runId>);
    if $c.require('agent.id', %r<agent><id>) {
        try parse-agent-id(%r<agent><id>);
        $c.add('agent.id', $!.message) if $!;
    }
    $c.add('agent.digest', 'must be sha256:<hex>') if %r<agent><digest> ne '' && !is-digest(%r<agent><digest>);
    $c.require('harness.adapter', %r<harness><adapter>);
    $c.add('packageDigest', 'must be sha256:<hex>') if $c.require('packageDigest', %r<packageDigest>) && !is-digest(%r<packageDigest>);
    $c.add('conditionsDigest', 'must be sha256:<hex>') if $c.require('conditionsDigest', %r<conditionsDigest>) && !is-digest(%r<conditionsDigest>);
    with %r<continues> -> %cn {
        $c.require('continues.runId', %cn<runId>);
        $c.require('continues.receiptId', %cn<receiptId>);
        $c.add('continues.receiptDigest', 'must be sha256:<hex>')
            if $c.require('continues.receiptDigest', %cn<receiptDigest>) && !is-digest(%cn<receiptDigest>);
    }
    $c.timestamp('startedAt', %r<startedAt>, True);
    $c.timestamp('endedAt', %r<endedAt>, True);
    $c.one-of('status', %r<status>, STATUS-COMPLETED, STATUS-NO-CHANGE, STATUS-BLOCKED, STATUS-FAILED, STATUS-STOPPED, STATUS-DENIED);
    $c.add('conditions', 'is required (an empty list is allowed)') unless %r<conditions>.defined;
    $c.add('directives', 'received, applied and rejected lists are required')
        unless %r<directives><received>.defined && %r<directives><applied>.defined && %r<directives><rejected>.defined;
    $c.add('denied', 'is required when status is denied') if %r<status> eq STATUS-DENIED && !%r<denied>.defined;
    $c.add('stop', 'is required when status is stopped') if %r<status> eq STATUS-STOPPED && !%r<stop>.defined;
    if $c.require('receiptDigest', %r<receiptDigest>) {
        $c.add('receiptDigest', "does not match the receipt's content") if receipt-digest(%r) ne %r<receiptDigest>;
    }
    $c;
}

#| Check a deployment-proposal.v1 document for shape and its own digest.
sub validate-deployment-proposal(%p --> Problems) is export {
    my $c = Problems.new;
    $c.schema('schema', %p<schema>, SCHEMA-DEPLOYMENT-PROPOSAL);
    $c.add('proposalId', 'must be a ULID') if $c.require('proposalId', %p<proposalId>) && !is-ulid(%p<proposalId>);
    $c.require('packageId', %p<packageId>);
    $c.require('agent.id', %p<agent><id>);
    $c.require('operation', %p<operation>);
    $c.one-of('status', %p<status>, 'planned', 'blocked');
    $c.require('observedAt', %p<observedAt>);
    if %p<status> eq 'planned' {
        $c.require('service', %p<service>);
        $c.require('target', %p<target>);
        my $sha = (%p<revision> // {})<sha>;
        $c.add('revision.sha', 'a planned proposal binds an exact revision') unless $sha ~~ Str && $sha ne '';
        my $d = (%p<manifest> // {})<digest>;
        $c.add('manifest.digest', 'a planned proposal binds the manifest digest') unless $d ~~ Str && $d ne '';
    }
    $c.add('unperformed', 'is required (an empty list means every check was performed)') unless %p<unperformed>.defined;
    $c.add('blockers', 'is required') unless %p<blockers>.defined;
    $c.add('proposalDigest', "does not match the proposal's content") if proposal-digest(%p) ne %p<proposalDigest>;
    $c;
}

#| Route a document to the validator its schema names.  Loads it through
#| the matching shape first; a shape error is one problem.
sub validate-document(Any $data --> Problems) is export {
    my $schema = ($data ~~ Associative ?? $data<schema> !! '') // '';
    my ($shape, &validator) = do given $schema {
        when SCHEMA-AGENT-PACKAGE       { 'AgentManifest', &validate-agent-manifest }
        when SCHEMA-WORK-PACKAGE        { 'WorkPackage', &validate-work-package }
        when SCHEMA-WORK-DIRECTIVE      { 'WorkDirective', &validate-work-directive }
        when SCHEMA-RUN-EVENT           { 'RunEvent', &validate-run-event }
        when SCHEMA-RUN-RECEIPT         { 'RunReceipt', &validate-run-receipt }
        when SCHEMA-DEPLOYMENT-PROPOSAL { 'DeploymentProposal', &validate-deployment-proposal }
        default { protocol-error("unknown schema \"$schema\"") }
    };
    my $doc = try load($shape, $data);
    if $! { my $c = Problems.new; $c.add('document', $!.message); return $c }
    validator($doc);
}

# -------------------------------------------------------------- digests

#| The hash a caller computes over an approval's params and the runtime
#| recomputes: the digest of the canonical params object.  An absent
#| params object hashes as the empty object.
sub params-hash(Any $params --> Str) is export {
    digest-of($params.defined ?? %($params) !! {});
}

#| The digest a directive carries: over the canonical directive with its
#| own digest field cleared.
sub directive-digest(%d --> Str) is export {
    my %copy = %d;
    %copy<digest> = '';
    digest-doc('WorkDirective', %copy);
}

#| The digest a receipt carries: over the canonical receipt with its own
#| digest and signature cleared.
sub receipt-digest(%r --> Str) is export {
    my %copy = %r;
    %copy<receiptDigest> = '';
    %copy<signature>:delete;
    digest-doc('RunReceipt', %copy);
}

#| Over the canonical proposal with its own digest cleared: the value an
#| approval binds to, and the value a later execution recomputes.
sub proposal-digest(%p --> Str) is export {
    my %copy = %p;
    %copy<proposalDigest> = '';
    digest-doc('DeploymentProposal', %copy);
}

#| The digest of a WorkPackage as a document (the receipt prefers the
#| bytes as received; this is the fallback).
sub package-digest(%wp --> Str) is export { digest-doc('WorkPackage', %wp) }

#| The digest of the ordered completion conditions.
sub conditions-digest($conditions --> Str) is export {
    digest-of([ |@($conditions // []) ]);
}
