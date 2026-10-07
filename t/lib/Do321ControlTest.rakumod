# Copyright Nige Ltd. Author: Nigel Hamilton.
unit module Do321ControlTest;
# A stand-in iz4 for the tests: it speaks the machine interface and
# answers whatever the environment tells it to.  The runtime only ever
# runs iz4 and reads its documents, so this is the whole dependency.
use Do321Test;

#| A stand-in iz4.  STUB_ACTION, STUB_CHANGE and STUB_VERIFY choose each
#| check's result (default pass); STUB_OLD=1 makes it an iz4 from before
#| the machine interface; STUB_INVALID=1 reports an invalid IZ4; every
#| call is appended to STUB_LOG when that is set.
sub stub-iz4(--> Str) is export {
    my $f = temp-dir().add('iz4');
    $f.spurt(q:to/SH/);
        #!/bin/sh
        [ -n "$STUB_LOG" ] && echo "$*" >> "$STUB_LOG"
        if [ -n "$STUB_OLD" ]; then
          case "$1 $2" in
            "agent packet") echo "IZ4 agent packet (old stub)"; exit 0 ;;
            *) echo "Usage: iz4 ..." >&2; exit 2 ;;
          esac
        fi
        find_iz4() { d=$(pwd); while :; do [ -f "$d/IZ4" ] && { echo "$d/IZ4"; return 0; }; [ -e "$d/.git" ] && return 1; [ "$d" = "/" ] && return 1; d=$(dirname "$d"); done; }
        doc() { # check result reason
          extra=''
          [ "$2" = needs_human ] && extra=',"proposed_invariant_change":{"kind":"change","summary":"1 commitment change(s)","changes":[{"kind":"reworded","number":5,"text":"Staff decide."}],"agree_with":"iz4 approve --candidate=abc --base=HEAD","proposal_digest":"d1g"}'
          [ "$2" = needs_human ] || extra=',"proposed_invariant_change":null'
          rep=''
          [ "$1" = verify ] && rep=',"report":{"uncertain":["Invariant 5 Nothing is deleted.: uncertain"]},"parts":[{"part":"structure","result":"pass","detail":"well formed"},{"part":"change","result":"'"${STUB_CHANGE:-pass}"'","detail":"change"},{"part":"report","result":"pass","detail":"report"}]'
          printf '{"schema":"iz4-check/1","tool":"iz4/stub","check":"%s","result":"%s","reason":"%s","invariants_considered":[5],"evidence":{"rule":"stub"%s}%s,"iz4":{"file":"x","sha256":"y"},"limits":"a stub establishes nothing"}\n' "$1" "$2" "$3" "$rep" "$extra"
          case "$2" in needs_human) exit 2 ;; block) exit 3 ;; *) exit 0 ;; esac
        }
        case "$1 $2" in
          "discover --json")
            f=$(find_iz4) || { echo '{"schema":"iz4-discover/1","present":false,"valid":false,"invariants":[]}'; exit 0; }
            if [ -n "$STUB_INVALID" ]; then
              printf '{"schema":"iz4-discover/1","present":true,"file":"%s","sha256":"abc123","valid":false,"errors":["3: no IS FOR WHAT"],"invariants":[]}\n' "$f"
            else
              printf '{"schema":"iz4-discover/1","present":true,"file":"%s","sha256":"abc123","valid":true,"errors":[],"invariants":[{"number":0,"foundation":true},{"number":5,"foundation":false}]}\n' "$f"
            fi
            exit 0 ;;
          "context --json") printf '%s\n' '{"schema":"iz4-context/1","text":"These invariants govern this work (stub).\nINVARIANT 5\nNothing is deleted.\n"}'; exit 0 ;;
          "check action") cat > "${STUB_ACTION_IN:-/dev/null}"; doc action "${STUB_ACTION:-pass}" "action ${STUB_ACTION:-pass}" ;;
          "check change") doc change "${STUB_CHANGE:-pass}" "change ${STUB_CHANGE:-pass}" ;;
          "verify --worktree")
            for a in "$@"; do case "$a" in --summary=*) [ -n "$STUB_SUMMARY_OUT" ] && cp "${a#--summary=}" "$STUB_SUMMARY_OUT" ;; esac; done
            doc verify "${STUB_VERIFY:-pass}" "verify ${STUB_VERIFY:-pass}" ;;
          *) echo "stub iz4: unknown: $*" >&2; exit 2 ;;
        esac
        SH
    $f.chmod(0o755);
    $f.Str;
}

#| A Git workspace that keeps an IZ4.
sub iz4-workspace(Bool :$iz4 = True --> IO::Path) is export {
    my $ws = temp-dir();
    my $p = run 'git', 'init', '-q', $ws.Str, :out, :err; $p.out.slurp(:close); $p.err.slurp(:close);
    $ws.add('IZ4').spurt("IZ4\n\nIS FOR WHAT?\nA test.\n\nIS FOR WHO?\nTesters.\n") if $iz4;
    $ws;
}
