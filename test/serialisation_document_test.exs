defmodule ALDocumentTest do
  use ExUnit.Case, async: true

  alias AL.Serialisation.Document
  alias AL.Serialisation.Document.Method

  defp class(overrides) do
    struct!(
      Document,
      Keyword.merge(
        [
          kind: :class,
          owner: :card,
          metaclass: :class,
          supers: [:value, :named],
          ivars: [rank: [], suit: [default: :clubs]],
          comment: nil,
          methods: []
        ],
        overrides
      )
    )
  end

  defp method(overrides) do
    struct!(
      Method,
      Keyword.merge(
        [selector: :rank, declaration: ":rank, [self, r]", body: "  pass"],
        overrides
      )
    )
  end

  test "a class document round trips its comment, declarations and bodies" do
    document =
      class(
        comment: "A playing card.\nSecond line.",
        methods: [
          method(
            selector: :label,
            declaration: ":label, [self, \"λ\"]",
            body: "  # ] is source\n  pass"
          ),
          method(
            selector: :rank,
            declaration: ":rank, [self, rank]",
            body: "  get_slot(self, :rank, rank)"
          )
        ]
      )

    text = Document.render(document)
    assert {:ok, ^document} = Document.parse(text)
  end

  test "the owner prefix is generated and the declaration is authored" do
    text = Document.render(class(methods: [method(declaration: ":rank, [self, r]")]))

    assert text =~ ":card >> :rank, [self, r] [\n"
    assert text =~ "#name : :card"
    assert text =~ "#superclass : [:value, :named]"
  end

  test "a body edited to a different length still parses" do
    text = Document.render(class(methods: [method(body: "  unify(r, 1)")]))
    edited = String.replace(text, "unify(r, 1)", "unify(r, 100)\n  pass")

    assert {:ok, parsed} = Document.parse(edited)
    assert [%Method{body: "  unify(r, 100)\n  pass"}] = parsed.methods
  end

  test "brackets inside strings, comments, char literals and lists do not end the body" do
    body = """
      unify(a, "close ]")
      # a bracket ] in a comment
      unify(b, ?])
      unify(c, [1, [2, 3]])
      forall([member(xs, x)]) do
        pass
      end\
    """

    document = class(methods: [method(body: body)])
    text = Document.render(document)

    assert {:ok, parsed} = Document.parse(text)
    assert [%Method{body: ^body}] = parsed.methods
  end

  test "several clauses of one selector keep file order" do
    document =
      class(
        methods: [
          method(
            selector: :between,
            declaration: ":between, [self, low, high, low]",
            body: "  pass"
          ),
          method(
            selector: :between,
            declaration: ":between, [self, low, high, v]",
            body: "  fail()"
          )
        ]
      )

    assert {:ok, parsed} = Document.parse(Document.render(document))

    assert Enum.map(parsed.methods, & &1.declaration) ==
             Enum.map(document.methods, & &1.declaration)
  end

  test "extension documents round trip" do
    document = %Document{
      kind: :extension,
      owner: :map_get,
      metaclass: nil,
      supers: [],
      ivars: [],
      comment: nil,
      methods: [method(selector: :foo, declaration: ":foo, [self]", body: "  pass")]
    }

    assert {:ok, ^document} = Document.parse(Document.render(document))
  end

  test "rejects executable header metadata" do
    assert {:error, {:invalid_document, _}} =
             Document.parse(
               "Class {\n  #name : System.halt(),\n  #metaclass : :class,\n  #superclass : [],\n  #ivars : []\n}"
             )
  end
end
