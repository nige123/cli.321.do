unit module Do321::Shape;

#| The protocol documents as field tables, in the order and with the
#| JSON semantics of the Go structs they replace.  Every document the
#| runtime reads or writes goes through a shape, so that:
#|
#|   - loading drops unknown fields, zero-fills scalars, checks types and
#|     keeps the difference between an absent list and an empty one;
#|   - marshalling emits exactly the fields Go's encoding/json would:
#|     omitempty scalars and lists left out when empty, a nested struct
#|     always present, a pointer struct present only when set, an absent
#|     list without omitempty rendered as null;
#|   - the field order on the wire is the struct order.
#|
#| Digests over documents (receipts, directives, proposals) are taken
#| over the marshalled form, so they equal the Go runtime's digests.
#|
#| Field specs: str int num bool strs anys any map:str, obj:<Type>,
#| ptr:<Type>, list:<Type>, map:<Type>; a trailing ? is omitempty.

use Do321::JSON;

class X::Do321::Shape is Exception {
    has Str $.message;
}

sub shape-error(Str $m) { X::Do321::Shape.new(message => $m).throw }

# --------------------------------------------------------------- tables

my %TYPES;

sub define(Str $name, @fields) { %TYPES{$name} = @fields.List }

define 'AgentManifest', (
    schema => 'str', id => 'str', name => 'str', displayName => 'str', version => 'str',
    publisher => 'obj:Publisher', owner => 'obj:Owner', licence => 'obj:Licence', provenance => 'obj:Provenance',
    identity => 'obj:Identity', prompts => 'strs', skills => 'strs?', procedures => 'list:Procedure?',
    capabilities => 'obj:CapabilitySpec', harness => 'obj:HarnessSpec', placement => 'obj:PlacementSpec',
    outputSchemas => 'obj:OutputSchemas', evaluations => 'strs?');
define 'Publisher', (domain => 'str', url => 'str?');
define 'Owner', (legalName => 'str?', url => 'str?');
define 'Licence', (spdx => 'str?', url => 'str?');
define 'Provenance', (source => 'str?', builtAt => 'str?', builtBy => 'str?');
define 'Identity', (role => 'str', personality => 'str?', tone => 'str?', decisionStyle => 'str?');
define 'Procedure', (name => 'str', matches => 'obj:ProcedureMatch', requires => 'strs?', steps => 'list:ProcedureStep');
define 'ProcedureMatch', (objectiveRegex => 'str?');
define 'ProcedureStep', (
    kind => 'str', tool => 'str?', op => 'str?', text => 'str?', path => 'str?', content => 'str?',
    condition => 'int?', met => 'bool?', proof => 'str?', question => 'str?', action => 'str?',
    target => 'str?', params => 'any?', duration => 'str?');
define 'CapabilitySpec', (required => 'strs', optional => 'strs?', denied => 'strs?');
define 'HarnessSpec', (requires => 'strs', overlays => 'map:str?');
define 'PlacementSpec', (allowed => 'strs');
define 'OutputSchemas', (default => 'str', byProcedure => 'map:str?');

define 'WorkPackage', (
    schema => 'str', packageId => 'str', issuer => 'obj:Issuer', issuedAt => 'str', expiresAt => 'str?',
    idempotencyKey => 'str?', supersedesPackageId => 'str?', correlation => 'obj:Correlation',
    agent => 'obj:AgentRef', placement => 'str', workspace => 'obj:Workspace',
    objective => 'str', instructions => 'str?', context => 'obj:Context', completion => 'obj:Completion',
    capabilities => 'obj:Grants', authority => 'obj:Authority', approval => 'ptr:Approval?', outputSchema => 'str?');
define 'Issuer', (kind => 'str', id => 'str', url => 'str?');
define 'Correlation', (refs => 'list:Ref?');
define 'Ref', (kind => 'str', id => 'str');
define 'AgentRef', (id => 'str', version => 'str?', digest => 'str?');
define 'Workspace', (kind => 'str', path => 'str?', branch => 'str?', ownership => 'str');
define 'Context', (lines => 'strs?', attachments => 'list:Attachment?');
define 'Attachment', (name => 'str', sha256 => 'str?', uri => 'str?');
define 'Completion', (conditions => 'strs', expectedEvidence => 'strs?', landing => 'str?');
define 'Grants', (granted => 'strs', limits => 'obj:Limits');
define 'Limits', (maxUsd => 'num?', maxTurns => 'int?', timeout => 'str?', network => 'str?');
define 'Authority', (may => 'list:AuthorityGrant?', mayNot => 'strs?', approvalRequired => 'strs?');
define 'AuthorityGrant', (capability => 'str', scope => 'str?');
define 'Approval', (
    proposalRef => 'str', approvalRef => 'str', approvedBy => 'str', action => 'str', target => 'str?',
    params => 'any', paramsHash => 'str', proposal => 'ptr:DeploymentProposal?');

define 'WorkDirective', (
    schema => 'str', directiveId => 'str', packageId => 'str', runRef => 'str?', seq => 'int',
    issuer => 'obj:Issuer', issuedAt => 'str', kind => 'str', payload => 'obj:DirectivePayload', digest => 'str');
define 'DirectivePayload', (text => 'str?', answerTo => 'str?', reason => 'str?');

define 'RunEvent', (
    schema => 'str', eventId => 'str', packageId => 'str', runId => 'str', attempt => 'int', seq => 'int',
    at => 'str', kind => 'str', payload => 'any?');
define 'ProtocolError', (schema => 'str', code => 'str', message => 'str', line => 'int?');

define 'RunReceipt', (
    schema => 'str', receiptId => 'str', packageId => 'str', supersedesPackageId => 'str?', runId => 'str',
    issuer => 'obj:Issuer', correlation => 'obj:Correlation', packageDigest => 'str', conditionsDigest => 'str',
    continues => 'ptr:Continuation?', agent => 'obj:AgentRef', harness => 'obj:HarnessInfo',
    attempts => 'list:Attempt', directives => 'obj:DirectiveSummary', instructionHistory => 'obj:HistoryRef',
    events => 'obj:EventSummary', startedAt => 'str', endedAt => 'str', status => 'str', summary => 'str?',
    blockedOn => 'str?', conditions => 'list:ConditionProof', evidence => 'obj:Evidence', cost => 'obj:Cost',
    stop => 'ptr:StopInfo?', denied => 'ptr:DenialInfo?', uncertain => 'strs?', receiptDigest => 'str',
    signature => 'ptr:Signature?');
define 'Continuation', (runId => 'str', receiptId => 'str', receiptDigest => 'str', attempts => 'int');
define 'HarnessInfo', (adapter => 'str', version => 'str?', procedure => 'str?', sessionRefs => 'strs?');
define 'Attempt', ( n => 'int', adapter => 'str', startedAt => 'str', endedAt => 'str', endReason => 'str',
    sessionRef => 'str?', cost => 'obj:Cost');
define 'DirectiveSummary', ( received => 'strs', applied => 'strs', rejected => 'list:RejectedDirective',
    duplicates => 'strs?', gaps => 'list:SequenceGap?');
define 'RejectedDirective', (directiveId => 'str', reason => 'str');
define 'SequenceGap', (directiveId => 'str', expectedSeq => 'int', receivedSeq => 'int');
define 'HistoryRef', (uri => 'str?', digest => 'str');
define 'EventSummary', (emitted => 'int', coalesced => 'int');
define 'ConditionProof', (met => 'bool', proof => 'str?');
define 'Evidence', (
    filesChanged => 'strs?', artifacts => 'list:Artifact?', externalAction => 'ptr:ExternalAction?',
    approvalCheck => 'ptr:ApprovalCheck?', denials => 'strs?', errors => 'strs?', noChange => 'bool?',
    toolCalls => 'list:ToolCall?', proposal => 'ptr:DeploymentProposal?');
define 'ToolCall', (
    tool => 'str', op => 'str', capability => 'str', params => 'map:str?', argv => 'strs?', ok => 'bool',
    exitCode => 'int', durationMs => 'int', unavailable => 'str?', summary => 'str?', outputSha256 => 'str?');
define 'DeploymentProposal', (
    schema => 'str', proposalId => 'str', packageId => 'str', supersedesPackageId => 'str?',
    agent => 'obj:AgentRef', operation => 'str', status => 'str', question => 'str?', service => 'str?',
    target => 'str?', targetHost => 'any?', repository => 'any?', revision => 'any?', manifest => 'any?',
    engine => 'any?', observed => 'any?', operations => 'anys?', checks => 'anys?', unperformed => 'strs',
    blockers => 'strs', health => 'any?', rollback => 'any?', engineCommands => 'anys?', observedAt => 'str',
    proposalDigest => 'str');
define 'Artifact', (name => 'str', sha256 => 'str', uri => 'str?');
define 'ExternalAction', ( proposalRef => 'str', approvalRef => 'str', action => 'str', target => 'str?',
    params => 'any', performedAt => 'str', result => 'str?');
define 'ApprovalCheck', (paramsHashMatched => 'bool', operationMatched => 'bool', detail => 'str?');
define 'Cost', (usd => 'num', turns => 'int', tokens => 'int', basis => 'str?');
define 'StopInfo', (issuer => 'obj:Issuer', at => 'str', reason => 'str?', directiveId => 'str?');
define 'DenialInfo', (reason => 'str', details => 'strs?');
define 'Signature', (keyId => 'str', algorithm => 'str', value => 'str');

# trust-config.v1
define 'TrustConfig', ( schema => 'str', publishers => 'map:TrustPublisher?', local => 'map:LocalPin?',
    aliases => 'map:str?', policy => 'obj:Policy');
define 'TrustPublisher', (keys => 'list:Key?', packages => 'map:Pin?');
define 'Key', (keyId => 'str', publicKey => 'str', since => 'str?', note => 'str?');
define 'Pin', (path => 'str', version => 'str', digest => 'str', trust => 'str?');
define 'LocalPin', (path => 'str');
define 'Policy', (capabilityCeiling => 'strs?', limits => 'obj:Limits', adapters => 'obj:AdapterPolicy');
define 'AdapterPolicy', (preferred => 'strs?', denied => 'strs?');

# the instruction history line
define 'HistoryLine', ( kind => 'str', package => 'ptr:WorkPackage?', directive => 'ptr:WorkDirective?',
    continues => 'ptr:Continuation?', disposition => 'str?', attempt => 'int?', instructions => 'strs?',
    sessionRef => 'str?', endReason => 'str?');

#| The field names a shape declares, in order (for the schema tests).
sub shape-fields(Str $type --> List) is export {
    shape-error("no shape named $type") unless %TYPES{$type}:exists;
    %TYPES{$type}.List.map(*.key).List;
}

sub shape-names(--> List) is export { %TYPES.keys.sort.List }

sub parse-spec(Str $spec) {
    my $omit = $spec.ends-with('?');
    my $s = $omit ?? $spec.chop !! $spec;
    my ($kind, $sub) = $s.contains(':') ?? $s.split(':', 2) !! ($s, '');
    ($kind, $sub, $omit);
}

# --------------------------------------------------------------- loading

sub json-type(Any $v --> Str) {
    given $v {
        when Bool { 'bool' }
        when Numeric { 'number' }
        when Str { 'string' }
        when Associative { 'object' }
        when Positional { 'array' }
        default { $v.defined ?? $v.^name !! 'null' }
    }
}

#| Load plain data (as parse-json returns it, or as code built it) into a
#| document of the named shape.  Unknown fields are dropped; a wrong type
#| throws X::Do321::Shape; scalars and nested structs are always present
#| afterwards, lists and maps only when given.  Idempotent.
sub load(Str $type, Any $data, Str :$path = $type --> Hash) is export {
    shape-error("no shape named $type") unless %TYPES{$type}:exists;
    my @fields = %TYPES{$type}.List;
    shape-error("cannot unmarshal {json-type($data)} into $path") unless $data ~~ Associative || !$data.defined;
    my %in = $data.defined ?? %($data) !! %();
    my %out;
    for @fields -> $field {
        my ($name, $spec) = $field.key, $field.value;
        my ($kind, $sub, $) = parse-spec($spec);
        my $v = %in{$name};
        my $here = "$path.$name";
        given $kind {
            when 'str' {
                %out{$name} = $v.defined ?? ($v ~~ Str ?? $v !! shape-error("cannot unmarshal {json-type($v)} into $here of type string")) !! '';
            }
            when 'int' {
                if !$v.defined { %out{$name} = 0 }
                elsif $v ~~ Int { %out{$name} = $v }
                elsif $v ~~ Numeric && $v == $v.Int { %out{$name} = $v.Int }
                else { shape-error("cannot unmarshal {json-type($v)} into $here of type int") }
            }
            when 'num' {
                if !$v.defined { %out{$name} = 0 }
                elsif $v ~~ Numeric && $v !~~ Bool { %out{$name} = $v }
                else { shape-error("cannot unmarshal {json-type($v)} into $here of type float64") }
            }
            when 'bool' {
                if !$v.defined { %out{$name} = False }
                elsif $v ~~ Bool { %out{$name} = $v }
                else { shape-error("cannot unmarshal {json-type($v)} into $here of type bool") }
            }
            when 'strs' {
                next unless $v.defined;
                shape-error("cannot unmarshal {json-type($v)} into $here of type []string") unless $v ~~ Positional;
                my @l;
                for @$v.kv -> $i, $e {
                    shape-error("cannot unmarshal {json-type($e)} into $here\[$i] of type string") unless $e ~~ Str;
                    @l.push($e);
                }
                %out{$name} = @l;
            }
            when 'anys' {
                next unless $v.defined;
                shape-error("cannot unmarshal {json-type($v)} into $here of type []interface") unless $v ~~ Positional;
                %out{$name} = [ @$v ];
            }
            when 'any' {
                next unless $v.defined;
                shape-error("cannot unmarshal {json-type($v)} into $here of type map") unless $v ~~ Associative;
                %out{$name} = %( $v );
            }
            when 'map' {
                next unless $v.defined;
                shape-error("cannot unmarshal {json-type($v)} into $here of type map") unless $v ~~ Associative;
                my %m;
                for $v.kv -> $k, $e {
                    if $sub eq 'str' {
                        shape-error("cannot unmarshal {json-type($e)} into $here.$k of type string") unless $e ~~ Str;
                        %m{$k} = $e;
                    }
                    else {
                        %m{$k} = load($sub, $e, :path("$here.$k"));
                    }
                }
                %out{$name} = %m;
            }
            when 'obj' {
                %out{$name} = load($sub, $v, :path($here));
            }
            when 'ptr' {
                next unless $v.defined;
                %out{$name} = load($sub, $v, :path($here));
            }
            when 'list' {
                next unless $v.defined;
                shape-error("cannot unmarshal {json-type($v)} into $here of type []$sub") unless $v ~~ Positional;
                %out{$name} = [ @$v.kv.map(-> $i, $e { load($sub, $e, :path("$here\[$i]")) }) ];
            }
            default { shape-error("bad spec $spec for $here") }
        }
    }
    %out;
}

#| A document of the named shape built from code: the same as load, but
#| for convenience with named arguments.
sub doc(Str $type, *%fields --> Hash) is export { load($type, %fields) }

# ------------------------------------------------------------ marshalling

sub empty-scalar($kind, $v --> Bool) {
    given $kind {
        when 'str'  { !$v.defined || $v eq '' }
        when 'int'  { !$v.defined || $v == 0 }
        when 'num'  { !$v.defined || $v == 0 }
        when 'bool' { !$v.defined || !$v }
        default     { !$v.defined || $v.elems == 0 }
    }
}

#| The plain data Go's encoding/json would emit for a document of the
#| named shape: an Ordered of the struct's fields, omitempty applied.
sub marshal(Str $type, Any $doc --> Ordered) is export {
    shape-error("no shape named $type") unless %TYPES{$type}:exists;
    my @fields = %TYPES{$type}.List;
    my %in = $doc.defined ?? %($doc) !! %();
    my @pairs;
    for @fields -> $field {
        my ($name, $spec) = $field.key, $field.value;
        my ($kind, $sub, $omit) = parse-spec($spec);
        my $v = %in{$name};
        given $kind {
            when 'str'  { next if $omit && empty-scalar('str', $v);  @pairs.push($name => ($v // '')) }
            when 'int'  { next if $omit && empty-scalar('int', $v);  @pairs.push($name => ($v // 0).Int) }
            when 'num'  { next if $omit && empty-scalar('num', $v);  @pairs.push($name => ($v // 0)) }
            when 'bool' { next if $omit && empty-scalar('bool', $v); @pairs.push($name => ($v // False)) }
            when 'strs' | 'anys' {
                if !$v.defined { next if $omit; @pairs.push($name => Any) }
                else { next if $omit && $v.elems == 0; @pairs.push($name => [ |@$v ]) }   # Raku++: [ @$v ] nests; |@$v flattens
            }
            when 'any' {
                if !$v.defined { next if $omit; @pairs.push($name => Any) }
                else { next if $omit && $v.elems == 0; @pairs.push($name => %($v)) }
            }
            when 'map' {
                if !$v.defined { next if $omit; @pairs.push($name => Any) }
                else {
                    next if $omit && $v.elems == 0;
                    @pairs.push($name => %( $v.kv.map(-> $k, $e { $k => ($sub eq 'str' ?? $e !! marshal($sub, $e)) }) ));
                }
            }
            when 'obj' { @pairs.push($name => marshal($sub, $v)) }
            when 'ptr' { next unless $v.defined; @pairs.push($name => marshal($sub, $v)) }
            when 'list' {
                if !$v.defined { next if $omit; @pairs.push($name => Any) }
                else { next if $omit && $v.elems == 0; @pairs.push($name => [ @$v.map({ marshal($sub, $_) }) ]) }
            }
        }
    }
    Ordered.new(:@pairs);
}

#| Wire JSON of a document, one line.
sub to-wire(Str $type, Any $doc --> Str) is export { encode-json(marshal($type, $doc)) }

#| Indented JSON of a document, for files.
sub to-pretty(Str $type, Any $doc --> Str) is export { encode-json-pretty(marshal($type, $doc)) }

#| The digest of a document: "sha256:<hex>" over its canonical form.
sub digest-doc(Str $type, Any $doc --> Str) is export { digest-of(marshal($type, $doc)) }
