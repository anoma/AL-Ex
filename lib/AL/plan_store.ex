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
    Enum.map(entries, fn {_id, entry} -> entry end)
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
    table = table(branch)

    case :mnesia.read(table, {:method, method}) do
      [{:implementations, _, {_revision, head}}] -> delete_entries(table, method, head)
      [] -> :ok
    end

    :mnesia.delete(table, {:method, method}, :write)
    cache = Process.get(@resident_entries, %{})
    Process.put(@resident_entries, Map.delete(cache, {table, method}))
    :ok
  end

  def fetch(branch, method, requirements, compute) do
    AL.ResolutionCache.fetch_dispatch(branch, {:implementation, method, requirements}, fn ->
      case exact_implementation(branch, method, requirements) do
        nil -> select(branch, method, &(&1.requirements == requirements), compute)
        implementation -> implementation
      end
    end)
  end

  defp exact_implementation(branch, method, requirements) do
    table = table(branch)
    identity = {requirements, %{}}
    key = variant_identity_key(method, identity)

    with [{:implementations, _, bucket}] <- :mnesia.read(table, key),
         {_identity, id} <- Enum.find(bucket, fn {stored, _id} -> stored === identity end),
         {revision, _head} when not is_nil(revision) <- current_method(branch, method),
         entry when not is_nil(entry) <- resident_entry(table, method, revision, id),
         true <- acceptable?(entry, id, branch, revision, fn _ -> true end) do
      entry
    else
      _ -> nil
    end
  end

  def select(branch, method, accepts?, compute) do
    {revision, head} = current_method(branch, method)
    table = table(branch)

    found =
      case Map.get(Process.get(@resident_entries, %{}), {table, method}) do
        {^revision, entries, _by_id, _by_dispatch} when not is_nil(revision) ->
          find_acceptable(entries, branch, revision, accepts?)

        _ ->
          find_acceptable(table, head, branch, revision, accepts?)
      end

    case found do
      nil ->
        compute_and_store(branch, method, compute)

      {_id, entry} ->
        entry
    end
  end

  def select_for_dispatch(branch, method, dispatches, accepts?, compute) do
    {revision, _head} = current_method(branch, method)
    by_dispatch = resident_dispatches(branch, method, revision)

    found =
      Enum.find_value(dispatches, fn dispatch ->
        by_dispatch
        |> Map.get(dispatch, [])
        |> find_acceptable(branch, revision, accepts?)
      end)

    case found do
      nil -> compute_and_store(branch, method, compute)
      {_id, entry} -> entry
    end
  end

  defp compute_and_store(branch, method, compute) do
    case compute.() do
      %Implementation{} = entry ->
        {_revision, entries} = entries(branch, method)
        store_entry(branch, method, entry, entries)
        entry

      nil ->
        nil
    end
  end

  defp entries(branch, method) do
    AL.ResolutionCache.fetch_dispatch(branch, {:implementation_entries, method}, fn ->
      table = table(branch)

      case current_method(branch, method) do
        {nil, nil} ->
          {nil, []}

        {revision, head} ->
          case Map.get(Process.get(@resident_entries, %{}), {table, method}) do
            {^revision, entries, _by_id, _by_dispatch} ->
              {revision, entries}

            _ ->
              entries = read_entries(table, head, [])
              retain_entries(branch, method, revision, entries)
              {revision, entries}
          end
      end
    end)
  end

  defp store_entry(branch, method, entry, entries) do
    table = table(branch)
    variant = variant_key(method, entry)
    identity = {entry.requirements, entry.deferred_queries}

    bucket =
      case :mnesia.read(table, variant) do
        [{:implementations, _, bucket}] -> bucket
        [] -> []
      end

    {head, entries, replaced_id} =
      case Enum.find_value(bucket, fn {stored_identity, id} ->
             if stored_identity === identity, do: id
           end) do
        old_id when not is_nil(old_id) ->
          unlink_entry(table, method, old_id)

          {head, _} = method_head(table, method)
          {head, Enum.reject(entries, fn {id, _entry} -> id == old_id end), old_id}

        nil ->
          {head, _} = method_head(table, method)
          {head, entries, nil}
      end

    id = make_ref()

    if head do
      [{:implementations, _, {_previous, next}}] = :mnesia.read(table, {:link, head})
      :mnesia.write(table, {:implementations, {:link, head}, {id, next}}, :write)
    end

    :mnesia.write(table, {:implementations, {:plan, id}, entry}, :write)
    :mnesia.write(table, {:implementations, {:link, id}, {nil, head}}, :write)
    link_dispatch_entry(table, method, id, entry)

    bucket =
      [
        {identity, id}
        | Enum.reject(bucket, fn {stored_identity, _id} -> stored_identity === identity end)
      ]

    :mnesia.write(table, {:implementations, variant, bucket}, :write)

    revision = make_ref()
    :mnesia.write(table, {:implementations, {:method, method}, {revision, id}}, :write)
    AL.ResolutionCache.delete_dispatch(branch, {:implementation, method, entry.requirements})
    AL.ResolutionCache.store_dispatch(branch, {:implementation_head, method}, {revision, id})

    AL.ResolutionCache.store_dispatch(
      branch,
      {:implementation_entries, method},
      {revision, [{id, entry} | entries]}
    )

    retain_stored_entry(branch, method, revision, [{id, entry} | entries], id, entry, replaced_id)
  end

  defp method_head(table, method) do
    case :mnesia.read(table, {:method, method}) do
      [{:implementations, _, {revision, head}}] -> {head, revision}
      [] -> {nil, nil}
    end
  end

  defp current_method(branch, method) do
    AL.ResolutionCache.fetch_dispatch(branch, {:implementation_head, method}, fn ->
      case :mnesia.read(table(branch), {:method, method}) do
        [{:implementations, _, {revision, head}}] -> {revision, head}
        [] -> {nil, nil}
      end
    end)
  end

  defp find_acceptable([], _branch, _revision, _accepts?), do: nil

  defp find_acceptable([{id, entry} | rest], branch, revision, accepts?) do
    if acceptable?(entry, id, branch, revision, accepts?),
      do: {id, entry},
      else: find_acceptable(rest, branch, revision, accepts?)
  end

  defp find_acceptable(_table, nil, _branch, _revision, _accepts?), do: nil

  defp find_acceptable(table, id, branch, revision, accepts?) do
    [{:implementations, _, entry}] = :mnesia.read(table, {:plan, id})

    if acceptable?(entry, id, branch, revision, accepts?) do
      {id, entry}
    else
      [{:implementations, _, {_previous, next}}] = :mnesia.read(table, {:link, id})
      find_acceptable(table, next, branch, revision, accepts?)
    end
  end

  defp link_dispatch_entry(table, method, id, %{requirements: %{dispatch: dispatch}}) do
    key = {:dispatch, method, dispatch}

    head =
      case :mnesia.read(table, key) do
        [{:implementations, _, head}] -> head
        [] -> nil
      end

    if head do
      [{:implementations, _, {_previous, next}}] = :mnesia.read(table, {:dispatch_link, head})
      :mnesia.write(table, {:implementations, {:dispatch_link, head}, {id, next}}, :write)
    end

    :mnesia.write(table, {:implementations, {:dispatch_link, id}, {nil, head}}, :write)
    :mnesia.write(table, {:implementations, key, id}, :write)
  end

  defp link_dispatch_entry(_table, _method, _id, _entry), do: :ok

  defp unlink_dispatch_entry(table, method, id, %{requirements: %{dispatch: dispatch}}) do
    [{:implementations, _, {previous, next}}] = :mnesia.read(table, {:dispatch_link, id})

    if previous do
      [{:implementations, _, {before_previous, _}}] =
        :mnesia.read(table, {:dispatch_link, previous})

      :mnesia.write(
        table,
        {:implementations, {:dispatch_link, previous}, {before_previous, next}},
        :write
      )
    else
      key = {:dispatch, method, dispatch}

      if next,
        do: :mnesia.write(table, {:implementations, key, next}, :write),
        else: :mnesia.delete(table, key, :write)
    end

    if next do
      [{:implementations, _, {_, after_next}}] = :mnesia.read(table, {:dispatch_link, next})

      :mnesia.write(
        table,
        {:implementations, {:dispatch_link, next}, {previous, after_next}},
        :write
      )
    end

    :mnesia.delete(table, {:dispatch_link, id}, :write)
  end

  defp unlink_dispatch_entry(_table, _method, _id, _entry), do: :ok

  defp acceptable?(entry, id, branch, revision, accepts?) do
    accepts?.(entry) and
      AL.ResolutionCache.fetch_dispatch(branch, {:implementation_valid, revision, id}, fn ->
        Implementation.valid_dependencies?(entry.dependencies, branch)
      end)
  end

  defp unlink_entry(table, method, id) do
    [{:implementations, _, entry}] = :mnesia.read(table, {:plan, id})
    unlink_dispatch_entry(table, method, id, entry)
    [{:implementations, _, {previous, next}}] = :mnesia.read(table, {:link, id})

    if previous do
      [{:implementations, _, {before_previous, _}}] = :mnesia.read(table, {:link, previous})
      :mnesia.write(table, {:implementations, {:link, previous}, {before_previous, next}}, :write)
    else
      [{:implementations, _, {revision, ^id}}] = :mnesia.read(table, {:method, method})
      :mnesia.write(table, {:implementations, {:method, method}, {revision, next}}, :write)
    end

    if next do
      [{:implementations, _, {_, after_next}}] = :mnesia.read(table, {:link, next})
      :mnesia.write(table, {:implementations, {:link, next}, {previous, after_next}}, :write)
    end

    :mnesia.delete(table, {:link, id}, :write)
    :mnesia.delete(table, {:plan, id}, :write)
  end

  defp read_entries(_table, nil, entries), do: Enum.reverse(entries)

  defp read_entries(table, id, entries) do
    [{:implementations, _, entry}] = :mnesia.read(table, {:plan, id})
    [{:implementations, _, {_previous, next}}] = :mnesia.read(table, {:link, id})
    read_entries(table, next, [{id, entry} | entries])
  end

  defp delete_entries(_table, _method, nil), do: :ok

  defp delete_entries(table, method, id) do
    [{:implementations, _, entry}] = :mnesia.read(table, {:plan, id})
    [{:implementations, _, {_previous, next}}] = :mnesia.read(table, {:link, id})
    :mnesia.delete(table, {:dispatch_link, id}, :write)

    case entry.requirements do
      %{dispatch: dispatch} -> :mnesia.delete(table, {:dispatch, method, dispatch}, :write)
      _ -> :ok
    end

    variant = variant_key(method, entry)
    [{:implementations, _, bucket}] = :mnesia.read(table, variant)
    bucket = Enum.reject(bucket, fn {_identity, stored_id} -> stored_id == id end)

    if bucket == [],
      do: :mnesia.delete(table, variant, :write),
      else: :mnesia.write(table, {:implementations, variant, bucket}, :write)

    :mnesia.delete(table, {:plan, id}, :write)
    :mnesia.delete(table, {:link, id}, :write)
    delete_entries(table, method, next)
  end

  defp variant_key(method, entry) do
    identity = {entry.requirements, entry.deferred_queries}
    variant_identity_key(method, identity)
  end

  defp variant_identity_key(method, identity) do
    {:variant, method, :crypto.hash(:sha256, :erlang.term_to_binary(identity))}
  end

  defp resident_entry(table, method, revision, id) do
    case Map.get(Process.get(@resident_entries, %{}), {table, method}) do
      {^revision, _entries, by_id, _by_dispatch} -> Map.get(by_id, id) || read_entry(table, id)
      _ -> read_entry(table, id)
    end
  end

  defp read_entry(table, id) do
    case :mnesia.read(table, {:plan, id}) do
      [{:implementations, _, entry}] -> entry
      [] -> nil
    end
  end

  defp retain_entries(branch, method, revision, entries) do
    key = {table(branch), method}
    cache = Process.get(@resident_entries, %{})
    by_dispatch = dispatch_index(entries)

    cache =
      if map_size(cache) >= @max_resident_methods and not Map.has_key?(cache, key),
        do: %{},
        else: cache

    Process.put(
      @resident_entries,
      Map.put(cache, key, {revision, entries, Map.new(entries), by_dispatch})
    )

    by_dispatch
  end

  defp retain_stored_entry(branch, method, revision, entries, id, entry, replaced_id) do
    key = {table(branch), method}
    cache = Process.get(@resident_entries, %{})

    {by_id, by_dispatch} =
      case Map.get(cache, key) do
        {_previous_revision, _previous_entries, by_id, by_dispatch} ->
          by_id = by_id |> Map.delete(replaced_id) |> Map.put(id, entry)

          by_dispatch =
            case entry.requirements do
              %{dispatch: dispatch} ->
                candidates = Map.get(by_dispatch, dispatch, [])

                candidates =
                  if replaced_id,
                    do:
                      Enum.reject(candidates, fn {candidate_id, _} ->
                        candidate_id == replaced_id
                      end),
                    else: candidates

                Map.put(by_dispatch, dispatch, [{id, entry} | candidates])

              _ ->
                by_dispatch
            end

          {by_id, by_dispatch}

        _ ->
          {Map.new(entries), dispatch_index(entries)}
      end

    Process.put(@resident_entries, Map.put(cache, key, {revision, entries, by_id, by_dispatch}))
  end

  defp resident_dispatches(branch, method, revision) do
    case Map.get(Process.get(@resident_entries, %{}), {table(branch), method}) do
      {^revision, _entries, _by_id, by_dispatch} ->
        by_dispatch

      _ ->
        {^revision, entries} = entries(branch, method)
        retain_entries(branch, method, revision, entries)
    end
  end

  defp dispatch_index(entries) do
    entries
    |> Enum.reduce(%{}, fn
      {_, %Implementation{requirements: %{dispatch: dispatch}}} = candidate, index ->
        Map.update(index, dispatch, [candidate], &[candidate | &1])

      _, index ->
        index
    end)
    |> Map.new(fn {dispatch, candidates} -> {dispatch, Enum.reverse(candidates)} end)
  end
end
