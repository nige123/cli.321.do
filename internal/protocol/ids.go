package protocol

import (
	"crypto/rand"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
)

// LocalDomain is the pseudo-publisher for unsigned packages that belong to
// nobody in particular: "local/helper". It is never a verified identity.
const LocalDomain = "local"

var (
	agentNameRe = regexp.MustCompile(`^[a-z0-9]{2,32}$`)
	domainRe    = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$`)
	versionRe   = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$`)
	digestRe    = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
)

// AgentID is a parsed canonical identity: publisher domain plus name.
type AgentID struct {
	Domain string
	Name   string
}

// String renders the canonical form.
func (a AgentID) String() string { return a.Domain + "/" + a.Name }

// IsLocal reports whether the identity is an unverified local one.
func (a AgentID) IsLocal() bool { return a.Domain == LocalDomain }

// ParseAgentID parses "<domain>/<name>". The runtime is format-neutral:
// it checks shape only. Naming policy (who may use digits, what is
// confusingly similar) belongs to the systems that seat packages.
func ParseAgentID(s string) (AgentID, error) {
	i := strings.LastIndex(s, "/")
	if i <= 0 || i == len(s)-1 {
		return AgentID{}, fmt.Errorf("agent id %q must be <publisher-domain>/<name>", s)
	}
	dom, name := s[:i], s[i+1:]
	if !agentNameRe.MatchString(name) {
		return AgentID{}, fmt.Errorf("agent name %q must be 2 to 32 lowercase letters or digits", name)
	}
	if dom != LocalDomain && !domainRe.MatchString(dom) {
		return AgentID{}, fmt.Errorf("publisher %q is not a domain name", dom)
	}
	return AgentID{Domain: dom, Name: name}, nil
}

// IsAgentName reports whether s is a bare agent name with no publisher.
func IsAgentName(s string) bool { return agentNameRe.MatchString(s) }

// IsDomain reports whether s looks like a publisher domain.
func IsDomain(s string) bool { return domainRe.MatchString(s) }

// IsVersion reports whether s is a semantic version.
func IsVersion(s string) bool { return versionRe.MatchString(s) }

// IsDigest reports whether s is a "sha256:<hex>" digest string.
func IsDigest(s string) bool { return digestRe.MatchString(s) }

// Now renders the current UTC time in the format every timestamp uses.
func Now() string { return time.Now().UTC().Format(time.RFC3339Nano) }

// ParseTime parses a protocol timestamp.
func ParseTime(s string) (time.Time, error) {
	if s == "" {
		return time.Time{}, errors.New("empty timestamp")
	}
	return time.Parse(time.RFC3339Nano, s)
}

// crockford is the ULID alphabet.
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// NewULID returns a 26-character ULID: 48 bits of millisecond time and 80
// bits of randomness, so ids sort by creation and never collide in practice.
func NewULID() string {
	var b [16]byte
	ms := uint64(time.Now().UnixMilli())
	for i := 5; i >= 0; i-- {
		b[i] = byte(ms & 0xff)
		ms >>= 8
	}
	if _, err := rand.Read(b[6:]); err != nil {
		panic("protocol: crypto/rand unavailable: " + err.Error())
	}
	return encodeULID(b)
}

func encodeULID(b [16]byte) string {
	// 128 bits -> 26 base32 characters, most significant first, with the
	// leading two bits of the first character always zero.
	var out [26]byte
	var acc uint64
	bits := 0
	pos := 25
	for i := 15; i >= 0; i-- {
		acc |= uint64(b[i]) << bits
		bits += 8
		for bits >= 5 && pos >= 0 {
			out[pos] = crockford[acc&31]
			acc >>= 5
			bits -= 5
			pos--
		}
	}
	for pos >= 0 {
		out[pos] = crockford[acc&31]
		acc >>= 5
		pos--
	}
	return string(out[:])
}

var ulidRe = regexp.MustCompile(`^[0-9A-HJKMNP-TV-Z]{26}$`)

// IsULID reports whether s has ULID shape.
func IsULID(s string) bool { return ulidRe.MatchString(s) }
