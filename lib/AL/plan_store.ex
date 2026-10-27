defmodule AL.PlanStore do
  @resident_entries :al_plan_store_entries
  @max_resident_methods 256

  defmodule Implementation do
    use TypedStruct

    typedstruct do
      field(:code, term(), enforce: true)
      field(:requirements, map(), default: %{})
      field(:dependencies, map(), default: %{})
      field(:deferred_queries, map(), default: %{})
    end

    def valid_dependencies?(dependencies, branch) do
      Enum.all?(dependencies, fn
        {{:method, receiver, selector}, {id, clauses}} ->
          case AL.Dispatch.target(receiver, selector, branch) do
            {:ok, _, ^id} -> AL.JAM.Clauses.cached_scan_clauses(id, branch) === clauses
            _ -> false
          end

        {{:direct_classes, object}, classes} ->
          AL.Dispatch.direct_classes(object, branch) === classes

        {{:providers, {receiver, selector, id}}, {cursor, rows}} ->
          case AL.Dispatch.target(receiver, selector, branch) do
            {:ok, _, ^id} ->
              AL.Dispatch.provider_cursor(receiver, selector, id, branch) === cursor and
                Enum.all?(rows, fn {provider, clauses} ->
                  AL.JAM.Clauses.cached_scan_clauses(provider, branch) === clauses
                end)

            _ ->
              false
          end

        {{:class, {object, class}}, rows} ->
          AL.Object.scan_class(object, class, branch) === rows

        {{:ivar_specs, class}, specs} ->
          AL.Dispatch.ivar_specs_for_classes([class], branch) === specs

        {{:ivar_spec, {object, key}}, spec} ->
          AL.Dispatch.find_ivar_spec(object, key, branch) === spec
      end)
    end
  end

  def table(%AL.Branch{id: :main}), do: :al_implementations

  def table(%AL.Branch{id: branch}) do
    AL.Branch.cached_table_name(:plan_store, :implementations, branch, fn ->
      :"al_implementations@#{branch}"
    end)
  end

  def create_tables(branch) do
    opts = [
      attributes: [:key, :value],
      type: :set,
      ram_copies: [node()],
      record_name: :implementations
    ]

    case :mnesia.create_table(table(branch), opts) do
      {:atomic, :ok} -> :ok
      {:aborted, {:already_exists, _}} -> :ok
    end

    AL.Command.ensure_local_copy(table(branch))
    :mnesia.wait_for_tables([table(branch)], 5_000)
    :ok
  end

  def drop_tables(branch) do
    :mnesia.delete_table(table(branch))
    :ok
  end

  def implementations(branch, method) do
    {_revision, entries} = entries(branch, method)
    entries
  end

  def fetch_method(branch, method, compute, requirements \\ %{}) do
    implementation =
      fetch(branch, method, requirements, fn ->
        %Implementation{
          code: compute.(),
          requirements: requirements
        }
      end)

    implementation.code
  end

  def invalidate_method(branch, method) do
    AL.ResolutionCache.invalidate_dispatch(branch)
    :mnesia.delete(table(branch), {:revision, method}, :write)
    :mnesia.delete(table(branch), {:entries, method}, :write)
    cache = Process.get(@resident_entries, %{})
    Process.put(@resident_entries, Map.delete(cache, {table(branch), method}))
    :ok
  end

  def fetch(branch, method, requirements, compute) do
    AL.ResolutionCache.fetch_dispatch(branch, {:implementation, method, requirements}, fn ->
      select(branch, method, &(&1.requirements == requirements), compute)
    end)
  end

  def select(branch, method, accepts?, compute) do
    {revision, entries} = entries(branch, method)

    case Enum.find(Enum.with_index(entries), fn {entry, index} ->
           accepts?.(entry) and
             AL.ResolutionCache.fetch_dispatch(
               branch,
               {:implementation_valid, revision, index},
               fn ->
                 Implementation.valid_dependencies?(entry.dependencies, branch)
               end
             )
         end) do
      nil ->
        case compute.() do
          %Implementation{} = entry ->
            {_revision, entries} = entries(branch, method)

            remaining =
              Enum.reject(entries, fn existing ->
                existing.requirements == entry.requirements and
                  existing.deferred_queries == entry.deferred_queries
              end)

            store_entries(branch, method, [entry | remaining])
            entry

          nil ->
            nil
        end

      {entry, _index} ->
        entry
    end
  end

  defp entries(branch, method) do
    AL.ResolutionCache.fetch_dispatch(branch, {:implementation_entries, method}, fn ->
      revision =
        case :mnesia.read(table(branch), {:revision, method}) do
          [{:implementations, _, revision}] -> revision
          [] -> nil
        end

      case {revision, Map.get(Process.get(@resident_entries, %{}), {table(branch), method})} do
        {nil, _} ->
          {nil, []}

        {revision, {revision, entries}} ->
          {revision, entries}

        {revision, _} ->
          [{:implementations, _, entries}] = :mnesia.read(table(branch), {:entries, method})
          retain_entries(branch, method, revision, entries)
          {revision, entries}
      end
    end)
  end

  defp store_entries(branch, method, entries) do
    revision = make_ref()
    :mnesia.write(table(branch), {:implementations, {:entries, method}, entries}, :write)
    :mnesia.write(table(branch), {:implementations, {:revision, method}, revision}, :write)
    AL.ResolutionCache.invalidate_dispatch(branch)

    AL.ResolutionCache.store_dispatch(
      branch,
      {:implementation_entries, method},
      {revision, entries}
    )

    retain_entries(branch, method, revision, entries)
  end

  defp retain_entries(branch, method, revision, entries) do
    key = {table(branch), method}
    cache = Process.get(@resident_entries, %{})

    cache =
      if map_size(cache) >= @max_resident_methods and not Map.has_key?(cache, key),
        do: %{},
        else: cache

    Process.put(@resident_entries, Map.put(cache, key, {revision, entries}))
  end
end
