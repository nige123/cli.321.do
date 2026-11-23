unit module Do321::Plan;

#| The execution plan a run is pinned to before it begins, and the part
#| of choosing it that is the runtime's alone.
#|
#| Two parties, kept apart:
#|   the agent's curation asks: a size class of model, an effort, the
#|     steps it may climb if the work proves harder, and its reasons;
#|   the runtime answers: which installed harness enforces what the
#|     package requires and can run a model of that class, which exact
#|     model and effort that harness will be given, and what it recorded.
#| Asking grants nothing.  A harness that cannot enforce the package is
#| never chosen for the sake of a model, and a plan never widens a grant
#| or a limit: both were settled before this module is reached.
#|
#| The plan is pinned once, written on the receipt, and changed only
#| between attempts, by a step the plan itself listed.

use Do321::JSON;
use Do321::Shape;
use Do321::Adapter;
use Do321::Models;

constant SCHEMA-EXECUTION-PLAN is export = 'execution-plan.v1';

#| What an agent's curation asks of the runtime for one piece of work.
class Want is export {
    has Str $.task = '';            # the kind of work, as curation read it
    has Str $.task-from = '';       # how it was read: stated, matched or default
    has Str $.profile = '';         # the agent's own name for the configuration
    has Str $.tier = '';            # the size class asked for; '' asks for the harness's own model
    has Str $.effort = '';
    has @.ladder;                   # steps above this one, in order: profile, tier, effort
    has Int $.max-escalations = 0;
    #| What a climb may answer: harness_failure, unmet_conditions.
    has @.escalate-on = ('harness_failure',);
    has Str $.model = '';           # a model a person named, which overrides the class
    has @.reasons;
    has @.overrides;                # what a person set by hand, in words
    has @.skills;                   # name, version, digest of each skill the run carries
    has $.evidence;                 # a PlanEvidence document, or undefined
}

#| The model and effort one harness would be given for a want, with what
#| had to give; or why this harness cannot run it.
sub fit-harness(Adapter $a, Str $tier, Str $effort, Str $named, @models --> List) is export {
    my %m = $a.manifest;
    my @providers = @(%m<providers> // []);
    my @notes;
    unless @providers {
        return (Model, '', @notes, "it runs no model, and '$named' was asked for") if $named ne '';
        return (Model, '', @notes, '');
    }
    my @reach = models-for(@models, @providers).grep({ .access eq (%m<access> // '') });
    my $model = Model;
    if $named ne '' {
        $model = find-model(@reach, $named);
        return (Model, '', @notes, "it cannot reach '$named' (it reaches {@providers.join(', ')})") without $model;
        return (Model, '', @notes, 'it cannot be given a model for one run') unless %m<sets-model> || $model.flag eq '';
    }
    elsif $tier ne '' {
        my $want = tier-rank($tier);
        $model = @reach.first({ .tier eq $tier });
        without $model {
            # the nearest class above, so the work is not under-served; then below
            $model = @reach.grep({ tier-rank(.tier) > $want }).head // @reach.grep({ tier-rank(.tier) < $want }).tail // Model;
            @notes.push("no $tier model is known for {harness-word($a.name)}; {$model.label} ({$model.tier}) stands in") with $model;
        }
        return (Model, '', @notes, "no model is known for it") without $model;
        $model = Model unless %m<sets-model> || $model.flag eq '';
    }
    my $given = '';
    if $effort ne '' {
        my @can = @(%m<efforts> // []).grep({ !$model.defined || !$model.efforts || $model.takes-effort($_) });
        if @can.first($effort) { $given = $effort }
        else {
            $given = @can.grep({ effort-rank($_) <= effort-rank($effort) }).tail // '';
            @notes.push($given ne '' ?? "effort $effort is not offered there; $given is used" !! "effort cannot be set there; its own is used");
        }
    }
    ($model, $given, @notes, '');
}

sub harness-word(Str $name --> Str) { harness-display($name) }

#| The plan's digest: over the plan as pinned, before any step was climbed.
sub plan-digest(%plan --> Str) is export {
    my %copy = %plan;
    %copy<planDigest> = '';
    %copy<escalated>:delete;
    digest-string(canonicalize-json-text(to-wire('ExecutionPlan', load('ExecutionPlan', %copy))));
}

sub fill-model(%plan, $model, Str $effort) {
    with $model {
        %plan<provider> = .provider; %plan<model> = .flag; %plan<modelName> = .label; %plan<tier> = .tier; %plan<access> = .access;
    }
    else { %plan<provider> = ''; %plan<model> = ''; %plan<modelName> = ''; %plan<access> = '' }
    %plan<effort> = $effort;
}

#| Pin a plan: the first adapter, in the order policy gives, that
#| enforces every requirement and can run what was asked.  Returns the
#| adapter, the plan and every rejection, so a denial says exactly why
#| nothing qualified.
sub pin-plan(Registry $reg, @reqs, %policy, Str $only, Want $want, @models --> List) is export {
    my ($ok, $rej) = $reg.qualifying(@reqs, %policy, $only);
    my @rejections = @$rej;
    my @considered;
    for @$ok -> $a {
        my ($model, $effort, $notes, $why-not) = fit-harness($a, $want.tier, $want.effort, $want.model, @models);
        if $why-not ne '' {
            @rejections.push(Rejection.new(:adapter($a.name), :unfit($why-not)));
            @considered.push(doc('PlanRejected', harness => $a.name, why => $why-not));
            next;
        }
        my %plan = doc('ExecutionPlan', schema => SCHEMA-EXECUTION-PLAN, task => $want.task, taskFrom => $want.task-from,
            profile => $want.profile, harness => $a.name, harnessVersion => $a.detect.version,
            reasons => [ |$want.reasons, |@$notes ], overrides => [ |$want.overrides ],
            ladder => [ $want.ladder.map({ doc('PlanStep', profile => .<profile>, tier => .<tier>, effort => (.<effort> // '')) }) ],
            maxEscalations => $want.max-escalations, escalateOn => [ |$want.escalate-on ],
            skills => [ $want.skills.map({ doc('PlanSkill', name => .<name>, version => (.<version> // ''), digest => (.<digest> // '')) }) ]);
        %plan<tier> = $want.tier;
        fill-model(%plan, $model, $effort);
        %plan<considered> = [ |@considered, |@rejections.grep({ .unfit eq '' }).map({ doc('PlanRejected', harness => .adapter, why => .Str.subst(/ ^ <-[:]>+ ':' \s* /, '')) }) ];
        %plan<evidence> = $want.evidence with $want.evidence;
        %plan<planDigest> = plan-digest(%plan);
        return ($a, %plan, @rejections.List);
    }
    (Adapter, Any, @rejections.List);
}

#| A plan for a run no model drives: the procedure executor, pinned to
#| its version, with nothing to choose.
sub procedure-plan(Adapter $a --> Hash) is export {
    my %plan = doc('ExecutionPlan', schema => SCHEMA-EXECUTION-PLAN, harness => $a.name, harnessVersion => $a.detect.version,
        reasons => ['a procedure of the package matched the request: no model is used']);
    %plan<planDigest> = plan-digest(%plan);
    %plan;
}

#| Climb one step of the plan's own ladder, on the same harness, when a
#| check showed the work needs more.  Returns the words of what changed,
#| or '' when there is no step left to take.  The pinned digest is not
#| recomputed: what was climbed is listed beside it.
sub escalate-plan(%plan, Adapter $a, @models, Int $attempt, Str $why --> Str) is export {
    my @done = @(%plan<escalated> // []);
    return '' if @done.elems >= (%plan<maxEscalations> // 0);
    my @ladder = @(%plan<ladder> // []);
    my $step = @ladder[@done.elems] // return '';
    my ($model, $effort, $notes, $why-not) = fit-harness($a, $step<tier>, ($step<effort> // ''), '', @models);
    return '' if $why-not ne '';
    my $from = plan-words(%plan);
    %plan<profile> = $step<profile>;
    %plan<tier> = $step<tier>;
    fill-model(%plan, $model, $effort);
    my $to = plan-words(%plan);
    return '' if $to eq $from;
    %plan<escalated> = [ |@done, doc('PlanEscalation', :$attempt, :$from, :$to, :$why) ];
    "$from to $to";
}

#| The configuration in a few words, for a person: model, then effort.
sub plan-words(%plan --> Str) is export {
    my @w;
    @w.push(%plan<modelName>) if (%plan<modelName> // '') ne '';
    @w.push(%plan<effort> ~ ' effort') if (%plan<effort> // '') ne '';
    @w ?? @w.join(', ') !! 'its own model';
}
