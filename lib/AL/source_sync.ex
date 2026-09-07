defmodule AL.SourceSync.Plan do
  @moduledoc "A deterministic source-sync plan ready for parsing and evaluation."

  @enforce_keys [:chunks, :prefix]
  defstruct [:chunks, :prefix]

  @type target() :: {term(), term()} | nil
  @type t() :: %__MODULE__{
          chunks: [{String.t(), target()}],
          prefix: [AL.Goal.t()]
        }
end

defmodule AL.SourceSync do
  @moduledoc """
  Calculates the AL transaction represented by definition-document edits.

  Planning is pure: all live facts required for diffing are supplied in an
  `AL.SourceSnapshot`. Filesystem watching and evaluation belong to callers.
  """

  alias AL.SourceDocument
  alias AL.SourceSnapshot
  alias AL.SourceSync.Plan

  @type error() :: term()

  @spec plan(SourceSnapshot.t(), [SourceDocument.t()], [term()]) ::
          {:ok, Plan.t()} | {:error, error()}
  def plan(%SourceSnapshot{} = snapshot, edited_documents, deleted_owners \\ [])
      when is_list(edited_documents) and is_list(deleted_owners) do
    with :ok <- validate_unique_owners(edited_documents),
         :ok <- validate_revisions(edited_documents, snapshot.documents),
         {:ok, deleted} <- deleted_documents(deleted_owners, snapshot.documents),
         {:ok, deleted_chunks, deleted_prefix} <- deleted_changes(deleted, snapshot),
         {:ok, edited_chunks, edited_prefix} <- edited_changes(edited_documents, snapshot) do
      {:ok,
       %Plan{
         chunks: deleted_chunks ++ edited_chunks,
         prefix: Enum.uniq(deleted_prefix ++ edited_prefix)
       }}
    end
  end

  defp validate_unique_owners(documents) do
    owners = Enum.map(documents, & &1.owner)

    if length(owners) == MapSet.size(MapSet.new(owners)),
      do: :ok,
      else: {:error, :duplicate_definition_owner}
  end

  defp validate_revisions(documents, current) do
    Enum.reduce_while(documents, :ok, fn document, :ok ->
      case Map.get(current, document.owner) do
        nil when document.revision == 0 ->
          {:cont, :ok}

        nil ->
          {:halt, {:error, {:new_document_revision_must_be_zero, document.owner}}}

        %{revision: revision} when revision == document.revision ->
          {:cont, :ok}

        %{revision: revision} ->
          {:halt, {:error, {:stale_definition, document.owner, document.revision, revision}}}
      end
    end)
  end

  defp deleted_documents(owners, current) do
    {:ok, owners |> Enum.uniq() |> Enum.flat_map(&List.wrap(Map.get(current, &1)))}
  end

  defp deleted_changes(documents, snapshot) do
    Enum.reduce_while(documents, {:ok, [], []}, fn document, {:ok, chunks, prefix} ->
      case document.kind do
        :class ->
          source = "delete_class(#{literal(document.owner)})"
          {:cont, {:ok, chunks ++ [{source, nil}], prefix}}

        :extension ->
          case method_changes(document, %{document | methods: []}, snapshot) do
            {:ok, method_chunks, method_prefix} ->
              {:cont, {:ok, chunks ++ method_chunks, prefix ++ method_prefix}}

            error ->
              {:halt, error}
          end
      end
    end)
  end

  defp edited_changes(documents, snapshot) do
    Enum.reduce_while(documents, {:ok, [], []}, fn document, {:ok, chunks, prefix} ->
      old = Map.get(snapshot.documents, document.owner)

      if old == document do
        {:cont, {:ok, chunks, prefix}}
      else
        with {:ok, metadata_chunks} <- metadata_changes(old, document),
             {:ok, method_chunks, method_prefix} <- method_changes(old, document, snapshot) do
          {:cont, {:ok, chunks ++ metadata_chunks ++ method_chunks, prefix ++ method_prefix}}
        else
          error -> {:halt, error}
        end
      end
    end)
  end

  defp metadata_changes(nil, %SourceDocument{kind: :class} = document) do
    source =
      ["vm_set_class(#{literal(document.owner)}, #{literal(document.metaclass)})"] ++
        Enum.map(document.supers, fn super ->
          "vm_set_super(#{literal(document.owner)}, #{literal(super)})"
        end) ++
        ["vm_set_slot(#{literal(document.owner)}, :ivars, #{literal(document.ivars)})"]

    {:ok, [{Enum.join(source, "\n"), nil}]}
  end

  defp metadata_changes(nil, %SourceDocument{kind: :extension}), do: {:ok, []}

  defp metadata_changes(%SourceDocument{} = old, %SourceDocument{} = new) do
    class_ops =
      if old.metaclass == new.metaclass do
        []
      else
        [
          "vm_retract_class(#{literal(new.owner)}, #{literal(old.metaclass)})",
          "vm_set_class(#{literal(new.owner)}, #{literal(new.metaclass)})"
        ]
      end

    super_ops =
      if old.supers == new.supers do
        []
      else
        Enum.map(old.supers, fn super ->
          "vm_retract_super(#{literal(new.owner)}, #{literal(super)})"
        end) ++
          Enum.map(new.supers, fn super ->
            "vm_set_super(#{literal(new.owner)}, #{literal(super)})"
          end)
      end

    ivar_ops =
      if old.ivars == new.ivars do
        []
      else
        ["vm_set_slot(#{literal(new.owner)}, :ivars, #{literal(new.ivars)})"]
      end

    migration =
      if old.kind == :class and new.kind == :class and
           (old.supers != new.supers or old.ivars != new.ivars) do
        old_spec = %{supers: old.supers, ivars: old.ivars}
        new_spec = %{supers: new.supers, ivars: new.ivars}

        [
          "class_redefined(#{literal(new.owner)}, #{literal(old_spec)}, #{literal(new_spec)})"
        ]
      else
        []
      end

    source = Enum.join(class_ops ++ super_ops ++ ivar_ops ++ migration, "\n")
    if source == "", do: {:ok, []}, else: {:ok, [{source, nil}]}
  end

  defp method_changes(nil, new, snapshot),
    do: method_changes(%{new | methods: []}, new, snapshot)

  defp method_changes(old, new, snapshot) do
    with {:ok, old_methods} <- method_groups(old.methods),
         {:ok, new_methods} <- method_groups(new.methods),
         :ok <- validate_method_id_changes(old_methods, new_methods) do
      removed = Map.keys(old_methods) -- Map.keys(new_methods)

      changed =
        Enum.filter(Map.keys(new_methods), fn selector ->
          Map.get(old_methods, selector) != Map.fetch!(new_methods, selector)
        end)

      remaining_ids = new_methods |> Map.values() |> MapSet.new(& &1.method_id)

      {remove_ops, remove_prefix} =
        Enum.flat_map_reduce(removed, [], fn selector, prefix ->
          method = Map.fetch!(old_methods, selector)

          operation =
            "vm_retract_method(#{literal(new.owner)}, #{literal(selector)}, #{literal(method.method_id)})"

          prefix =
            if MapSet.member?(remaining_ids, method.method_id) or
                 binding_count(snapshot, method.method_id) > 1 do
              prefix
            else
              prefix ++ retract_clause_goals(snapshot, method.method_id)
            end

          {[operation], prefix}
        end)

      {change_ops, change_prefix, method_chunks} =
        Enum.reduce(changed, {[], remove_prefix, []}, fn selector, {ops, prefix, chunks} ->
          new_method = Map.fetch!(new_methods, selector)
          old_method = Map.get(old_methods, selector)

          prefix =
            if old_method || binding_count(snapshot, new_method.method_id) > 0 do
              prefix ++ retract_clause_goals(snapshot, new_method.method_id)
            else
              prefix
            end

          ops =
            if old_method do
              ops
            else
              ops ++
                [
                  "vm_set_method(#{literal(new.owner)}, #{literal(selector)}, #{literal(new_method.method_id)})"
                ]
            end

          clauses = Enum.map(new_method.clauses, &{&1.source, {new.owner, selector}})
          {ops, prefix, chunks ++ clauses}
        end)

      operation_source = Enum.join(remove_ops ++ change_ops, "\n")

      chunks =
        if operation_source == "",
          do: method_chunks,
          else: [{operation_source, nil} | method_chunks]

      {:ok, chunks, change_prefix}
    end
  end

  defp method_groups(methods) do
    methods
    |> Enum.group_by(& &1.selector)
    |> Enum.reduce_while({:ok, %{}}, fn {selector, clauses}, {:ok, groups} ->
      ids = clauses |> Enum.map(& &1.method_id) |> Enum.uniq()
      clauses = Enum.sort_by(clauses, & &1.clause)
      sequence = Enum.map(clauses, & &1.clause)

      cond do
        length(ids) != 1 ->
          {:halt, {:error, {:multiple_method_ids, selector, ids}}}

        sequence != Enum.to_list(0..(length(clauses) - 1)) ->
          {:halt, {:error, {:invalid_clause_sequence, selector, sequence}}}

        true ->
          group = %{method_id: hd(ids), clauses: clauses}
          {:cont, {:ok, Map.put(groups, selector, group)}}
      end
    end)
  end

  defp validate_method_id_changes(old, new) do
    Enum.reduce_while(new, :ok, fn {selector, method}, :ok ->
      case Map.get(old, selector) do
        nil ->
          {:cont, :ok}

        %{method_id: id} when id == method.method_id ->
          {:cont, :ok}

        %{method_id: id} ->
          {:halt, {:error, {:method_identity_changed, selector, id, method.method_id}}}
      end
    end)
  end

  defp binding_count(snapshot, method_id),
    do: Map.get(snapshot.method_binding_counts, method_id, 0)

  defp retract_clause_goals(snapshot, method_id) do
    snapshot.clause_heads
    |> Map.get(method_id, [])
    |> Enum.map(&%AL.Goal.RetractOapply{object: method_id, head: &1})
  end

  defp literal(term),
    do:
      inspect(term, pretty: true, limit: :infinity, printable_limit: :infinity, width: :infinity)
end
