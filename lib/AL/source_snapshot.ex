defmodule AL.SourceSnapshot do
  @moduledoc """
  A consistent, structured snapshot of AL definitions on one branch.

  Documents are the human-facing projection. Clause heads and method binding
  counts carry the storage facts needed to calculate edits without consulting
  Mnesia again.
  """

  alias AL.SourceDocument
  alias AL.SourceDocument.Method

  @enforce_keys [:documents, :clause_heads, :method_binding_counts]
  defstruct [:documents, :clause_heads, :method_binding_counts]

  @type t() :: %__MODULE__{
          documents: %{term() => SourceDocument.t()},
          clause_heads: %{term() => [term()]},
          method_binding_counts: %{term() => non_neg_integer()}
        }

  @spec capture(AL.Branch.t()) :: {:ok, t()} | {:error, {:mnesia, term()}}
  def capture(branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn -> capture_in_transaction(branch) end) do
      {:atomic, snapshot} -> {:ok, snapshot}
      {:aborted, reason} -> {:error, {:mnesia, reason}}
    end
  end

  @doc false
  @spec capture_in_transaction(AL.Branch.t()) :: t()
  def capture_in_transaction(branch) do
    bindings =
      AL.Object.scan_open_method_versions(
        AL.Var.var("source_snapshot_owner"),
        AL.Var.var("source_snapshot_selector"),
        AL.Var.var("source_snapshot_method"),
        branch
      )

    method_ids = bindings |> Enum.map(&elem(&1, 6)) |> Enum.uniq()
    clause_heads = Map.new(method_ids, &{&1, clause_heads(&1, branch)})

    binding_counts =
      Enum.frequencies_by(bindings, fn {:method, _owner, _selector, _seq, _tx, :open, id} ->
        id
      end)

    %__MODULE__{
      documents: documents(bindings, branch),
      clause_heads: clause_heads,
      method_binding_counts: binding_counts
    }
  end

  @spec rendered(t()) :: [{term(), String.t()}]
  def rendered(%__MODULE__{documents: documents}) do
    documents
    |> Enum.sort_by(fn {owner, _document} -> inspect(owner) end)
    |> Enum.map(fn {owner, document} -> {owner, SourceDocument.render(document)} end)
  end

  defp documents(bindings, branch) do
    class_metaclasses = class_metaclass_closure(branch)

    classes =
      AL.Object.scan_class(
        AL.Var.var("source_snapshot_class"),
        AL.Var.var("source_snapshot_metaclass"),
        branch
      )
      |> Enum.filter(fn {:class, _owner, _seq, meta} ->
        MapSet.member?(class_metaclasses, meta)
      end)
      |> Map.new(fn {:class, owner, _seq, meta} -> {owner, meta} end)

    methods_by_owner =
      Enum.group_by(bindings, fn {:method, owner, _selector, _seq, _tx, :open, _id} -> owner end)

    classes
    |> Map.keys()
    |> Kernel.++(Map.keys(methods_by_owner))
    |> Enum.uniq()
    |> Map.new(fn owner ->
      document =
        definition_document(
          owner,
          Map.get(classes, owner),
          Map.get(methods_by_owner, owner, []),
          branch
        )

      {owner, document}
    end)
  end

  defp definition_document(owner, class_meta, bindings, branch) do
    methods =
      bindings
      |> Enum.sort_by(fn {:method, _owner, selector, seq, tx, :open, method_id} ->
        {seq, tx, inspect(selector), inspect(method_id)}
      end)
      |> Enum.flat_map(&method_records(&1, branch))

    {kind, metaclass, supers, ivars} =
      case class_meta do
        nil -> {:extension, direct_class(owner, branch), [], []}
        meta -> {:class, meta, live_supers(owner, branch), class_ivars(owner, branch)}
      end

    %SourceDocument{
      kind: kind,
      owner: owner,
      metaclass: metaclass,
      supers: supers,
      ivars: ivars,
      revision: owner_revision(owner, methods, branch),
      methods: methods
    }
  end

  defp method_records(
         {:method, owner, selector, _binding_seq, _binding_tx, :open, method_id},
         branch
       ) do
    AL.Object.scan_open_oapply_versions(
      method_id,
      AL.Var.var("source_snapshot_clause"),
      AL.Var.var("source_snapshot_head"),
      AL.Var.var("source_snapshot_body"),
      branch
    )
    |> Enum.map(fn {:oapply, ^method_id, clause, _seq, _tx, :open, _head, _body} ->
      source = AL.Source.method_clause_source(owner, selector, method_id, clause, branch)

      %Method{
        selector: selector,
        method_id: method_id,
        clause: clause,
        source: source.text,
        provenance: source.provenance
      }
    end)
  end

  defp clause_heads(method_id, branch) do
    AL.Object.scan_open_oapply_versions(
      method_id,
      AL.Var.var("source_snapshot_clause_head_seq"),
      AL.Var.var("source_snapshot_clause_head"),
      AL.Var.var("source_snapshot_clause_body"),
      branch
    )
    |> Enum.map(fn {:oapply, ^method_id, _clause, _seq, _tx, :open, head, _body} -> head end)
  end

  defp direct_class(owner, branch) do
    case AL.Object.scan_class(owner, AL.Var.var("source_snapshot_owner_class"), branch) do
      [{:class, ^owner, _seq, class} | _] -> class
      [] -> nil
    end
  end

  defp owner_revision(owner, methods, branch) do
    soa_revisions =
      :mnesia.read(AL.Object.table(:soa, branch), owner)
      |> Enum.map(fn {:soa, ^owner, _key, _seq, tx_from, _tx_to, _value} -> tx_from end)

    aos_revisions =
      :mnesia.read(AL.Object.table(:aos, branch), owner)
      |> Enum.map(fn {:aos, ^owner, tx_from, _tx_to, _slots} -> tx_from end)

    method_revisions =
      methods
      |> Enum.flat_map(fn %Method{method_id: method_id} ->
        AL.Object.scan_open_oapply_versions(
          method_id,
          AL.Var.var("source_snapshot_revision_clause"),
          AL.Var.var("source_snapshot_revision_head"),
          AL.Var.var("source_snapshot_revision_body"),
          branch
        )
        |> Enum.map(fn {:oapply, ^method_id, _clause, _seq, tx, :open, _head, _body} -> tx end)
      end)

    Enum.max([0 | soa_revisions ++ aos_revisions ++ method_revisions])
  end

  defp class_metaclass_closure(branch) do
    children_by_parent =
      AL.Object.scan_super(
        AL.Var.var("source_snapshot_meta_child"),
        AL.Var.var("source_snapshot_meta_parent"),
        branch
      )
      |> Enum.reduce(%{}, fn {:super, child, _seq, parent}, acc ->
        Map.update(acc, parent, [child], &[child | &1])
      end)

    metaclass_closure(children_by_parent, [:class], MapSet.new([:class]))
  end

  defp metaclass_closure(_children_by_parent, [], seen), do: seen

  defp metaclass_closure(children_by_parent, [node | rest], seen) do
    new_nodes =
      children_by_parent
      |> Map.get(node, [])
      |> Enum.reject(&MapSet.member?(seen, &1))

    metaclass_closure(children_by_parent, new_nodes ++ rest, Enum.into(new_nodes, seen))
  end

  defp live_supers(class, branch) do
    AL.Object.scan_super(class, AL.Var.var("source_snapshot_super"), branch)
    |> Enum.map(fn {:super, ^class, _seq, super} -> super end)
  end

  defp class_ivars(class, branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{ivars: ivars}}] -> ivars
      _ -> []
    end
  end
end
