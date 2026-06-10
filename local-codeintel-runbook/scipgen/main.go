// Command scipgen emits a tiny, hand-built SCIP index for the demo repository
// used by ../run-stack.sh.
//
// Why this exists:
//   The usual way to produce a SCIP index is a language indexer such as
//   `scip-go` / `scip-typescript`. In this public snapshot that path is broken:
//   older `scip-go` releases depend on `github.com/sourcegraph/sourcegraph/lib`,
//   which became a private repo (the module is now 404 on the network), and the
//   newest tag has a mismatched module path. So instead we construct a minimal
//   but completely valid SCIP index directly with the `scip` Go bindings, which
//   are already a dependency of this monorepo (see go.mod).
//
// What it encodes (must stay in sync with the files run-stack.sh writes into
// the demo repo):
//
//   greeter.go
//     0: package demo
//     1:
//     2: // Greet returns a greeting for the given name.
//     3: func Greet(name string) string {     <- DEFINITION of Greet, cols 5..10
//     4:     return "Hello, " + name
//     5: }
//
//   caller.go
//     0: package demo
//     1:
//     2: // CallIt calls Greet and returns the result.
//     3: func CallIt() string {
//     4:     return Greet("world")            <- REFERENCE to Greet, cols 8..13
//     5: }
//
// The single SCIP symbol string is reused for both the definition occurrence
// (in greeter.go) and the reference occurrence (in caller.go); that shared
// string is what lets Sourcegraph link a reference to its definition.
//
// Usage: go run ./local-codeintel-runbook/scipgen <output-path>
package main

import (
	"os"

	"github.com/sourcegraph/scip/bindings/go/scip"
	"google.golang.org/protobuf/proto"
)

func main() {
	out := "/tmp/index.scip"
	if len(os.Args) > 1 {
		out = os.Args[1]
	}

	// A well-formed *global* SCIP symbol:
	//   "<scheme> <package-manager> <package-name> <package-version> <descriptors>"
	// Descriptor "Greet()." denotes a function named Greet. The string only has
	// to be syntactically valid and identical across documents.
	greet := "scip-go gomod demo v0.0.0 Greet()."

	index := &scip.Index{
		Metadata: &scip.Metadata{
			Version: scip.ProtocolVersion_UnspecifiedProtocolVersion,
			ToolInfo: &scip.ToolInfo{
				Name:    "scip-go",
				Version: "v0.0.0-demo",
			},
			ProjectRoot:          "file:///tmp/sg-demo-repo",
			TextDocumentEncoding: scip.TextEncoding_UTF8,
		},
		Documents: []*scip.Document{
			{
				Language:     "go",
				RelativePath: "greeter.go",
				// SymbolInformation carries documentation -> powers `hover`.
				Symbols: []*scip.SymbolInformation{
					{
						Symbol: greet,
						Documentation: []string{
							"```go\nfunc Greet(name string) string\n```\n\nGreet returns a greeting for the given name.",
						},
					},
				},
				Occurrences: []*scip.Occurrence{
					{
						// Range is [startLine, startChar, endChar] (single line).
						// All positions are 0-based, matching LSP / the GraphQL API.
						Range:       []int32{3, 5, 10},
						Symbol:      greet,
						SymbolRoles: int32(scip.SymbolRole_Definition),
					},
				},
			},
			{
				Language:     "go",
				RelativePath: "caller.go",
				Occurrences: []*scip.Occurrence{
					{
						Range:       []int32{4, 8, 13},
						Symbol:      greet,
						SymbolRoles: 0, // 0 == a plain reference (not a definition)
					},
				},
			},
		},
	}

	b, err := proto.Marshal(index)
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(out, b, 0o644); err != nil {
		panic(err)
	}
	println("wrote", out, len(b), "bytes")
}
