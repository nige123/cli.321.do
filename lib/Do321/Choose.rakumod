unit module Do321::Choose;

#| The one place a run's curation is asked for, whoever started it: a
#| person at a terminal, Mission Control, or a work system handing over
#| a package.  It joins the agent's own curation to what this machine
#| has recorded, and returns what to ask the runtime for.
#|
#| It reads and never writes.  A package handed over by a work system
#| carries no kind of work and no override of its own, so its request
#| is read exactly as a person's would be.

use Do321::Models;
use Do321::Plan;
use Do321::Curate;
use Do321::Learn;
use Do321::JSON;
use Do321::RunDir;

#| A skill as installed here (~/.321/skills/<publisher>/<name>/skill.json),
#| or nothing.  Read directly: the registry client is not needed to know
#| what is already on this machine.
my sub installed-skill(IO::Path $home, Str $id) {
    return Any unless $id ~~ / ^ <[a..z 0..9]> <[a..z 0..9 . _ -]>* '/' <[a..z 0..9]> <[a..z 0..9 . _ -]>* $ /;
    my ($pub, $name) = $id.split('/', 2);
    my $f = $home.add('skills').add($pub).add($name).add('skill.json');
    my $d = $f.f ?? (try parse-json($f.slurp)) !! Any;
    $d ~~ Associative ?? $d !! Any;
}

#| The models known on this machine.
sub models-here(IO::Path $home --> List) is export { catalogue($home)[0] }

#| The words a person may set a run's configuration with.
class Asked is export {
    has Str $.task = '';
    has Str $.profile = '';
    has Str $.model = '';
    has Str $.effort = '';
    method any(--> Bool) { so ($!task, $!profile, $!model, $!effort).first(* ne '') }
    #| As arguments for `321 run`, so a hosted run is asked the same way.
    method argv(--> List) {
        my @a;
        @a.push('--task', $!task) if $!task ne '';
        @a.push('--profile', $!profile) if $!profile ne '';
        @a.push('--model', $!model) if $!model ne '';
        @a.push('--effort', $!effort) if $!effort ne '';
        @a.List;
    }
}

#| What to ask the runtime for, for this agent and this package.  Dies
#| (X::Do321::Curate) when the agent's curation is unsound or a person
#| named something it does not have.
sub want-for(IO::Path $home, $agent, %wp, Asked $asked = Asked.new --> Want) is export {
    my %c = read-curation($agent.defined ?? $agent.curation !! Str);
    my $id = (%wp<packageId> // '').Str;
    my %applied = (runs-applied($home){$id} // {}).Hash;
    my $context = (%applied<context> // '').Str;
    my @work = read-work($home, days => 90);
    curate(%c, objective => (%wp<objective> // '').Str, task => $asked.task, profile => $asked.profile,
        model => $asked.model, effort => $asked.effort,
        max-usd => ((%wp<capabilities><limits><maxUsd> // 0) ~~ Numeric ?? (%wp<capabilities><limits><maxUsd> // 0) !! 0),
        :@work, agent => (%wp<agent><id> // '').Str, :$context,
        # a skill is pinned as it is installed here: its version and the digest of its text
        skills => @(%applied<skills> // []).map({
            my $d = installed-skill($home, .Str);
            %( name => .Str, version => (($d // {})<version> // '').Str, digest => (($d // {})<digest> // '').Str )
        }).List);
}

# ------------------------------------------------------- what a project pins

#| A project may say which version of an agent and of a skill its work is
#| done with: <repo>/.321/pins.json (project-pins.v1), a file the team
#| reviews and commits like any other.  Two people working in the same
#| repository then run the same agent and the same skill text, or are told
#| exactly what differs.  It grants nothing: trust is still each person's
#| own trust file, and a pin can only refuse a run, never allow one.
constant SCHEMA-PROJECT-PINS is export = 'project-pins.v1';

sub project-pins-file(Str $root --> IO::Path) is export { $root.IO.add('.321').add('pins.json') }

sub read-project-pins(Str $root --> Hash) is export {
    return %() if $root eq '';
    my $f = project-pins-file($root);
    my $d = $f.f ?? (try parse-json($f.slurp)) !! Any;
    return %() unless $d ~~ Associative && ($d<schema> // '') eq SCHEMA-PROJECT-PINS;
    %( agents => %(($d<agents> // {}) ~~ Associative ?? $d<agents> !! {}), skills => %(($d<skills> // {}) ~~ Associative ?? $d<skills> !! {}) );
}

#| Pin an agent as it is loaded here, and any skills as installed here.
sub write-project-pins(Str $root, IO::Path $home, $agent, @skills --> Hash) is export {
    my %p = read-project-pins($root);
    %p<agents> //= %(); %p<skills> //= %();
    %p<agents>{$agent.id} = %( version => ($agent.manifest<version> // '').Str, digest => $agent.digest ) with $agent;
    for @skills -> $id {
        my $d = installed-skill($home, $id) // die "$id is not installed here, so there is no version to pin\n";
        %p<skills>{$id} = %( version => ($d<version> // '').Str, digest => ($d<digest> // '').Str );
    }
    my $f = project-pins-file($root);
    $f.parent.mkdir unless $f.parent.d;
    write-atomic($f, encode-json-pretty(%( schema => SCHEMA-PROJECT-PINS, agents => %p<agents>, skills => %p<skills> )) ~ "\n");
    %p;
}

#| Where this machine differs from what the project pins, in words; none
#| when it agrees or the project pins nothing that is in use.
sub pin-problems(Str $root, IO::Path $home, $agent, @skills --> List) is export {
    my %p = read-project-pins($root);
    return () unless %p;
    my @out;
    with $agent {
        with %p<agents>{$agent.id} -> %want {
            @out.push("this project pins {$agent.id} {%want<version>} ({short(%want<digest>)}); here it is {$agent.manifest<version>} ({short($agent.digest)})")
                if (%want<digest> // '') ne $agent.digest;
        }
    }
    for @skills -> $id {
        with %p<skills>{$id} -> %want {
            my $d = installed-skill($home, $id);
            my $have = (($d // {})<digest> // '').Str;
            @out.push("this project pins the skill $id {%want<version>} ({short(%want<digest>)}); here it is " ~ ($have eq '' ?? 'not installed' !! "{$d<version>} ({short($have)})"))
                if (%want<digest> // '') ne $have;
        }
    }
    @out.List;
}

my sub short(Str $digest --> Str) { $digest.subst(/ ^ 'sha256:' /, '').substr(0, 12) }

#| The same check for a package about to run: its workspace is the project.
sub package-pin-problems(IO::Path $home, $agent, %wp --> List) is export {
    my $root = ((%wp<workspace> // {})<path> // '').Str;
    return () if $root eq '';
    my %applied = (runs-applied($home){(%wp<packageId> // '').Str} // {}).Hash;
    pin-problems($root, $home, $agent, @(%applied<skills> // []).map(*.Str));
}
