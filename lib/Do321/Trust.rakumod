unit module Do321::Trust;

#| Resolves agent names to configured, pinned packages and loads them
#| under the trust level the configuration grants.
#|
#| Everything here is administrator-managed in ~/.321/trust.json.  There
#| is no downloading, no installation and no online enrolment.
#|
#| Trust levels a loaded package can hold:
#|
#|   verified     a publisher pin whose digest matches and whose SIGNATURE
#|                verifies against one of the publisher's pinned keys
#|   development  a publisher pin with "trust": "development": digest must
#|                match, the signature is not required, and the package is
#|                labelled unsigned and administrator-pinned.  It is never
#|                reported as verified.
#|   local        an unsigned package with a local/<name> identity, pinned
#|                by path.  It has no publisher and claims none.

use Do321::JSON;
use Do321::Shape;
use Do321::Protocol;
use Do321::Digest;

constant LEVEL-VERIFIED    is export = 'verified';
constant LEVEL-DEVELOPMENT is export = 'development';
constant LEVEL-LOCAL       is export = 'local';

constant MANIFEST-FILE is export = 'agent.json';

#| Reserved names an alias may never shadow.
constant RESERVED is export = <run agents packages trust doctor help version>;

class X::Do321::Trust is Exception is export {
    has Str $.message;
}

sub trust-error(Str $m) { X::Do321::Trust.new(message => $m).throw }

#| ~/.321/trust.json, or X321_TRUST.
sub default-trust-path(--> IO::Path) is export {
    return %*ENV<X321_TRUST>.IO if %*ENV<X321_TRUST>;
    $*HOME.add('.321').add('trust.json');
}

#| A name resolved to a configured package.
class Resolution is export {
    has AgentID $.id;
    has Str $.path;
    has Str $.level;
    has $.pin;          # the Pin document, for publisher packages
    has @.keys;         # the publisher's keys
    has Str $.alias = '';
}

#| trust.json, loaded and checked.
class Config is export {
    has %.doc;          # the TrustConfig document
    has Str $.path = '';

    method schema { %!doc<schema> }
    method publishers { %!doc<publishers> // {} }
    method local { %!doc<local> // {} }
    method aliases { %!doc<aliases> // {} }
    method policy { %!doc<policy> }

    method display-path(--> Str) { $!path eq '' ?? '~/.321/trust.json' !! $!path }

    #| Validate the configuration's internal consistency.
    method check() {
        trust-error("schema must be \"{SCHEMA-TRUST-CONFIG}\"") unless self.schema eq SCHEMA-TRUST-CONFIG;
        for self.publishers.sort(*.key) -> (:key($dom), :value(%p)) {
            trust-error("publisher \"$dom\" is not a domain") unless is-domain($dom);
            for @(%p<keys> // []).kv -> $i, %k {
                trust-error("publisher $dom key[$i] needs keyId and publicKey") if %k<keyId> eq '' || %k<publicKey> eq '';
            }
            for (%p<packages> // {}).sort(*.key) -> (:key($name), :value(%pin)) {
                trust-error("publisher $dom package \"$name\" is not an agent name") unless is-agent-name($name);
                trust-error("publisher $dom package $name needs path, version and digest")
                    if %pin<path> eq '' || %pin<version> eq '' || %pin<digest> eq '';
                trust-error("publisher $dom package $name digest must be sha256:<hex>") unless is-digest(%pin<digest>);
                trust-error("publisher $dom package $name trust must be verified or development")
                    unless is-in(%pin<trust>, ['', LEVEL-VERIFIED, LEVEL-DEVELOPMENT]);
                trust-error("publisher $dom package $name is pinned as verified but the publisher has no keys")
                    if (%pin<trust> eq '' || %pin<trust> eq LEVEL-VERIFIED) && !@(%p<keys> // []);
            }
        }
        for self.local.sort(*.key) -> (:key($name), :value(%l)) {
            trust-error("local package \"$name\" is not an agent name") unless is-agent-name($name);
            trust-error("local package $name needs a path") if %l<path> eq '';
        }
        for @((self.policy // {})<standingApprovals> // []).kv -> $i, %sa {
            trust-error("policy.standingApprovals[$i]: action must be \"deploy\"") unless %sa<action> eq 'deploy';
            trust-error("policy.standingApprovals[$i]: approvedBy names the person approving") if (%sa<approvedBy> // '').trim eq '';
            trust-error("policy.standingApprovals[$i]: targets must list at least one service\@target") unless @(%sa<targets> // []);
            for @(%sa<targets>) -> $t {
                trust-error("policy.standingApprovals[$i]: \"$t\" is not service\@target (either side may be *)")
                    unless $t ~~ m:P5/^(\*|[a-z0-9][a-z0-9.-]*)@(\*|[a-z0-9][a-z0-9_-]*)$/;
            }
        }
        for self.aliases.sort(*.key) -> (:key($alias), :value($target)) {
            trust-error("alias \"$alias\" is not an agent name") unless is-agent-name($alias);
            trust-error("alias \"$alias\" shadows a reserved command") if is-in($alias, RESERVED);
            my $r = try self!find($target);
            trust-error("alias $alias -> $target: {$!.message}") if $!;
        }
        self;
    }

    #| Turn what a person typed into a configured package: a canonical id
    #| with a slash is looked up directly; a bare name is looked up as an
    #| explicit alias, then as a local package.  Nothing is inferred from
    #| package contents.  Ambiguity or absence is an error that names the
    #| candidates and the canonical form.
    method resolve(Str $name --> Resolution) {
        return self!find($name) if $name.contains('/');
        trust-error("\"$name\" is not an agent name or canonical id") unless is-agent-name($name);
        if self.aliases{$name}:exists {
            my $r = self!find(self.aliases{$name});
            return Resolution.new(:id($r.id), :path($r.path), :level($r.level), :pin($r.pin), :keys($r.keys), :alias($name));
        }
        my @candidates;
        @candidates.push(LOCAL-DOMAIN ~ "/$name") if self.local{$name}:exists;
        for self.publishers.sort(*.key) -> (:key($dom), :value(%p)) {
            @candidates.push("$dom/$name") if (%p<packages> // {}){$name}:exists;
        }
        @candidates .= sort;
        given @candidates.elems {
            when 0 {
                trust-error("no agent \"$name\" is configured; use a canonical id such as <publisher>/$name or add an alias to {self.display-path}");
            }
            when 1 {
                return self!find(@candidates[0]) if @candidates[0].starts-with(LOCAL-DOMAIN ~ '/');
                trust-error("\"$name\" is not an alias; {@candidates[0]} is configured, so use that canonical id or add the alias explicitly");
            }
            default {
                trust-error("\"$name\" is ambiguous between {@candidates.join(', ')}; use a canonical id");
            }
        }
    }

    method !find(Str $canonical --> Resolution) {
        my $id = try parse-agent-id($canonical);
        trust-error($!.message) if $!;
        if $id.is-local {
            trust-error("no local package \"{$id.name}\" is configured") unless self.local{$id.name}:exists;
            return Resolution.new(:$id, :path(self.local{$id.name}<path>), :level(LEVEL-LOCAL));
        }
        trust-error("publisher \"{$id.domain}\" is not configured") unless self.publishers{$id.domain}:exists;
        my %p = self.publishers{$id.domain};
        trust-error("publisher {$id.domain} has no package \"{$id.name}\" configured") unless (%p<packages> // {}){$id.name}:exists;
        my %pin = %p<packages>{$id.name};
        my $level = %pin<trust> eq LEVEL-DEVELOPMENT ?? LEVEL-DEVELOPMENT !! LEVEL-VERIFIED;
        Resolution.new(:$id, :path(%pin<path>), :$level, :pin(%pin), :keys(@(%p<keys> // [])));
    }

    #| Every configured package identity, sorted, with its trust level.
    method configured(--> List) {
        my @out;
        for self.local.kv -> $name, %l {
            @out.push(Resolution.new(:id(AgentID.new(:domain(LOCAL-DOMAIN), :$name)), :path(%l<path>), :level(LEVEL-LOCAL)));
        }
        for self.publishers.kv -> $dom, %p {
            for (%p<packages> // {}).kv -> $name, %pin {
                my $level = %pin<trust> eq LEVEL-DEVELOPMENT ?? LEVEL-DEVELOPMENT !! LEVEL-VERIFIED;
                @out.push(Resolution.new(:id(AgentID.new(:domain($dom), :$name)), :path(%pin<path>), :$level, :pin(%pin), :keys(@(%p<keys> // []))));
            }
        }
        @out = @out.sort(*.id.Str);
        my %alias-of = self.aliases.kv.map(-> $a, $t { $t => $a });
        @out.map({
            %alias-of{.id.Str}:exists
                ?? Resolution.new(:id(.id), :path(.path), :level(.level), :pin(.pin), :keys(.keys), :alias(%alias-of{.id.Str}))
                !! $_
        }).List;
    }
}

#| Read and check a trust file.  A missing file yields an empty
#| configuration, so path-based local packages still work.
sub load-trust(IO() $path --> Config) is export {
    return Config.new(:doc(doc('TrustConfig', schema => SCHEMA-TRUST-CONFIG)), :path($path.Str)) unless $path.e;
    my $data = try parse-json($path.slurp);
    trust-error("trust: {$path.Str}: {$!.message}") if $!;
    my $docd = try load('TrustConfig', $data);
    trust-error("trust: {$path.Str}: {$!.message}") if $!;
    my $c = Config.new(:doc($docd), :path($path.Str));
    try $c.check;
    trust-error("trust: {$path.Str}: {$!.message}") if $!;
    $c;
}

#| A configuration built in code (tests): checked before use.
sub trust-config(%fields --> Config) is export {
    Config.new(:doc(load('TrustConfig', %fields)));
}

# ---------------------------------------------------------------- loading

#| A package the runtime may execute, with the trust it holds.
class Loaded is export {
    has %.manifest;
    has Str $.root;
    has Str $.digest;
    has Str $.level;
    has Bool $.verified = False;     # true only for a verifying signature under a pinned key
    has Str $.label = '';            # what to show a person about this package's trust
    has @.warnings;
    has %.prompts;

    method id(--> Str) { %!manifest<id> }

    #| The concatenated prompt files in manifest order.
    method prompt(--> Str) {
        %!manifest<prompts>.map({ %!prompts{$_}.trim }).join("\n\n");
    }

    #| The default output schema, or the one named for a procedure.
    method output-schema(Str $procedure = '' --> Str) {
        my $file = %!manifest<outputSchemas><default>;
        if $procedure ne '' && ((%!manifest<outputSchemas><byProcedure> // {}){$procedure}:exists) {
            $file = %!manifest<outputSchemas><byProcedure>{$procedure};
        }
        read-inside($!root, $file);
    }

    #| Adapter-specific tuning, if the package ships one; Str otherwise.
    method overlay(Str $adapter --> Str) {
        my %o = %!manifest<harness><overlays> // {};
        return Str unless %o{$adapter}:exists;
        read-inside($!root, %o{$adapter});
    }
}

#| Parse and validate agent.json without loading anything else.
sub read-manifest(IO() $root --> Hash) is export {
    my $f = $root.add(MANIFEST-FILE);
    trust-error("{$f.Str}: no such file") unless $f.f;
    my $data = try parse-json($f.slurp);
    trust-error("{MANIFEST-FILE}: {$!.message}") if $!;
    my $m = try load('AgentManifest', $data);
    trust-error("{MANIFEST-FILE}: {$!.message}") if $!;
    my $ps = validate-agent-manifest($m);
    trust-error($ps.Str) if $ps;
    $m;
}

#| Read a file by safe relative path and refuse anything that would land
#| outside root, including through a symlink.
sub read-inside(IO() $root, Str $rel --> Str) is export {
    trust-error("package: \"$rel\" is not a safe relative path") unless safe-rel-path($rel);
    my $abs = $root.absolute.IO;
    my $full = $abs.add($rel);
    trust-error("package: $rel: no such file") unless $full.e;
    my $resolved = try $full.resolve;
    trust-error("package: $rel: {$!.message}") if $!;
    my $root-resolved = $abs.resolve;
    trust-error("package: \"$rel\" escapes the package root") unless within($resolved, $root-resolved);
    trust-error("package: \"$rel\" is not a regular file") unless $full.f && !$full.l;
    $full.slurp;
}

sub check-references(IO::Path $root, %m) {
    my @refs = |@(%m<prompts> // []), |@(%m<skills> // []), |@(%m<evaluations> // []), %m<outputSchemas><default>,
        |(%m<outputSchemas><byProcedure> // {}).values, |(%m<harness><overlays> // {}).values;
    read-inside($root, $_) for @refs;
}

#| Check a package directory as a package: manifest shape, every
#| referenced file present and inside the root, DIGEST matching the
#| content.  Returns (manifest, digest).  Does not consult trust.
sub validate-package(IO() $root --> List) is export {
    my $m = read-manifest($root);
    check-references($root, $m);
    my $d = verify-digest($root);
    ($m, $d);
}

sub load-prompts(IO::Path $root, %m --> Hash) {
    my %p;
    %p{$_} = read-inside($root, $_) for @(%m<prompts>);
    %p;
}

sub verify-against-keys(Str $d, %sig, @keys) {
    for @keys -> %k {
        next unless %k<keyId> eq %sig<keyId>;
        my $pub = try parse-public-key(%k<publicKey>);
        trust-error("pinned key {%k<keyId>}: {$!.message}") if $!;
        verify-signature($d, %sig, $pub);
        return;
    }
    trust-error("signature key {%sig<keyId>} is not a pinned key for this publisher");
}

#| Load a resolved package under its trust level.  It never rewrites the
#| manifest's identity: a manifest whose id disagrees with the
#| configuration is an error, as is a domain-claiming manifest pinned as
#| a local package.
sub load-resolved(Resolution $r --> Loaded) is export {
    my ($m, $computed) = try validate-package($r.path.IO);
    trust-error("package {$r.id} at {$r.path}: {$!.message}") if $!;
    if $m<id> ne $r.id.Str {
        if $r.level eq LEVEL-LOCAL {
            trust-error("package at {$r.path} declares id \"{$m<id>}\" but is configured as the local package {$r.id}; pin it under publishers.{$m<id>.split('/', 2)[0]} instead (as development if it is unsigned)");
        }
        trust-error("package at {$r.path} declares id \"{$m<id>}\" but is configured as {$r.id}");
    }
    my ($label, $verified, @warnings) = '', False;
    given $r.level {
        when LEVEL-LOCAL { $label = 'local package, unsigned, not published' }
        when LEVEL-DEVELOPMENT {
            trust-error("package {$r.id}: pinned digest {$r.pin<digest>} but the content is $computed") if $r.pin<digest> ne $computed;
            trust-error("package {$r.id}: pinned version {$r.pin<version>} but the manifest says {$m<version>}") if $r.pin<version> ne $m<version>;
            $label = "{$r.id.domain}: unsigned, administrator-pinned development package (not cryptographically verified)";
            @warnings.push('development pin: publisher identity is asserted by the administrator, not proven by a signature');
        }
        when LEVEL-VERIFIED {
            trust-error("package {$r.id}: pinned digest {$r.pin<digest>} but the content is $computed") if $r.pin<digest> ne $computed;
            trust-error("package {$r.id}: pinned version {$r.pin<version>} but the manifest says {$m<version>}") if $r.pin<version> ne $m<version>;
            trust-error("package {$r.id} is pinned as verified but has no SIGNATURE; pin it as development or sign it")
                unless $r.path.IO.add(SIGNATURE-FILE).f;
            my %sig = try read-signature-file($r.path.IO);
            trust-error("package {$r.id}: {$!.message}") if $!;
            try verify-against-keys($computed, %sig, $r.keys);
            trust-error("package {$r.id}: {$!.message}") if $!;
            $verified = True;
            $label = "{$r.id.domain}: verified against pinned key {%sig<keyId>}";
        }
        default { trust-error("package {$r.id}: unknown trust level \"{$r.level}\"") }
    }
    Loaded.new(:manifest($m), :root($r.path), :digest($computed), :level($r.level), :$verified, :$label,
        :@warnings, :prompts(load-prompts($r.path.IO, $m)));
}

#| Load an unsigned package straight from a directory with no trust
#| configuration at all.  Only a local/<name> identity is accepted this
#| way; a manifest claiming a publisher domain must go through a pin.
sub load-path(IO() $root --> Loaded) is export {
    my ($m, $computed) = try validate-package($root);
    trust-error("package at {$root.Str}: {$!.message}") if $!;
    my $id = try parse-agent-id($m<id>);
    trust-error($!.message) if $!;
    trust-error("package at {$root.Str} declares publisher {$id.domain}; a path reference may only load a local/<name> package. Pin it in trust configuration to load it under that identity")
        unless $id.is-local;
    Loaded.new(:manifest($m), :root($root.Str), :digest($computed), :level(LEVEL-LOCAL),
        :label('local package by path, unsigned, not published'), :prompts(load-prompts($root, $m)));
}
