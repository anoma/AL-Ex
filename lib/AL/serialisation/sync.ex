defmodule AL.Serialisation.Sync do
  @moduledoc """
  Calculates the AL transaction represented by definition-document edits.

  Planning is pure and needs no store-local identity. A selector's clauses are
  retracted by enumerating `vm_clause` at run time, which leaves the method
  binding in place so `defmethod` reuses its existing method id.
  """

  alias AL.Serialisation.Document
  alias AL.Serialisation.Snapshot

  @type chunk() :: {String.t(), {term(), term()} | nil}

  @spec plan(Snapshot.t(), [Document.t()], [term()]) ::
          {:ok, [chunk()]} | {:error, term()}
  def plan(%Snapshot{} = snapshot, edited_documents, deleted_owners \\ [])
      when is_list(edited_documents) and is_list(deleted_owners) do
    with :ok <- validate_unique_owners(edited_documents) do
      {:ok, deleted_chunks(deleted_owners, snapshot) ++ edited_chunks(edited_documents, snapshot)}
    end
  end

  defp validate_unique_owners(documents) do
    owners = Enum.map(documents, & &1.owner)

    if length(owners) == MapSet.size(MapSet.new(owners)),
      do: :ok,
      else: {:error, :duplicate_definition_owner}
  end

  defp deleted_chunks(owners, snapshot) do
    owners
    |> Enum.uniq()
    |> Enum.flat_map(&List.wrap(Map.get(snapshot.documents, &1)))
    |> Enum.flat_map(fn
      %Document{kind: :class} = document ->
        [{"delete_class(#{literal(document.owner)})", nil}]

      %Document{kind: :extension} = document ->
        method_chunks(document, %{document | methods: []})
    end)
  end

  defp edited_chunks(documents, snapshot) do
    Enum.flat_map(documents, fn document ->
      case Map.get(snapshot.documents, document.owner) do
        ^document -> []
        old -> metadata_chunks(old, document) ++ method_chunks(old, document)
      end
    end)
  end

  defp metadata_chunks(nil, %Document{kind: :class} = document) do
    operations =
      ["vm_set_class(#{literal(document.owner)}, #{literal(document.metaclass)})"] ++
        Enum.map(document.supers, &"vm_set_super(#{literal(document.owner)}, #{literal(&1)})") ++
        ["vm_set_slot(#{literal(document.owner)}, :ivars, #{literal(document.ivars)})"] ++
        comment_operations(document)

    [{Enum.join(operations, "\n"), nil}]
  end

  defp metadata_chunks(nil, %Document{kind: :extension}), do: []

  defp metadata_chunks(%Document{} = old, %Document{} = new) do
    class_operations =
      if old.metaclass == new.metaclass do
        []
      else
        [
          "vm_retract_class(#{literal(new.owner)}, #{literal(old.metaclass)})",
          "vm_set_class(#{literal(new.owner)}, #{literal(new.metaclass)})"
        ]
      end

    super_operations =
      if old.supers == new.supers do
        []
      else
        Enum.map(old.supers, &"vm_retract_super(#{literal(new.owner)}, #{literal(&1)})") ++
          Enum.map(new.supers, &"vm_set_super(#{literal(new.owner)}, #{literal(&1)})")
      end

    ivar_operations =
      if old.ivars == new.ivars,
        do: [],
        else: ["vm_set_slot(#{literal(new.owner)}, :ivars, #{literal(new.ivars)})"]

    comment_operations =
      if old.comment == new.comment, do: [], else: comment_operations(new)

    migration =
      if old.kind == :class and new.kind == :class and
           (old.supers != new.supers or old.ivars != new.ivars) do
        old_spec = %{supers: old.supers, ivars: old.ivars}
        new_spec = %{supers: new.supers, ivars: new.ivars}
        ["class_redefined(#{literal(new.owner)}, #{literal(old_spec)}, #{literal(new_spec)})"]
      else
        []
      end

    operations =
      class_operations ++ super_operations ++ ivar_operations ++ comment_operations ++ migration

    if operations == [], do: [], else: [{Enum.join(operations, "\n"), nil}]
  end

  defp comment_operations(%Document{comment: nil}), do: []

  defp comment_operations(%Document{} = document),
    do: ["vm_set_slot(#{literal(document.owner)}, :comment, #{literal(document.comment)})"]

  defp method_chunks(old, new) do
    old_methods = groups(old)
    new_methods = groups(new.methods)

    removed = Enum.reject(selectors(old), &Map.has_key?(new_methods, &1))

    changed =
      Enum.filter(selectors(new.methods), fn selector ->
        Map.get(old_methods, selector) != Map.fetch!(new_methods, selector)
      end)

    Enum.map(removed, &{remove_method(new.owner, &1), nil}) ++
      Enum.flat_map(changed, fn selector ->
        [{retract_clauses(new.owner, selector), nil}] ++
          Enum.map(Map.fetch!(new_methods, selector), fn clause ->
            {definition(new.owner, clause), {new.owner, selector}}
          end)
      end)
  end

  defp groups(nil), do: %{}
  defp groups(%Document{methods: methods}), do: groups(methods)

  defp groups(methods) when is_list(methods),
    do: Enum.group_by(methods, & &1.selector, &{&1.declaration, &1.body})

  defp selectors(nil), do: []
  defp selectors(%Document{methods: methods}), do: selectors(methods)

  defp selectors(methods) when is_list(methods),
    do: methods |> Enum.map(& &1.selector) |> Enum.uniq()

  defp definition(owner, {declaration, body}),
    do: "defmethod(#{literal(owner)}, #{declaration}) do\n#{body}\nend"

  defp retract_clauses(owner, selector) do
    scope = scope(owner, selector)

    """
    findall(id_#{scope}, [vm_method(#{literal(owner)}, #{literal(selector)}, id_#{scope})], ids_#{scope})

    forall([member(ids_#{scope}, id_#{scope})]) do
      findall(
        [head_#{scope}, body_#{scope}],
        [vm_clause(id_#{scope}, head_#{scope}, body_#{scope})],
        clauses_#{scope}
      )

      forall([member(clauses_#{scope}, [head_#{scope}, body_#{scope}])]) do
        vm_retract_oapply(id_#{scope}, head_#{scope})
      end
    end\
    """
  end

  defp remove_method(owner, selector) do
    scope = scope(owner, selector)

    retract_clauses(owner, selector) <>
      """


      forall([member(ids_#{scope}, id_#{scope})]) do
        vm_retract_method(#{literal(owner)}, #{literal(selector)}, id_#{scope})
      end\
      """
  end

  defp scope(owner, selector) do
    "#{identifier(owner)}_#{identifier(selector)}"
  end

  defp identifier(term) do
    term
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9]/u, "_")
    |> String.downcase()
  end

  defp literal(term),
    do:
      inspect(term, pretty: true, limit: :infinity, printable_limit: :infinity, width: :infinity)
end
