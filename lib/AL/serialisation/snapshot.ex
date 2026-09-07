defmodule AL.Serialisation.Snapshot do
  @moduledoc """
  A consistent snapshot of AL definitions on one branch, as Tonel documents.

  Documents are the portable projection used for rendering and for comparing a
  file against the store. Method identity and clause heads are read from the
  tables at install time, never carried here or in a file.
  """

  alias AL.Serialisation.Document
  alias AL.Serialisation.Document.Method

  @enforce_keys [:documents]
  defstruct [:documents]

  @type t() :: %__MODULE__{documents: %{term() => Document.t()}}

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
        AL.Var.var("serialisation_snapshot_owner"),
        AL.Var.var("serialisation_snapshot_selector"),
        AL.Var.var("serialisation_snapshot_method"),
        branch
      )

    %__MODULE__{documents: documents(bindings, branch)}
  end

  @spec rendered(t()) :: [{term(), String.t()}]
  def rendered(%__MODULE__{documents: documents}) do
    documents
    |> Enum.sort_by(fn {owner, _document} -> inspect(owner) end)
    |> Enum.map(fn {owner, document} -> {owner, Document.render(document)} end)
  end

  defp documents(bindings, branch) do
    class_metaclasses = class_metaclass_closure(branch)

    classes =
      AL.Object.scan_class(
        AL.Var.var("serialisation_snapshot_class"),
        AL.Var.var("serialisation_snapshot_metaclass"),
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

    {kind, metaclass, supers, ivars, comment} =
      case class_meta do
        nil ->
          {:extension, nil, [], [], nil}

        meta ->
          {:class, meta, live_supers(owner, branch), slot(owner, :ivars, [], branch),
           slot(owner, :comment, nil, branch)}
      end

    %Document{
      kind: kind,
      owner: owner,
      metaclass: metaclass,
      supers: supers,
      ivars: ivars,
      comment: comment,
      methods: methods
    }
  end

  defp method_records(
         {:method, owner, selector, _binding_seq, _binding_tx, :open, method_id},
         branch
       ) do
    method_id
    |> clause_rows(branch)
    |> Enum.map(fn {:oapply, ^method_id, _clause, _seq, _tx, :open, head, body} ->
      {:ok, declaration, text} =
        AL.Source.split_clause_source(AL.Source.defmethod_source(owner, selector, head, body))

      %Method{selector: selector, declaration: declaration, body: text}
    end)
  end

  @doc false
  @spec clause_rows(term(), AL.Branch.t()) :: [tuple()]
  def clause_rows(method_id, branch) do
    AL.Object.scan_open_oapply_versions(
      method_id,
      AL.Var.var("serialisation_snapshot_clause"),
      AL.Var.var("serialisation_snapshot_head"),
      AL.Var.var("serialisation_snapshot_body"),
      branch
    )
    |> Enum.sort_by(fn {:oapply, ^method_id, clause, _seq, _tx, :open, _head, _body} ->
      clause
    end)
  end

  defp class_metaclass_closure(branch) do
    children_by_parent =
      AL.Object.scan_super(
        AL.Var.var("serialisation_snapshot_meta_child"),
        AL.Var.var("serialisation_snapshot_meta_parent"),
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
    AL.Object.scan_super(class, AL.Var.var("serialisation_snapshot_super"), branch)
    |> Enum.map(fn {:super, ^class, _seq, super} -> super end)
  end

  defp slot(owner, key, default, branch) do
    case AL.Object.read_slots(owner, branch) do
      [{:slots, ^owner, slots}] -> Map.get(slots, key, default)
      _ -> default
    end
  end
end
