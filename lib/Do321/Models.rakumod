unit module Do321::Models;

#| Model connectors: what the runtime knows about the models a harness
#| can be asked for.  A connector is a document (model-connector.v1): a
#| provider, how its models are reached, and for each model its size
#| class, context limit, effort settings and list price.
#|
#| Access is one of two kinds, kept apart on purpose:
#|   harness   the harness signs in and calls the provider itself; 321
#|             only names the model and the effort on its command line
#|   runtime   321 itself would hold the credential and call the provider
#| Every connector built in is harness access: 321 runs no inference
#| proxy and no agent loop of its own.  A runtime connector is accepted
#| and listed, and no run is placed on one until an adapter drives it.
#|
#| Adding a provider is one file in ~/.321/models/, and nothing else
#| changes: the CLI, Mission Control and a work system read this module.
#|
#| A list price is the provider's published rate on the day stated.  It
#| is used only to estimate; what a run cost is what its harness reported.

use Do321::JSON;

constant SCHEMA-MODEL-CONNECTOR is export = 'model-connector.v1';
constant ACCESS-HARNESS is export = 'harness';
constant ACCESS-RUNTIME is export = 'runtime';

#| Size classes, smallest first.  An agent asks for a class, never for a
#| vendor's model: the same agent keeps its ways when the models change.
sub tiers(--> List) is export { <small medium large> }
#| Effort settings, least first.
sub efforts(--> List) is export { <low medium high xhigh max> }

sub tier-rank(Str $t --> Int) is export { (tiers().first($t, :k)) // -1 }
sub effort-rank(Str $e --> Int) is export { (efforts().first($e, :k)) // -1 }

my constant BUILT-IN = (
    q:to/JSON/,
    {
      "schema": "model-connector.v1",
      "provider": "anthropic",
      "access": "harness",
      "auth": { "kind": "harness_login", "reference": "the harness signs in itself; 321 holds no key" },
      "pricing": { "asOf": "2026-11-03", "source": "the provider's published first-party rates", "unit": "usd per million tokens" },
      "models": [
        { "id": "claude-haiku-5-5", "alias": "haiku", "tier": "small", "contextTokens": 1000000,
          "efforts": ["low", "medium", "high", "xhigh", "max"], "price": { "input": 0.10, "output": 0.50 } },
        { "id": "claude-sonnet-5-5", "alias": "sonnet", "tier": "medium", "contextTokens": 1000000,
          "efforts": ["low", "medium", "high", "xhigh", "max"], "price": { "input": 2.00, "output": 10.00 } },
        { "id": "claude-opus-5-5", "alias": "opus", "tier": "large", "contextTokens": 1000000,
          "efforts": ["low", "medium", "high", "xhigh", "max"], "price": { "input": 4.00, "output": 20.00 } }
      ]
    }
    JSON
    q:to/JSON/,
    {
      "schema": "model-connector.v1",
      "provider": "openai",
      "access": "harness",
      "auth": { "kind": "harness_login", "reference": "the harness signs in itself; 321 holds no key" },
      "pricing": { "asOf": "", "source": "none recorded: add the models and rates you use in ~/.321/models/", "unit": "usd per million tokens" },
      "models": [
        { "id": "", "alias": "default", "tier": "medium", "contextTokens": 0,
          "efforts": ["low", "medium", "high"], "price": null }
      ]
    }
    JSON
);

class X::Do321::Models is Exception is export {
    has Str $.message;
}

#| One model as the runtime reasons about it.
class Model is export {
    has Str $.provider;
    has Str $.access;
    has Str $.id;                 # '' means the harness's own configured model
    has Str $.alias = '';
    has Str $.tier;
    has Int $.context-tokens = 0; # 0: not recorded
    has @.efforts;
    has $.price-in;               # USD per million tokens, or undefined: not recorded
    has $.price-out;
    has Str $.price-as-of = '';
    has Str $.source = 'built in';

    #| The name a person reads: the alias when there is one.
    method label(--> Str) { $!alias ne '' ?? $!alias !! $!id }
    #| What is put on a harness's command line: nothing for its default.
    method flag(--> Str) { $!id }
    method priced(--> Bool) { $!price-in.defined && $!price-out.defined }
    method takes-effort(Str $e --> Bool) { so @!efforts.first($e) }
}

#| The keys of a document that would hold a secret.
sub secret-keys($doc --> List) { $doc.keys.grep({ .lc eq 'apikey' | 'key' | 'token' | 'secret' | 'password' }).List }

#| A connector document, checked.  Returns the problems, none when sound.
sub connector-problems(%c --> List) is export {
    my @p;
    @p.push("schema must be {SCHEMA-MODEL-CONNECTOR}") unless (%c<schema> // '') eq SCHEMA-MODEL-CONNECTOR;
    @p.push('provider must be a lower-case name') unless (%c<provider> // '') ~~ Str && (%c<provider> // '') ~~ / ^ <[a..z 0..9 _ -]> ** 1..32 $ /;
    @p.push('access must be harness or runtime') unless (%c<access> // '') eq ACCESS-HARNESS | ACCESS-RUNTIME;
    @p.push('auth.kind must be stated') unless (%c<auth> // {}) ~~ Associative && ((%c<auth> // {})<kind> // '') ne '';
    my @m = @(%c<models> // []);
    @p.push('models must list at least one model') unless @m;
    for @m.kv -> $i, $m {
        unless $m ~~ Associative { @p.push("models[$i] must be an object"); next }
        @p.push("models[$i].tier must be one of {tiers().join(', ')}") unless tier-rank(($m<tier> // '').Str) >= 0;
        @p.push("models[$i] needs an id or an alias") if ($m<id> // '') eq '' && ($m<alias> // '') eq '';
        for @($m<efforts> // []) -> $e { @p.push("models[$i].efforts: '$e' is not an effort setting") unless effort-rank($e.Str) >= 0 }
        with $m<price> -> $pr {
            @p.push("models[$i].price needs input and output") unless $pr ~~ Associative && $pr<input> ~~ Numeric && $pr<output> ~~ Numeric;
        }
        # A secret never belongs in a connector: it names where a credential
        # is, and holds none.
        @p.push("models[$i] must not carry a key") if secret-keys($m);
    }
    @p.push('a connector names where a credential is kept and never holds one') if (%c<auth> // {}) ~~ Associative && secret-keys(%c<auth> // {});
    @p.List;
}

sub models-of(%c, Str $source --> List) {
    my $as-of = ((%c<pricing> // {})<asOf> // '').Str;
    @(%c<models>).map(-> $m {
        my $pr = $m<price>;
        Model.new(provider => %c<provider>, access => %c<access>, id => ($m<id> // '').Str, alias => ($m<alias> // '').Str,
            tier => $m<tier>, context-tokens => (($m<contextTokens> // 0) ~~ Int ?? ($m<contextTokens> // 0) !! 0),
            efforts => [ @($m<efforts> // []).map(*.Str) ],
            price-in => ($pr ~~ Associative ?? $pr<input> !! Any), price-out => ($pr ~~ Associative ?? $pr<output> !! Any),
            price-as-of => $as-of, :$source)
    }).List;
}

sub models-dir(IO::Path $home --> IO::Path) is export { $home.add('models') }

#| Every model known here: the connectors built in, then the ones a
#| person added, a later one replacing an earlier one for the same
#| provider.  A file that is not a sound connector is left out and named.
sub catalogue(IO::Path $home --> List) is export {
    my %by;
    my @order;
    my @skipped;
    for BUILT-IN -> $text {
        my %c = parse-json($text);
        %by{%c<provider>} = models-of(%c, 'built in');
        @order.push(%c<provider>);
    }
    my $dir = models-dir($home);
    if $dir.d {
        for $dir.dir.grep({ .basename.ends-with('.json') }).sort(*.basename) -> $f {
            my $c = try parse-json($f.slurp);
            unless $c ~~ Associative { @skipped.push("{$f.basename}: not a JSON object"); next }
            my @p = connector-problems($c);
            if @p { @skipped.push("{$f.basename}: {@p[0]}"); next }
            @order.push($c<provider>) unless %by{$c<provider>}:exists;
            %by{$c<provider>} = models-of($c, $f.Str);
        }
    }
    (@order.map({ |%by{$_} }).List, @skipped.List);
}

#| The models of the given providers, cheapest first within a class.  A
#| model with no recorded price sorts after the priced ones.
sub models-for(@models, @providers --> List) is export {
    my %want = @providers.map({ $_ => True });
    @models.grep({ %want{.provider} }).sort({ tier-rank(.tier), (.priced ?? 0 !! 1), (.price-out // 0) }).List;
}

#| A model by what a person typed: an id, an alias, or provider/alias.
sub find-model(@models, Str $name) is export {
    my $n = $name.lc;
    return Model if $n eq '';
    my ($prov, $rest) = $n.contains('/') ?? $n.split('/', 2) !! ('', $n);
    @models.first({ ($prov eq '' || .provider eq $prov) && ($rest eq .id.lc || ($rest eq .alias.lc && .alias ne '')) }) // Model;
}

#| What a run is likely to cost on a model, from tokens and the list
#| price: an estimate, and undefined when either is not known.  Every
#| token is priced at the input rate except those said to be output,
#| which is the low side: it is a floor, and is called one.
sub list-cost(Model $m, Int $tokens-in, Int $tokens-out) is export {
    return Any unless $m.defined && $m.priced;
    ($tokens-in * $m.price-in + $tokens-out * $m.price-out) / 1_000_000;
}
