defmodule ALSourceDocumentTest do
  use ExUnit.Case, async: true

  alias AL.SourceDocument
  alias AL.SourceDocument.Method

  test "class documents round trip retained and decompiled method source byte for byte" do
    document = %SourceDocument{
      kind: :class,
      owner: :card,
      metaclass: :class,
      supers: [:value, :named],
      ivars: [rank: [], suit: [default: :clubs]],
      revision: 42,
      methods: [
        %Method{
          selector: :label,
          method_id: :"#12",
          clause: 0,
          provenance: :retained,
          source: "defmethod(:label, [self, \"λ\"]) do\n  # ] is source\n  pass\nend\n"
        },
        %Method{
          selector: :rank,
          method_id: :"#13",
          clause: 0,
          provenance: :decompiled,
          source: "defmethod(:card, :rank, [self, rank])"
        }
      ]
    }

    text = SourceDocument.render(document)
    assert {:ok, ^document} = SourceDocument.parse(text)
    assert text =~ "bytes: 62"
  end

  test "extension documents round trip" do
    document = %SourceDocument{
      kind: :extension,
      owner: :map_get,
      metaclass: :behaviour,
      supers: [],
      ivars: [],
      revision: 7,
      methods: []
    }

    assert document ==
             document |> SourceDocument.render() |> then(&elem(SourceDocument.parse(&1), 1))
  end

  test "rejects executable header metadata" do
    assert {:error, {:invalid_document, _}} =
             SourceDocument.parse(
               "Class {\n  id: System.halt(),\n  metaclass: :class,\n  supers: [],\n  ivars: [],\n  revision: 0\n}"
             )
  end
end
