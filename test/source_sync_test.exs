defmodule ALSourceSyncTest do
  use ExUnit.Case, async: true

  alias AL.SourceDocument
  alias AL.SourceDocument.Method
  alias AL.SourceSnapshot
  alias AL.SourceSync

  test "a method edit plans source retention and clause replacement without live reads" do
    old_method = %Method{
      selector: :pick,
      method_id: :pick_impl,
      clause: 0,
      source: "defmethod(:pick, [self, :old])",
      provenance: :retained
    }

    old = document(methods: [old_method])
    edited_source = "defmethod(:pick, [self, :edited])"
    edited = %{old | methods: [%{old_method | source: edited_source}]}
    head = [AL.Var.var("self"), :old]

    snapshot = %SourceSnapshot{
      documents: %{example: old},
      clause_heads: %{pick_impl: [head]},
      method_binding_counts: %{pick_impl: 1}
    }

    assert {:ok, plan} = SourceSync.plan(snapshot, [edited])
    assert plan.chunks == [{edited_source, {:example, :pick}}]
    assert plan.prefix == [%AL.Goal.RetractOapply{object: :pick_impl, head: head}]
  end

  test "a class metadata edit produces an explicit AL transaction body" do
    old = document()
    edited = %{old | supers: [:value], ivars: [rank: []]}

    snapshot = %SourceSnapshot{
      documents: %{example: old},
      clause_heads: %{},
      method_binding_counts: %{}
    }

    assert {:ok, plan} = SourceSync.plan(snapshot, [edited])
    assert plan.prefix == []
    assert [{source, nil}] = plan.chunks
    assert source =~ "vm_retract_super(:example, :object)"
    assert source =~ "vm_set_super(:example, :value)"
    assert source =~ "vm_set_slot(:example, :ivars, [rank: []])"
    assert source =~ "class_redefined(:example,"
  end

  test "unchanged and stale documents are distinguished" do
    current = document()

    snapshot = %SourceSnapshot{
      documents: %{example: current},
      clause_heads: %{},
      method_binding_counts: %{}
    }

    assert {:ok, %{chunks: [], prefix: []}} = SourceSync.plan(snapshot, [current])

    assert {:error, {:stale_definition, :example, 9, 10}} =
             SourceSync.plan(snapshot, [%{current | revision: 9}])
  end

  defp document(overrides \\ []) do
    struct!(
      SourceDocument,
      Keyword.merge(
        [
          kind: :class,
          owner: :example,
          metaclass: :class,
          supers: [:object],
          ivars: [],
          revision: 10,
          methods: []
        ],
        overrides
      )
    )
  end
end
