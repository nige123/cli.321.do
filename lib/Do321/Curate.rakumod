unit module Do321::Curate;

#| Execution curation: how an agent decides what a piece of work needs.
#|
#| One implementation, here, and each agent's own configuration of it
#| (curation.v1, a file in the agent's package).  The configuration
#| names the kinds of work the agent tells apart, and for each a
#| profile: a size class of model and an effort.  It names no vendor
#| and no harness, so an agent keeps its ways when models change.
#|
#| Curation asks and explains; it decides nothing the runtime owns.  The
#| answer is a Want, which the runtime checks against what is installed,
#| what the package requires and what the budget allows (Do321::Plan).
#| It grants nothing, and it never moves a limit.
#|
#| It is rules and recorded evidence, with no model call: choosing how
#| to run a job costs nothing.  Evidence is the earlier comparable runs
#| and what people said of them.  Fewer than MIN-JUDGED runs with a
#| word said of them is not evidence, and the reasons say so.

use Do321::JSON;
use Do321::Shape;
use Do321::Models;
use Do321::Plan;

constant SCHEMA-CURATION is export = 'curation.v1';
#| Fewer judged comparable runs than this changes no choice.
constant MIN-JUDGED is export = 3;

my constant DEFAULT = q:to/JSON/;
    {
      "schema": "curation.v1",
      "profiles": {
        "economy":  { "tier": "small",  "effort": "low" },
        "standard": { "tier": "medium", "effort": "medium" },
        "deep":     { "tier": "large",  "effort": "high" }
      },
      "order": ["economy", "standard", "deep"],
      "default": "standard",
      "tasks": [
        { "type": "read",   "profile": "economy",
          "words": ["explain", "summarise", "summarize", "list", "find", "describe", "show", "review", "what", "where", "which", "why", "how"] },
        { "type": "change", "profile": "standard",
          "words": ["fix", "add", "implement", "write", "update", "rename", "remove", "change", "test", "make", "build"] },
        { "type": "design", "profile": "deep",
          "words": ["design", "architect", "refactor", "migrate", "rewrite", "restructure", "plan"] }
      ],
      "maxEscalations": 1
    }
    JSON

class X::Do321::Curate is Exception is export {
    has Str $.message;
}

#| What is wrong with a curation document, nothing when it is sound.
sub curation-problems(%c --> List) is export {
    my @p;
    @p.push("schema must be {SCHEMA-CURATION}") unless (%c<schema> // '') eq SCHEMA-CURATION;
    my %profiles = (%c<profiles> // {}) ~~ Associative ?? %(%c<profiles> // {}) !! %();
    @p.push('profiles must name at least one profile') unless %profiles;
    for %profiles.sort(*.key) -> $kv {
        my ($name, $v) = $kv.key, $kv.value;
        unless $v ~~ Associative { @p.push("profiles.$name must be an object"); next }
        @p.push("profiles.$name.tier must be one of {tiers().join(', ')}") unless tier-rank(($v<tier> // '').Str) >= 0;
        @p.push("profiles.$name.effort must be one of {efforts().join(', ')}") unless ($v<effort> // '') eq '' || effort-rank(($v<effort> // '').Str) >= 0;
        # A profile is a class and an effort and nothing else: a vendor's
        # model named here would tie the agent to it.
        @p.push("profiles.$name names a model: a profile asks for a class, never a vendor's model") if $v<model>:exists;
    }
    my @order = @(%c<order> // []);
    @p.push('order must list the profiles, least first') unless @order;
    for @order -> $o { @p.push("order: no profile is called '$o'") unless %profiles{$o}:exists }
    @p.push("default: no profile is called '{%c<default> // ''}'") unless %profiles{(%c<default> // '').Str}:exists;
    for @(%c<tasks> // []).kv -> $i, $t {
        unless $t ~~ Associative { @p.push("tasks[$i] must be an object"); next }
        @p.push("tasks[$i].type must be a short lower-case name") unless ($t<type> // '') ~~ Str && ($t<type> // '') ~~ / ^ <[a..z 0..9 _ -]> ** 1..32 $ /;
        @p.push("tasks[$i].profile: no profile is called '{$t<profile> // ''}'") unless %profiles{($t<profile> // '').Str}:exists;
        @p.push("tasks[$i].words must list the words that mark this kind of work") unless @($t<words> // []);
    }
    my $max = %c<maxEscalations> // 0;
    @p.push('maxEscalations must be 0, 1, 2 or 3') unless $max ~~ Int && 0 <= $max <= 3;
    for @(%c<escalateOn> // []) -> $e { @p.push("escalateOn: '$e' is not harness_failure or unmet_conditions") unless $e eq 'harness_failure' | 'unmet_conditions' }
    # Curation asks for a configuration.  It has no word for a grant or a limit.
    for <grants capabilities limits permissions network> -> $k {
        @p.push("$k has no place in curation: it grants nothing and moves no limit") if %c{$k}:exists;
    }
    @p.List;
}

#| The curation every agent has until its package says otherwise.
sub default-curation(--> Hash) is export { parse-json(DEFAULT) }

#| An agent's curation from the text its package ships, or the default.
sub read-curation($text --> Hash) is export {
    return default-curation() unless $text.defined && $text.trim ne '';
    my $c = try parse-json($text);
    X::Do321::Curate.new(message => "curation: {$!.message}").throw if $!;
    X::Do321::Curate.new(message => 'curation: must be a JSON object').throw unless $c ~~ Associative;
    my @p = curation-problems($c);
    X::Do321::Curate.new(message => "curation: {@p[0]}").throw if @p;
    %$c;
}

#| The kind of work a request is, and how that was read: the kind a
#| person stated; else the kind whose marking word comes first in the
#| request, since a request leads with what it wants done; else none.
sub task-of(%c, Str $objective, Str $stated = '' --> List) is export {
    my @tasks = @(%c<tasks> // []);
    if $stated ne '' {
        X::Do321::Curate.new(message => "no kind of work is called '$stated' for this agent (it tells apart: {@tasks.map(*<type>).join(', ')})").throw
            unless @tasks.first({ .<type> eq $stated });
        return ($stated, 'stated', '');
    }
    my @words = $objective.lc.comb(/ <[a..z]>+ /);
    my ($best, $at, $word) = ('', Inf, '');
    for @tasks -> $t {
        for @($t<words>) -> $w {
            my $i = @words.first($w.lc, :k) // next;
            ($best, $at, $word) = ($t<type>, $i, $w.lc) if $i < $at;
        }
    }
    $best ne '' ?? ($best, 'matched', $word) !! ('', 'default', '');
}

my sub median(@n) {
    return Any unless @n;
    my @s = @n.sort;
    @s.elems %% 2 ?? (@s[@s.elems div 2 - 1] + @s[@s.elems div 2]) / 2 !! @s[@s.elems div 2];
}

#| The earlier runs a choice may rest on: the same agent doing the same
#| kind of work, and in the same work context when the run has one.
sub comparable(@work, Str :$agent, Str :$task, Str :$context = '' --> List) is export {
    @work.grep({ .agent eq $agent && .task eq $task && .task ne '' && ($context eq '' || .context eq $context) }).List;
}

#| What is known of one profile from comparable runs.
sub profile-evidence(@runs, Str $profile, Str $basis --> Hash) is export {
    my @on = @runs.grep({ .profile eq $profile });
    my @judged = @on.grep({ .outcome ne '' });
    my @priced = @on.grep({ .usd.defined });
    my $usd = median(@priced.map(*.usd));
    my $secs = median(@on.map(*.seconds));
    doc('PlanEvidence', comparable => @on.elems, judged => @judged.elems, accepted => @judged.grep({ .outcome eq 'accepted' }).elems,
        medianUsd => ($usd // 0), usdRuns => @priced.elems, medianSeconds => (($secs // 0).Int), :$basis);
}

#| Choose what to ask the runtime for.
#|   %c         the agent's curation
#|   objective  the request
#|   task       the kind of work a person stated, or ''
#|   profile    a profile a person named, or ''
#|   model      a model a person named, or ''
#|   effort     an effort a person named, or ''
#|   max-usd    the spend limit of the job, 0 when there is none
#|   work       earlier runs (Do321::Learn::Work), for evidence
sub curate(%c, Str :$objective = '', Str :$task = '', Str :$profile = '', Str :$model = '', Str :$effort = '',
           :$max-usd = 0, :@work, Str :$agent = '', Str :$context = '', :@skills --> Want) is export {
    my %profiles = %(%c<profiles>);
    my @order = @(%c<order>);
    my (@reasons, @overrides);
    my ($type, $from, $word) = task-of(%c, $objective, $task);
    my $rule = @(%c<tasks> // []).first({ .<type> eq $type });
    my $chosen = $rule.defined ?? $rule<profile> !! %c<default>;
    @reasons.push($from eq 'stated' ?? "you said this is $type work: {$chosen} is what the agent uses for it"
        !! $from eq 'matched' ?? "the request reads as $type work (it says '$word'): {$chosen} is what the agent uses for it"
        !! "the request names no kind of work the agent tells apart: its usual, {$chosen}, is used");

    my @runs = comparable(@work, :$agent, task => $type, :$context);
    my $basis = $type eq '' ?? 'no kind of work was read, so no earlier run is comparable'
        !! 'the same agent on ' ~ $type ~ ' work' ~ ($context ne '' ?? " in the context $context" !! '');
    my sub ev(Str $p) { profile-evidence(@runs, $p, $basis) }
    my sub rank(Str $p) { @order.first($p, :k) // 0 }

    if $profile ne '' {
        X::Do321::Curate.new(message => "no profile is called '$profile' for this agent (it has: {@order.join(', ')})").throw unless %profiles{$profile}:exists;
        $chosen = $profile;
        @overrides.push("profile $profile");
        @reasons.push("you asked for $profile");
    }
    else {
        # What people said of comparable runs moves the choice one step,
        # and only when enough was said.
        my %e = ev($chosen);
        if %e<judged> >= MIN-JUDGED && %e<accepted> * 2 < %e<judged> && rank($chosen) < @order.end {
            my $up = @order[rank($chosen) + 1];
            @reasons.push("{%e<judged> - %e<accepted>} of {%e<judged>} comparable runs on $chosen were not accepted: $up is used");
            $chosen = $up;
        }
        elsif rank($chosen) > 0 {
            my $down = @order[rank($chosen) - 1];
            my %d = ev($down);
            if %d<judged> >= MIN-JUDGED && %d<accepted> * 5 >= %d<judged> * 4 {
                @reasons.push("{%d<accepted>} of {%d<judged>} comparable runs on $down were accepted: the cheaper configuration is used");
                $chosen = $down;
            }
        }
        # The budget: step down while comparable runs say this costs more
        # than the job may spend.  With no priced runs nothing is assumed.
        if $max-usd > 0 {
            while rank($chosen) > 0 {
                my %e2 = ev($chosen);
                last unless %e2<usdRuns> >= MIN-JUDGED && %e2<medianUsd> > $max-usd;
                my $down = @order[rank($chosen) - 1];
                @reasons.push(sprintf('comparable runs on %s cost about $%.2f and the limit is $%.2f: %s is used', $chosen, %e2<medianUsd>, $max-usd, $down));
                $chosen = $down;
            }
        }
    }

    my %ev = ev($chosen);
    # said once: a step already gave this count as its reason
    @reasons.push(%ev<judged> >= MIN-JUDGED
        ?? "{%ev<accepted>} of {%ev<judged>} comparable runs on $chosen were accepted"
        !! %ev<comparable> > 0
            ?? "{%ev<comparable>} comparable run{%ev<comparable> == 1 ?? '' !! 's'} on $chosen, {%ev<judged>} with a word said of {%ev<judged> == 1 ?? 'it' !! 'them'}: too few to weigh"
            !! "no comparable run on $chosen yet")
        unless @reasons.first(*.contains("comparable runs on $chosen were"));

    my $ask-effort = (%profiles{$chosen}<effort> // '').Str;
    if $effort ne '' {
        X::Do321::Curate.new(message => "--effort must be one of {efforts().join(', ')}").throw unless effort-rank($effort) >= 0;
        $ask-effort = $effort;
        @overrides.push("effort $effort");
    }
    @overrides.push("model $model") if $model ne '';
    # A person who named the model made the choice: nothing climbs past it.
    my @ladder = $model ne '' ?? () !! @order[(rank($chosen) + 1) .. *].map({ %( profile => $_, tier => %profiles{$_}<tier>, effort => (%profiles{$_}<effort> // '') ) });
    Want.new(task => $type, task-from => $from, profile => $chosen, tier => %profiles{$chosen}<tier>, effort => $ask-effort,
        :@ladder, max-escalations => ($model ne '' ?? 0 !! (%c<maxEscalations> // 0)), :$model, :@reasons, :@overrides, :@skills, evidence => %ev,
        escalate-on => (@(%c<escalateOn> // []) ?? @(%c<escalateOn>).map(*.Str).List !! ('harness_failure',)));
}
