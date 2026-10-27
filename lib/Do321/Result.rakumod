unit module Do321::Result;

use Do321::JSON;

#| What a command says, for a program.
#|
#| One envelope, one version, for every command: the outcome in words a
#| caller can switch on, the exit code that belongs to it, the facts under
#| 'data' in a shape named by 'dataSchema', and the next step where there
#| is one.  A failure is the same envelope with 'error' filled in, so a
#| caller never has to parse prose to find out what went wrong, and never
#| meets a human screen on standard output.
#|
#| The outcomes are the six a run can end on, and the four a command that
#| is not a run can: a work system distinguishes them without reading a
#| sentence.

constant SCHEMA-RESULT is export = '321-result.v1';

#| What happened, as one word.  'done' and 'no change' both mean the
#| command did what was asked; the rest each need a different answer from
#| whoever called.
constant OUTCOMES is export = <done no_change blocked denied failed stopped>;

#| The exit code that belongs to each outcome.  A document is believed
#| only with its own code beside it.
my constant %EXIT = (
    done      => 0,
    no_change => 0,
    blocked   => 2,
    stopped   => 3,
    failed    => 4,
    denied    => 5,
);
#| Where a command could not even begin: the caller's fault, not the run's.
constant EXIT-USAGE     is export = 64;
constant EXIT-MALFORMED is export = 65;
constant EXIT-INTERNAL  is export = 70;

sub exit-for(Str $outcome --> Int) is export { %EXIT{$outcome} // EXIT-INTERNAL }

#| The error codes a caller may switch on.  A closed list: a new one is a
#| deliberate addition, never a message that happened to be phrased
#| differently.
constant ERROR-CODES is export = <
    unknown_command unknown_agent usage_error
    package_moved package_unreadable package_invalid
    not_permitted approval_required
    harness_missing tool_missing
    receipt_unsigned receipt_invalid
    workspace_missing internal_error
>;

#| An error, as a value: the code a program reads, the one line a person
#| reads, and where to look.
class Error is export {
    has Str $.code is required;
    has Str $.message is required;
    has Str $.detail = '';
    submethod TWEAK { die "not an error code: $!code" unless $!code eq any(ERROR-CODES) }
}

#| The envelope.  'words' carries the lines a person would have read, for
#| a caller that wants to show them rather than invent its own; nothing
#| else in the document is prose.
sub result-document(
    Str  :$command!,
    Str  :$outcome!,
    Str  :$dataSchema = '',
         :%data,
         :@words,
         :@next,
    Error :$error,
    Int  :$exit,
    --> Hash
) is export {
    die "not an outcome: $outcome" unless $outcome eq any(OUTCOMES);
    my %doc =
        schema  => SCHEMA-RESULT,
        command => $command,
        outcome => $outcome,
        exit    => $exit // ($error ?? exit-for($outcome) !! exit-for($outcome)),
        data    => %data,
        ;
    %doc<dataSchema> = $dataSchema if $dataSchema ne '';
    %doc<words> = [|@words] if @words;
    %doc<next>  = [|@next.map({ %( advice => .advice, command => .command ) })] if @next;
    %doc<error> = $error
        ?? %( code => $error.code, message => $error.message, |($error.detail ne '' ?? (detail => $error.detail) !! ()) )
        !! Nil;
    %doc;
}

sub result-json(%doc --> Str) is export { encode-json-pretty(%doc) }
