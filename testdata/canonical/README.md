# Canonical JSON fixtures

Each `NN-name.json` is an input document. The matching `NN-name.canonical`
holds the exact canonical bytes (no trailing newline) and `NN-name.digest`
the `sha256:<hex>` digest of those bytes. Every implementation of the 321
canonical form (Go here, Perl in api.123.do) must reproduce both from the
input. The rules are stated in `internal/protocol/canonical.go`:

1. Object members sorted by key as UTF-8 byte strings; no whitespace.
2. Arrays in order; no whitespace.
3. Strings raw UTF-8 except `\"`, `\\`, `\b \f \n \r \t`, and `\u00xx`
   (lowercase) for the other control characters below U+0020. Nothing else
   is escaped. Invalid UTF-8 is an error.
4. Integer literals as their digits, `-0` as `0`. Other numbers as the
   shortest round-tripping double in ES6 `Number.prototype.toString` form.
5. `true`, `false`, `null`.
6. No trailing newline.

The `.canonical` and `.digest` files are produced by the Go implementation
and checked in; `go test ./internal/protocol/` fails if they drift, and the
Perl implementation is tested against the same files.
