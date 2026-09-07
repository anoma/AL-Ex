defmodule AL.SourceExport do
  @moduledoc """
  I project a branch's retained AL transactions into an append-only directory,
  with derived class and method files alongside them.

  Mnesia and `AL.SourceStore` remain authoritative. The filesystem is a
  repairable, human-facing projection: each retained source transaction gets
  one file named by its branch-local transaction sequence. Transaction files
  are repaired from retained source when missing or different, and removed
  when their transactions no longer exist in the store.

  Class and method files draw the same line Tonel and classic Smalltalk
  fileout draw: a class file is metadata (`super`, `ivars`), always
  regenerated from live facts, never treated as retained text -- there's no
  meaningful "verbatim class statement" once facts can enter from
  `vm_set_super`/`vm_set_class` outside `defclass` too. A method file is
  retained source when a clause has one (via `AL.Source`, comments and
  formatting intact), decompiled straight from the live head/body otherwise,
  clearly marked as such.

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
    case :mnesia.transaction(fn -> definition_rows(branch) end) do
      {:atomic, rows} ->
        case Enum.reduce_while(rows, {:ok, []}, fn {kind, target, text}, {:ok, paths} ->
               case write_derived(root, branch, kind, target, text) do
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

      {:aborted, reason} ->
        {:error, {:mnesia, reason}}
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

  @doc "Return the derived class file path for `class`."
  @spec class_path(root(), AL.Branch.t(), term()) :: Path.t()
  def class_path(root, branch, class) do
    Path.join([definitions_dir(root, branch), "classes", identifier(class) <> ".al"])
  end

  @doc "Return the derived method file path for `class` and `method`."
  @spec method_path(root(), AL.Branch.t(), term(), term()) :: Path.t()
  def method_path(root, branch, class, method) do
    Path.join([
      definitions_dir(root, branch),
      "methods",
      identifier(class),
      identifier(method) <> ".al"
    ])
  end

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
    :mnesia.subscribe({:table, source_text_table, :detailed})
    :mnesia.subscribe({:table, soa_table, :detailed})

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
        definition_snapshot: definition_snapshot(root, branch),
        export_pending: false,
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
    {:reply, pending == 0 and not state.export_pending, state}
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

  defp handle_definition_file_event(state, path) do
    current = file_fingerprint(path)
    previous = Map.get(state.definition_snapshot, path)

    cond do
      previous == current ->
        state

      current == :missing and match?({:present, _, _}, previous) ->
        retract_deleted_definition(state, path)

      true ->
        state
        |> Map.update!(:definition_snapshot, &Map.put(&1, path, current))
        |> import_changed_definitions([path])
    end
  end

  defp retract_deleted_definition(state, path) do
    state = Map.update!(state, :definition_snapshot, &Map.delete(&1, path))

    case resolve_deleted_definition(state.root, state.branch, path) do
      {:method, class, method} ->
        case AL.eval(retract_method_program(class, method), nil, state.branch, []) do
          {:atomic, _} ->
            :ok

          {:aborted, reason} ->
            Logger.error(
              "AL source export could not retract #{inspect({class, method})}: #{inspect(reason)}"
            )
        end

      {:class, class} ->
        case AL.eval_source("delete_class(#{inspect(class)})\n", state.branch) do
          {:atomic, _} ->
            :ok

          {:aborted, reason} ->
            Logger.error(
              "AL source export could not retract class #{inspect(class)}: #{inspect(reason)}"
            )

          {:error, reason} ->
            Logger.error(
              "AL source export could not delete class #{inspect(class)}: #{inspect(reason)}"
            )
        end

      nil ->
        Logger.warning("AL source export could not resolve deleted definition #{path}")
    end

    state
  end

  defp resolve_deleted_definition(root, branch, path) do
    case :mnesia.transaction(fn -> definition_rows(branch) end) do
      {:atomic, rows} ->
        Enum.find_value(rows, fn
          {:class, class, _text} ->
            if class_path(root, branch, class) == path, do: {:class, class}

          {:method, {class, method}, _text} ->
            if method_path(root, branch, class, method) == path, do: {:method, class, method}
        end)

      {:aborted, _reason} ->
        nil
    end
  end

  defp retract_method_program(class, method) do
    method_id = AL.Var.var("source_export_delete_method")
    head = AL.Var.var("source_export_delete_head")

    [
      %AL.Goal.Forall{
        condition: [%AL.Goal.GetMethod{object: class, name: method, id: method_id}],
        body: [
          %AL.Goal.RetractOapply{object: method_id, head: head},
          %AL.Goal.RetractMethod{object: class, name: method, id: method_id}
        ]
      }
    ]
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
    case :mnesia.transaction(fn -> definition_rows(branch) end) do
      {:atomic, rows} ->
        expected =
          Map.new(rows, fn
            {:class, class, text} ->
              {class_path(root, branch, class), text}

            {:method, {class, method}, text} ->
              {method_path(root, branch, class, method), text}
          end)

        expected
        |> changed_definition_sources()
        |> import_definition_batch(branch, root)

        :ok

      {:aborted, reason} ->
        {:error, {:mnesia, reason}}
    end
  end

  defp file_fingerprint(path) do
    case File.read(path) do
      {:ok, text} -> fingerprint(text)
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp fingerprint(text), do: {:present, byte_size(text), :erlang.phash2(text)}

  defp import_changed_definitions(state, paths) do
    result =
      paths
      |> Enum.sort()
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, text} ->
            [{path, text}]

          {:error, :enoent} ->
            Logger.warning("AL source export ignored deleted definition #{path}")
            []

          {:error, reason} ->
            Logger.warning("AL source export could not read #{path}: #{inspect(reason)}")
            []
        end
      end)
      |> import_definition_batch(state.branch, state.root)

    Map.put(state, :last_import, %{paths: paths, result: result})
  end

  defp changed_definition_sources(expected) do
    expected
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {path, expected_text} ->
      case File.read(path) do
        {:ok, ^expected_text} ->
          []

        {:ok, text} ->
          [{path, text}]

        {:error, :enoent} ->
          []

        {:error, reason} ->
          Logger.warning("AL source export could not read #{path}: #{inspect(reason)}")
          []
      end
    end)
  end

  defp import_definition_batch([], _branch, _root), do: :ok

  defp import_definition_batch(entries, branch, root) do
    source = Enum.map_join(entries, "\n\n", &elem(&1, 1))
    paths = Enum.map(entries, &elem(&1, 0))

    case prepare_definition_batch(entries, source, branch, root) do
      {:ok, result} ->
        result = redefine_classes(result)
        origin = %{kind: :source_export, label: nil, files: paths, redefine_classes: true}

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

      {:error, reason} ->
        Logger.error("AL source export could not parse #{inspect(paths)}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp prepare_definition_batch(entries, source, branch, root) do
    with {:atomic, methods} <-
           :mnesia.transaction(fn ->
             AL.Object.scan_method(
               AL.Var.var("source_export_owner"),
               AL.Var.var("source_export_selector"),
               AL.Var.var("source_export_method"),
               branch
             )
           end),
         {:ok, ast} <-
           Code.string_to_quoted(source <> "\n:__source_export_end__",
             columns: true,
             token_metadata: true
           ) do
      targets =
        Map.new(methods, fn {:method, owner, selector, _id} ->
          {method_path(root, branch, owner, selector), {owner, selector}}
        end)

      {ranges, _line} =
        Enum.map_reduce(entries, 1, fn {path, text}, line ->
          stop = line + length(String.split(text, "\n")) - 1
          {{line, stop, Map.get(targets, path)}, stop + 2}
        end)

      forms =
        case ast do
          {:__block__, _, forms} -> Enum.drop(forms, -1)
          :__source_export_end__ -> []
        end

      results =
        Enum.map(forms, fn form ->
          line =
            case form do
              {_, meta, _} when is_list(meta) -> Keyword.get(meta, :line, 0)
              _ -> 0
            end

          case Enum.find(ranges, fn {first, last, _} -> line >= first and line <= last end) do
            {_, _, {owner, selector}} ->
              qualified = qualify_method(form, owner, selector)

              if qualified == form do
                AL.Source.Parser.capture(form, source)
              else
                AL.Source.Parser.capture_method(form, source, owner)
              end

            _ ->
              AL.Source.Parser.capture(form, source)
          end
        end)

      with {:ok, result} <- combine_captures(results) do
        replacements =
          entries
          |> Enum.map(fn {path, _} -> Map.get(targets, path) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        prefix =
          Enum.map(replacements, fn {owner, selector} ->
            method = AL.Var.var("source_export_replace_#{System.unique_integer([:positive])}")

            %AL.Goal.Forall{
              condition: [%AL.Goal.GetMethod{object: owner, name: selector, id: method}],
              body: [
                %AL.Goal.RetractOapply{
                  object: method,
                  head: AL.Var.var("source_export_head_#{System.unique_integer([:positive])}")
                }
              ]
            }
          end)

        captures =
          Enum.map(result.captures, fn capture ->
            [index | rest] = capture.path
            %{capture | path: [index + length(prefix) | rest]}
          end)

        {:ok, %{result | program: prefix ++ result.program, captures: captures}}
      end
    else
      {:aborted, reason} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
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

  defp qualify_method({:defmethod, meta, [selector, head]}, owner, selector)
       when is_list(head),
       do: {:defmethod, meta, [owner, selector, head]}

  defp qualify_method({:defmethod, meta, [selector, head, body]}, owner, selector)
       when is_list(head) and is_list(body),
       do: {:defmethod, meta, [owner, selector, head, body]}

  defp qualify_method({:defmethod, _, [owner, selector, head | _]} = form, owner, selector)
       when is_list(head),
       do: form

  defp qualify_method(_form, owner, selector),
    do: raise(ArgumentError, "method file must define #{inspect(owner)}.#{selector}")

  # Method files always show the fully-qualified `defmethod(class, name,
  # head)` form, even for a clause originally authored via class-body
  # shorthand -- one format regardless of how it was written, so a file
  # freshly created by hand needs no different treatment than an edited one.
  # Parsing is only to classify shorthand vs. already-qualified -- the
  # written-out text is never a reserialized AST (that drops comments), it's
  # either the original text untouched or the original text with the owner
  # spliced into the argument list.
  defp qualify_method_text(text, class, method) do
    {:ok, ast} = Code.string_to_quoted(text, columns: true, token_metadata: true)

    case qualify_method(ast, class, method) do
      ^ast -> text
      _qualified -> splice_owner(text, class)
    end
  end

  defp splice_owner(text, class) do
    case Regex.run(~r/\Adefmethod\(/, text) do
      [prefix] -> String.replace_prefix(text, prefix, "defmethod(#{inspect(class)}, ")
      nil -> raise ArgumentError, "expected a defmethod(...) call, got: #{inspect(text)}"
    end
  end

  defp redefine_classes(result) do
    program =
      Enum.reduce(result.captures, result.program, fn
        %{kind: :defclass, path: [index]}, program ->
          List.update_at(program, index, fn %AL.Goal.OApply{method_id: :defclass, args: args} =
                                              goal ->
            %{goal | args: List.replace_at(args, 6, true)}
          end)

        _capture, program ->
          program
      end)

    %{result | program: program}
  end

  defp definition_rows(branch) do
    method_bindings =
      AL.Object.scan_open_method_versions(
        AL.Var.var("source_export_method_class"),
        AL.Var.var("source_export_method_name"),
        AL.Var.var("source_export_method_id"),
        branch
      )

    # A class file is metadata (super, ivars), always regenerated from live
    # facts -- never treated as retained text. There's no meaningful
    # "verbatim class statement" to preserve once facts can enter from
    # `vm_set_super`/`vm_set_class` outside `defclass` too (Tonel and
    # classic Smalltalk fileout draw the same line: class header
    # regenerated, method body retained). This also means any object
    # classified via raw `vm_set_class` gets a file, not just ones defined
    # through `defclass`.
    class_metaclasses = class_metaclass_closure(branch)

    class_rows =
      AL.Object.scan_class(
        AL.Var.var("source_export_class_self"),
        AL.Var.var("source_export_class_meta"),
        branch
      )
      |> Enum.filter(fn {:class, _o, _seq, meta} -> MapSet.member?(class_metaclasses, meta) end)
      |> Enum.map(fn {:class, o, _seq, meta} -> {o, meta} end)
      |> Enum.uniq()
      |> Enum.map(fn {class, meta} -> {:class, class, class_source(class, meta, branch)} end)

    # Per clause, `AL.Source` returns the retained span when one exists and
    # slices cleanly, decompiled straight from the live head/body otherwise
    # (the same fallback the GT bridge's method-coder view already relies
    # on) -- so a clause changed by any path other than `defmethod` still
    # gets a file, not silent absence.
    method_rows =
      Enum.map(method_bindings, fn {:method, class, name, _seq, _method_t, :open, method_id} ->
        text =
          method_id
          |> AL.Source.method_object_source_rows(branch)
          |> Enum.sort_by(fn {:method_source, _id, clause_seq, _text, _provenance} ->
            clause_seq
          end)
          |> Enum.map_join("\n\n", fn {:method_source, _id, _clause_seq, source, provenance} ->
            render_method_clause(provenance, source, class, name)
          end)

        {:method, {class, name}, text}
      end)

    class_rows ++ method_rows
  end

  defp render_method_clause(:retained, text, class, method),
    do: qualify_method_text(text, class, method)

  defp render_method_clause(:decompiled, text, _class, _method),
    do: "# decompiled -- no retained source for this clause\n" <> text

  # All class-like metaclasses: `:class` itself plus every descendant
  # reachable by following `super` -- so a custom metaclass (or `:behaviour`
  # itself, which is a `:class` instance even though *its own* instances
  # like `:map_get` are method-implementation holders, not classes) is
  # included, while a plain `:behaviour`-classed atom is not.
  defp class_metaclass_closure(branch) do
    children_by_parent =
      AL.Object.scan_super(
        AL.Var.var("source_export_meta_child"),
        AL.Var.var("source_export_meta_parent"),
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

  defp class_source(class, meta, branch) do
    supers =
      AL.Object.scan_super(class, AL.Var.var("source_export_class_super"), branch)
      |> Enum.map(fn {:super, ^class, _seq, s} -> s end)

    ivars = class_ivars(class, branch)

    opts =
      if meta == :class,
        do: [super: supers, ivars: ivars],
        else: [metaclass: meta, super: supers, ivars: ivars]

    {:defclass, [], [class, Macro.escape(opts), [do: {:__block__, [], []}]]}
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
  end

  defp class_ivars(class, branch) do
    case AL.Object.read_slots(class, branch) do
      [{:slots, ^class, %{ivars: ivars}}] -> ivars
      _ -> []
    end
  end

  defp write_derived(root, branch, :class, class, text),
    do: write_file(class_path(root, branch, class), text)

  defp write_derived(root, branch, :method, {class, method}, text),
    do: write_file(method_path(root, branch, class, method), text)

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
