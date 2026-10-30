unit module Do321::RunWords;

#| The words that act on runs, said the same way in two places: at the
#| shell, one at a time ('321 stop 3by'), and on Mission Control's input
#| line ('/stop'), where a run left out is the one you are on.  One list
#| and one parser, so the two cannot drift: a word learnt in one place
#| works in the other.
#|
#| It carries no behaviour.  Parsing says what was asked; the shell and
#| the screen each carry it out and say what came of it in their own way.

class RunWord is export {
    has Str  $.name is required;
    #| How it is said, after the word.
    has Str  $.usage is required;
    has Str  $.what is required;
    #| Only on the screen: there is nothing to find or view at a shell.
    has Bool $.screen-only = False;
}

constant RUN-VIEWS is export = <all active needs>;

#| Every word, in the order the screen offers them.
sub run-words(--> List) is export {
    (
    RunWord.new(name => 'start',   usage => '[--harness NAME] [--isolate] <agent> <request...>', what => 'start a run that keeps going when you leave'),
    RunWord.new(name => 'steer',   usage => '<run> <words...>', what => 'say something to a run while it works'),
    RunWord.new(name => 'hold',    usage => '<run>',            what => 'end its current step now and wait'),
    RunWord.new(name => 'resume',  usage => '<run>',            what => 'carry on a held run where it was'),
    RunWord.new(name => 'stop',    usage => '<run> [--force]',  what => 'ask a run to stop, and wait for its own word'),
    RunWord.new(name => 'restart', usage => '<run> [--harness NAME]', what => "run an ended run's request again, with its own budget"),
    RunWord.new(name => 'attach',  usage => '<run>',            what => 'open Mission Control on one run'),
    RunWord.new(name => 'find',    usage => '<words...>',       what => "find words in this run's conversation", :screen-only),
    RunWord.new(name => 'view',    usage => '[all|active|needs]', what => 'which runs the deck shows', :screen-only),
    RunWord.new(name => 'quit',    usage => '',                 what => 'leave Mission Control; every run keeps going', :screen-only),
    )
}

sub run-word(Str $name --> RunWord) is export { run-words().first({ .name eq $name }) }

#| The words a screen line could be finishing: '/st' offers start, steer
#| and stop.
sub run-words-starting(Str $prefix, Bool :$screen = True --> List) is export {
    run-words().grep({ ($screen || !.screen-only) && .name.starts-with($prefix) }).List;
}

#| What was asked, from the words after the command word.  On the screen
#| a run may be left out; at the shell it never may.  Returns a hash: verb,
#| run (a name, or '' for the one you are on), words (the request, the
#| steer or what to find, word for word), harness, isolate, workspace,
#| force, yes, view; or error, saying what is wrong in one line.
sub parse-run-words(Str $verb, @args, Bool :$screen = False --> Hash) is export {
    my %r = verb => $verb, run => '', words => '', harness => '', isolate => False, workspace => '',
            force => False, yes => False, view => '';
    my $w = run-word($verb);
    return %( |%r, error => "'$verb' is not a run word" ) without $w;
    return %( |%r, error => "'$verb' is for Mission Control's screen" ) if $w.screen-only && !$screen;
    my @a = @args;
    my sub err(Str $e) { %( |%r, error => $e ) }

    # the request or the steer is the person's own, word for word: options
    # come before it, never inside it
    given $verb {
        when 'start' {
            while @a && @a[0].starts-with('--') {
                given @a.shift {
                    when '--harness'   { return err('--harness needs a name; 321 harness can lists them') unless @a; %r<harness> = @a.shift }
                    when '--isolate'   { %r<isolate> = True }
                    when '--workspace' { return err('--workspace needs a directory') unless @a; %r<workspace> = @a.shift }
                    default            { return err("'$_' is not an option of start") }
                }
            }
            return err('say which agent and what it should do') if @a < 2;
            %r<run> = '';
            %r<agent> = @a.shift;
            %r<words> = @a.join(' ');
            return %r;
        }
        when 'steer' {
            # on the screen the run is the one you are on
            unless $screen {
                return err('say which run, then what to tell it') if @a < 2;
                %r<run> = @a.shift;
            }
            return err('say what to tell it') unless @a;
            %r<words> = @a.join(' ');
            return %r;
        }
        when 'find' {
            return err('say what to find') unless @a;
            %r<words> = @a.join(' ');
            return %r;
        }
        when 'view' {
            return err('view takes one of: ' ~ RUN-VIEWS.join(', ')) if @a > 1 || (@a && @a[0] ne any(RUN-VIEWS));
            %r<view> = @a ?? @a[0] !! '';
            return %r;
        }
        when 'quit' {
            return err('quit takes nothing after it') if @a;
            return %r;
        }
    }

    # stop, hold, resume, restart, attach: one run, and their own options
    my @runs;
    while @a {
        my $x = @a.shift;
        given $x {
            when '--force'   { return err("'--force' is not an option of $verb") unless $verb eq 'stop'; %r<force> = True }
            when '--yes'     { return err("'--yes' is not an option of $verb") unless $verb eq 'restart'; %r<yes> = True }
            when '--harness' {
                return err("'--harness' is not an option of $verb") unless $verb eq 'restart';
                return err('--harness needs a name; 321 harness can lists them') unless @a;
                %r<harness> = @a.shift;
            }
            when .starts-with('--') { return err("'$x' is not an option of $verb") }
            default { @runs.push($x) }
        }
    }
    return err("say one run; its last three characters will do") if @runs > 1;
    if !@runs && (!$screen || $verb eq 'attach') {
        return err("say which run; its last three characters will do");
    }
    %r<run> = @runs ?? @runs[0] !! '';
    %r;
}

#| A line typed on the screen: '/stop 3by' is the word stop, '//x' is the
#| text '/x' sent as a steer, and anything else is a steer.  Returns the
#| same hash as parse-run-words, with verb 'steer' for plain text.
sub parse-run-line(Str $line --> Hash) is export {
    my $t = $line.trim;
    return parse-run-words('steer', [$t.substr(1)], :screen) if $t.starts-with('//');
    return parse-run-words('steer', [$t], :screen) unless $t.starts-with('/');
    my @w = $t.substr(1).words;
    return %( verb => '', error => 'say a word after the slash; / alone lists them' ) unless @w;
    my $verb = @w.shift;
    with run-word($verb) { return parse-run-words($verb, @w, :screen) }
    my @near = run-words-starting($verb);
    return parse-run-words(@near[0].name, @w, :screen) if @near == 1;
    %( verb => $verb, error => @near
        ?? "/$verb could be {@near.map({ '/' ~ .name }).join(' or ')}"
        !! "/$verb is not a word here; / lists them" );
}
