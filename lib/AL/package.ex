defmodule AL.Package do
  @moduledoc "Discovers, resolves, realises, and activates definition packages."

  alias AL.Package.BuildSpec
  alias AL.Package.Candidate
  alias AL.Package.Catalog
  alias AL.Package.Channel
  alias AL.Package.Document
  alias AL.Package.Plan
  alias AL.Package.Realisation
  alias AL.Serialisation.Document, as: DefinitionDocument
  alias AL.Serialisation.Snapshot
  alias AL.Serialisation.Sync

  @type import_result() :: %{
          package: atom(),
          build: term(),
          definitions: [term()]
        }

  @doc "Configured package channel specifications."
  @spec configured_channels() :: [{atom(), term()}]
  def configured_channels, do: Application.get_env(:al, :package_channels, [])

  @doc "Configured root package names."
  @spec configured_environment() :: [atom()]
  def configured_environment, do: Application.get_env(:al, :package_environment, [])

  @doc "Read and validate a package bundle's manifest."
  @spec manifest(Path.t()) :: {:ok, Document.t()} | {:error, term()}
  def manifest(directory) do
    path = Path.join(directory, "package.al")

    with {:ok, text} <- read(path), do: Document.parse(text)
  end

  @doc "Discover an immutable catalog from channel specifications."
  @spec discover([{atom(), term()}]) :: {:ok, Catalog.t()} | {:error, term()}
  def discover(specs \\ configured_channels()) when is_list(specs) do
    with :ok <- validate_channel_specs(specs),
         {:ok, discovered} <- discover_channels(specs) do
      channels = Enum.map(discovered, &elem(&1, 0))
      candidates = Enum.flat_map(discovered, &elem(&1, 1))
      {:ok, %Catalog{channels: channels, candidates: candidates}}
    end
  end

  @doc "List candidates currently available through configured channels."
  @spec available([{atom(), term()}]) :: {:ok, [map()]} | {:error, term()}
  def available(specs \\ configured_channels()) do
    with {:ok, catalog} <- discover(specs) do
      {:ok,
       Enum.map(catalog.candidates, fn candidate ->
         %{
           package: candidate.document.name,
           version: candidate.document.version,
           requirements: candidate.document.deps,
           channel: candidate.channel.name,
           source_digest: candidate.source_digest,
           directory: candidate.directory
         }
       end)}
    end
  end

  @doc "Resolve requested packages into a deterministic exact build plan."
  @spec resolve(Catalog.t(), [atom()]) :: {:ok, Plan.t()} | {:error, term()}
  def resolve(%Catalog{} = catalog, requested \\ configured_environment()) do
    requested = Enum.uniq(requested)

    with :ok <- validate_requested(requested),
         {:ok, candidates} <- select_candidates(catalog, requested),
         {:ok, builds} <- build_specs(candidates) do
      {:ok, %Plan{requested: requested, catalog: catalog, builds: builds}}
    end
  end

  @doc "Create or reuse all exact builds in a resolved plan without activating them."
  @spec realise(Plan.t(), keyword()) :: {:ok, Realisation.t()} | {:error, term()}
  def realise(%Plan{} = plan, opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    case :mnesia.transaction(fn -> realise_transaction(plan, branch) end) do
      {:atomic, {:ok, realisation}} -> {:ok, realisation}
      {:atomic, {:error, reason}} -> {:error, reason}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc "Activate a realisation. With replace: true it becomes the exact active package set."
  @spec activate(Realisation.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def activate(%Realisation{} = realisation, opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())
    replace? = Keyword.get(opts, :replace, false)

    case :mnesia.transaction(fn -> activate_transaction(realisation, branch, replace?) end) do
      {:atomic, {:ok, result}} -> {:ok, result}
      {:atomic, {:error, reason}} -> {:error, reason}
      {:aborted, reason} -> {:error, reason}
    end
  end

  @doc "Keep the retained active graph on restart, resolving only when configuration changed."
  @spec ensure_configured(keyword()) :: :ok | {:error, term()}
  def ensure_configured(opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())
    requested = configured_environment()

    if current_environment?(requested, branch) and
         configured_channels_registered?(configured_channels(), branch) do
      :ok
    else
      update_configured(opts)
    end
  end

  @doc "Rediscover configured channels, resolve, realise, and activate their package set."
  @spec update_configured(keyword()) :: :ok | {:error, term()}
  def update_configured(opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with {:ok, catalog} <- discover(),
         {:ok, plan} <- resolve(catalog),
         {:ok, realisation} <- realise(plan, branch: branch),
         {:ok, _activation} <- activate(realisation, branch: branch, replace: true) do
      :ok
    end
  end

  @doc "Whether a package class exists on a branch."
  @spec installed?(atom(), AL.Branch.t()) :: boolean()
  def installed?(name, branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn -> package_class?(name, branch) end) do
      {:atomic, installed?} -> installed?
      _ -> false
    end
  end

  @doc "Whether the package metamodel is available on a branch."
  @spec system_available?(AL.Branch.t()) :: boolean()
  def system_available?(branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn -> package_system_available?(branch) end) do
      {:atomic, available?} -> available?
      _ -> false
    end
  end

  @doc "Whether a package currently supplies active definitions on a branch."
  @spec active?(atom(), AL.Branch.t()) :: boolean()
  def active?(name, branch \\ AL.Branch.head()), do: not is_nil(active_build(name, branch))

  @doc "The active build of a package, if any."
  @spec active_build(atom(), AL.Branch.t()) :: atom() | nil
  def active_build(name, branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn -> active_build_in_transaction(name, branch) end) do
      {:atomic, build} -> build
      _ -> nil
    end
  end

  @doc "All realised builds of a package on a branch."
  @spec builds(atom(), AL.Branch.t()) :: [%{id: atom(), slots: map()}]
  def builds(name, branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn -> builds_in_transaction(name, branch) end) do
      {:atomic, builds} -> builds
      _ -> []
    end
  end

  @doc "Import and activate one bundle directly."
  @spec import(Path.t(), keyword()) :: {:ok, import_result()} | {:error, term()}
  def import(directory, opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with {:ok, candidate} <- direct_candidate(directory),
         channel = candidate.channel,
         catalog = %Catalog{channels: [channel], candidates: [candidate]},
         {:ok, plan} <- resolve(catalog, [candidate.document.name]),
         {:ok, realisation} <- realise(plan, branch: branch),
         {:ok, _activation} <- activate(realisation, branch: branch) do
      build = Map.fetch!(realisation.builds, candidate.document.name)

      {:ok,
       %{
         package: candidate.document.name,
         build: build,
         definitions: Enum.map(candidate.definitions, & &1.document.owner)
       }}
    end
  end

  @doc "Import a bundle unless its package is already active."
  @spec ensure_imported(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_imported(directory, opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with {:ok, document} <- manifest(directory) do
      if active?(document.name, branch) do
        :ok
      else
        case __MODULE__.import(directory, Keyword.put(opts, :branch, branch)) do
          {:ok, _result} -> :ok
          {:error, _reason} = error -> error
        end
      end
    end
  end

  @doc "Whether a direct bundle's name-only package requirements are active."
  @spec ready?(Path.t(), AL.Branch.t()) :: boolean()
  def ready?(directory, branch \\ AL.Branch.head()) do
    case manifest(directory) do
      {:ok, document} ->
        system_available?(branch) and
          Enum.all?(document.deps, fn
            name when is_atom(name) -> active?(name, branch)
            _requirement -> false
          end)

      {:error, _reason} ->
        false
    end
  end

  defp discover_channels(specs) do
    specs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{name, location}, priority}, {:ok, channels} ->
      root = resolve_location(location)

      case discover_channel(name, location, root, priority) do
        {:ok, channel} -> {:cont, {:ok, [channel | channels]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, channels} -> {:ok, Enum.reverse(channels)}
      error -> error
    end
  end

  defp discover_channel(name, location, root, priority) do
    with true <- File.dir?(root) || {:error, {:package_channel_not_found, name, root}},
         {:ok, entries} <- File.ls(root),
         directories <-
           entries
           |> Enum.sort()
           |> Enum.map(&Path.join(root, &1))
           |> Enum.filter(&(File.dir?(&1) and File.regular?(Path.join(&1, "package.al")))),
         {:ok, raw_candidates} <- read_candidates(directories),
         :ok <- validate_channel_candidates(name, raw_candidates) do
      revision =
        digest(
          {:package_channel, 1, Enum.map(raw_candidates, &{&1.document.name, &1.source_digest})}
        )

      channel = %Channel{
        name: name,
        location: location,
        root: root,
        revision: revision,
        priority: priority
      }

      candidates = Enum.map(raw_candidates, &%{&1 | channel: channel})
      {:ok, {channel, candidates}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:package_channel_read, name, root, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp read_candidates(directories) do
    Enum.reduce_while(directories, {:ok, []}, fn directory, {:ok, candidates} ->
      case read_candidate(directory, nil) do
        {:ok, candidate} -> {:cont, {:ok, [candidate | candidates]}}
        {:error, reason} -> {:halt, {:error, {:invalid_package_candidate, directory, reason}}}
      end
    end)
    |> case do
      {:ok, candidates} -> {:ok, Enum.reverse(candidates)}
      error -> error
    end
  end

  defp direct_candidate(directory) do
    directory = Path.expand(directory)

    with {:ok, candidate} <- read_candidate(directory, nil) do
      channel = %Channel{
        name: {:direct, directory},
        location: directory,
        root: directory,
        revision: candidate.source_digest,
        priority: 0
      }

      {:ok, %{candidate | channel: channel}}
    end
  end

  defp read_candidate(directory, channel) do
    manifest_path = Path.join(directory, "package.al")

    with {:ok, manifest_text} <- read(manifest_path),
         {:ok, document} <- Document.parse(manifest_text),
         {:ok, definitions} <- read_definitions(directory) do
      source_digest =
        digest({:package_source, 1, manifest_text, Enum.map(definitions, &{&1.path, &1.text})})

      {:ok,
       %Candidate{
         channel: channel,
         directory: directory,
         manifest_path: manifest_path,
         manifest_text: manifest_text,
         document: document,
         definitions: definitions,
         source_digest: source_digest
       }}
    end
  end

  defp read_definitions(directory) do
    directory
    |> Path.join("definitions/**/*.al")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, definitions} ->
      with {:ok, text} <- read(path),
           {:ok, document} <- DefinitionDocument.parse(text) do
        definition = %{path: Path.relative_to(path, directory), text: text, document: document}
        {:cont, {:ok, [definition | definitions]}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_definition, path, reason}}}
      end
    end)
    |> case do
      {:ok, definitions} -> {:ok, Enum.reverse(definitions)}
      error -> error
    end
  end

  defp validate_channel_specs(specs) do
    cond do
      not Enum.all?(specs, &valid_channel_spec?/1) ->
        {:error, :invalid_package_channel_configuration}

      duplicated?(Enum.map(specs, &elem(&1, 0))) ->
        {:error, :duplicate_package_channel_name}

      true ->
        :ok
    end
  end

  defp valid_channel_spec?({name, {:priv, path}}) when is_atom(name) and is_binary(path), do: true
  defp valid_channel_spec?({name, path}) when is_atom(name) and is_binary(path), do: true
  defp valid_channel_spec?(_spec), do: false

  defp validate_channel_candidates(channel, candidates) do
    candidates
    |> Enum.group_by(& &1.document.name)
    |> Enum.find(fn {_name, matches} -> length(matches) > 1 end)
    |> case do
      nil ->
        :ok

      {name, matches} ->
        {:error, {:duplicate_channel_package, channel, name, Enum.map(matches, & &1.directory)}}
    end
  end

  defp validate_requested(requested) do
    if Enum.all?(requested, &is_atom/1),
      do: :ok,
      else: {:error, :invalid_package_environment}
  end

  defp select_candidates(catalog, requested) do
    available = Enum.group_by(catalog.candidates, & &1.document.name)

    Enum.reduce_while(requested, {:ok, %{}, []}, fn name, {:ok, selected, order} ->
      case select_candidate(name, available, selected, order, []) do
        {:ok, selected, order} -> {:cont, {:ok, selected, order}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, _selected, order} -> {:ok, order}
      error -> error
    end
  end

  defp select_candidate(name, available, selected, order, stack) do
    cond do
      Map.has_key?(selected, name) ->
        {:ok, selected, order}

      name in stack ->
        {:error, {:package_dependency_cycle, Enum.reverse([name | stack])}}

      true ->
        case Map.get(available, name, []) do
          [] ->
            {:error, {:package_not_found, name}}

          [candidate | _lower_priority] ->
            with {:ok, dependency_names} <- dependency_names(candidate),
                 {:ok, selected, order} <-
                   select_dependencies(
                     dependency_names,
                     available,
                     selected,
                     order,
                     [name | stack]
                   ) do
              {:ok, Map.put(selected, name, candidate), order ++ [candidate]}
            end
        end
    end
  end

  defp select_dependencies(names, available, selected, order, stack) do
    Enum.reduce_while(names, {:ok, selected, order}, fn name, {:ok, selected, order} ->
      case select_candidate(name, available, selected, order, stack) do
        {:ok, selected, order} -> {:cont, {:ok, selected, order}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp dependency_names(candidate) do
    Enum.reduce_while(candidate.document.deps, {:ok, []}, fn
      name, {:ok, names} when is_atom(name) ->
        {:cont, {:ok, names ++ [name]}}

      {name, requirement}, _acc ->
        {:halt,
         {:error, {:unsupported_package_requirement, candidate.document.name, name, requirement}}}
    end)
  end

  defp build_specs(candidates) do
    {by_name, builds} =
      Enum.reduce(candidates, {%{}, []}, fn candidate, {by_name, builds} ->
        dependencies =
          Enum.map(candidate.document.deps, fn name -> {name, Map.fetch!(by_name, name)} end)

        dependency_inputs = Enum.map(dependencies, fn {name, build} -> {name, build.digest} end)
        digest = digest({:package_build, 1, candidate.source_digest, dependency_inputs})
        build = %BuildSpec{candidate: candidate, dependencies: dependencies, digest: digest}

        {Map.put(by_name, candidate.document.name, build), builds ++ [build]}
      end)

    if map_size(by_name) == length(builds), do: {:ok, builds}, else: {:error, :invalid_build_plan}
  end

  defp realise_transaction(plan, branch) do
    with :ok <- package_system_available(branch),
         :ok <- validate_catalog_names(plan.catalog, branch),
         {:ok, channels} <- realise_channels(plan.catalog.channels, branch),
         :ok <- realise_package_classes(plan, branch),
         {:ok, builds, created} <- realise_builds(plan, channels, branch) do
      {:ok, %Realisation{plan: plan, builds: builds, created: created}}
    end
  end

  defp validate_catalog_names(catalog, branch) do
    catalog.candidates
    |> Enum.map(& &1.document.name)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case package_name_available(name, branch) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp realise_channels(channels, branch) do
    Enum.reduce_while(channels, {:ok, %{}}, fn channel, {:ok, realised} ->
      case realise_channel(channel, branch) do
        {:ok, id} -> {:cont, {:ok, Map.put(realised, channel.name, id)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp realise_channel(channel, branch) do
    slots = %{
      channel_name: channel.name,
      location: channel.location,
      revision: channel.revision
    }

    case channel_instances(channel.name, branch) do
      [] ->
        chunks = [{"new(:channel, #{literal(slots)}, channel_instance)", nil}]

        with {:ok, {bindings, _state}} <-
               evaluate_chunks_result(chunks, channel_origin(channel), branch) do
          {:ok, Map.fetch!(bindings, :"$channel_instance")}
        end

      [%{id: id, slots: ^slots}] ->
        {:ok, id}

      [%{id: id}] ->
        with :ok <-
               evaluate_chunks(
                 [{"set_slots(#{literal(id)}, #{literal(slots)})", nil}],
                 channel_origin(channel),
                 branch
               ) do
          {:ok, id}
        end

      matches ->
        {:error, {:duplicate_channel_instances, channel.name, Enum.map(matches, & &1.id)}}
    end
  end

  defp channel_instances(name, branch) do
    AL.Object.scan_class(AL.Var.var("channel_instance"), :channel, branch)
    |> Enum.flat_map(fn {:class, id, _seq, :channel} ->
      case AL.Object.read_slots(id, branch) do
        [{:slots, ^id, %{channel_name: ^name} = slots}] -> [%{id: id, slots: slots}]
        _ -> []
      end
    end)
  end

  defp realise_package_classes(plan, branch) do
    chunks =
      plan.catalog.candidates
      |> Enum.map(& &1.document.name)
      |> Enum.uniq()
      |> Enum.flat_map(&package_class_chunks(&1, branch))

    evaluate_chunks(chunks, package_registration_origin(plan), branch)
  end

  defp package_class_chunks(name, branch) do
    case classes_of(name, branch) do
      [] ->
        [{package_class_source(name), nil}]

      [:program_execution] ->
        [
          {"retract_existing_facts(#{literal(name)})", nil},
          {package_class_source(name), nil}
        ]

      [:package] ->
        case AL.Object.read_slots(name, branch) do
          [{:slots, ^name, slots}] when is_map_key(slots, :deps) ->
            [{"vm_retract_slot(#{literal(name)}, :deps)", nil}]

          _ ->
            []
        end
    end
  end

  defp realise_builds(plan, channels, branch) do
    Enum.reduce_while(plan.builds, {:ok, %{}, []}, fn build, {:ok, realised, created} ->
      dependencies =
        Enum.map(build.dependencies, fn {name, _dependency} ->
          {name, Map.fetch!(realised, name)}
        end)

      channel = Map.fetch!(channels, build.candidate.channel.name)
      args = build_args(build, dependencies, channel)

      case reusable_build(build.candidate.document.name, build.digest, branch) do
        {:ok, id} ->
          {:cont, {:ok, Map.put(realised, build.candidate.document.name, id), created}}

        :none ->
          case create_build(build, args, branch) do
            {:ok, id} ->
              {:cont,
               {:ok, Map.put(realised, build.candidate.document.name, id), created ++ [id]}}

            {:error, _reason} = error ->
              {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp package_class_source(name) do
    "new(:package, %{name: #{literal(name)}, super: :package_build, ivars: []}, _)"
  end

  defp reusable_build(package, digest, branch) do
    matches =
      builds_in_transaction(package, branch)
      |> Enum.filter(&match?(%{digest: ^digest}, &1.slots))

    case matches do
      [] ->
        :none

      [%{id: id}] ->
        {:ok, id}

      duplicates ->
        {:error, {:duplicate_equivalent_package_builds, package, Enum.map(duplicates, & &1.id)}}
    end
  end

  defp create_build(build, args, branch) do
    candidate = build.candidate

    chunks = [
      {"build(#{literal(candidate.document.name)}, #{literal(args)}, package_build)", nil}
    ]

    with {:ok, {bindings, _state}} <-
           evaluate_chunks_result(chunks, build_origin(build, args), branch) do
      {:ok, Map.fetch!(bindings, :"$package_build")}
    end
  end

  defp build_args(build, dependencies, channel) do
    candidate = build.candidate

    source = %{
      format: 1,
      manifest: candidate.manifest_text,
      definitions: Enum.map(candidate.definitions, &Map.take(&1, [:path, :text]))
    }

    %{
      package: candidate.document.name,
      version: candidate.document.version,
      dependency_builds: dependencies,
      digest: build.digest,
      channel: channel,
      channel_revision: candidate.channel.revision,
      source: source,
      status: :complete
    }
  end

  defp activate_transaction(realisation, branch, replace?) do
    selected = realisation.builds
    current = active_builds_in_transaction(branch)
    final = if replace?, do: selected, else: Map.merge(current, selected)

    with :ok <- validate_build_closure(final, branch),
         {:ok, old_documents} <- documents_for_builds(current, branch),
         {:ok, new_documents} <- documents_for_builds(final, branch),
         snapshot <- Snapshot.capture_in_transaction(branch),
         deleted <-
           old_documents
           |> Map.keys()
           |> Kernel.--(Map.keys(new_documents))
           |> Enum.sort_by(&:erlang.term_to_binary/1),
         definitions <-
           new_documents
           |> Map.values()
           |> Enum.sort_by(&:erlang.term_to_binary(&1.owner)),
         {:ok, definition_chunks} <- Sync.plan(snapshot, definitions, deleted),
         pointer_chunks <- active_pointer_chunks(current, final),
         :ok <-
           evaluate_chunks(
             definition_chunks ++ pointer_chunks,
             activation_origin(realisation, final),
             branch
           ) do
      {:ok, %{active: final}}
    end
  end

  defp validate_build_closure(builds, branch) do
    Enum.reduce_while(builds, :ok, fn {package, build}, :ok ->
      case build_slots(build, branch) do
        {:ok, %{package: ^package, dependency_builds: dependencies}} ->
          case Enum.find(dependencies, fn {name, dependency_build} ->
                 Map.get(builds, name) != dependency_build
               end) do
            nil ->
              {:cont, :ok}

            dependency ->
              {:halt, {:error, {:unsatisfied_realised_dependency, build, dependency}}}
          end

        {:ok, _slots} ->
          {:halt, {:error, {:build_package_mismatch, package, build}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp documents_for_builds(builds, branch) do
    builds
    |> Enum.sort_by(fn {name, _build} -> name end)
    |> Enum.reduce_while({:ok, %{}}, fn {_name, build}, {:ok, documents} ->
      with {:ok, slots} <- build_slots(build, branch),
           {:ok, build_documents} <- parse_build_documents(build, slots) do
        duplicate = Enum.find(build_documents, &Map.has_key?(documents, &1.owner))

        if duplicate do
          {:halt, {:error, {:duplicate_package_definition_owner, duplicate.owner}}}
        else
          {:cont, {:ok, Map.merge(documents, Map.new(build_documents, &{&1.owner, &1}))}}
        end
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_build_documents(build, %{source: %{format: 1, definitions: definitions}})
       when is_list(definitions) do
    Enum.reduce_while(definitions, {:ok, []}, fn
      %{path: path, text: text}, {:ok, documents} ->
        case DefinitionDocument.parse(text) do
          {:ok, document} ->
            {:cont, {:ok, [document | documents]}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_retained_package_definition, build, path, reason}}}
        end

      _definition, _acc ->
        {:halt, {:error, {:invalid_retained_package_source, build}}}
    end)
    |> case do
      {:ok, documents} -> {:ok, Enum.reverse(documents)}
      error -> error
    end
  end

  defp parse_build_documents(build, _slots),
    do: {:error, {:package_build_source_unavailable, build}}

  defp active_pointer_chunks(current, final) do
    removed =
      current
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(final, &1))
      |> Enum.sort_by(&:erlang.term_to_binary/1)
      |> Enum.map(&{"vm_retract_slot(#{literal(&1)}, :active_build)", nil})

    changed =
      final
      |> Enum.reject(fn {package, build} -> Map.get(current, package) == build end)
      |> Enum.sort_by(fn {package, _build} -> :erlang.term_to_binary(package) end)
      |> Enum.map(fn {package, build} ->
        {"vm_set_slot(#{literal(package)}, :active_build, #{literal(build)})", nil}
      end)

    removed ++ changed
  end

  defp current_environment?(requested, branch) do
    case :mnesia.transaction(fn -> current_environment_in_transaction?(requested, branch) end) do
      {:atomic, current?} -> current?
      _ -> false
    end
  end

  defp configured_channels_registered?(specs, branch) do
    case :mnesia.transaction(fn ->
           configured_channels_registered_in_transaction?(specs, branch)
         end) do
      {:atomic, registered?} -> registered?
      _ -> false
    end
  end

  defp configured_channels_registered_in_transaction?(specs, branch) do
    Enum.all?(specs, fn {name, location} ->
      case channel_instances(name, branch) do
        [%{slots: %{location: ^location}}] -> true
        _ -> false
      end
    end)
  end

  defp current_environment_in_transaction?(requested, branch) do
    current = active_builds_in_transaction(branch)

    with true <- Enum.all?(requested, &Map.has_key?(current, &1)),
         {:ok, closure} <- active_closure(requested, current, branch, %{}) do
      closure == current
    else
      _ -> false
    end
  end

  defp active_closure([], _current, _branch, closure), do: {:ok, closure}

  defp active_closure([name | rest], current, branch, closure) do
    if Map.has_key?(closure, name) do
      active_closure(rest, current, branch, closure)
    else
      with {:ok, build} <- Map.fetch(current, name),
           {:ok, %{dependency_builds: dependencies}} <- build_slots(build, branch),
           true <-
             Enum.all?(dependencies, fn {dependency, id} -> Map.get(current, dependency) == id end) do
        dependency_names = Enum.map(dependencies, &elem(&1, 0))
        active_closure(rest ++ dependency_names, current, branch, Map.put(closure, name, build))
      else
        _ -> {:error, :invalid_active_package_closure}
      end
    end
  end

  defp active_builds_in_transaction(branch) do
    AL.Object.scan_class(AL.Var.var("active_package"), :package, branch)
    |> Enum.reduce(%{}, fn {:class, package, _seq, :package}, active ->
      case active_build_in_transaction(package, branch) do
        nil -> active
        build -> Map.put(active, package, build)
      end
    end)
  end

  defp active_build_in_transaction(name, branch) do
    case AL.Object.read_slots(name, branch) do
      [{:slots, ^name, %{active_build: build}}] -> build
      _ -> nil
    end
  end

  defp builds_in_transaction(name, branch) do
    AL.Object.scan_class(AL.Var.var("package_build"), name, branch)
    |> Enum.flat_map(fn {:class, id, _seq, ^name} ->
      case AL.Object.read_slots(id, branch) do
        [{:slots, ^id, slots}] -> [%{id: id, slots: slots}]
        _ -> []
      end
    end)
  end

  defp build_slots(build, branch) do
    case AL.Object.read_slots(build, branch) do
      [{:slots, ^build, slots}] -> {:ok, slots}
      _ -> {:error, {:package_build_not_found, build}}
    end
  end

  defp package_system_available(branch) do
    if package_system_available?(branch),
      do: :ok,
      else: {:error, :package_system_not_installed}
  end

  defp package_system_available?(branch),
    do: AL.Object.scan_class(:package, :class, branch) != []

  defp package_class?(name, branch), do: classes_of(name, branch) == [:package]

  defp package_name_available(name, branch) do
    case classes_of(name, branch) do
      [] -> :ok
      [:package] -> :ok
      [:program_execution] -> :ok
      classes -> {:error, {:package_name_in_use, name, classes}}
    end
  end

  defp classes_of(object, branch) do
    AL.Object.scan_class(object, AL.Var.var("package_existing_class"), branch)
    |> Enum.map(fn {:class, ^object, _seq, class} -> class end)
    |> Enum.uniq()
  end

  defp evaluate_chunks([], _origin, _branch), do: :ok

  defp evaluate_chunks(chunks, origin, branch) do
    with {:ok, _result} <- evaluate_chunks_result(chunks, origin, branch), do: :ok
  end

  defp evaluate_chunks_result(chunks, origin, branch) do
    with {:ok, parsed, source} <- AL.Serialisation.compile_chunks(chunks) do
      case AL.eval_captured(parsed, source, origin, nil, branch, []) do
        {:atomic, result} -> {:ok, result}
        {:aborted, reason} -> {:error, {:package_operation_failed, reason}}
        {:error, reason} -> {:error, {:invalid_generated_package_operation, reason}}
      end
    end
  end

  defp channel_origin(channel) do
    %{
      kind: :package_channel,
      channel: channel.name,
      location: channel.location,
      revision: channel.revision
    }
  end

  defp package_registration_origin(plan) do
    %{
      kind: :package_registration,
      requested: plan.requested,
      packages: plan.catalog.candidates |> Enum.map(& &1.document.name) |> Enum.uniq()
    }
  end

  defp build_origin(build, args) do
    %{
      kind: :package_realisation,
      package: build.candidate.document.name,
      digest: build.digest,
      source_digest: build.candidate.source_digest,
      channel: build.candidate.channel.name,
      channel_revision: build.candidate.channel.revision,
      dependency_builds: args.dependency_builds
    }
  end

  defp activation_origin(realisation, builds) do
    %{
      kind: :package_activation,
      requested: realisation.plan.requested,
      builds: builds
    }
  end

  defp resolve_location({:priv, path}),
    do: Application.app_dir(:al, Path.join("priv", path))

  defp resolve_location(path) when is_binary(path), do: Path.expand(path)

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:file_read, path, reason}}
    end
  end

  defp digest(term) do
    term
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp duplicated?(values), do: length(values) != length(Enum.uniq(values))

  defp literal(value),
    do: inspect(value, pretty: false, limit: :infinity, printable_limit: :infinity)

  @doc false
  def remove_legacy_package_classes(branch \\ AL.Branch.head()) do
    objects =
      [:users_package, :interval_package]
      |> Enum.flat_map(&legacy_package_objects(&1, branch))
      |> Enum.uniq()

    case objects do
      [] ->
        :ok

      _ ->
        source = Enum.map_join(objects, "\n", &"retract_existing_facts(#{literal(&1)})")

        case AL.eval_source(source, branch) do
          {:atomic, _} -> :ok
          {:aborted, reason} -> :mnesia.abort(reason)
          {:error, reason} -> :mnesia.abort(reason)
        end
    end
  end

  defp legacy_package_objects(package, branch) do
    builds =
      AL.Object.scan_class(AL.Var.var("legacy_package_build"), package, branch)
      |> Enum.map(fn {:class, build, _seq, ^package} -> build end)

    if AL.Object.scan_class(package, :package, branch) == [] do
      builds
    else
      builds ++ [package]
    end
  end
end
