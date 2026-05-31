require "../manifest"

module Vow
  module Codegen
    # The namespace tree a client is rendered from, shared by every target.
    # Leaves are procedures; branches are nested namespaces keyed by the
    # `.`-split procedure id (`Geo.find_account` → `Geo` → `find_account`).
    alias Tree = Hash(String, Tree) | ProcedureDescriptor

    def self.build_tree(procedures : Array(ProcedureDescriptor)) : Hash(String, Tree)
      root = {} of String => Tree
      procedures.each { |p| insert(root, p.name.split("."), p) }
      root
    end

    private def self.insert(node : Hash(String, Tree), path : Array(String), proc : ProcedureDescriptor) : Nil
      head, *rest = path
      if rest.empty?
        node[head] = proc
        return
      end
      child = node[head]?
      unless child.is_a?(Hash)
        child = {} of String => Tree
        node[head] = child
      end
      insert(child, rest, proc)
    end

    # Renders the namespace tree to a nested literal. `leaf` turns a
    # `(segment, procedure)` pair into one member line (no trailing separator);
    # `type_mode` switches the member separator and so the literal kind —
    # `;` for a TypeScript *type* literal (a `.d.ts` shape), `,` for a value
    # object literal (a `.ts`/`.js` runtime object). Branches recurse with the
    # same `leaf`, so all three targets share one walk.
    def self.render_tree(
      node : Hash(String, Tree),
      indent : Int32,
      type_mode : Bool,
      leaf : Proc(String, ProcedureDescriptor, String),
    ) : String
      sep = type_mode ? ";" : ","
      pad = " " * indent
      inner = " " * (indent + 2)
      String.build do |s|
        s << "{\n"
        node.each do |key, value|
          case value
          in ProcedureDescriptor
            s << inner << leaf.call(key, value) << sep << "\n"
          in Hash
            s << inner << key << ": " << render_tree(value, indent + 2, type_mode, leaf) << sep << "\n"
          end
        end
        s << pad << "}"
      end
    end
  end
end
