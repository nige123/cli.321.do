# Protocol fixtures

`valid/<schema>-<name>.json` must pass the validator for its `schema`.
`invalid/<schema>-<name>.json` is `{"document": {...}, "expect": ["path", ...]}`:
the document must fail, and every listed path substring must appear among
the problems. Digest-bearing documents carry real digests computed by the
canonical rules; a fixture that changes a digested field must recompute it
(`go test ./internal/protocol/ -run TestProtocolFixtures` reports the
expected digest when one is wrong). Both the Go validators and the Perl
consumer in api.123.do run these files.
