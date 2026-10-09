defmodule AL.DefinitionSnapshotTest do
  use ExUnit.Case, async: true

  test "selected snapshots preserve class and extension documents without unrelated owners" do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.run(
               ~S"""
               @snapshot_probe #{super => value}.
               snapshot_probe >> answer
               | _Self 42 |.
               defmethod snapshot_extension answer [_Self, 43] {pass}.
               """,
               branch
             )

    owners = [:snapshot_probe, :snapshot_extension, :missing_snapshot_owner]
    assert {:ok, full} = AL.Definition.Snapshot.capture(branch)
    assert {:ok, selected} = AL.Definition.Snapshot.capture(branch, owners)
    assert selected.documents == Map.take(full.documents, owners)
    assert selected.documents.snapshot_probe.kind == :class
    assert selected.documents.snapshot_extension.kind == :extension
    refute Map.has_key?(selected.documents, :missing_snapshot_owner)
  end
end
