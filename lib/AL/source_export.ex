defmodule AL.SourceExport do
  @moduledoc """
  I project a branch's retained AL transactions into an append-only directory,
  with Tonel-like definition documents alongside them.

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
  the live branch unchanged. Existing edits are reconciled once at startup
  (before the first regeneration and before the watcher attaches), so edits
  made while AL is stopped are imported on restart.

  Source exports are enabled by default under `al-source-export/`. Set
  `config :al, :source_export_dir, "path"` or `AL_SOURCE_EXPORT_DIR` to choose another
  root.
  """

  use GenServer

  require Logger

  alias AL.SourceDocument
  alias AL.SourceSnapshot
  alias AL.SourceSync

  @supervisor AL.SourceExport.Supervisor

  @type root() :: Path.t()
  @type result() :: {:ok, [Path.t()]} | {:error, term()}

  @doc "The Dynamic Supervisor child spec for per-branch source export projectors."
  @spec supervisor_spec() :: {module(), keyword()}
  def supervisor_spec do
    {DynamicSupervisor, name: @supervisor, strategy: :one_for_one}
  end

  @doc "The configured source export root, defaulting to `al-source-export/`."
  @spec configured_root() :: root() | nil
  def configured_root do
    case Application.fetch_env(:al, :source_export_dir) do
      {:ok, nil} -> nil
      {:ok, false} -> nil
      {:ok, root} -> root
      :error -> System.get_env("AL_SOURCE_EXPORT_DIR") || "al-source-export"
    end
  end

  @doc "Start a projector for `branch` when a source export root is configured."
  @spec start(AL.Branch.t(), root() | nil) :: :ok | :disabled | {:error, term()}
  def start(branch, root \\ configured_root())

  def start(_branch, nil), do: :disabled

  def start(branch, root) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {branch, root}}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, pid}} -> GenServer.call(pid, :ensure_watching)
      other -> other
    end
  end

  @doc "Return the watcher state for a branch, including its last import result."
  def status(branch \\ AL.Branch.head()) do
    case Process.whereis(name(branch)) do
      nil -> :not_running
      pid -> GenServer.call(pid, :status)
    end
  end

  @doc """
  Whether `branch`'s projector has fully caught up: no queued Mnesia or file
  events, and no export debounced for later. A caller that just made a
  change and wants to observe its effect should poll this instead of
  sleeping a guessed duration — it reflects real backlog, not a timer.
  """
  @spec quiescent?(AL.Branch.t()) :: boolean()
  def quiescent?(branch \\ AL.Branch.head()) do
    case Process.whereis(name(branch)) do
      nil -> true
      pid -> GenServer.call(pid, :quiescent?)
    end
  end

  @doc "Start projectors for the main branch and all existing forks."
  @spec start_all(root() | nil) :: :ok | {:error, term()}
  def start_all(root \\ configured_root())
  def start_all(nil), do: :ok

  def start_all(root) do
    branches = [AL.Branch.main() | AL.Branch.list()]
    current_dirs = MapSet.new(branches, &branch_dir(root, &1))

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

  @doc "Stop the local projector for `branch`, if one is running."
  @spec stop(AL.Branch.t()) :: :ok
  def stop(branch) do
    case {Process.whereis(@supervisor), Process.whereis(name(branch))} do
      {nil, _} -> :ok
      {_, nil} -> :ok
      {_, pid} -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end
  end

  @doc "Export all retained source transactions for `branch` into `root`."
  @spec export_branch(AL.Branch.t(), root() | nil) ::
          result() | {:error, :source_export_not_configured}
  def export_branch(branch, root \\ configured_root())
  def export_branch(_branch, nil), do: {:error, :source_export_not_configured}

  def export_branch(branch, root) do
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

  @doc "Export current retained class and method definitions for `branch`."
  @spec export_definitions(AL.Branch.t(), root() | nil) ::
          result() | {:error, :source_export_not_configured}
  def export_definitions(_branch, nil), do: {:error, :source_export_not_configured}

  def export_definitions(branch, root) do
    case SourceSnapshot.capture(branch) do
      {:ok, snapshot} ->
        case Enum.reduce_while(SourceSnapshot.rendered(snapshot), {:ok, []}, fn {owner, text},
                                                                                {:ok, paths} ->
               case write_derived(root, branch, owner, text) do
                 {:ok, path} -> {:cont, {:ok, [path | paths]}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end) do
          {:ok, paths} ->
            paths = Enum.reverse(paths)

            case prune_derived(root, branch, paths) do
              :ok -> {:ok, paths}
              {:error, reason} -> {:error, reason}
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
  def transactions_dir(root, %AL.Branch{id: branch}) do
    Path.join([root, "branches", Atom.to_string(branch), "transactions"])
  end

  @doc "Return the definitions directory for a branch."
  @spec definitions_dir(root(), AL.Branch.t()) :: Path.t()
  def definitions_dir(root, branch), do: Path.join(branch_dir(root, branch), "definitions")

  @doc "Return the definition document path for an owner."
  @spec definition_path(root(), AL.Branch.t(), term()) :: Path.t()
  def definition_path(root, branch, owner) do
    Path.join([definitions_dir(root, branch), identifier(owner) <> ".class.al"])
  end

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
  def transaction_path(root, branch, tx) when is_integer(tx) and tx >= 0 do
    filename = "#{String.pad_leading(Integer.to_string(tx), 12, "0")}_tx_#{tx}.al"
    Path.join(transactions_dir(root, branch), filename)
  end

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
         {:ok, _transaction_paths} <- export_branch(branch, root),
         :ok <- import_external_definitions(root, branch),
         {:ok, _definition_paths} <- export_definitions(branch, root) do
      state = %{
        branch: branch,
        root: root,
        definitions_root: definitions_dir(root, branch),
        source_text_table: source_text_table,
        soa_table: soa_table,
        aos_table: aos_table,
        definition_snapshot: definition_snapshot(root, branch),
        export_pending: false,
        import_pending: MapSet.new(),
        import_timer: nil,
        watcher: nil
      }

      {:ok, start_watcher(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_info(:export_definitions, %{branch: branch, root: root} = state) do
    state = %{state | export_pending: false}

    case export_definitions(branch, root) do
      {:ok, _paths} ->
        {:noreply, %{state | definition_snapshot: definition_snapshot(root, branch)}}

      {:error, reason} ->
        Logger.warning("AL source export could not project definitions: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:import_definitions, state) do
    paths = state.import_pending |> MapSet.to_list() |> Enum.sort()

    entries =
      Enum.flat_map(paths, fn path ->
        case File.read(path) do
          {:ok, text} ->
            [{path, text}]

          {:error, :enoent} ->
            []

          {:error, reason} ->
            Logger.warning("AL source export could not read #{path}: #{inspect(reason)}")
            []
        end
      end)

    deleted = Enum.reject(paths, &File.exists?/1)
    result = import_document_batch(entries, deleted, state.branch, state.root)

    snapshot =
      Enum.reduce(paths, state.definition_snapshot, fn path, snapshot ->
        case file_fingerprint(path) do
          :missing -> Map.delete(snapshot, path)
          fingerprint -> Map.put(snapshot, path, fingerprint)
        end
      end)

    state =
      state
      |> Map.put(:import_pending, MapSet.new())
      |> Map.put(:import_timer, nil)
      |> Map.put(:definition_snapshot, snapshot)
      |> Map.put(:last_import, %{paths: paths, result: result})

    {:noreply, state}
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
        Logger.warning("AL source export could not project tx_#{tx}: #{inspect(reason)}")
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
    if definition_file?(state, path) do
      {:noreply, handle_definition_file_event(state, path)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher: watcher} = state) do
    Logger.warning(
      "AL source export file watcher for #{state.definitions_root} stopped, restarting"
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
     pending == 0 and not state.export_pending and is_nil(state.import_timer) and
       MapSet.size(state.import_pending) == 0, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       branch: state.branch,
       directory: Path.expand(definitions_dir(state.root, state.branch)),
       watching: match?(pid when is_pid(pid), state[:watcher]),
       last_import: Map.get(state, :last_import, :none)
     }, state}
  end

  def handle_call(:export, _from, %{branch: branch, root: root} = state) do
    {:reply, export_branch(branch, root), state}
  end

  defp name(%AL.Branch{id: branch}), do: String.to_atom("#{__MODULE__}.#{branch}")

  defp branch_dir(root, %AL.Branch{id: branch}),
    do: Path.join([root, "branches", Atom.to_string(branch)])

  defp start_watcher(%{watcher: pid} = state) when is_pid(pid), do: state

  defp start_watcher(state) do
    File.mkdir_p!(state.definitions_root)

    case FileSystem.start_link(dirs: [state.definitions_root]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        await_watcher_ready(pid, state.definitions_root)
        %{state | watcher: pid}

      {:error, reason} ->
        Logger.error("AL source export could not start file watcher: #{inspect(reason)}")
        state
    end
  end

  # inotifywait is a separate OS process; subscribing doesn't mean it has
  # attached its watches yet -- recursive setup takes real time proportional
  # to tree size, so a single fixed wait either wastes time on a small tree
  # or loses the race on a large one (a fresh fork's ~150 exported files
  # regularly takes longer to watch than a single short wait). Retry a
  # cheap sentinel write instead of guessing one timeout: succeeds as soon
  # as the watch is actually live, bounded overall the same as before.
  @watcher_ready_retry_ms 50
  @watcher_ready_max_attempts 40

  defp await_watcher_ready(pid, definitions_root),
    do: await_watcher_ready(pid, definitions_root, @watcher_ready_max_attempts)

  defp await_watcher_ready(_pid, definitions_root, 0) do
    Logger.warning(
      "AL source export file watcher for #{definitions_root} didn't confirm readiness"
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

  defp definition_file?(state, path) do
    String.ends_with?(path, ".al") and String.starts_with?(path, state.definitions_root)
  end

  # A branch materializing lots of inherited state at once (a fresh fork,
  # bulk hydration) writes `:soa` one row at a time, not as a single
  # transaction — each write would otherwise trigger its own full
  # re-export. Debounce into one flush per burst instead of one per write.
  @definitions_flush_delay_ms 100

  defp mark_definitions_dirty(%{export_pending: true} = state), do: state

  defp mark_definitions_dirty(state) do
    Process.send_after(self(), :export_definitions, @definitions_flush_delay_ms)
    %{state | export_pending: true}
  end

  @definitions_import_delay_ms 120

  defp handle_definition_file_event(state, path) do
    current = file_fingerprint(path)
    previous = Map.get(state.definition_snapshot, path)

    if previous == current do
      state
    else
      timer =
        state.import_timer ||
          Process.send_after(self(), :import_definitions, @definitions_import_delay_ms)

      %{state | import_pending: MapSet.put(state.import_pending, path), import_timer: timer}
    end
  end

  defp reconcile_store(root) do
    with {:atomic, identity} <- AL.Command.store_identity(),
         :ok <- File.mkdir_p(root) do
      marker = Path.join(root, ".store-id")

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

  defp import_external_definitions(root, branch) do
    case SourceSnapshot.capture(branch) do
      {:ok, snapshot} ->
        expected =
          Map.new(SourceSnapshot.rendered(snapshot), fn {owner, text} ->
            {definition_path(root, branch, owner), text}
          end)

        existing =
          definitions_dir(root, branch)
          |> Path.join("*.class.al")
          |> Path.wildcard()

        entries =
          existing
          |> Enum.flat_map(fn path ->
            case File.read(path) do
              {:ok, text} ->
                if Map.get(expected, path) == text, do: [], else: [{path, text}]

              {:error, reason} ->
                Logger.warning("AL source export could not read #{path}: #{inspect(reason)}")
                []
            end
          end)

        import_document_batch(entries, [], branch, root)

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_document_batch([], [], _branch, _root), do: :ok

  defp import_document_batch(entries, deleted_paths, branch, root) do
    paths = Enum.map(entries, &elem(&1, 0)) ++ deleted_paths

    with {:ok, parsed} <- parse_documents(entries),
         {:atomic, {:ok, chunks, prefix}} <-
           :mnesia.transaction(fn ->
             prepare_document_changes(parsed, deleted_paths, branch, root)
           end) do
      evaluate_document_changes(chunks, prefix, paths, branch)
    else
      {:atomic, {:error, reason}} ->
        Logger.error("AL source export rejected #{inspect(paths)}: #{inspect(reason)}")
        {:error, reason}

      {:aborted, reason} ->
        Logger.error("AL source export could not inspect #{inspect(paths)}: #{inspect(reason)}")
        {:error, reason}

      {:error, reason} ->
        Logger.error("AL source export could not parse #{inspect(paths)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp evaluate_document_changes([], [], _paths, _branch), do: :ok

  defp evaluate_document_changes(chunks, prefix, paths, branch) do
    with {:ok, result, source} <- capture_document_source(chunks) do
      result = prepend_program(result, prefix)
      origin = %{kind: :source_export, label: nil, files: paths, format: :definition_document}

      case AL.eval_captured(result, source, origin, nil, branch, []) do
        {:atomic, _} ->
          :ok

        {:aborted, reason} ->
          Logger.error("AL source export rejected #{inspect(paths)}: #{inspect(reason)}")
          {:error, reason}

        {:error, reason} ->
          Logger.error("AL source export could not parse #{inspect(paths)}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp parse_documents(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {path, text}, {:ok, documents} ->
      case SourceDocument.parse(text) do
        {:ok, document} -> {:cont, {:ok, [{path, document} | documents]}}
        {:error, reason} -> {:halt, {:error, {path, reason}}}
      end
    end)
    |> case do
      {:ok, documents} -> {:ok, Enum.reverse(documents)}
      error -> error
    end
  end

  defp prepare_document_changes(parsed, deleted_paths, branch, root) do
    snapshot = SourceSnapshot.capture_in_transaction(branch)

    with :ok <- validate_document_paths(parsed, root, branch),
         deleted_owners <- deleted_owners(deleted_paths, snapshot, root, branch),
         documents <- Enum.map(parsed, &elem(&1, 1)),
         {:ok, plan} <- SourceSync.plan(snapshot, documents, deleted_owners) do
      {:ok, plan.chunks, plan.prefix}
    end
  end

  defp deleted_owners(paths, snapshot, root, branch) do
    Enum.flat_map(paths, fn path ->
      snapshot.documents
      |> Enum.find_value(fn {owner, _document} ->
        if definition_path(root, branch, owner) == path, do: owner
      end)
      |> List.wrap()
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

  defp capture_document_source(chunks) do
    source = Enum.map_join(chunks, "\n\n", &elem(&1, 0))

    {ranges, _line} =
      Enum.map_reduce(chunks, 1, fn {text, target}, line ->
        stop = line + length(String.split(text, "\n")) - 1
        {{line, stop, target}, stop + 2}
      end)

    with {:ok, ast} <-
           Code.string_to_quoted(source <> "\n:__source_export_end__",
             columns: true,
             token_metadata: true
           ) do
      forms =
        case ast do
          {:__block__, _, forms} -> Enum.drop(forms, -1)
          :__source_export_end__ -> []
        end

      results =
        Enum.map(forms, fn form ->
          line = form_line(form)

          target =
            case Enum.find(ranges, fn {first, last, _target} ->
                   line >= first and line <= last
                 end) do
              {_, _, target} -> target
              nil -> nil
            end

          capture_document_form(form, source, target)
        end)

      case combine_captures(results) do
        {:ok, result} -> {:ok, result, source}
        error -> error
      end
    end
  end

  defp capture_document_form(form, source, nil), do: AL.Source.Parser.capture(form, source)

  defp capture_document_form(form, source, {owner, selector}) do
    case form_target(form, owner) do
      {^owner, ^selector} ->
        if qualify_method(form, owner) == form,
          do: AL.Source.Parser.capture(form, source),
          else: AL.Source.Parser.capture_method(form, source, owner)

      target ->
        {:error, {:method_source_mismatch, {owner, selector}, target}}
    end
  end

  defp form_line({_, metadata, _}) when is_list(metadata), do: Keyword.get(metadata, :line, 0)
  defp form_line(_form), do: 0

  defp prepend_program(result, []), do: result

  defp prepend_program(result, prefix) do
    captures =
      Enum.map(result.captures, fn capture ->
        [index | rest] = capture.path
        %{capture | path: [index + length(prefix) | rest]}
      end)

    %{result | program: prefix ++ result.program, captures: captures}
  end

  defp file_fingerprint(path) do
    case File.read(path) do
      {:ok, text} -> fingerprint(text)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp fingerprint(text), do: {:present, byte_size(text), :erlang.phash2(text)}

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

  defp form_target({:defmethod, _, [owner, selector, head | _]}, _fallback_owner)
       when is_atom(owner) and is_atom(selector) and is_list(head),
       do: {owner, selector}

  defp form_target({:defmethod, _, [selector, head | _]}, owner)
       when is_atom(selector) and is_list(head) and not is_nil(owner),
       do: {owner, selector}

  defp form_target(_form, _owner), do: nil

  defp qualify_method({:defmethod, meta, [selector, head]}, owner)
       when is_atom(selector) and is_list(head),
       do: {:defmethod, meta, [owner, selector, head]}

  defp qualify_method({:defmethod, meta, [selector, head, body]}, owner)
       when is_atom(selector) and is_list(head) and is_list(body),
       do: {:defmethod, meta, [owner, selector, head, body]}

  defp qualify_method(form, _owner), do: form

  defp write_derived(root, branch, owner, text),
    do: write_file(definition_path(root, branch, owner), text)

  defp write_file(path, text) do
    with :ok <- File.mkdir_p(Path.dirname(path)), {:ok, ^path} <- atomic_write(path, text) do
      {:ok, path}
    else
      {:error, reason} -> {:error, {:file_write, path, reason}}
    end
  end

  defp prune_derived(root, branch, current_paths) do
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

  defp identifier(term) when is_atom(term), do: safe_identifier(Atom.to_string(term))
  defp identifier(term), do: safe_identifier(inspect(term))

  defp safe_identifier(value) do
    value = Regex.replace(~r/[^A-Za-z0-9_.-]/u, value, "_")
    if value in ["", ".", ".."], do: "_", else: value
  end

  defp write_transaction(root, branch, tx, text) do
    directory = transactions_dir(root, branch)
    path = transaction_path(root, branch, tx)
    :ok = File.mkdir_p(directory)

    case File.read(path) do
      {:ok, ^text} -> {:ok, path}
      {:ok, _other} -> atomic_write(path, text)
      {:error, :enoent} -> atomic_write(path, text)
      {:error, reason} -> {:error, {:file_read, path, reason}}
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
