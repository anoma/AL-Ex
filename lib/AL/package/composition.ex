defmodule AL.Package.Composition do
  alias AL.Definition.Document, as: DefinitionDocument

  def runtime_definition_sources(old_sources, new_sources, snapshot) do
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

  def validate_unique_build_documents(build, documents) do
    owners = Enum.map(documents, & &1.owner)

    if duplicated?(owners),
      do: {:error, {:duplicate_package_definition_owner, build}},
      else: :ok
  end

  def compose_build_documents(sources) do
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

  defp duplicated?(values), do: length(values) != length(Enum.uniq(values))
end
