defmodule ALDefinitionDocumentTest do
  use ExUnit.Case, async: true

  alias AL.Definition.Document
  alias AL.Definition.Document.Method

  defp class(overrides) do
    struct!(
      Document,
      Keyword.merge(
        [
          kind: :class,
          owner: :card,
          metaclass: :class,
          supers: [:value, :named],
          ivars: [%{name: :rank}, %{name: :suit, default: :clubs}],
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
        [selector: :rank, declaration: "rank\n| Self R |", body: "  pass"],
        overrides
      )
    )
  end

  test "a class document round trips its comment, declarations and bodies" do
    document =
      class(
        comment: "A playing card.\n\nSecond line.",
        methods: [
          method(
            selector: :label,
            declaration: "label\n| Self \"λ\" |",
            body: "  # . is source\n  pass"
          ),
          method(
            selector: :rank,
            declaration: "rank\n| Self Rank |",
            body: "  get Self rank Rank"
          )
        ]
      )

    text = Document.render(document)
    assert {:ok, ^document} = Document.parse(text)
  end

  test "a definition file is AL source" do
    text =
      Document.render(
        class(comment: "A card.", methods: [method(declaration: "rank\n| Self R |")])
      )

    assert text ==
             "# A card.\n\n" <>
               "@card\n" <>
               "\#{\n  super => [value, named],\n  ivars => [\#{name => rank}, \#{default => clubs, name => suit}]\n}.\n\n" <>
               "card >> rank\n| Self R |\n  pass."

    assert {:ok, %{program: [%AL.Goal.Compound{name: :defclass} | _]}} = AL.Syntax.parse(text)
  end

  test "a single super is written without a list" do
    text = Document.render(class(supers: [:value]))
    assert text =~ "@card\n\#{super => value,"
    assert {:ok, %Document{supers: [:value]}} = Document.parse(text)
  end

  test "a declaration whose head spans several lines round trips" do
    document =
      class(
        methods: [
          method(
            selector: :define_probe,
            declaration: "define_probe\n| Self\n    Class\n    plain |",
            body: "  defmethod Class [] [] {}"
          ),
          method([])
        ]
      )

    assert {:ok, ^document} = Document.parse(Document.render(document))
  end

  test "a body edited to a different length still parses" do
    text = Document.render(class(methods: [method(body: "  = R 1")]))
    edited = String.replace(text, "= R 1", "= R 100,\n  pass")

    assert {:ok, parsed} = Document.parse(edited)
    assert [%Method{body: "  = R 100,\n  pass"}] = parsed.methods
  end

  test "full stops inside strings, lists, comments and nested forms do not end the body" do
    body = """
      = A "stop. \\" still",
      = B 'atom. too',
      = C [1, [2, 3] . T],
      forall {member Xs X} {
        pass
      }
      # a trailing note.\
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
            declaration: "between\n| Self Low High Low |",
            body: "  pass"
          ),
          method(selector: :between, declaration: "between\n| Self Low High V |", body: ""),
          method(
            selector: :between,
            declaration: "between\n| Self Low . Rest |",
            body: "  fail"
          )
        ]
      )

    assert {:ok, ^document} = Document.parse(Document.render(document))
  end

  test "extension documents round trip, with and without added supers" do
    document = %Document{
      kind: :extension,
      owner: :map,
      metaclass: nil,
      supers: [],
      ivars: [],
      comment: nil,
      methods: [method(selector: :foo, declaration: "foo\n| Self |", body: "  pass")]
    }

    assert {:ok, ^document} = Document.parse(Document.render(document))

    extended = %{document | supers: [:renderable]}
    text = Document.render(extended)
    assert text =~ "@+map\n\#{super => [renderable]}.\n\n"
    assert {:ok, ^extended} = Document.parse(text)
  end

  test "literal metadata may hold any term" do
    document =
      class(
        owner: :"a}class",
        ivars: [%{name: :config, default: %{closing: "}."}}]
      )

    assert {:ok, ^document} = Document.parse(Document.render(document))
  end

  test "rejects a method owned by another object" do
    assert {:error, {:invalid_document, _}} =
             Document.parse("@card \#{super => object}.\n\nother >> rank\n| Self |.")
  end

  test "rejects goals and variables in a definition" do
    assert {:error, {:invalid_document, _}} =
             Document.parse("@card \#{super => object}.\n\nvm_set_class x object.")

    assert {:error, {:invalid_document, _}} = Document.parse("@card \#{super => Super}.")
  end

  test "rejects bare ivar names" do
    assert {:error, {:invalid_document, "ivars must be a list of maps with a name"}} =
             Document.parse("@card \#{super => object, ivars => [rank]}.")
  end
end
