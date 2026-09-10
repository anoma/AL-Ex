defmodule AL.Package do
  @moduledoc "Discovers, resolves, realises, and activates definition packages."

  require AL

  alias AL.Package.BuildSpec
  alias AL.Package.Catalog
  alias AL.Package.Channel
  alias AL.Package.Document
  alias AL.Package.Plan
  alias AL.Package.Provider
  alias AL.Package.Realisation
  alias AL.Package.SourceSnapshot
  alias AL.Serialisation.Document, as: DefinitionDocument
  alias AL.Serialisation.Layout
  alias AL.Serialisation.Snapshot
  alias AL.Serialisation.Sync

  @type import_result() :: %{
          package: atom(),
          provider: atom(),
          build: term(),
          definitions: [term()]
        }

  @type selected_export_result() :: %{
          package: atom(),
          directory: Path.t(),
          document: Document.t(),
          definitions: [term()]
        }

  @type active_export_result() :: %{
          package: atom(),
          directory: Path.t(),
          document: Document.t(),
          definitions: [term()],
          build: term(),
          provider: atom()
        }

  @type export_result() :: selected_export_result() | active_export_result()

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

  @doc "Export active package source or selected live definitions as a portable bundle."
  @spec export(atom(), keyword()) :: {:ok, export_result()} | {:error, term()}
  def export(name, opts) when is_atom(name) and is_list(opts) do
    if Keyword.has_key?(opts, :definitions) do
      export_selected_definitions(name, opts)
    else
      export_active_package(name, opts)
    end
  end

  def export(_name, _opts), do: {:error, :invalid_package_export}

  defp export_selected_definitions(name, opts) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())
    version = Keyword.get(opts, :version, 1)
    deps = Keyword.get(opts, :deps, [])

    with {:ok, directory} <- export_directory(opts),
         {:ok, owners} <- export_owners(opts),
         {:ok, document, manifest_text} <- export_document(name, version, deps),
         {:ok, snapshot} <- Snapshot.capture(branch),
         {:ok, definitions} <- export_definitions(snapshot, owners),
         :ok <- write_export_bundle(directory, manifest_text, definitions) do
      {:ok,
       %{
         package: name,
         directory: directory,
         document: document,
         definitions: owners
       }}
    end
  end

  defp export_active_package(name, opts) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with {:ok, directory} <- export_directory(opts),
         {:ok, state} <- package_source_state(name, branch),
         {:ok, snapshot} <- current_package_snapshot(name, state),
         {:ok, defaults} <- package_export_metadata(state),
         version = Keyword.get(opts, :version, defaults.version),
         deps = Keyword.get(opts, :deps, defaults.deps),
         {:ok, document, manifest_text} <- export_document(name, version, deps),
         definitions <- render_package_definitions(snapshot.documents),
         :ok <- write_export_bundle(directory, manifest_text, definitions),
         {:ok, publication} <-
           seal_exported_open_build(name, state, directory, document, branch) do
      {:ok,
       %{
         package: name,
         directory: directory,
         document: document,
         definitions: Enum.map(snapshot.documents, & &1.owner),
         build: state.build,
         provider: publication.provider
       }}
    end
  end

  @doc "Capture the current live definitions attributed to an active package build."
  @spec source_snapshot(atom(), keyword()) :: {:ok, SourceSnapshot.t()} | {:error, term()}
  def source_snapshot(name, opts \\ []) when is_atom(name) and is_list(opts) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with {:ok, state} <- package_source_state(name, branch),
         {:ok, snapshot} <- current_package_snapshot(name, state) do
      {:ok, snapshot}
    end
  end

  @doc "Compare an active package's current live definitions with its provider source."
  @spec diff(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def diff(name, opts \\ []) when is_atom(name) and is_list(opts) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with {:ok, state} <- package_source_state(name, branch),
         {:ok, current} <- current_package_snapshot(name, state),
         {:ok, reference} <- parse_provider_documents(state.provider, state.provider_slots) do
      classes =
        definition_changes(reference_classes(reference), reference_classes(current.documents))

      methods =
        definition_changes(
          reference_methods(reference),
          reference_methods(current.documents),
          &method_definition_key/1
        )

      superclasses =
        definition_changes(
          reference_superclasses(reference),
          reference_superclasses(current.documents),
          &superclass_definition_key/1
        )

      {:ok,
       %{
         package: name,
         build: state.build,
         provider: state.provider,
         changed?: changed?(classes) or changed?(methods) or changed?(superclasses),
         classes: classes,
         methods: methods,
         superclasses: superclasses
       }}
    end
  end

  @doc "Discover and durably register the providers exposed by channel specifications."
  @spec discover([{atom(), term()}], keyword()) :: {:ok, Catalog.t()} | {:error, term()}
  def discover(specs \\ configured_channels(), opts \\ []) when is_list(specs) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with :ok <- validate_channel_specs(specs),
         {:ok, discovered} <- discover_channels(specs),
         channels = Enum.map(discovered, &elem(&1, 0)),
         providers = Enum.flat_map(discovered, &elem(&1, 1)),
         {:ok, catalog} <-
           register_catalog(%Catalog{channels: channels, providers: providers}, branch) do
      {:ok, catalog}
    end
  end

  @doc "List providers currently available through configured channels."
  @spec available([{atom(), term()}], keyword()) :: {:ok, [map()]} | {:error, term()}
  def available(specs \\ configured_channels(), opts \\ []) do
    with {:ok, catalog} <- discover(specs, opts) do
      {:ok,
       Enum.map(catalog.providers, fn provider ->
         %{
           provider: provider.id,
           package: provider.document.name,
           version: provider.document.version,
           requirements: provider.document.deps,
           channel: provider.channel.name,
           source_digest: provider.source_digest,
           directory: provider.directory
         }
       end)}
    end
  end

  @doc "Resolve requested packages into a deterministic exact build plan."
  @spec resolve(Catalog.t(), [Document.dependency()], keyword()) ::
          {:ok, Plan.t()} | {:error, term()}
  def resolve(%Catalog{} = catalog, requested \\ configured_environment(), opts \\ []) do
    requested = Enum.uniq(requested)
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with :ok <- validate_requested(requested),
         :ok <- validate_registered_providers(catalog),
         {:ok, selections} <- resolve_providers(catalog, requested, branch),
         {:ok, builds} <- build_specs(selections) do
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

  @doc "Ensure configured roots are active without removing additional live packages."
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

    with {:ok, catalog} <- discover(configured_channels(), branch: branch),
         {:ok, plan} <- resolve(catalog, configured_environment(), branch: branch),
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

  @doc "All durable providers capable of producing a package on a branch."
  @spec providers(atom(), AL.Branch.t()) :: [%{id: atom(), slots: map()}]
  def providers(name, branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn -> providers_in_transaction(name, branch) end) do
      {:atomic, providers} -> providers
      _ -> []
    end
  end

  @doc "Import and activate one bundle directly."
  @spec import(Path.t(), keyword()) :: {:ok, import_result()} | {:error, term()}
  def import(directory, opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with {:ok, provider} <- direct_provider(directory),
         channel = provider.channel,
         {:ok, catalog} <-
           register_catalog(%Catalog{channels: [channel], providers: [provider]}, branch),
         [provider] = catalog.providers,
         {:ok, plan} <- resolve(catalog, [provider.document.name], branch: branch),
         {:ok, realisation} <- realise(plan, branch: branch),
         {:ok, _activation} <- activate(realisation, branch: branch) do
      build = Map.fetch!(realisation.builds, provider.document.name)

      {:ok,
       %{
         package: provider.document.name,
         provider: provider.id,
         build: build,
         definitions: Enum.map(provider.definitions, & &1.document.owner)
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
         {:ok, raw_providers} <- read_providers(directories),
         :ok <- validate_channel_providers(name, raw_providers) do
      revision =
        digest(
          {:package_channel, 1, Enum.map(raw_providers, &{&1.document.name, &1.source_digest})}
        )

      channel = %Channel{
        name: name,
        location: location,
        root: root,
        revision: revision,
        priority: priority
      }

      providers = Enum.map(raw_providers, &%{&1 | channel: channel})
      {:ok, {channel, providers}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, {:package_channel_read, name, root, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp read_providers(directories) do
    Enum.reduce_while(directories, {:ok, []}, fn directory, {:ok, providers} ->
      case read_provider(directory, nil) do
        {:ok, provider} -> {:cont, {:ok, [provider | providers]}}
        {:error, reason} -> {:halt, {:error, {:invalid_package_provider, directory, reason}}}
      end
    end)
    |> case do
      {:ok, providers} -> {:ok, Enum.reverse(providers)}
      error -> error
    end
  end

  defp direct_provider(directory) do
    directory = Path.expand(directory)

    with {:ok, provider} <- read_provider(directory, nil) do
      channel = %Channel{
        name: {:direct, directory},
        location: directory,
        root: directory,
        revision: provider.source_digest,
        priority: 0
      }

      {:ok, %{provider | channel: channel}}
    end
  end

  defp export_directory(opts) do
    case Keyword.fetch(opts, :to) do
      {:ok, directory} when is_binary(directory) -> {:ok, Path.expand(directory)}
      _ -> {:error, :package_export_directory_required}
    end
  end

  defp export_owners(opts) do
    case Keyword.fetch(opts, :definitions) do
      {:ok, owners} when is_list(owners) ->
        if duplicated?(owners),
          do: {:error, :duplicate_package_export_definition},
          else: {:ok, owners}

      _ ->
        {:error, :package_export_definitions_required}
    end
  end

  defp export_document(name, version, deps) do
    document = %Document{name: name, version: version, deps: deps}
    text = Document.render(document)

    case Document.parse(text) do
      {:ok, ^document} -> {:ok, document, text}
      {:error, _reason} = error -> error
    end
  end

  defp export_definitions(%Snapshot{documents: documents}, owners) do
    Enum.reduce_while(owners, {:ok, []}, fn owner, {:ok, definitions} ->
      case Map.fetch(documents, owner) do
        {:ok, document} ->
          path = Path.join("definitions", Layout.definition_filename(owner))
          definition = %{owner: owner, path: path, text: DefinitionDocument.render(document)}
          {:cont, {:ok, [definition | definitions]}}

        :error ->
          {:halt, {:error, {:package_export_definition_not_found, owner}}}
      end
    end)
    |> case do
      {:ok, definitions} -> {:ok, Enum.reverse(definitions)}
      error -> error
    end
  end

  defp render_package_definitions(documents) do
    Enum.map(documents, fn document ->
      path = Path.join("definitions", Layout.definition_filename(document.owner, document.kind))

      %{
        owner: document.owner,
        path: path,
        text: DefinitionDocument.render(document)
      }
    end)
  end

  defp provider_document(%{source: %{format: 1, manifest: manifest}})
       when is_binary(manifest),
       do: Document.parse(manifest)

  defp provider_document(_slots), do: {:error, :package_provider_source_unavailable}

  defp write_export_bundle(directory, manifest_text, definitions) do
    definition_directory = Path.join(directory, "definitions")

    with :ok <- File.mkdir_p(definition_directory),
         {:ok, _path} <- write_export_file(Path.join(directory, "package.al"), manifest_text),
         {:ok, paths} <- write_export_definitions(directory, definitions),
         :ok <- prune_export_definitions(definition_directory, paths) do
      :ok
    else
      {:error, {:file_write, _path, _reason} = reason} -> {:error, reason}
      {:error, reason} -> {:error, {:package_export_write, directory, reason}}
    end
  end

  defp write_export_definitions(directory, definitions) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, paths} ->
      path = Path.join(directory, definition.path)

      case write_export_file(path, definition.text) do
        {:ok, ^path} -> {:cont, {:ok, [path | paths]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      error -> error
    end
  end

  defp prune_export_definitions(directory, paths) do
    retained = MapSet.new(paths)

    directory
    |> Path.join("**/*.al")
    |> Path.wildcard()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      if MapSet.member?(retained, path) do
        {:cont, :ok}
      else
        case File.rm(path) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:file_remove, path, reason}}}
        end
      end
    end)
  end

  defp write_export_file(path, text) do
    temporary = "#{path}.tmp-#{System.unique_integer([:positive])}"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temporary, text),
           :ok <- File.rename(temporary, path) do
        {:ok, path}
      else
        {:error, reason} -> {:error, {:file_write, path, reason}}
      end
    after
      File.rm(temporary)
    end
  end

  defp package_source_state(name, branch) do
    case :mnesia.transaction(fn ->
           case active_build_in_transaction(name, branch) do
             nil ->
               {:error, {:package_not_active, name}}

             build ->
               with {:ok, build_slots} <- build_slots(build, branch),
                    %{
                      originated_classes: classes,
                      added_methods: methods,
                      added_superclasses: superclasses
                    } <- build_slots,
                    provider = Map.get(build_slots, :provider),
                    true <-
                      (is_nil(provider) or is_atom(provider)) and is_list(classes) and
                        is_list(methods) and
                        is_list(superclasses),
                    {:ok, provider_slots} <- optional_provider_slots(provider, branch),
                    {:ok, foreign} <- foreign_build_contributions(build, branch) do
                 {:ok,
                  %{
                    build: build,
                    provider: provider,
                    provider_slots: provider_slots,
                    build_slots: build_slots,
                    originated_classes: classes,
                    added_methods: methods,
                    added_superclasses: superclasses,
                    foreign_methods: foreign.methods,
                    foreign_superclasses: foreign.superclasses,
                    snapshot: Snapshot.capture_in_transaction(branch)
                  }}
               else
                 {:error, _reason} = error -> error
                 _ -> {:error, {:package_build_definitions_unavailable, build}}
               end
           end
         end) do
      {:atomic, result} -> result
      {:aborted, reason} -> {:error, {:mnesia, reason}}
    end
  end

  defp optional_provider_slots(nil, _branch), do: {:ok, nil}
  defp optional_provider_slots(provider, branch), do: package_provider_slots(provider, branch)

  defp package_export_metadata(%{provider_slots: nil, build_slots: build_slots}) do
    case build_slots do
      %{version: version, requirements: requirements}
      when is_integer(version) and version > 0 and is_list(requirements) ->
        {:ok, %{version: version, deps: requirements}}

      _ ->
        {:error, :open_package_build_metadata_unavailable}
    end
  end

  defp package_export_metadata(%{provider_slots: provider_slots}) do
    with {:ok, document} <- provider_document(provider_slots) do
      {:ok, %{version: document.version, deps: document.deps}}
    end
  end

  defp seal_exported_open_build(
         name,
         %{build: build, provider: nil, build_slots: %{status: :open} = build_slots},
         directory,
         document,
         branch
       ) do
    with {:ok, provider} <- direct_provider(directory),
         {:ok, catalog} <-
           register_catalog(
             %Catalog{channels: [provider.channel], providers: [provider]},
             branch
           ),
         [%Provider{id: provider_id} = provider] <- catalog.providers,
         {:ok, dependency_inputs} <-
           open_build_dependency_inputs(document.deps, build_slots.dependency_builds, branch),
         build_digest =
           digest({:package_build, 1, provider.source_digest, dependency_inputs}),
         slots = %{
           version: document.version,
           requirements: document.deps,
           digest: build_digest,
           provider: provider_id,
           status: :complete
         },
         :ok <-
           evaluate_chunks(
             [{"set_slots(#{literal(build)}, #{literal(slots)})", nil}],
             package_publication_origin(name, build, provider, build_digest),
             branch
           ) do
      {:ok, %{provider: provider_id, digest: build_digest}}
    else
      {:error, _reason} = error -> error
      _ -> {:error, {:package_publication_failed, name}}
    end
  end

  defp seal_exported_open_build(_name, state, _directory, _document, _branch),
    do: {:ok, %{provider: state.provider}}

  defp open_build_dependency_inputs(requirements, dependency_builds, branch) do
    required_names = Enum.map(requirements, &requirement_name/1)
    selected_names = Enum.map(dependency_builds, &elem(&1, 0))

    if required_names == selected_names do
      Enum.reduce_while(dependency_builds, {:ok, []}, fn {name, build}, {:ok, inputs} ->
        case build_slots(build, branch) do
          {:ok, %{digest: digest}} when is_binary(digest) ->
            {:cont, {:ok, inputs ++ [{name, digest}]}}

          _ ->
            {:halt, {:error, {:open_package_dependency_not_complete, name, build}}}
        end
      end)
    else
      {:error, {:open_package_dependencies_unresolved, required_names, selected_names}}
    end
  end

  defp current_package_snapshot(name, state) do
    with {:ok, classes} <- definition_class_set(state.originated_classes),
         {:ok, methods} <- definition_relation_set(state.added_methods),
         {:ok, superclasses} <- definition_relation_set(state.added_superclasses) do
      owners =
        classes
        |> MapSet.union(methods |> Map.keys() |> MapSet.new())
        |> MapSet.union(superclasses |> Map.keys() |> MapSet.new())
        |> Enum.sort_by(&:erlang.term_to_binary/1)

      documents =
        Enum.flat_map(owners, fn owner ->
          current_package_document(
            state.snapshot,
            owner,
            classes,
            Map.get(methods, owner, MapSet.new()),
            Map.get(superclasses, owner, MapSet.new()),
            state.foreign_methods,
            state.foreign_superclasses
          )
        end)

      {:ok,
       %SourceSnapshot{
         package: name,
         build: state.build,
         provider: state.provider,
         documents: documents
       }}
    end
  end

  defp definition_class_set(classes) do
    if duplicated?(classes),
      do: {:error, :invalid_package_build_definitions},
      else: {:ok, MapSet.new(classes)}
  end

  defp definition_relation_set(relations) do
    Enum.reduce_while(relations, {:ok, %{}}, fn
      [owner, value], {:ok, by_owner} ->
        values = Map.get(by_owner, owner, MapSet.new())

        if MapSet.member?(values, value) do
          {:halt, {:error, :invalid_package_build_definitions}}
        else
          {:cont, {:ok, Map.put(by_owner, owner, MapSet.put(values, value))}}
        end

      _relation, _acc ->
        {:halt, {:error, :invalid_package_build_definitions}}
    end)
  end

  defp current_package_document(
         %Snapshot{documents: documents},
         owner,
         classes,
         selectors,
         superclasses,
         foreign_methods,
         foreign_superclasses
       ) do
    case Map.fetch(documents, owner) do
      {:ok, document} ->
        owns_class? = MapSet.member?(classes, owner)

        methods =
          Enum.filter(document.methods, fn method ->
            MapSet.member?(selectors, method.selector) or
              (owns_class? and not MapSet.member?(foreign_methods, {owner, method.selector}))
          end)

        supers =
          Enum.filter(document.supers, fn superclass ->
            MapSet.member?(superclasses, superclass) or
              (owns_class? and
                 not MapSet.member?(foreign_superclasses, {owner, superclass}))
          end)

        cond do
          owns_class? and document.kind == :class ->
            [%{document | supers: supers, methods: methods}]

          methods != [] or supers != [] ->
            [
              %DefinitionDocument{
                kind: :extension,
                owner: owner,
                metaclass: nil,
                supers: supers,
                ivars: [],
                comment: nil,
                methods: methods
              }
            ]

          true ->
            []
        end

      :error ->
        []
    end
  end

  defp foreign_build_contributions(build, branch) do
    active_builds_in_transaction(branch)
    |> Map.values()
    |> Enum.reject(&(&1 == build))
    |> Enum.reduce_while(
      {:ok, %{methods: MapSet.new(), superclasses: MapSet.new()}},
      fn other_build, {:ok, contributions} ->
        case build_slots(other_build, branch) do
          {:ok, %{added_methods: methods, added_superclasses: superclasses}}
          when is_list(methods) and is_list(superclasses) ->
            with {:ok, found_methods} <- add_relations(methods, contributions.methods),
                 {:ok, found_superclasses} <-
                   add_relations(superclasses, contributions.superclasses) do
              {:cont, {:ok, %{methods: found_methods, superclasses: found_superclasses}}}
            else
              :error ->
                {:halt, {:error, {:package_build_definitions_unavailable, other_build}}}
            end

          _ ->
            {:halt, {:error, {:package_build_definitions_unavailable, other_build}}}
        end
      end
    )
  end

  defp add_relations(relations, found) do
    Enum.reduce_while(relations, {:ok, found}, fn
      [owner, value], {:ok, found} ->
        {:cont, {:ok, MapSet.put(found, {owner, value})}}

      _relation, _acc ->
        {:halt, :error}
    end)
  end

  defp reference_classes(documents) do
    Enum.reduce(documents, %{}, fn
      %DefinitionDocument{kind: :class} = document, classes ->
        Map.put(
          classes,
          document.owner,
          {document.metaclass, document.ivars, document.comment}
        )

      %DefinitionDocument{kind: :extension}, classes ->
        classes
    end)
  end

  defp reference_methods(documents) do
    documents
    |> Enum.flat_map(fn document ->
      Enum.map(document.methods, &{{document.owner, &1.selector}, &1})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp reference_superclasses(documents) do
    documents
    |> Enum.flat_map(fn document ->
      Enum.map(document.supers, &{{document.owner, &1}, true})
    end)
    |> Map.new()
  end

  defp definition_changes(reference, current),
    do: definition_changes(reference, current, &Function.identity/1)

  defp definition_changes(reference, current, render_key) do
    reference_keys = reference |> Map.keys() |> MapSet.new()
    current_keys = current |> Map.keys() |> MapSet.new()

    added = MapSet.difference(current_keys, reference_keys)
    removed = MapSet.difference(reference_keys, current_keys)

    changed =
      reference_keys
      |> MapSet.intersection(current_keys)
      |> Enum.filter(&(Map.fetch!(reference, &1) != Map.fetch!(current, &1)))

    %{
      added: render_definition_keys(added, render_key),
      changed: render_definition_keys(changed, render_key),
      removed: render_definition_keys(removed, render_key)
    }
  end

  defp render_definition_keys(keys, render_key) do
    keys
    |> Enum.sort_by(&:erlang.term_to_binary/1)
    |> Enum.map(render_key)
  end

  defp method_definition_key({owner, selector}), do: [owner, selector]

  defp superclass_definition_key({owner, superclass}), do: [owner, superclass]

  defp changed?(changes),
    do: changes.added != [] or changes.changed != [] or changes.removed != []

  defp read_provider(directory, channel) do
    manifest_path = Path.join(directory, "package.al")

    with {:ok, manifest_text} <- read(manifest_path),
         {:ok, document} <- Document.parse(manifest_text),
         {:ok, definitions} <- read_definitions(directory) do
      source_digest =
        digest({:package_source, 1, manifest_text, Enum.map(definitions, &{&1.path, &1.text})})

      {:ok,
       %Provider{
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

  defp validate_channel_providers(channel, providers) do
    providers
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
    if Enum.all?(requested, &valid_requirement?/1),
      do: :ok,
      else: {:error, :invalid_package_environment}
  end

  defp valid_requirement?(name) when is_atom(name), do: true
  defp valid_requirement?({name, _requirement}) when is_atom(name), do: true
  defp valid_requirement?(_requirement), do: false

  defp requirement_name(name) when is_atom(name), do: name
  defp requirement_name({name, _requirement}), do: name

  defp register_catalog(catalog, branch) do
    case :mnesia.transaction(fn -> register_catalog_transaction(catalog, branch) end) do
      {:atomic, {:ok, registered}} -> {:ok, registered}
      {:atomic, {:error, reason}} -> {:error, reason}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp register_catalog_transaction(catalog, branch) do
    with :ok <- package_system_available(branch),
         :ok <- validate_catalog_names(catalog, branch),
         {:ok, channels} <- realise_channels(catalog.channels, branch),
         :ok <- realise_package_classes(catalog, branch),
         {:ok, providers} <- realise_providers(catalog.providers, channels, branch) do
      registered_channels = Enum.map(catalog.channels, &Map.fetch!(channels, &1.name))
      {:ok, %Catalog{channels: registered_channels, providers: providers}}
    end
  end

  defp validate_registered_providers(catalog) do
    if Enum.all?(catalog.providers, fn provider ->
         is_atom(provider.id) and is_atom(provider.channel.id)
       end),
       do: :ok,
       else: {:error, :unregistered_package_provider}
  end

  defp resolve_providers(_catalog, [], _branch), do: {:ok, []}

  defp resolve_providers(catalog, requested, branch) do
    provider_ids = Enum.map(catalog.providers, & &1.id)

    result =
      AL.run branch: branch.id do
        resolve(:package_resolver, ^provider_ids, ^requested, solution)
      end

    case result do
      {:atomic, {%{:"$solution" => solution}, _state}} ->
        validate_resolution(solution, catalog, requested)

      {:aborted, _reason} ->
        {:error, {:package_resolution_failed, requested}}

      {:error, reason} ->
        {:error, {:package_resolution_query_failed, reason}}

      _result ->
        {:error, :invalid_package_resolution}
    end
  end

  defp validate_resolution(solution, catalog, requested) when is_list(solution) do
    providers = Map.new(catalog.providers, &{&1.id, &1})

    Enum.reduce_while(solution, {:ok, %{}, []}, fn
      [package, provider_id, dependencies], {:ok, selected, ordered}
      when is_atom(package) and is_atom(provider_id) and is_list(dependencies) ->
        with {:ok, provider} <- Map.fetch(providers, provider_id),
             true <- provider.document.name == package,
             :ok <- validate_resolution_dependencies(provider, dependencies, selected) do
          selection = {provider, dependencies}
          {:cont, {:ok, Map.put(selected, package, provider_id), ordered ++ [selection]}}
        else
          _ -> {:halt, {:error, :invalid_package_resolution}}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_package_resolution}}
    end)
    |> case do
      {:ok, selected, ordered} ->
        if Enum.all?(requested, &Map.has_key?(selected, requirement_name(&1))) and
             map_size(selected) == length(ordered),
           do: {:ok, ordered},
           else: {:error, :invalid_package_resolution}

      error ->
        error
    end
  end

  defp validate_resolution(_solution, _catalog, _requested),
    do: {:error, :invalid_package_resolution}

  defp validate_resolution_dependencies(provider, dependencies, selected) do
    expected = provider.document.deps

    if length(dependencies) == length(expected) and
         Enum.all?(Enum.zip(expected, dependencies), fn
           {expected_requirement, {requirement, package, provider_id}}
           when is_atom(package) and is_atom(provider_id) ->
             requirement == expected_requirement and
               package == requirement_name(expected_requirement) and
               Map.get(selected, package) == provider_id

           _dependency ->
             false
         end),
       do: :ok,
       else: {:error, :invalid_package_resolution}
  end

  defp build_specs(selections) do
    {by_name, builds} =
      Enum.reduce(selections, {%{}, []}, fn {provider, dependency_selections},
                                            {by_name, builds} ->
        dependencies =
          Enum.map(dependency_selections, fn {_requirement, name, _provider} ->
            {name, Map.fetch!(by_name, name)}
          end)

        dependency_inputs = Enum.map(dependencies, fn {name, build} -> {name, build.digest} end)
        digest = digest({:package_build, 1, provider.source_digest, dependency_inputs})
        build = %BuildSpec{provider: provider, dependencies: dependencies, digest: digest}

        {Map.put(by_name, provider.document.name, build), builds ++ [build]}
      end)

    if map_size(by_name) == length(builds), do: {:ok, builds}, else: {:error, :invalid_build_plan}
  end

  defp realise_transaction(plan, branch) do
    with :ok <- package_system_available(branch),
         :ok <- validate_catalog_names(plan.catalog, branch),
         :ok <- validate_plan_providers(plan, branch),
         {:ok, builds, created} <- realise_builds(plan, branch) do
      {:ok, %Realisation{plan: plan, builds: builds, created: created}}
    end
  end

  defp validate_catalog_names(catalog, branch) do
    catalog.providers
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
        {:ok, id} -> {:cont, {:ok, Map.put(realised, channel.name, %{channel | id: id})}}
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

  defp realise_package_classes(catalog, branch) do
    chunks =
      catalog.providers
      |> Enum.map(& &1.document.name)
      |> Enum.uniq()
      |> Enum.flat_map(&package_class_chunks(&1, branch))

    evaluate_chunks(chunks, package_registration_origin(catalog), branch)
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

  defp realise_providers(providers, channels, branch) do
    Enum.reduce_while(providers, {:ok, []}, fn provider, {:ok, realised} ->
      channel = Map.fetch!(channels, provider.channel.name)

      case realise_provider(provider, channel, branch) do
        {:ok, provider} -> {:cont, {:ok, realised ++ [provider]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp realise_provider(provider, channel, branch) do
    slots = provider_slots(provider, channel.id)

    case matching_providers(slots, branch) do
      [] ->
        chunks = [{"new(:package_provider, #{literal(slots)}, package_provider)", nil}]

        with {:ok, {bindings, _state}} <-
               evaluate_chunks_result(chunks, provider_origin(provider, channel), branch) do
          id = Map.fetch!(bindings, :"$package_provider")
          {:ok, %{provider | id: id, channel: channel}}
        end

      [%{id: id}] ->
        {:ok, %{provider | id: id, channel: channel}}

      matches ->
        {:error, {:duplicate_equivalent_package_providers, Enum.map(matches, & &1.id)}}
    end
  end

  defp provider_slots(provider, channel) do
    %{
      channel: channel,
      channel_revision: provider.channel.revision,
      provides: provider.document.name,
      version: provider.document.version,
      requirements: provider.document.deps,
      source_digest: provider.source_digest,
      source: provider_source(provider)
    }
  end

  defp provider_source(provider) do
    %{
      format: 1,
      manifest: provider.manifest_text,
      definitions: Enum.map(provider.definitions, &Map.take(&1, [:path, :text]))
    }
  end

  defp matching_providers(slots, branch) do
    AL.Object.scan_class(AL.Var.var("package_provider"), :package_provider, branch)
    |> Enum.flat_map(fn {:class, id, _seq, :package_provider} ->
      case AL.Object.read_slots(id, branch) do
        [{:slots, ^id, ^slots}] -> [%{id: id, slots: slots}]
        _ -> []
      end
    end)
  end

  defp validate_plan_providers(plan, branch) do
    Enum.reduce_while(plan.builds, :ok, fn build, :ok ->
      provider = build.provider

      case package_provider_slots(provider.id, branch) do
        {:ok,
         %{
           provides: package,
           source_digest: source_digest,
           channel: channel,
           channel_revision: channel_revision
         }}
        when package == provider.document.name and source_digest == provider.source_digest and
               channel == provider.channel.id and channel_revision == provider.channel.revision ->
          {:cont, :ok}

        {:ok, _slots} ->
          {:halt, {:error, {:package_provider_mismatch, provider.id}}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp realise_builds(plan, branch) do
    Enum.reduce_while(plan.builds, {:ok, %{}, []}, fn build, {:ok, realised, created} ->
      dependencies =
        Enum.map(build.dependencies, fn {name, _dependency} ->
          {name, Map.fetch!(realised, name)}
        end)

      args = build_args(build, dependencies)

      case reusable_build(build.provider.document.name, build.digest, branch) do
        {:ok, id} ->
          {:cont, {:ok, Map.put(realised, build.provider.document.name, id), created}}

        :none ->
          case create_build(build, args, branch) do
            {:ok, id} ->
              {:cont, {:ok, Map.put(realised, build.provider.document.name, id), created ++ [id]}}

            {:error, _reason} = error ->
              {:halt, error}
          end

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  defp package_class_source(name) do
    "new(:package, %{name: #{literal(name)}, super: :package_build, ivars: [], open_build: false}, _)"
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
    provider = build.provider

    chunks = [
      {"build(#{literal(provider.document.name)}, #{literal(args)}, package_build)", nil}
    ]

    with {:ok, {bindings, _state}} <-
           evaluate_chunks_result(chunks, build_origin(build, args), branch) do
      {:ok, Map.fetch!(bindings, :"$package_build")}
    end
  end

  defp build_args(build, dependencies) do
    provider = build.provider

    %{
      package: provider.document.name,
      version: provider.document.version,
      requirements: provider.document.deps,
      dependency_builds: dependencies,
      digest: build.digest,
      provider: provider.id,
      status: :complete
    }
  end

  defp activate_transaction(realisation, branch, replace?) do
    selected = realisation.builds
    current = active_builds_in_transaction(branch)
    final = if replace?, do: selected, else: Map.merge(current, selected)

    with :ok <- validate_build_closure(final, branch),
         {:ok, old_sources} <- sources_for_builds(current, branch),
         {:ok, new_sources} <- sources_for_builds(final, branch),
         snapshot <- Snapshot.capture_in_transaction(branch),
         runtime <- runtime_definition_sources(old_sources, new_sources, snapshot),
         {:ok, old_documents} <- compose_build_documents(runtime ++ old_sources),
         {:ok, new_documents} <- compose_build_documents(runtime ++ new_sources),
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
         {:ok, membership_chunks} <- build_definition_chunks(final, branch),
         pointer_chunks <- active_pointer_chunks(current, final),
         :ok <-
           evaluate_chunks(
             definition_chunks ++ membership_chunks ++ pointer_chunks,
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

  defp sources_for_builds(builds, branch) do
    builds
    |> Enum.sort_by(fn {name, _build} -> name end)
    |> Enum.reduce_while({:ok, []}, fn {package, build}, {:ok, sources} ->
      with {:ok, build_slots} <- build_slots(build, branch),
           {:ok, build_documents} <- build_source_documents(build, build_slots, branch),
           :ok <- validate_unique_build_documents(build, build_documents) do
        source = %{
          package: package,
          build: build,
          dependencies: Map.get(build_slots, :dependency_builds, []),
          documents: build_documents
        }

        {:cont, {:ok, sources ++ [source]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp runtime_definition_sources(old_sources, new_sources, snapshot) do
    documents = Enum.flat_map(old_sources ++ new_sources, & &1.documents)
    origins = documents |> Enum.filter(&(&1.kind == :class)) |> MapSet.new(& &1.owner)

    old_extensions =
      old_sources
      |> Enum.flat_map(& &1.documents)
      |> Enum.filter(&(&1.kind == :extension))
      |> Enum.group_by(& &1.owner)

    documents
    |> Enum.filter(&(&1.kind == :extension and not MapSet.member?(origins, &1.owner)))
    |> Enum.uniq_by(& &1.owner)
    |> Enum.flat_map(fn extension ->
      case Map.get(snapshot.documents, extension.owner) do
        %DefinitionDocument{kind: :class} = document ->
          previous = Map.get(old_extensions, document.owner, [])
          methods = previous |> Enum.flat_map(& &1.methods) |> MapSet.new(& &1.selector)
          supers = previous |> Enum.flat_map(& &1.supers) |> MapSet.new()

          base = %{
            document
            | methods: Enum.reject(document.methods, &MapSet.member?(methods, &1.selector)),
              supers: Enum.reject(document.supers, &MapSet.member?(supers, &1))
          }

          [%{package: nil, build: nil, dependencies: [], documents: [base]}]

        _ ->
          []
      end
    end)
  end

  defp validate_unique_build_documents(build, documents) do
    owners = Enum.map(documents, & &1.owner)

    if duplicated?(owners),
      do: {:error, {:duplicate_package_definition_owner, build}},
      else: :ok
  end

  defp compose_build_documents(sources) do
    contributions =
      Enum.flat_map(sources, fn source ->
        Enum.map(source.documents, &Map.put(source, :document, &1))
      end)

    with {:ok, origins} <- class_origins(contributions),
         :ok <- validate_extension_dependencies(contributions, origins, sources) do
      contributions
      |> Enum.group_by(& &1.document.owner)
      |> Enum.reduce_while({:ok, %{}}, fn {owner, owner_contributions}, {:ok, documents} ->
        case compose_owner_document(owner, owner_contributions) do
          {:ok, document} -> {:cont, {:ok, Map.put(documents, owner, document)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp class_origins(contributions) do
    contributions
    |> Enum.filter(&(&1.document.kind == :class))
    |> Enum.reduce_while({:ok, %{}}, fn contribution, {:ok, origins} ->
      owner = contribution.document.owner

      if Map.has_key?(origins, owner) do
        {:halt, {:error, {:multiple_package_class_origins, owner}}}
      else
        {:cont, {:ok, Map.put(origins, owner, contribution)}}
      end
    end)
  end

  defp validate_extension_dependencies(contributions, origins, sources) do
    dependencies = Map.new(sources, &{&1.build, &1.dependencies})

    contributions
    |> Enum.filter(&(&1.document.kind == :extension))
    |> Enum.reduce_while(:ok, fn extension, :ok ->
      owner = extension.document.owner

      case Map.fetch(origins, owner) do
        {:ok, %{build: nil, document: runtime}} ->
          shared_supers = Enum.filter(extension.document.supers, &(&1 in runtime.supers))

          if shared_supers == [] do
            {:cont, :ok}
          else
            {:halt, {:error, {:duplicate_runtime_superclass_contribution, owner, shared_supers}}}
          end

        {:ok, origin} ->
          reachable = dependency_builds(extension.build, dependencies, MapSet.new())

          if MapSet.member?(reachable, origin.build) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              {:package_extension_missing_dependency, extension.build, owner, origin.build}}}
          end

        :error ->
          {:halt, {:error, {:package_extension_without_origin, extension.build, owner}}}
      end
    end)
  end

  defp dependency_builds(build, dependencies, seen) do
    Enum.reduce(Map.get(dependencies, build, []), seen, fn {_package, dependency}, reachable ->
      if MapSet.member?(reachable, dependency) do
        reachable
      else
        dependency_builds(dependency, dependencies, MapSet.put(reachable, dependency))
      end
    end)
  end

  defp compose_owner_document(owner, contributions) do
    case Enum.split_with(contributions, &(&1.document.kind == :class)) do
      {[origin], extensions} -> merge_definition_contributions(origin.document, extensions)
      {[], _extensions} -> {:error, {:package_extension_without_origin, owner}}
      {_origins, _extensions} -> {:error, {:multiple_package_class_origins, owner}}
    end
  end

  defp merge_definition_contributions(origin, extensions) do
    Enum.reduce_while(extensions, {:ok, origin, method_selectors(origin)}, fn extension,
                                                                              {:ok, document,
                                                                               selectors} ->
      extension_selectors = method_selectors(extension.document)
      duplicate_selectors = MapSet.intersection(selectors, extension_selectors)

      if MapSet.size(duplicate_selectors) == 0 do
        merged = %{
          document
          | supers: Enum.uniq(document.supers ++ extension.document.supers),
            methods: document.methods ++ extension.document.methods
        }

        {:cont, {:ok, merged, MapSet.union(selectors, extension_selectors)}}
      else
        {:halt,
         {:error,
          {:duplicate_package_method_contribution, document.owner,
           duplicate_selectors |> MapSet.to_list() |> Enum.sort()}}}
      end
    end)
    |> case do
      {:ok, document, _selectors} -> {:ok, document}
      error -> error
    end
  end

  defp method_selectors(document),
    do: document.methods |> Enum.map(& &1.selector) |> MapSet.new()

  defp build_source_documents(_build, %{provider: provider}, branch) when is_atom(provider) do
    with {:ok, slots} <- package_provider_slots(provider, branch),
         {:ok, documents} <- parse_provider_documents(provider, slots) do
      {:ok, documents}
    end
  end

  defp build_source_documents(
         build,
         %{
           package: package,
           status: :open,
           originated_classes: classes,
           added_methods: methods,
           added_superclasses: superclasses
         },
         branch
       ) do
    with {:ok, foreign} <- foreign_build_contributions(build, branch),
         {:ok, snapshot} <-
           current_package_snapshot(package, %{
             build: build,
             provider: nil,
             originated_classes: classes,
             added_methods: methods,
             added_superclasses: superclasses,
             foreign_methods: foreign.methods,
             foreign_superclasses: foreign.superclasses,
             snapshot: Snapshot.capture_in_transaction(branch)
           }) do
      {:ok, snapshot.documents}
    end
  end

  defp build_source_documents(build, _slots, _branch),
    do: {:error, {:package_build_source_unavailable, build}}

  defp parse_provider_documents(provider, %{source: %{format: 1, definitions: definitions}})
       when is_list(definitions) do
    Enum.reduce_while(definitions, {:ok, []}, fn
      %{path: path, text: text}, {:ok, documents} ->
        case DefinitionDocument.parse(text) do
          {:ok, document} ->
            {:cont, {:ok, [document | documents]}}

          {:error, reason} ->
            {:halt, {:error, {:invalid_retained_package_definition, provider, path, reason}}}
        end

      _definition, _acc ->
        {:halt, {:error, {:invalid_retained_package_source, provider}}}
    end)
    |> case do
      {:ok, documents} -> {:ok, Enum.reverse(documents)}
      error -> error
    end
  end

  defp parse_provider_documents(provider, _slots),
    do: {:error, {:package_provider_source_unavailable, provider}}

  defp build_definition_chunks(builds, branch) do
    builds
    |> Enum.sort_by(fn {package, _build} -> package end)
    |> Enum.reduce_while({:ok, []}, fn {_package, build}, {:ok, chunks} ->
      with {:ok, build_slots} <- build_slots(build, branch),
           {:ok, documents} <- build_source_documents(build, build_slots, branch) do
        classes =
          documents
          |> Enum.flat_map(fn
            %DefinitionDocument{kind: :class, owner: owner} -> [owner]
            %DefinitionDocument{} -> []
          end)
          |> Enum.uniq()
          |> Enum.sort_by(&:erlang.term_to_binary/1)

        methods =
          documents
          |> Enum.flat_map(fn document ->
            Enum.map(document.methods, &[document.owner, &1.selector])
          end)
          |> Enum.uniq()
          |> Enum.sort_by(&:erlang.term_to_binary/1)

        superclasses =
          documents
          |> Enum.flat_map(fn document ->
            Enum.map(document.supers, &[document.owner, &1])
          end)
          |> Enum.uniq()
          |> Enum.sort_by(&:erlang.term_to_binary/1)

        slots = %{
          originated_classes: classes,
          added_methods: methods,
          added_superclasses: superclasses
        }

        chunk = {"set_slots(#{literal(build)}, #{literal(slots)})", nil}
        {:cont, {:ok, chunks ++ [chunk]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

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
         {:ok, _closure} <- active_closure(requested, current, branch, %{}) do
      true
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

  defp providers_in_transaction(name, branch) do
    AL.Object.scan_class(AL.Var.var("package_provider"), :package_provider, branch)
    |> Enum.flat_map(fn {:class, id, _seq, :package_provider} ->
      case AL.Object.read_slots(id, branch) do
        [{:slots, ^id, %{provides: ^name} = slots}] -> [%{id: id, slots: slots}]
        _ -> []
      end
    end)
  end

  defp package_provider_slots(provider, branch) do
    case AL.Object.read_slots(provider, branch) do
      [{:slots, ^provider, slots}] -> {:ok, slots}
      _ -> {:error, {:package_provider_not_found, provider}}
    end
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

  defp package_registration_origin(catalog) do
    %{
      kind: :package_registration,
      packages: catalog.providers |> Enum.map(& &1.document.name) |> Enum.uniq()
    }
  end

  defp provider_origin(provider, channel) do
    %{
      kind: :package_provider,
      package: provider.document.name,
      source_digest: provider.source_digest,
      channel: channel.name,
      channel_revision: channel.revision
    }
  end

  defp build_origin(build, args) do
    %{
      kind: :package_realisation,
      package: build.provider.document.name,
      digest: build.digest,
      provider: build.provider.id,
      source_digest: build.provider.source_digest,
      channel: build.provider.channel.name,
      channel_revision: build.provider.channel.revision,
      dependency_builds: args.dependency_builds
    }
  end

  defp package_publication_origin(package, build, provider, build_digest) do
    %{
      kind: :package_publication,
      package: package,
      build: build,
      provider: provider.id,
      source_digest: provider.source_digest,
      digest: build_digest,
      channel: provider.channel.name,
      channel_revision: provider.channel.revision
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
