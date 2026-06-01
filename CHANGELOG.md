# Changelog

## [0.1.1] - 2026-06-01

### Fixed

- `Vow::Codegen.collect` no longer crashes the compiler (stack overflow from infinite macro recursion) when an exported signature returns or accepts a `NamedTuple`. NamedTuples are now walked by key: nested `JSON::Serializable` members are captured as surface types, while the NamedTuple itself stays an inline `{ ... }` shape via `crystal_to_ts`.

## [0.1.0]

- Initial release: typed RPC codegen — a TypeScript/JavaScript client generated from annotated Crystal methods, with a transport-agnostic `Vow::Registry#dispatch` seam.
