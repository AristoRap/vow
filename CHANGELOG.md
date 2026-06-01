# Changelog

## [0.2.0] - 2026-06-01

### Added

- **`Vow::Exportable::Marked` — consumer-driven dispatch registration.** A downstream framework with its _own_ export annotation can `include Vow::Exportable::Marked` and call `vow_register_marked(registry, MyAnnotation)` from one of its instance methods. Because the macro expands in the consumer's class context, Vow registers every method carrying that annotation with the exact decode → invoke → JSON-encode callback it generates for `@[Vow::Export]` — so the consumer reuses Vow's dispatch instead of reimplementing it, while keeping its own annotation and ids. Vow stays annotation-agnostic (the marker is the consumer's type, matched via `m.annotation(marker.resolve)`).
- **"Did you mean?" suggestions on unknown dispatch.** `Registry#dispatch` now attaches a `hint` to the `not_found` error naming the closest registered procedure (nearest edit distance within a length-scaled tolerance, via stdlib `Levenshtein`), or no hint when nothing is close. A transport that surfaces `Vow::Error#hint` turns a typo'd procedure name into an actionable message.
- **Enum capture → TypeScript string-literal union.** An `Enum` referenced by an exported signature (directly or transitively, through generics/unions/`NamedTuple` members/struct fields) is now captured as a `TypeDescriptor` with `kind: "enum"` and its serialized values, and emitted as a `type X = "a" | "b" | "c";` alias instead of being rejected at the boundary. The union records the value each member **serializes to** (`Enum#to_json`), so the generated type always matches the wire: Crystal's default lowercases (`Red` → `"red"`), and a custom `to_json` is reflected. Vow applies no transform of its own. `TypeDescriptor` gains `kind` (`"struct"` default) and `members`, both defaulted so older manifests still deserialize.

## [0.1.1] - 2026-06-01

### Fixed

- `Vow::Codegen.collect` no longer crashes the compiler (stack overflow from infinite macro recursion) when an exported signature returns or accepts a `NamedTuple`. NamedTuples are now walked by key: nested `JSON::Serializable` members are captured as surface types, while the NamedTuple itself stays an inline `{ ... }` shape via `crystal_to_ts`.

## [0.1.0]

- Initial release: typed RPC codegen — a TypeScript/JavaScript client generated from annotated Crystal methods, with a transport-agnostic `Vow::Registry#dispatch` seam.
