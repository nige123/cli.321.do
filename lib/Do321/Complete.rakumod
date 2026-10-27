unit module Do321::Complete;

use Do321::Commands;
use Do321::JSON;

#| What a shell offers when somebody presses TAB.
#|
#| Three promises, and a test for each:
#|
#|   fast             it reads at most two small files and starts nothing
#|   side-effect free it writes nothing, anywhere, ever
#|   never authority  it loads no package, runs no agent, asks for no
#|                    grant and prompts for nothing
#|
#| Everything it offers comes from the registry in Do321::Commands, or
#| from the trust file a person already has, so a shell cannot offer a
#| command that dispatch does not know.

#| The agents a person can name here: the aliases they chose, and the
#| canonical ids.  Read straight from the trust file - never resolved,
#| never loaded.
sub agent-words(IO::Path $trust --> List) is export {
    return () unless $trust.e;
    my $doc = try parse-json($trust.slurp);
    return () unless $doc ~~ Associative;
    my @words = ($doc<aliases> // {}).keys.sort;
    for ($doc<publishers> // {}).kv -> $domain, %p {
        @words.append(((%p<packages> // {}).keys.sort.map({ "$domain/$_" })));
    }
    @words.unique.List;
}

#| Where a named agent's package sits, by the trust file's own word for
#| it.  Nothing is loaded: the path is read, not followed.
my sub package-path(IO::Path $trust, Str $name --> Str) {
    return '' unless $trust.e;
    my $doc = try parse-json($trust.slurp);
    return '' unless $doc ~~ Associative;
    my $id = ($doc<aliases> // {}){$name} // $name;
    return '' unless $id.contains('/');
    my ($domain, $pkg) = $id.split('/', 2);
    my %entry = ((($doc<publishers> // {}){$domain} // {})<packages> // {}){$pkg} // {};
    (%entry<path> // '').Str;
}

#| The words that start a request to this agent, where its package names
#| procedures: '321 1da go ...' rather than a sentence.  One file is read
#| as text; nothing in the package is run, which is what
#| loading-executes-nothing promises anyway.
sub procedure-words(IO::Path $trust, Str $agent --> List) is export {
    my $path = package-path($trust, $agent);
    return () if $path eq '';
    my $manifest = $path.IO.add('agent.json');
    return () unless $manifest.e;
    my $doc = try parse-json($manifest.slurp);
    return () unless $doc ~~ Associative;
    # 'unsupported' is the fallback a package keeps for anything it cannot
    # do: it is not a word anyone would type.
    (($doc<procedures> // []).map({ (.<name> // '').Str }).grep({ $_ ne '' && $_ ne 'unsupported' })).unique.sort.List;
}

my sub values-for(Str $kind, IO::Path $trust, @adapters --> List) {
    given $kind {
        when 'capability' { CAPABILITIES.List }
        when 'network'    { NETWORKS.List }
        when 'placement'  { PLACEMENTS.List }
        when 'shell'      { SHELLS.List }
        when 'adapter'    { @adapters.List }
        when 'harness'    { @adapters.grep({ $_ ne 'procedure' && $_ ne 'fake' }).List }
        when 'agent'      { agent-words($trust) }
        default           { () }     # a file, a directory or free text: the shell knows better than we do
    }
}

#| True where the shell should complete paths itself rather than take a
#| list from us.
sub paths-wanted(Str $kind --> Bool) is export { so $kind eq 'file' | 'dir' }

#| The candidates for a line somebody is part way through typing.
#|
#| @words is what follows '321', with the word under the cursor last - an
#| empty string where the cursor sits after a space.  The answer is the
#| words to offer, already filtered by what has been typed, or the single
#| token '--paths--' where the shell should offer files of its own.
sub candidates(
    @words,
    IO::Path :$trust = ($*HOME // '/'.IO).add('.321/trust.json'),
    :@adapters = <claude_code procedure fake>,
    --> List
) is export {
    my $current = @words ?? @words.tail !! '';
    my @before  = @words ?? @words[0 ..^ @words.end] !! ();

    # a value for the flag just typed, where that flag takes one
    if @before && @before.tail.starts-with('--') {
        my $flag = (|global-flags(), |(@before[0].defined ?? (command(@before[0]) ?? command(@before[0]).flags !! ()) !! ()))
                   .first({ .name eq @before.tail });
        with $flag {
            return ('--paths--',) if .takes && paths-wanted(.values);
            return values-for(.values, $trust, @adapters).grep({ .starts-with($current) }).List if .takes;
        }
    }

    # a flag is being typed
    if $current.starts-with('-') {
        my $cmd = @before.first({ !.starts-with('-') });
        my @flags = global-flags().map(*.name);
        @flags.append(command($cmd).flags.map(*.name)) if $cmd.defined && command($cmd);
        return @flags.unique.grep({ .starts-with($current) }).sort.List;
    }

    # the first word that is not an option: a command, or an agent
    my $head = @before.grep({ !.starts-with('-') }).first;

    without $head {
        return (|offered-names(), |agent-words($trust)).unique.grep({ .starts-with($current) }).sort.List;
    }

    # a command's own words
    with command($head) -> $cmd {
        my @typed = @before.grep({ !.starts-with('-') });
        if @typed.elems == 1 {
            return $cmd.subs.map(*.name).grep({ .starts-with($current) }).sort.List;
        }
        with $cmd.subs.first({ .name eq @typed[1] }) -> $word {
            return ('--paths--',) if paths-wanted($word.values);
            return values-for($word.values, $trust, @adapters).grep({ .starts-with($current) }).List;
        }
        return ();
    }

    # an agent: the words its package names, and then plain words, which
    # are the person's own and nobody else's business
    if $head eq any(agent-words($trust)) {
        my @typed = @before.grep({ !.starts-with('-') });
        return procedure-words($trust, $head).grep({ .starts-with($current) }).List if @typed.elems == 1;
    }
    ();
}

#| The scripts.  Each is a few lines that call '321 completion words' and
#| offer what comes back, so the shell holds no list of its own and
#| nothing goes stale between releases.
sub script(Str $shell --> Str) is export {
    given $shell {
        when 'bash' { q:to/SH/ }
            # 321 completion for bash.  Install with:
            #   321 completion bash >> ~/.bashrc
            _321_complete() {
                local words candidates
                words=("${COMP_WORDS[@]:1}")
                [[ -z "${COMP_WORDS[COMP_CWORD]}" ]] && words+=("")
                candidates="$(321 completion words -- "${words[@]}" 2>/dev/null)"
                if [[ "$candidates" == "--paths--" ]]; then
                    COMPREPLY=($(compgen -f -- "${COMP_WORDS[COMP_CWORD]}"))
                else
                    COMPREPLY=($(compgen -W "$candidates" -- "${COMP_WORDS[COMP_CWORD]}"))
                fi
            }
            complete -o default -F _321_complete 321
            SH
        when 'zsh' { q:to/SH/ }
            # 321 completion for zsh.  Install with:
            #   321 completion zsh >> ~/.zshrc
            _321_complete() {
                local -a candidates
                candidates=(${(f)"$(321 completion words -- ${words[2,-1]} 2>/dev/null)"})
                if [[ "$candidates[1]" == "--paths--" ]]; then
                    _files
                else
                    compadd -- $candidates
                fi
            }
            compdef _321_complete 321
            SH
        when 'fish' { q:to/SH/ }
            # 321 completion for fish.  Install with:
            #   321 completion fish > ~/.config/fish/completions/321.fish
            function __321_complete
                set -l words (commandline -opc) (commandline -ct)
                set -l candidates (321 completion words -- $words[2..-1] 2>/dev/null)
                if test "$candidates[1]" = "--paths--"
                    __fish_complete_path (commandline -ct)
                else
                    printf '%s\n' $candidates
                end
            end
            complete -c 321 -f -a '(__321_complete)'
            SH
        default { '' }
    }
}
