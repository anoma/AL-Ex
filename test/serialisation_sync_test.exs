defmodule ALSyncTest do
  use ExUnit.Case, async: true

  alias AL.Serialisation.Document
  alias AL.Serialisation.Document.Method
  alias AL.Serialisation.Snapshot
  alias AL.Serialisation.Sync

  defp document(overrides \\ []) do
    struct!(
      Document,
      Keyword.merge(
        [
          kind: :class,
          owner: :example,
          metaclass: :class,
          supers: [:object],
          ivars: [],
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
        [
          selector: :pick,
          declaration: "pick\n| Self old |",
          body: "  pass"
        ],
        overrides
      )
    )
  end

  defp snapshot(documents), do: %Snapshot{documents: documents}

  test "a method edit rewrites the selector's clauses, which clears the old ones" do
    old = document(methods: [method([])])
    edited = %{old | methods: [method(body: "  fail")]}

    assert {:ok, [{definition, {:example, :pick}}]} =
             Sync.plan(snapshot(%{example: old}), [edited])

    assert definition == "example >> pick\n| Self old |\n  fail."

    assert {:ok,
            %{
              program: [
                %AL.Goal.OApply{method_id: :clear_method, args: [:example, :pick]},
                %AL.Goal.OApply{method_id: :defmethod}
              ]
            }} = AL.Syntax.parse(definition)
  end

  test "a removed method retracts its binding as well as its clauses" do
    old = document(methods: [method([])])
    edited = %{old | methods: []}

    assert {:ok, [{removal, nil}]} = Sync.plan(snapshot(%{example: old}), [edited])
    assert removal =~ "vm_retract_oapply Id_serialisation_"
    assert removal =~ "vm_retract_method example pick Id_serialisation_"
  end

  test "a selector new to its owner installs without any retraction of its own" do
    old = document()
    edited = %{old | methods: [method(body: "  pass")]}

    assert {:ok, [{definition, {:example, :pick}}]} =
             Sync.plan(snapshot(%{example: old}), [edited])

    assert definition == "example >> pick\n| Self old |\n  pass."
  end

  test "each removed selector gets its own variable scope" do
    old =
      document(
        methods: [
          method(selector: :a, declaration: "a\n| Self |"),
          method(selector: :b, declaration: "b\n| Self |")
        ]
      )

    edited = %{old | methods: []}

    assert {:ok, chunks} = Sync.plan(snapshot(%{example: old}), [edited])
    text = chunks |> Enum.map_join("\n", &elem(&1, 0))

    scopes = Regex.scan(~r/Ids_(serialisation_[a-f0-9]+)/, text, capture: :all_but_first)
    assert scopes |> List.flatten() |> Enum.uniq() |> length() == 2
  end

  test "a class metadata edit produces an explicit AL transaction body" do
    old = document()
    edited = %{old | supers: [:value], ivars: [%{name: :rank}], comment: "A thing."}

    assert {:ok, [{source, nil}]} = Sync.plan(snapshot(%{example: old}), [edited])
    assert source =~ "vm_retract_super example object."
    assert source =~ "vm_set_super example value."
    assert source =~ "vm_set_slot example ivars [\#{name => rank}]."
    assert source =~ "vm_set_slot example comment \"A thing.\"."
    assert source =~ "class_redefined example \#{"
  end

  test "an unchanged document plans nothing" do
    current = document(methods: [method([])])
    assert {:ok, []} = Sync.plan(snapshot(%{example: current}), [current])
  end

  test "changing a definition between class and extension is rejected" do
    old = document()
    edited = %{old | kind: :extension, metaclass: nil, supers: [], ivars: []}

    assert {:error, {:definition_kind_changed, :example, :class, :extension}} =
             Sync.plan(snapshot(%{example: old}), [edited])
  end

  test "deleting a class document deletes the class" do
    current = document()

    assert {:ok, [{"delete_class example.", nil}]} =
             Sync.plan(snapshot(%{example: current}), [], [:example])
  end

  test "a body ending in a comment keeps its closing brace live" do
    old = document()
    edited = %{old | methods: [method(body: "  pass\n  # trailing note")]}

    assert {:ok, [{definition, {:example, :pick}}]} =
             Sync.plan(snapshot(%{example: old}), [edited])

    assert {:ok, %{program: [_clear, %AL.Goal.OApply{method_id: :defmethod}]}} =
             AL.Syntax.parse(definition)
  end
end
