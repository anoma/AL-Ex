defmodule AL.Serialisation do
  @moduledoc """
  Serialises a branch into ordinary AL files and deserialises definition edits
  back into atomic AL transactions.

  Mnesia and `AL.SourceStore` remain authoritative. The filesystem is a
  repairable, human-facing projection: each retained source transaction gets
  one file named by its branch-local transaction sequence. Transaction files
  are repaired from retained source when missing or different, and removed
  when their transactions no longer exist in the store.

  Each definition owner has one document. Its class metadata and method
  identity/order metadata are regenerated from live facts. Only method bodies
  are source: retained source is written verbatim, while clauses without it use
  a decompiled body explicitly marked as such.

  Both directions are event-driven, no polling. An `inotify` watcher (via
  `:file_system`) reports definition file edits directly; retracted or
  redefined objects reach the filesystem through a Mnesia table subscription
  on the branch's `soa` and `source_text` tables. Valid AL edits become new
  retained transactions; parse and evaluation failures are logged and leave
  the live branch unchanged. Startup regenerates files from the store before
  attaching the watcher. Offline edits are overwritten, missing files restored,
  and definitions absent from the store removed. Only definition file edits
  observed by the running watcher are deserialised.

  Serialisation is enabled by default under `src/al/`. Set
  `config :al, :serialisation_dir, "path"` to choose another root, or set it
  to `nil` to disable serialisation.
  """

  use GenServer

  require Logger

  alias AL.Serialisation.Document
  alias AL.Serialisation.Layout
  alias AL.Serialisation.Snapshot
  alias AL.Serialisation.Sync

  @supervisor AL.Serialisation.Supervisor

  @type root() :: Path.t()
  @type result() :: {:ok, [Path.t()]} | {:error, term()}

  @doc "The DynamicSupervisor child spec for per-branch serialisers."
  @spec supervisor_spec() :: {module(), keyword()}
  def supervisor_spec do
    {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
  end

  @doc "The configured serialisation root, defaulting to `src/al/`."
  @spec configured_root() :: root() | nil
  def configured_root do
    case Application.fetch_env(:al, :serialisation_dir) do
      {:ok, nil} -> nil
      {:ok, false} -> nil
      {:ok, root} -> root
      :error -> "src/al"
    end
  end

  @doc "Start the serialiser for `branch` when a root is configured."
  @spec start(AL.Branch.t(), root() | nil) :: :ok | :disabled | {:error, term()}
  def start(branch, root \\ configured_root())

  def start(_branch, nil), do: :disabled

  def start(branch, root) do
    if owner_node?(), do: start_local(branch, root), else: call_owner(:start, [branch, root])
  end

  defp start_local(branch, root) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {branch, root}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> GenServer.call(pid, :ensure_watching)
      other -> other
    end
  end

  @doc "Return the watcher state, including the last deserialisation result."
  def status(branch \\ AL.Branch.head()) do
    if owner_node?(), do: status_local(branch), else: call_owner(:status, [branch])
  end

  defp status_local(branch) do
    case Process.whereis(name(branch)) do
      nil -> :not_running
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc """
  Whether `branch`'s serialiser has fully caught up: no queued Mnesia or file
  events, and no serialisation debounced for later. A caller that just made a
  change and wants to observe its effect should poll this instead of
  sleeping a guessed duration — it reflects real backlog, not a timer.
  """
  @spec quiescent?(AL.Branch.t()) :: boolean()
  def quiescent?(branch \\ AL.Branch.head()) do
    if owner_node?() do
      quiescent_local?(branch)
    else
      case call_owner(:quiescent?, [branch]) do
        result when is_boolean(result) -> result
        {:error, _reason} -> false
      end
    end
  end

  defp quiescent_local?(branch) do
    case Process.whereis(name(branch)) do
      nil -> true
      pid -> GenServer.call(pid, :quiescent?)
    end
  end

  @doc "Start serialisers for the main branch and all existing forks."
  @spec start_all(root() | nil) :: :ok | {:error, term()}
  def start_all(root \\ configured_root())
  def start_all(nil), do: :ok

  def start_all(root) do
    if owner_node?(), do: start_all_local(root), else: call_owner(:start_all, [root])
  end

  defp start_all_local(root) do
    branches = [AL.Branch.main() | AL.Branch.list()]
    current_dirs = MapSet.new(branches, &Layout.branch_dir(root, &1))

    root
    |> Path.join("branches/*")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(current_dirs, &1))
    |> Enum.each(&File.rm_rf!/1)

    Enum.reduce_while(branches, :ok, fn branch, :ok ->
      case start(branch, root) do
        :ok -> {:cont, :ok}
        other -> {:halt, other}
      end
    end)
  end

  @doc "Stop the local serialiser for `branch`, if one is running."
  @spec stop(AL.Branch.t()) :: :ok | {:error, term()}
  def stop(branch) do
    if owner_node?(), do: stop_local(branch), else: call_owner(:stop, [branch])
  end

  defp stop_local(branch) do
    case {Process.whereis(@supervisor), Process.whereis(name(branch))} do
      {nil, _} -> :ok
      {_, nil} -> :ok
      {_, pid} -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc "Serialise all retained transactions for `branch` into `root`."
  @spec serialise_branch(AL.Branch.t(), root() | nil) ::
          result() | {:error, :serialisation_not_configured}
  def serialise_branch(branch, root \\ configured_root())
  def serialise_branch(_branch, nil), do: {:error, :serialisation_not_configured}

  def serialise_branch(branch, root) do
    case :mnesia.transaction(fn -> AL.SourceStore.texts(branch) end) do
      {:atomic, rows} ->
        rows
        |> Enum.reduce_while({:ok, []}, fn {:source_text, tx, text, _origin}, {:ok, paths} ->
          case write_transaction(root, branch, tx, text) do
            {:ok, path} -> {:cont, {:ok, [path | paths]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, paths} ->
            paths = Enum.reverse(paths)

            case prune_files(Path.join(transactions_dir(root, branch), "*.al"), paths) do
              :ok -> {:ok, paths}
              {:error, reason} -> {:error, reason}
            end

          other ->
            other
        end

      {:aborted, reason} ->
        {:error, {:mnesia, reason}}
    end
  end

  @doc "Serialise current class and method definitions for `branch`."
  @spec serialise_definitions(AL.Branch.t(), root() | nil) ::
          result() | {:error, :serialisation_not_configured}
  def serialise_definitions(_branch, nil), do: {:error, :serialisation_not_configured}

  def serialise_definitions(branch, root) do
    case Snapshot.capture(branch) do
      {:ok, snapshot} ->
        case Enum.reduce_while(Snapshot.rendered(snapshot), {:ok, []}, fn {owner, text},
                                                                          {:ok, written} ->
               case write_definition(root, branch, owner, text) do
                 {:ok, path} -> {:cont, {:ok, [{path, fingerprint(text)} | written]}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end) do
          {:ok, written} ->
            written = Enum.reverse(written)
            paths = Enum.map(written, &elem(&1, 0))

            with :ok <- prune_definitions(root, branch, paths),
                 :ok <- write_index(root, branch, Map.new(written)) do
              {:ok, paths}
            end

          other ->
            other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Return the ordered transaction directory for a branch."
  @spec transactions_dir(root(), AL.Branch.t()) :: Path.t()
  defdelegate transactions_dir(root, branch), to: Layout

  @doc "Return the definitions directory for a branch."
  @spec definitions_dir(root(), AL.Branch.t()) :: Path.t()
  defdelegate definitions_dir(root, branch), to: Layout

  @doc "Return the definition document path for an owner."
  @spec definition_path(root(), AL.Branch.t(), term()) :: Path.t()
  defdelegate definition_path(root, branch, owner), to: Layout

  @doc "Return the definition document path for `class`."
  @spec class_path(root(), AL.Branch.t(), term()) :: Path.t()
  def class_path(root, branch, class) do
    definition_path(root, branch, class)
  end

  @doc "Return the owner document containing `class` and `method`."
  @spec method_path(root(), AL.Branch.t(), term(), term()) :: Path.t()
  def method_path(root, branch, class, _method), do: definition_path(root, branch, class)

  @doc "Return the path used for a branch-local transaction sequence number."
  @spec transaction_path(root(), AL.Branch.t(), non_neg_integer()) :: Path.t()
  defdelegate transaction_path(root, branch, tx), to: Layout

  def child_spec({branch, root}) do
    %{
      id: {__MODULE__, branch.id},
      start: {__MODULE__, :start_link, [{branch, root}]},
      type: :worker
    }
  end

  def start_link({branch, root}) do
    GenServer.start_link(__MODULE__, {branch, root}, name: name(branch))
  end

  @impl true
  def init({branch, root}) do
    # `file_system`'s inotify backend reports event paths absolutized
    # (`Path.absname/1`), so `root` must be normalized the same way here —
    # otherwise `definition_file?/2` compares an absolute event path against
    # a relative `definitions_root` and never matches.
    root = Path.expand(root)
    source_text_table = AL.SourceStore.table(:source_text, branch)
    soa_table = AL.Object.table(:soa, branch)
    aos_table = AL.Object.table(:aos, branch)
    :mnesia.subscribe({:table, source_text_table, :detailed})
    :mnesia.subscribe({:table, soa_table, :detailed})
    :mnesia.subscribe({:table, aos_table, :detailed})

    with :ok <- reconcile_store(root),
         {:ok, _transaction_paths} <- serialise_branch(branch, root),
         {:ok, _definition_paths} <- serialise_definitions(branch, root) do
      state = %{
        branch: branch,
        root: root,
        definitions_root: definitions_dir(root, branch),
        source_text_table: source_text_table,
        soa_table: soa_table,
        aos_table: aos_table,
        definition_snapshot: definition_snapshot(root, branch),
        serialisation_pending: false,
        deserialisation_pending: MapSet.new(),
        deserialisation_timer: nil,
        watcher: nil
      }

      {:ok, start_watcher(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:serialise_definitions, %{branch: branch, root: root} = state) do
    state = %{state | serialisation_pending: false}

    case serialise_definitions(branch, root) do
      {:ok, _paths} ->
        {:noreply, %{state | definition_snapshot: definition_snapshot(root, branch)}}

      {:error, reason} ->
        Logger.warning("AL could not serialise definitions: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:deserialise_definitions, state) do
    paths = state.deserialisation_pending |> MapSet.to_list() |> Enum.sort()

    entries =
      Enum.flat_map(paths, fn path ->
        case File.read(path) do
          {:ok, text} ->
            [{path, text}]

          {:error, :enoent} ->
            []

          {:error, reason} ->
            Logger.warning("AL serialisation could not read #{path}: #{inspect(reason)}")
            []
        end
      end)

    deleted = Enum.reject(paths, &File.exists?/1)
    result = deserialise_document_batch(entries, deleted, state.branch, state.root)

    snapshot =
      Enum.reduce(paths, state.definition_snapshot, fn path, snapshot ->
        case file_fingerprint(path) do
          :missing -> Map.delete(snapshot, path)
          fingerprint -> Map.put(snapshot, path, fingerprint)
        end
      end)

    state =
      state
      |> Map.put(:deserialisation_pending, MapSet.new())
      |> Map.put(:deserialisation_timer, nil)
      |> Map.put(:definition_snapshot, snapshot)
      |> Map.put(:last_deserialisation, %{paths: paths, result: result})

    {:noreply, refresh_definitions(state, result)}
  end

  @impl true
  def handle_info(
        {:mnesia_table_event, {:write, table, {:source_text, tx, text, _origin}, _old, _tid}},
        %{source_text_table: table, branch: branch, root: root} = state
      ) do
    case write_transaction(root, branch, tx, text) do
      {:ok, _path} ->
        :ok

      {:error, reason} ->
        Logger.warning("AL could not serialise tx_#{tx}: #{inspect(reason)}")
    end

    {:noreply, mark_definitions_dirty(state)}
  end

  @impl true
  def handle_info(
        {:mnesia_table_event, {_op, table, _record, _old, _tid}},
        %{soa_table: table} = state
      ) do
    {:noreply, mark_definitions_dirty(state)}
  end

  def handle_info(
        {:mnesia_table_event, {_op, table, _record, _old, _tid}},
        %{aos_table: table} = state
      ) do
    {:noreply, mark_definitions_dirty(state)}
  end

  @impl true
  def handle_info({:mnesia_table_event, _event}, state), do: {:noreply, state}

  @impl true
  def handle_info({:file_event, watcher, {path, _events}}, %{watcher: watcher} = state) do
    if Layout.definition_file?(state.definitions_root, path) do
      {:noreply, handle_definition_file_event(state, path)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher: watcher} = state) do
    Logger.warning(
      "AL serialisation file watcher for #{state.definitions_root} stopped, restarting"
    )

    {:noreply, start_watcher(%{state | watcher: nil})}
  end

  @impl true
  def handle_call(:ensure_watching, _from, state) do
    state =
      state
      |> Map.put_new_lazy(:definition_snapshot, fn ->
        definition_snapshot(state.root, state.branch)
      end)
      |> start_watcher()

    {:reply, :ok, state}
  end

  def handle_call(:quiescent?, _from, state) do
    {:message_queue_len, pending} = Process.info(self(), :message_queue_len)

    {:reply,
     pending == 0 and not state.serialisation_pending and
       is_nil(state.deserialisation_timer) and
       MapSet.size(state.deserialisation_pending) == 0, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       branch: state.branch,
       directory: Path.expand(definitions_dir(state.root, state.branch)),
       watching: match?(pid when is_pid(pid), state[:watcher]),
       last_deserialisation: Map.get(state, :last_deserialisation, :none)
     }, state}
  end

  defp refresh_definitions(%{branch: branch, root: root} = state, :ok) do
    case serialise_definitions(branch, root) do
      {:ok, _paths} ->
        %{state | definition_snapshot: definition_snapshot(root, branch)}

      {:error, reason} ->
        Logger.warning("AL could not serialise definitions: #{inspect(reason)}")
        state
    end
  end

  defp refresh_definitions(state, {:error, {:stale_definition, _owner}}),
    do: refresh_definitions(state, :ok)

  defp refresh_definitions(state, _result), do: state

  defp name(%AL.Branch{id: branch}), do: String.to_atom("#{__MODULE__}.#{branch}")

  defp owner_node?, do: node() == AL.Command.owner_node()

  defp call_owner(function, arguments) do
    owner = AL.Command.owner_node()

    case :rpc.call(owner, __MODULE__, function, arguments) do
      {:badrpc, reason} -> {:error, {:owner_unavailable, owner, reason}}
      result -> result
    end
  end

  defp start_watcher(%{watcher: pid} = state) when is_pid(pid), do: state

  defp start_watcher(state) do
    with :ok <- File.mkdir_p(state.definitions_root),
         {:ok, pid} <- FileSystem.start_link(dirs: [state.definitions_root]) do
      FileSystem.subscribe(pid)
      await_watcher_ready(pid, state.definitions_root)
      %{state | watcher: pid}
    else
      {:error, reason} ->
        Logger.error("AL serialisation could not start file watcher: #{inspect(reason)}")
        state
    end
  end

  # inotifywait is a separate OS process; subscribing doesn't mean it has
  # attached its watches yet -- recursive setup takes real time proportional
  # to tree size, so a single fixed wait either wastes time on a small tree
  # or loses the race on a large one (a fresh fork's ~150 serialised files
  # regularly takes longer to watch than a single short wait). Retry a
  # cheap sentinel write instead of guessing one timeout: succeeds as soon
  # as the watch is actually live, bounded overall the same as before.
  @watcher_ready_retry_ms 50
  @watcher_ready_max_attempts 40

  defp await_watcher_ready(pid, definitions_root),
    do: await_watcher_ready(pid, definitions_root, @watcher_ready_max_attempts)

  defp await_watcher_ready(_pid, definitions_root, 0) do
    Logger.warning(
      "AL serialisation file watcher for #{definitions_root} didn't confirm readiness"
    )
  end

  defp await_watcher_ready(pid, definitions_root, attempts) do
    sentinel = Path.join(definitions_root, ".watch-ready")
    File.write!(sentinel, "")

    outcome =
      receive do
        {:file_event, ^pid, {^sentinel, _events}} -> :ready
        {:file_event, ^pid, :stop} -> :ready
      after
        @watcher_ready_retry_ms -> :retry
      end

    File.rm(sentinel)

    if outcome == :retry, do: await_watcher_ready(pid, definitions_root, attempts - 1)
  end

  # A branch materializing lots of inherited state at once (a fresh fork,
  # bulk hydration) writes `:soa` one row at a time, not as a single
  # transaction — each write would otherwise trigger its own full
  # reserialisation. Debounce into one flush per burst instead of one per write.
  @definitions_flush_delay_ms 100

  defp mark_definitions_dirty(%{serialisation_pending: true} = state), do: state

  defp mark_definitions_dirty(state) do
    Process.send_after(self(), :serialise_definitions, @definitions_flush_delay_ms)
    %{state | serialisation_pending: true}
  end

  @definitions_deserialisation_delay_ms 120

  defp handle_definition_file_event(state, path) do
    current = file_fingerprint(path)
    previous = Map.get(state.definition_snapshot, path)

    if previous == current do
      state
    else
      timer =
        state.deserialisation_timer ||
          Process.send_after(
            self(),
            :deserialise_definitions,
            @definitions_deserialisation_delay_ms
          )

      %{
        state
        | deserialisation_pending: MapSet.put(state.deserialisation_pending, path),
          deserialisation_timer: timer
      }
    end
  end

  defp reconcile_store(root) do
    with {:atomic, identity} <- AL.Command.store_identity(),
         :ok <- File.mkdir_p(root) do
      marker = Layout.store_marker_path(root)

      case File.read(marker) do
        {:ok, ^identity} ->
          :ok

        result when elem(result, 0) == :ok or result == {:error, :enoent} ->
          with {:ok, _} <- File.rm_rf(Path.join(root, "branches")),
               {:ok, _} <- atomic_write(marker, identity) do
            :ok
          end

        {:error, reason} ->
          {:error, {:file_read, marker, reason}}
      end
    else
      {:aborted, reason} -> {:error, {:mnesia, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp definition_snapshot(root, branch) do
    definitions_dir(root, branch)
    |> Path.join("**/*.al")
    |> Path.wildcard()
    |> Map.new(fn path -> {path, file_fingerprint(path)} end)
  end

  defp deserialise_document_batch([], [], _branch, _root), do: :ok

  defp deserialise_document_batch(entries, deleted_paths, branch, root) do
    paths = Enum.map(entries, &elem(&1, 0)) ++ deleted_paths
    index = read_index(root, branch)

    with {:ok, parsed} <- parse_documents(entries),
         {:atomic, {:ok, chunks}} <-
           :mnesia.transaction(fn ->
             prepare_document_changes(parsed, deleted_paths, branch, root, index)
           end) do
      evaluate_document_changes(chunks, paths, branch)
    else
      {:atomic, {:error, reason}} ->
        Logger.error("AL serialisation rejected #{inspect(paths)}: #{inspect(reason)}")
        {:error, reason}

      {:aborted, reason} ->
        Logger.error("AL serialisation could not inspect #{inspect(paths)}: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("AL serialisation could not parse #{inspect(paths)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp evaluate_document_changes([], _paths, _branch), do: :ok

  defp evaluate_document_changes(chunks, paths, branch) do
    with {:ok, result, source} <- compile_chunks(chunks) do
      origin = %{kind: :serialisation, label: nil, files: paths, format: :definition_document}

      case AL.eval_captured(result, source, origin, nil, branch, []) do
        {:atomic, _} ->
          :ok

        {:aborted, reason} ->
          Logger.error("AL serialisation rejected #{inspect(paths)}: #{inspect(reason)}")
          {:error, reason}

        {:error, reason} ->
          Logger.error("AL serialisation could not parse #{inspect(paths)}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp parse_documents(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {path, text}, {:ok, documents} ->
      case Document.parse(text) do
        {:ok, document} -> {:cont, {:ok, [{path, document} | documents]}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, Enum.reverse(documents)}
      error -> error
    end
  end

  defp prepare_document_changes(parsed, deleted_paths, branch, root, index) do
    snapshot = Snapshot.capture_in_transaction(branch)

    with :ok <- validate_document_paths(parsed, root, branch),
         :ok <- validate_fresh_base(parsed, snapshot, index),
         :ok <- validate_deleted_fresh_base(deleted_paths, snapshot, index, root, branch),
         deleted_owners <- deleted_owners(deleted_paths, snapshot, root, branch),
         documents <- Enum.map(parsed, &elem(&1, 1)),
         {:ok, chunks} <- Sync.plan(snapshot, documents, deleted_owners) do
      {:ok, chunks}
    end
  end

  defp deleted_owners(paths, snapshot, root, branch) do
    Enum.flat_map(paths, fn path ->
      case owner_document_for_path(snapshot, path, root, branch) do
        {owner, _document} -> [owner]
        nil -> []
      end
    end)
  end

  defp validate_fresh_base(parsed, snapshot, index) do
    Enum.reduce_while(parsed, :ok, fn {path, document}, :ok ->
      with %Document{} = current <- Map.get(snapshot.documents, document.owner),
           recorded when not is_nil(recorded) <- Map.get(index, path),
           false <- recorded == fingerprint(Document.render(current)) do
        {:halt, {:error, {:stale_definition, document.owner}}}
      else
        _ -> {:cont, :ok}
      end
    end)
  end

  defp validate_deleted_fresh_base(paths, snapshot, index, root, branch) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case owner_document_for_path(snapshot, path, root, branch) do
        nil ->
          {:cont, :ok}

        {owner, document} ->
          if Map.get(index, path) == fingerprint(Document.render(document)) do
            {:cont, :ok}
          else
            {:halt, {:error, {:stale_definition, owner}}}
          end
      end
    end)
  end

  defp owner_document_for_path(snapshot, path, root, branch) do
    Enum.find_value(snapshot.documents, fn {owner, document} ->
      if definition_path(root, branch, owner) == path, do: {owner, document}
    end)
  end

  defp validate_document_paths(parsed, root, branch) do
    Enum.reduce_while(parsed, :ok, fn {path, document}, :ok ->
      if definition_path(root, branch, document.owner) == path do
        {:cont, :ok}
      else
        {:halt, {:error, {:owner_path_mismatch, path, document.owner}}}
      end
    end)
  end

  @doc false
  @spec compile_chunks([Sync.chunk()]) ::
          {:ok, AL.Source.Parser.Result.t(), String.t()} | {:error, term()}
  def compile_chunks(chunks) do
    source = Enum.map_join(chunks, "\n\n", &elem(&1, 0))

    {results, _line} =
      Enum.map_reduce(chunks, 1, fn {text, _target}, line ->
        {capture_chunk(text, line, source), line + length(String.split(text, "\n")) + 1}
      end)

    case combine_captures(results) do
      {:ok, result} -> {:ok, result, source}
      error -> error
    end
  end

  defp capture_chunk(text, line, source) do
    case AL.Source.Parser.parse_quoted(text, line: line) do
      {:ok, ast} -> AL.Source.Parser.capture(ast, source)
      {:error, reason} -> {:error, {:invalid_definition_source, reason}}
    end
  end

  defp combine_captures(results) do
    Enum.reduce_while(results, {:ok, %AL.Source.Parser.Result{program: [], captures: []}}, fn
      {:error, reason}, _ ->
        {:halt, {:error, reason}}

      {:ok, part}, {:ok, combined} ->
        index = length(combined.program)
        ordinal = length(flatten_captures(combined.captures))
        captures = Enum.map(part.captures, &offset_capture(&1, index, ordinal))

        {:cont,
         {:ok,
          %{
            combined
            | program: combined.program ++ part.program,
              captures: combined.captures ++ captures
          }}}
    end)
  end

  defp flatten_captures(captures),
    do: Enum.flat_map(captures, fn capture -> [capture | flatten_captures(capture.children)] end)

  defp offset_capture(capture, index, ordinal) do
    [first | rest] = capture.path

    %{
      capture
      | path: [first + index | rest],
        ordinal: capture.ordinal + ordinal,
        children: Enum.map(capture.children, &offset_capture(&1, index, ordinal))
    }
  end

  defp file_fingerprint(path) do
    case File.read(path) do
      {:ok, text} -> fingerprint(text)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp fingerprint(text), do: {:present, byte_size(text), :crypto.hash(:sha256, text)}

  defp write_index(root, branch, index) do
    relative_index =
      Map.new(index, fn {path, fingerprint} ->
        {Path.relative_to(path, Layout.branch_dir(root, branch)), fingerprint}
      end)

    path = Layout.index_path(root, branch)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, _path} <- atomic_write(path, :erlang.term_to_binary(relative_index)) do
      :ok
    else
      {:error, {:file_write, _path, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:file_write, path, reason}}
    end
  end

  defp read_index(root, branch) do
    with {:ok, binary} <- File.read(Layout.index_path(root, branch)),
         {:ok, index} when is_map(index) <- safe_term(binary),
         true <- Enum.all?(Map.keys(index), &is_binary/1) do
      Map.new(index, fn {path, fingerprint} ->
        absolute =
          if Path.type(path) == :absolute,
            do: path,
            else: Path.join(Layout.branch_dir(root, branch), path)

        {absolute, fingerprint}
      end)
    else
      _ -> %{}
    end
  end

  defp safe_term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> :error
  end

  defp write_definition(root, branch, owner, text),
    do: write_file(definition_path(root, branch, owner), text)

  defp write_file(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)), {:ok, ^path} <- atomic_write(path, text) do
      {:ok, path}
    else
      {:error, {:file_write, _path, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:file_write, path, reason}}
    end
  end

  defp prune_definitions(root, branch, current_paths) do
    prune_files(Path.join(definitions_dir(root, branch), "**/*.al"), current_paths)
  end

  defp prune_files(pattern, current_paths) do
    current = MapSet.new(current_paths)

    pattern
    |> Path.wildcard()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      if MapSet.member?(current, path) do
        {:cont, :ok}
      else
        case File.rm(path) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:file_remove, path, reason}}}
        end
      end
    end)
  end

  defp write_transaction(root, branch, tx, text) do
    directory = transactions_dir(root, branch)
    path = transaction_path(root, branch, tx)

    with :ok <- File.mkdir_p(directory) do
      case File.read(path) do
        {:ok, ^text} -> {:ok, path}
        {:ok, _other} -> atomic_write(path, text)
        {:error, :enoent} -> atomic_write(path, text)
        {:error, reason} -> {:error, {:file_read, path, reason}}
      end
    else
      {:error, reason} -> {:error, {:file_write, directory, reason}}
    end
  end

  defp atomic_write(path, text) do
    temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

    try do
      with :ok <- File.write(temporary, text), :ok <- File.rename(temporary, path) do
        {:ok, path}
      else
        {:error, reason} -> {:error, {:file_write, path, reason}}
      end
    after
      File.rm(temporary)
    end
  end
end
