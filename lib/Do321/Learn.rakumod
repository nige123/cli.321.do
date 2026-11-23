unit module Do321::Learn;

use Do321::JSON;
use Do321::RunDir;

#| What 321 keeps so that work gets better and its value can be seen:
#| work contexts, lessons, what came of a run, and the sums over them.
#|
#| Four things are kept apart, each in a place of its own:
#|   a work context   ~/.321/contexts/<name>.json   a region of related work
#|   a lesson         ~/.321/lessons/<id>.json      one person's, by scope
#|   project lessons  <repo>/.321/lessons/<id>.json the team's, in the repo
#|   an outcome       ~/.321/learn/outcomes.ndjson  what a person or a work
#|                                                  system said of a run
#| A receipt is never rewritten: what is learnt about a run afterwards sits
#| beside it.  Nothing here is an instruction with authority: a lesson and
#| a context reach an agent as what is already known, they grant nothing,
#| and a run's grants are the package's alone.

constant SCHEMA-CONTEXT  is export = 'work-context.v1';
constant SCHEMA-LESSON   is export = 'lesson.v1';
constant SCHEMA-OUTCOME  is export = 'run-outcome.v1';
constant SCHEMA-VALUE    is export = 'value-report.v1';
constant OUTCOMES        is export = <accepted rejected corrected>;
constant LESSON-STATES   is export = <trial kept reverted>;
#| Fewer comparable runs than this is not evidence, and is said so.
constant MIN-SAMPLE      is export = 3;
#| The most lessons kept at the registry that one run is told.
constant REGISTRY-LESSONS-CAP is export = 12;

my sub stamp-now(--> Str) { DateTime.now.utc.Str.subst(/\.\d+/, '') }

sub learn-name-ok(Str $n --> Bool) is export { so $n ~~ / ^ <[a..z 0..9]> <[a..z 0..9 . _ -]> ** 0..63 $ / }

my sub read-doc(IO::Path $f) {
    return Nil unless $f.e;
    my $d = try parse-json($f.slurp);
    $d ~~ Associative ?? $d !! Nil;
}

my sub write-doc(IO::Path $f, %doc) {
    $f.parent.mkdir unless $f.parent.d;
    write-atomic($f, encode-json(%doc) ~ "\n");
}

my sub append-line(IO::Path $f, %doc) {
    $f.parent.mkdir unless $f.parent.d;
    my $h = $f.open(:a);
    $h.say(encode-json(%doc));
    $h.close;
}

my sub read-lines(IO::Path $f --> List) {
    return () unless $f.e;
    $f.lines.map({ try parse-json($_) }).grep(Associative).List;
}

# ----------------------------------------------------------------- contexts

sub contexts-dir(IO::Path $home --> IO::Path) is export { $home.add('contexts') }

#| Every work context kept here, by name.
sub contexts(IO::Path $home --> List) is export {
    my $d = contexts-dir($home);
    return () unless $d.d;
    $d.dir(test => / '.json' $ /).sort.map({ read-doc($_) }).grep(Associative).List;
}

sub context(IO::Path $home, Str $name) is export {
    return Nil unless learn-name-ok($name);
    read-doc(contexts-dir($home).add("$name.json"));
}

#| The copy a run in a context works from: the one of that name, else
#| the nearest name above it that has a copy here, found by dropping
#| leading labels one at a time and never going below two.  A run in
#| billing.api.123.do is told what is known at api.123.do.
sub context-for(IO::Path $home, Str $name) is export {
    return Nil unless learn-name-ok($name);
    my @p = $name.split('.');
    my $last = @p.elems > 2 ?? @p.elems - 2 !! 0;
    for 0 .. $last -> $i {
        my $c = context($home, @p[$i .. *].join('.'));
        return $c if $c.defined;
    }
    Nil;
}

#| Is a name a context or under it?  Names inherit by suffix.
sub context-within(Str $name, Str $of --> Bool) is export { $name eq $of || $name.ends-with('.' ~ $of) }

sub save-context(IO::Path $home, %c) is export {
    private-dir($home);
    private-dir(contexts-dir($home));
    write-doc(contexts-dir($home).add("{%c<name>}.json"), %c);
}

#| The organisation a context belongs to, by its name: a context named
#| under a domain (checkout.acme.example) is that domain's; a plain name
#| is the person's own.  The name says whose it is; it grants no access.
sub context-owner(Str $name --> Str) is export {
    my @p = $name.split('.');
    @p.elems >= 3 ?? @p[1 .. *].join('.') !! '';
}

sub new-context(IO::Path $home, Str $name, Str $purpose --> Hash) is export {
    my %c = schema => SCHEMA-CONTEXT, name => $name, owner => context-owner($name), sharing => 'private',
            purpose => $purpose, notes => [], createdAt => stamp-now();
    save-context($home, %c);
    %c;
}

#| A decision, a rejected approach or a note, added to a context's history.
sub context-note(IO::Path $home, Str $name, Str $kind, Str $text --> Hash) is export {
    my %c = context($home, $name).Hash;
    my @notes = @(%c<notes> // []);
    @notes.push(%( kind => $kind, text => $text, at => stamp-now() ));
    %c<notes> = @notes;
    save-context($home, %c);
    %c;
}

#| Keep a copy of a context as a registry describes it.  What the
#| registry says replaces what it said before; notes made on this machine
#| are kept beside it and stay here.  The copy says where it came from.
sub pull-context(IO::Path $home, %doc, Str $source --> Hash) is export {
    my $name = (%doc<name> // '').Str;
    die "the registry gave a context with no usable name" unless learn-name-ok($name);
    my %was = (context($home, $name) // {}).Hash;
    my @mine = @(%was<notes> // []).grep({ $_ ~~ Associative && (.<from> // '') ne 'registry' });
    my @theirs = (%doc<notes> // []).grep(Associative).map({ %( kind => (.<kind> // 'note').Str, text => (.<text> // '').Str, at => (.<at> // '').Str,
        by => (.<by> // '').Str, from => 'registry' ) });
    my %c = schema => SCHEMA-CONTEXT, name => $name, owner => ((%doc<owner> // '').Str || context-owner($name)),
        sharing => (%doc<sharing> // 'private').Str, purpose => (%doc<purpose> // '').Str, notes => [ |@theirs, |@mine ],
        createdAt => (%was<createdAt> // stamp-now()), source => $source, pulledAt => stamp-now();
    # the lessons the registry gave before stay until it gives them again
    %c<lessons> = %was<lessons> if %was<lessons>:exists;
    %c<lessonsPulledAt> = %was<lessonsPulledAt> if %was<lessonsPulledAt>:exists;
    save-context($home, %c);
    %c;
}

#| The lessons a registry keeps for a context, held in the copy of it.
#| What the registry says replaces what it said before.  Only what is
#| used here is kept of each; a lesson with no words or one taken back
#| is not kept at all.
sub pull-context-lessons(IO::Path $home, Str $name, @cards --> Hash) is export {
    my %c = context($home, $name).Hash;
    my @keep = @cards.grep(Associative).grep({ (.<text> // '').Str ne '' && (.<state> // '').Str ne 'reverted' }).map({ %( id => (.<id> // '').Str, name => (.<name> // '').Str,
        at => (.<at> // '').Str, scope => (.<scope> // '').Str, agent => (.<agent> // '').Str, state => (.<state> // '').Str, text => (.<text> // '').Str ) });
    %c<lessons> = [ |@keep ];
    %c<lessonsPulledAt> = stamp-now();
    save-context($home, %c);
    %c;
}

#| The lessons a context's copy holds from the registry, in the order served.
sub context-lessons(%c --> List) is export { @(%c<lessons> // []).grep(Associative).List }

#| Every registry lesson held in the copies here, each once.
sub registry-lessons(IO::Path $home --> List) is export {
    my %seen;
    my @l;
    for contexts($home) -> %c {
        for context-lessons(%c) -> %r {
            my $key = (%r<id> // '') ne '' ?? %r<id> !! %r<text>;
            next if %seen{$key};
            %seen{$key} = True;
            @l.push(%r);
        }
    }
    @l.List;
}

# ------------------------------------------------------------------ lessons

sub lessons-dir(IO::Path $home --> IO::Path) is export { $home.add('lessons') }
sub project-lessons-dir(Str $root --> IO::Path) is export { $root.IO.add('.321').add('lessons') }

#| The repository a workspace is in, or '' when it is in none: project
#| knowledge lives in the project, under version control, or nowhere.
sub project-root(Str $workspace --> Str) is export {
    return '' if $workspace eq '' || !$workspace.IO.d;
    my $p = try run 'git', '-C', $workspace, 'rev-parse', '--show-toplevel', :out, :err;
    return '' without $p;
    my $o = $p.out.slurp(:close).trim;
    $p.err.slurp(:close);
    $p.exitcode == 0 ?? $o !! '';
}

my sub short-id(--> Str) { ('a'..'z', '2'..'9').flat.roll(6).join }

#| Every lesson that can be read from here: the person's own, and the
#| project's when a project is named.  Each says where it is kept.
sub lessons(IO::Path $home, Str :$project = '' --> List) is export {
    my @l;
    my $d = lessons-dir($home);
    if $d.d {
        for $d.dir(test => / '.json' $ /).sort -> $f {
            my $doc = read-doc($f) // next;
            @l.push(%( |$doc, kept-in => 'personal', file => $f.Str ));
        }
    }
    if $project ne '' && project-lessons-dir($project).d {
        for project-lessons-dir($project).dir(test => / '.json' $ /).sort -> $f {
            my $doc = read-doc($f) // next;
            @l.push(%( |$doc, kept-in => 'project', file => $f.Str ));
        }
    }
    @l.List;
}

sub lesson(IO::Path $home, Str $id, Str :$project = '') is export {
    lessons($home, :$project).first({ (.<id> // '') eq $id });
}

#| A new lesson, on trial: it is tried from the next run it applies to.
#| The scope says when it applies; the provenance, where it came from.
#| When it holds and why may be said too: a registry asks for both.
sub add-lesson(IO::Path $home, Str $text, %scope, %provenance, Str :$when = '', Str :$because = '' --> Hash) is export {
    private-dir($home);
    private-dir(lessons-dir($home));
    my %l = schema => SCHEMA-LESSON, id => short-id(), text => $text, scope => %scope, state => 'trial',
            provenance => %( |%provenance, at => stamp-now() );
    %l<when> = $when if $when ne '';
    %l<because> = $because if $because ne '';
    write-doc(lessons-dir($home).add("{%l<id>}.json"), %l);
    %l;
}

my sub stored(%l --> Hash) { %( %l.grep({ .key ne 'kept-in' && .key ne 'file' }) ) }

#| A change of state, with who made it: a person by name, or
#| EVIDENCE when the runs made it (lessons-review, below).
sub set-lesson-state(%l, Str $state, Str $why = '', Str :$by = '', :%figures) is export {
    my %n = stored(%l);
    %n<state> = $state;
    my @h = @(%n<history> // []);
    @h.push(%( state => $state, at => stamp-now(), why => $why, |($by ne '' ?? (by => $by) !! ()), |(%figures ?? (figures => %figures) !! ()) ));
    %n<history> = @h;
    write-doc(%l<file>.IO, %n);
    %n;
}

sub remove-lesson(%l) is export { %l<file>.IO.unlink }

#| A lesson that was taught to a registry says so: the id it has there,
#| the context it is kept at, and when.  What was sent as its when and
#| because is kept with it.
sub mark-taught(%l, Str $id, Str $at, Str :$when = '', Str :$because = '' --> Hash) is export {
    my %n = stored(%l);
    %n<when> = $when if $when ne '';
    %n<because> = $because if $because ne '';
    %n<taught> = %( id => $id, at => $at, when => stamp-now() );
    write-doc(%l<file>.IO, %n);
    %n;
}

#| A person's lesson put into the project, for the team: a deliberate
#| act, never a side effect of a run.  The copy says where it came from.
sub share-lesson(%l, Str $project, Str $by --> Hash) is export {
    my %n = stored(%l);
    %n<scope> = %( |(%n<scope> // {}), project => True );
    %n<provenance> = %( |(%n<provenance> // {}), sharedBy => $by, sharedAt => stamp-now() );
    my $d = project-lessons-dir($project);
    $d.mkdir unless $d.d;
    write-doc($d.add("{%n<id>}.json"), %n);
    %n;
}

#| Does a lesson apply to this piece of work?  Every scope it states must
#| match; a scope it does not state is not asked.  A harness-scoped
#| lesson applies only when the harness was named, because learning is
#| not assumed to carry from one harness to another.  A project lesson
#| applies only to work in its project.  A context's lesson applies in
#| that context and in the names under it.
sub lesson-applies(%l, Str :$agent = '', Str :$context = '', Str :$harness = '', :@skills) is export {
    return False if (%l<state> // '') eq 'reverted';
    my %s = %l<scope> ~~ Associative ?? %l<scope>.Hash !! {};
    return False if (%s<agent> // '') ne '' && %s<agent> ne $agent && !$agent.ends-with('/' ~ %s<agent>);
    return False if (%s<context> // '') ne '' && !context-within($context, %s<context>);
    return False if (%s<harness> // '') ne '' && %s<harness> ne $harness;
    return False if (%s<skill> // '') ne '' && !@skills.first({ $_ eq %s<skill> }).defined;
    True;
}

sub scope-text(%l --> Str) is export {
    my %s = %l<scope> ~~ Associative ?? %l<scope>.Hash !! {};
    my @p;
    @p.push("agent {%s<agent>}") if (%s<agent> // '') ne '';
    @p.push("context {%s<context>}") if (%s<context> // '') ne '';
    @p.push("skill {%s<skill>}") if (%s<skill> // '') ne '';
    @p.push("harness {%s<harness>}") if (%s<harness> // '') ne '';
    @p.push('this project') if (%l<kept-in> // '') eq 'project';
    @p ?? @p.join(', ') !! 'every run of yours';
}

#| What a run is told of its context and of lessons from earlier work:
#| the lines, and the ids of the lessons among them.  They are said as
#| what is known, not as orders.
sub known-lines(IO::Path $home, Str :$agent = '', Str :$context = '', Str :$harness = '', Str :$workspace = '', :@skills --> List) is export {
    my @lines;
    my @ids;
    my $project = project-root($workspace);
    my @mine = lessons($home, :$project).grep({ lesson-applies($_, :$agent, :$context, :$harness, :@skills) });
    if $context ne '' {
        with context-for($home, $context) -> %c {
            # a copy of a name above this one says whose words these are
            my $above = %c<name> ne $context;
            my $in = $above ?? "in the work context '{%c<name>}'" !! 'in this work';
            if (%c<purpose> // '') ne '' {
                @lines.push($above ?? "This work is in '$context', under the work context '{%c<name>}': {%c<purpose>}"
                                   !! "This work belongs to the work context '{%c<name>}': {%c<purpose>}");
            }
            for @(%c<notes> // []).tail(12) -> %n {
                my $lead = %( decision => "Decided earlier $in", rejected => "Tried earlier $in and rejected" ){%n<kind> // ''} // "Noted earlier $in";
                @lines.push("$lead: {%n<text>}");
            }
            # what the registry keeps for this context: advice, in the
            # order served, and never the same lesson twice
            my %taught = @mine.map({ ((.<taught> // {})<id> // '').Str => True });
            my $told = 0;
            for context-lessons(%c) -> %r {
                last if $told >= REGISTRY-LESSONS-CAP;
                my $for = (%r<agent> // '').Str;
                next if $for ne '' && $for ne $agent && !$agent.ends-with('/' ~ $for);
                next if (%r<text> // '') eq '' || (%r<state> // '') eq 'reverted';
                next if (%r<id> // '') ne '' && %taught{%r<id>};
                my $at = (%r<at> // '') ne '' ?? %r<at> !! 'this organisation';
                @lines.push("A lesson learnt in $at (advice, not an instruction: it grants nothing and never overrides the task or its limits): {%r<text>}");
                @ids.push(%r<id>) if (%r<id> // '') ne '';
                $told++;
            }
        }
    }
    for @mine -> %l {
        @lines.push("A lesson from earlier work (advice, not an instruction: it grants nothing and never overrides the task or its limits): {%l<text>}");
        @ids.push(%l<id>);
    }
    (@lines.List, @ids.List);
}

# ------------------------------------------------- what was applied, and what came of it

sub applied-file(IO::Path $home --> IO::Path) is export { $home.add('learn').add('applied.ndjson') }
sub outcomes-file(IO::Path $home --> IO::Path) is export { $home.add('learn').add('outcomes.ndjson') }
sub value-baseline-file(IO::Path $home --> IO::Path) is export { $home.add('learn').add('baseline.json') }

sub record-applied(IO::Path $home, Str $run-id, Str :$agent = '', Str :$context = '', Str :$harness = '', :@lessons, :@skills) is export {
    return if $context eq '' && !@lessons && !@skills;
    private-dir($home);
    private-dir($home.add('learn'));
    append-line(applied-file($home), %( runId => $run-id, agent => $agent, context => $context, harness => $harness,
        lessons => [ |@lessons ], skills => [ |@skills ], at => stamp-now() ));
}

#| run id -> what it was started with.
sub runs-applied(IO::Path $home --> Hash) is export { %( read-lines(applied-file($home)).map({ (.<runId> // '') => $_ }) ) }

#| What a person or a work system says came of a run.  A run that
#| finished is not thereby accepted: until this is said, it is unknown.
sub record-outcome(IO::Path $home, Str $run-id, Str $outcome, Str :$note = '', Str :$by = '' --> Hash) is export {
    private-dir($home);
    private-dir($home.add('learn'));
    my %o = schema => SCHEMA-OUTCOME, runId => $run-id, outcome => $outcome, note => $note, by => $by, at => stamp-now();
    append-line(outcomes-file($home), %o);
    %o;
}

#| run id -> the last thing said of it.
sub run-outcomes(IO::Path $home --> Hash) is export { %( read-lines(outcomes-file($home)).map({ (.<runId> // '') => $_ }) ) }

# --------------------------------------------------------------------- work

#| One run as the sums need it.  Tokens and money are Int/Numeric when
#| the harness reported them and undefined when it did not: never zero.
class Work is export {
    has Str $.id;
    has Str $.agent = '';
    has Str $.harness = '';
    has Str $.status = '';
    has Str $.basis = '';
    has $.usd;
    has $.tokens;
    has Numeric $.seconds = 0;
    has Int $.attempts = 0;
    has Str $.context = '';
    has @.lessons;
    has Str $.outcome = '';       # accepted | rejected | corrected | '' for unknown
    has Str $.version = '';       # the agent's, as its receipt gave it
    has Str $.digest = '';
    has Str $.ended = '';
    has Str $.receipt-digest = '';  # what the receipt's signature is over
    has Str $.signature = '';       # its value, '' for a receipt nobody signed
    has Str $.signed-by = '';       # the id of the key that signed it
    has DateTime $.started;
    has Str $.task = '';            # the kind of work, as the plan read it
    has Str $.profile = '';         # the configuration the run ended on
    has Str $.model = '';           # the model's name there, '' when the harness used its own
    has Str $.effort = '';
    method who(--> Str) { $!agent.contains('/') ?? $!agent.split('/').tail !! $!agent }
    method finished(--> Bool) { so $!status eq 'completed' | 'no_change' }
}

#| The runs of the last days, newest first, each joined to what it was
#| started with and what was said of it.
sub read-work(IO::Path $home, Int :$days = 30, Int :$cap = 2000, DateTime :$now = DateTime.now --> List) is export {
    my $dir = $home.add('runs');
    return () unless $dir.d;
    my %ap = runs-applied($home);
    my %oc = run-outcomes($home);
    my $floor = $now.earlier(:$days);
    my @out;
    for $dir.dir.grep(*.d).map(*.basename).sort.reverse -> $id {
        last if @out.elems >= $cap;
        my $doc = read-doc($dir.add($id).add('receipt.json')) // next;
        my $started = (try DateTime.new(($doc<startedAt> // '').Str)) // DateTime.new(0);
        last if $started < $floor;
        my $ended = (try DateTime.new(($doc<endedAt> // '').Str)) // $started;
        my %cost = $doc<cost> ~~ Associative ?? $doc<cost>.Hash !! {};
        my $basis = (%cost<basis> // '').Str;
        my $reported = $basis eq 'harness' | 'mixed';
        my $tokens = (%cost<tokens> // 0).Int;
        @out.push(Work.new(:$id, agent => (($doc<agent> // {})<id> // '').Str, harness => (($doc<harness> // {})<adapter> // '').Str,
            status => ($doc<status> // '').Str, :$basis, :$started,
            usd => ($reported ?? (%cost<usd> // 0) !! Any),
            tokens => ($tokens > 0 ?? $tokens !! Any),
            seconds => ($ended > $started ?? ($ended - $started) !! 0),
            attempts => @($doc<attempts> // []).elems,
            version => (($doc<agent> // {})<version> // '').Str, digest => (($doc<agent> // {})<digest> // '').Str, ended => ($doc<endedAt> // '').Str,
            receipt-digest => ($doc<receiptDigest> // '').Str, signature => (($doc<signature> // {})<value> // '').Str, signed-by => (($doc<signature> // {})<keyId> // '').Str,
            context => ((%ap{$id} // {})<context> // '').Str,
            lessons => @((%ap{$id} // {})<lessons> // []),
            task => (($doc<plan> // {})<task> // '').Str, profile => (($doc<plan> // {})<profile> // '').Str,
            model => (($doc<plan> // {})<modelName> // '').Str, effort => (($doc<plan> // {})<effort> // '').Str,
            outcome => ((%oc{$id} // {})<outcome> // '').Str));
    }
    @out.List;
}

my sub median(@n) {
    return Any unless @n;
    my @s = @n.sort;
    @s.elems %% 2 ?? (@s[@s.elems div 2 - 1] + @s[@s.elems div 2]) / 2 !! @s[@s.elems div 2];
}

#| What a set of runs adds up to.  Every figure says how many runs it
#| rests on; a run that reported no cost is counted as unknown.
sub sums(@work --> Hash) is export {
    my @priced = @work.grep({ .usd.defined });
    my @counted = @work.grep({ .tokens.defined });
    my @known = @work.grep({ .outcome ne '' });
    %(
        runs => @work.elems,
        finished => @work.grep(*.finished).elems,
        usd => ([+] @priced.map(*.usd)) // 0,
        priced-runs => @priced.elems,
        unpriced-runs => @work.grep({ !.usd.defined && .basis ne 'none' }).elems,
        modelless-runs => @work.grep({ .basis eq 'none' }).elems,
        tokens => ([+] @counted.map(*.tokens)) // 0,
        token-runs => @counted.elems,
        seconds => ([+] @work.map(*.seconds)) // 0,
        retries => ([+] @work.map({ (.attempts - 1) max 0 })) // 0,
        accepted => @work.grep({ .outcome eq 'accepted' }).elems,
        rejected => @work.grep({ .outcome eq 'rejected' }).elems,
        corrected => @work.grep({ .outcome eq 'corrected' }).elems,
        unknown => @work.elems - @known.elems,
        median-usd => median(@priced.map(*.usd)),
        median-seconds => median(@work.map(*.seconds)),
    );
}

#| A lesson against the work it could have helped: the runs it was
#| applied to, and comparable runs it was not (the same agent, and the
#| same context when the lesson is scoped to one).  Two sums and whether
#| there is enough of each to say anything.
sub compare-lesson(%l, @work --> Hash) is export {
    my %s = %l<scope> ~~ Associative ?? %l<scope>.Hash !! {};
    my @with = @work.grep({ (%l<id> // '') (elem) .lessons });
    my @pool = @work.grep({ !((%l<id> // '') (elem) .lessons) });
    @pool = @pool.grep({ .who eq %s<agent> || .agent eq %s<agent> }) if (%s<agent> // '') ne '';
    @pool = @pool.grep({ context-within(.context, %s<context>) }) if (%s<context> // '') ne '';
    @pool = @pool.grep({ .harness eq %s<harness> }) if (%s<harness> // '') ne '';
    # with no agent in its scope, compare within the agents it ran with
    if (%s<agent> // '') eq '' && @with { my %who = @with.map({ .agent => True }); @pool = @pool.grep({ %who{.agent} }) }
    %( with => sums(@with), without => sums(@pool), enough => (@with.elems >= MIN-SAMPLE && @pool.elems >= MIN-SAMPLE) );
}

# ------------------------------------------------- lessons from what people said

#| Who decided a lesson's state when the runs did, not a person.
constant EVIDENCE is export = 'evidence';
#| The longest correction kept as a lesson's words.
constant LESSON-TEXT-MAX is export = 1000;

#| A person's correction is the cheapest lesson there is: their own words,
#| said of a run they judged.  An outcome of corrected or rejected that
#| carries words becomes ONE lesson on trial, scoped to the run's agent
#| and its work context and to no harness and no model, so it reaches the
#| agent's next runs whatever they run on.  Its provenance names the run,
#| the outcome, who said it and what the run ran on.  No model is asked:
#| the words are the person's, as written.  The same run never proposes a
#| second lesson, however often its outcome is said again; an outcome with
#| no words proposes nothing, since there is nothing to learn from it.
sub propose-from-outcome(IO::Path $home, %o --> Hash) is export {
    return %() unless (%o<outcome> // '') eq 'corrected' | 'rejected';
    my $text = (%o<note> // '').Str.trim.subst(/\s+/, ' ', :g);
    return %() if $text eq '';
    my $run = (%o<runId> // '').Str;
    return %() if $run eq '';
    with lessons($home).first({ ((.<provenance> // {})<fromOutcome> // '') eq $run }) { return %( |$_, existing => True ) }
    my $doc = read-doc($home.add('runs').add($run).add('receipt.json'));
    my %ap = (runs-applied($home){$run} // {}).Hash;
    my $agent = ($doc ?? (($doc<agent> // {})<id> // '') !! (%ap<agent> // '')).Str;
    return %() if $agent eq '';
    my %scope = agent => ($agent.contains('/') ?? $agent.split('/').tail !! $agent);
    %scope<context> = %ap<context>.Str if (%ap<context> // '') ne '';
    my %plan = $doc && $doc<plan> ~~ Associative ?? $doc<plan>.Hash !! {};
    my %prov = from => 'outcome', fromOutcome => $run, runId => $run, outcome => %o<outcome>.Str, by => (%o<by> // '').Str,
        agent => $agent, agentVersion => ($doc ?? (($doc<agent> // {})<version> // '') !! '').Str,
        harness => ($doc ?? (($doc<harness> // {})<adapter> // '') !! (%ap<harness> // '')).Str,
        model => (%plan<modelName> // %plan<model> // '').Str;
    add-lesson($home, $text.substr(0, LESSON-TEXT-MAX), %scope, %prov);
}

#| Did a person decide this lesson?  Any change of state not made by
#| the evidence is a person's, and the evidence never overrules it.
sub person-decided(%l --> Bool) is export {
    so @(%l<history> // []).first({ $_ ~~ Associative && ($_<by> // '') ne EVIDENCE });
}

#| What the runs say of a lesson: supported, contradicted, or not enough
#| to say.  Judged runs are those a person or a work system gave an
#| outcome; a finished run nobody judged is not evidence either way.
#|   contradicted: MIN-SAMPLE judged runs with it, and none accepted, or
#|                 accepted less often than MIN-SAMPLE judged comparable
#|                 runs without it.
#|   supported:    MIN-SAMPLE accepted runs with it, and accepted at
#|                 least as often as MIN-SAMPLE judged comparable runs
#|                 without it.  One success, or a few with nothing to
#|                 compare them to, is not support.
sub judge-lesson(%l, @work --> Hash) is export {
    my %c = compare-lesson(%l, @work);
    my sub judged(%x) { %x<accepted> + %x<rejected> + %x<corrected> }
    my ($wj, $oj) = judged(%c<with>), judged(%c<without>);
    my %f = with-judged => $wj, with-accepted => %c<with><accepted>, without-judged => $oj, without-accepted => %c<without><accepted>;
    my sub rate($a, $n) { $n ?? $a / $n !! 0 }
    my $wr = rate(%c<with><accepted>, $wj);
    my $or = rate(%c<without><accepted>, $oj);
    my sub pct($r) { ($r * 100).round ~ '%' }
    return %( verdict => 'too-few', figures => %f, why => "{$wj} judged runs with it; {MIN-SAMPLE} are needed" ) if $wj < MIN-SAMPLE;
    return %( verdict => 'contradicted', figures => %f, why => "none of the {$wj} judged runs with it was accepted" ) if %c<with><accepted> == 0;
    return %( verdict => 'no-baseline', figures => %f, why => "{$oj} judged comparable runs without it; {MIN-SAMPLE} are needed to compare" ) if $oj < MIN-SAMPLE;
    return %( verdict => 'contradicted', figures => %f, why => "accepted {pct($wr)} of {$wj} runs with it, against {pct($or)} of {$oj} without" ) if $wr < $or;
    return %( verdict => 'too-few', figures => %f, why => "{%c<with><accepted>} accepted runs with it; {MIN-SAMPLE} are needed" ) if %c<with><accepted> < MIN-SAMPLE;
    %( verdict => 'supported', figures => %f, why => "accepted {pct($wr)} of {$wj} runs with it, against {pct($or)} of {$oj} without" );
}

#| Let the runs move the lessons the runs may move: this person's own
#| lessons that no person has decided, on trial or kept by the evidence.
#| Supported moves trial to kept; contradicted moves trial, or kept by
#| the evidence, to reverted, where it stays on record and is given to
#| no run.  A person's keep or revert stands, and only a person restores
#| a reverted lesson.  Project lessons are the team's, kept in its
#| repository, and are never rewritten here.  Returns what changed.
sub review-lessons(IO::Path $home, @work --> List) is export {
    my @changed;
    # lessons() named no project, so these are this person's own only
    for lessons($home).grep({ !person-decided($_) }) -> %l {
        my $state = (%l<state> // '').Str;
        next unless $state eq 'trial' | 'kept';
        my %j = judge-lesson(%l, @work);
        my $to = %j<verdict> eq 'contradicted' ?? 'reverted' !! (%j<verdict> eq 'supported' && $state eq 'trial') ?? 'kept' !! '';
        next if $to eq '';
        my %n = set-lesson-state(%l, $to, %j<why>, by => EVIDENCE, figures => %j<figures>);
        @changed.push(%( |%n, was => $state ));
    }
    @changed.List;
}

sub baseline(IO::Path $home) is export { read-doc(value-baseline-file($home)) }

#| A person's own estimate of what an accepted piece of work would have
#| taken them: minutes each, and what an hour of theirs is worth.
sub set-baseline(IO::Path $home, Numeric $minutes, Numeric $rate, Str :$note = '' --> Hash) is export {
    private-dir($home);
    private-dir($home.add('learn'));
    my %b = minutes => $minutes, rate => $rate, currency => 'USD', note => $note, setAt => stamp-now();
    write-doc(value-baseline-file($home), %b);
    %b;
}

#| An estimate of what was saved, or why none can be given.  It counts
#| only work a person accepted, sets the whole spend against it (failed
#| runs and retries included), and says its assumptions.
sub savings(%sum, $base --> Hash) is export {
    return %( known => False, why => 'no baseline: say what accepted work would have taken you' ) unless $base ~~ Associative;
    return %( known => False, why => "not enough comparable work yet: {%sum<accepted>} accepted, {MIN-SAMPLE} needed" ) if %sum<accepted> < MIN-SAMPLE;
    my $minutes = %sum<accepted> * $base<minutes>;
    my $worth = $minutes / 60 * $base<rate>;
    %( known => True, accepted => %sum<accepted>, minutes => $minutes, worth => $worth, spend => %sum<usd>,
       net => $worth - %sum<usd>, spend-is-floor => (%sum<unpriced-runs> > 0),
       assumption => "{$base<minutes>} minutes of a person's time for each accepted run, at \${$base<rate>} an hour" );
}

sub money($n --> Str) is export { $n.defined ?? sprintf('$%.2f', $n) !! 'not reported' }

sub duration(Numeric $s --> Str) is export {
    my $t = $s.Int;
    $t >= 3600 ?? sprintf('%dh %02dm', $t div 3600, ($t div 60) % 60) !! $t >= 60 ?? sprintf('%dm %02ds', $t div 60, $t % 60) !! "{$t}s";
}

sub count-text(Int $n --> Str) is export {
    $n >= 1_000_000 ?? sprintf('%.1fM', $n / 1_000_000) !! $n >= 10_000 ?? sprintf('%.0fk', $n / 1000) !! $n.Str;
}
