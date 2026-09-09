defmodule AL.Package do
  @moduledoc "Imports portable definition packages into an explicit AL branch."

  alias AL.Package.Document
  alias AL.Serialisation.Document, as: DefinitionDocument
  alias AL.Serialisation.Snapshot
  alias AL.Serialisation.Sync

  @type import_result() :: %{
          package: atom(),
          build: term(),
          definitions: [term()]
        }

  @doc "The configured portable package bundle directories."
  @spec configured() :: [Path.t()]
  def configured do
    :al
    |> Application.get_env(:package_imports, [])
    |> Enum.map(&resolve_configured_path/1)
  end

  @doc "Read and validate a package bundle's manifest."
  @spec manifest(Path.t()) :: {:ok, Document.t()} | {:error, term()}
  def manifest(directory) do
    path = Path.join(directory, "package.al")

    with {:ok, text} <- read(path), do: Document.parse(text)
  end

  @doc "Whether a package class is installed on a branch."
  @spec installed?(atom(), AL.Branch.t()) :: boolean()
  def installed?(name, branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn -> package_installed?(name, branch) end) do
      {:atomic, installed?} -> installed?
      _ -> false
    end
  end

  @doc "Import a bundle unless its package class is already installed."
  @spec ensure_imported(Path.t(), keyword()) :: :ok | {:error, term()}
  def ensure_imported(directory, opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())

    with {:ok, document} <- manifest(directory) do
      if installed?(document.name, branch) do
        :ok
      else
        case __MODULE__.import(directory, Keyword.put(opts, :branch, branch)) do
          {:ok, _result} -> :ok
          {:error, _reason} = error -> error
        end
      end
    end
  end

  @doc "Whether a bundle's package dependencies are installed on a branch."
  @spec ready?(Path.t(), AL.Branch.t()) :: boolean()
  def ready?(directory, branch \\ AL.Branch.head()) do
    case manifest(directory) do
      {:ok, document} ->
        case :mnesia.transaction(fn ->
               package_system_available?(branch) and
                 Enum.all?(document.deps, &dependency_available?(&1, branch))
             end) do
          {:atomic, ready?} -> ready?
          _ -> false
        end

      {:error, _reason} ->
        false
    end
  end

  @doc "Import all definition documents and create the package's completed build."
  @spec import(Path.t(), keyword()) :: {:ok, import_result()} | {:error, term()}
  def import(directory, opts \\ []) do
    branch = Keyword.get(opts, :branch, AL.Branch.head())
    manifest_path = Path.join(directory, "package.al")

    with {:ok, text} <- read(manifest_path),
         {:ok, document} <- Document.parse(text),
         {:ok, definitions} <- read_definitions(directory),
         {:ok, result} <- install(document, definitions, branch, manifest_path) do
      {:ok, result}
    end
  end

  defp resolve_configured_path({:priv, path}) when is_binary(path),
    do: Application.app_dir(:al, Path.join("priv", path))

  defp resolve_configured_path(path) when is_binary(path), do: Path.expand(path)

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:file_read, path, reason}}
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
        {:cont, {:ok, [{path, document} | definitions]}}
      else
        {:error, reason} -> {:halt, {:error, {:invalid_definition, path, reason}}}
      end
    end)
    |> case do
      {:ok, definitions} -> {:ok, Enum.reverse(definitions)}
      error -> error
    end
  end

  defp install(document, definitions, branch, manifest_path) do
    case :mnesia.transaction(fn ->
           install_transaction(document, definitions, branch, manifest_path)
         end) do
      {:atomic, {:ok, result}} -> {:ok, result}
      {:atomic, {:error, reason}} -> {:error, reason}
      {:aborted, reason} -> {:error, reason}
    end
  end

  defp install_transaction(document, definitions, branch, manifest_path) do
    with :ok <- package_system_available(branch),
         :ok <- package_not_installed(document.name, branch),
         :ok <- package_name_available(document.name, branch),
         :ok <- dependencies_available(document.deps, branch),
         snapshot <- Snapshot.capture_in_transaction(branch),
         definition_documents <- Enum.map(definitions, &elem(&1, 1)),
         {:ok, definition_chunks} <- Sync.plan(snapshot, definition_documents),
         chunks <-
           definition_chunks ++
             legacy_package_chunks(document, branch) ++
             legacy_receipt_chunks(document.name, branch) ++ [{package_source(document), nil}],
         {:ok, parsed, source} <- AL.Serialisation.compile_chunks(chunks),
         {:ok, build} <-
           evaluate(parsed, source, document, definitions, branch, manifest_path) do
      {:ok,
       %{
         package: document.name,
         build: build,
         definitions: Enum.map(definition_documents, & &1.owner)
       }}
    end
  end

  defp package_system_available(branch) do
    if package_system_available?(branch),
      do: :ok,
      else: {:error, :package_system_not_installed}
  end

  defp package_system_available?(branch),
    do: AL.Object.scan_class(:package, :class, branch) != []

  defp package_not_installed(name, branch) do
    if package_installed?(name, branch),
      do: {:error, {:package_already_installed, name}},
      else: :ok
  end

  defp package_installed?(name, branch),
    do: AL.Object.scan_class(name, :package, branch) != []

  defp package_name_available(name, branch) do
    classes =
      AL.Object.scan_class(name, AL.Var.var("package_import_existing_class"), branch)
      |> Enum.map(fn {:class, ^name, _seq, class} -> class end)

    case classes do
      [] -> :ok
      [:program_execution] -> :ok
      _ -> {:error, {:package_name_in_use, name, classes}}
    end
  end

  defp dependencies_available(dependencies, branch) do
    case Enum.reject(dependencies, &dependency_available?(&1, branch)) do
      [] -> :ok
      missing -> {:error, {:missing_package_dependencies, missing}}
    end
  end

  defp dependency_available?(dependency, branch) do
    name = dependency_name(dependency)
    package_installed?(name, branch) or program_installed?(name, branch)
  end

  defp dependency_name(name) when is_atom(name), do: name
  defp dependency_name({name, _requirement}), do: name

  defp program_installed?(name, branch) do
    AL.Object.scan_class(AL.Var.var("package_import_execution"), :program_execution, branch)
    |> Enum.any?(fn {:class, execution, _seq, :program_execution} ->
      match?([{:slots, ^execution, %{name: ^name}}], AL.Object.read_slots(execution, branch))
    end)
  end

  defp legacy_package_chunks(document, branch) do
    legacy = String.to_atom(Atom.to_string(document.name) <> "_package")

    case AL.Object.read_slots(legacy, branch) do
      [{:slots, ^legacy, %{package_name: name}}] when name == document.name ->
        legacy
        |> legacy_package_objects(branch)
        |> Enum.map(&{"retract_existing_facts(#{literal(&1)})", nil})

      _ ->
        []
    end
  end

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

  defp legacy_receipt_chunks(name, branch) do
    if AL.Object.scan_class(name, :program_execution, branch) == [] do
      []
    else
      [{"retract_existing_facts(#{literal(name)})", nil}]
    end
  end

  defp evaluate(parsed, source, document, definitions, branch, manifest_path) do
    origin = %{
      kind: :package_import,
      package: document.name,
      version: document.version,
      manifest: manifest_path,
      definitions: Enum.map(definitions, &elem(&1, 0)),
      format: :definition_package
    }

    case AL.eval_captured(parsed, source, origin, nil, branch, []) do
      {:atomic, {bindings, _state}} ->
        {:ok, Map.fetch!(bindings, :"$package_build")}

      {:aborted, reason} ->
        {:error, {:package_import_failed, reason}}

      {:error, reason} ->
        {:error, {:invalid_generated_package, reason}}
    end
  end

  defp package_source(document) do
    """
    new(
      :package,
      %{
        name: #{literal(document.name)},
        super: :package_build,
        ivars: [],
        deps: #{literal(document.deps)},
        redef: true
      },
      _
    )

    build(
      #{literal(document.name)},
      #{document.version},
      [],
      package_build
    )

    set_slot(package_build, :status, :complete)
    """
  end

  defp literal(value),
    do: inspect(value, pretty: false, limit: :infinity, printable_limit: :infinity)
end
