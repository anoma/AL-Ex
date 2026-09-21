defmodule AL.Package.Resolver do
  @moduledoc "I turn registered package catalogs into exact build plans."

  require AL

  alias AL.Package.BuildSpec
  alias AL.Package.Catalog
  alias AL.Package.ContentAddress
  alias AL.Package.Document
  alias AL.Package.Plan

  @spec resolve(Catalog.t(), [Document.dependency()], AL.Branch.t()) ::
          {:ok, Plan.t()} | {:error, term()}
  def resolve(%Catalog{} = catalog, requested, branch) do
    requested = Enum.uniq(requested)

    with :ok <- validate_requested(requested),
         :ok <- validate_registered_providers(catalog),
         {:ok, selections} <- resolve_providers(catalog, requested, branch),
         {:ok, builds} <- build_specs(selections) do
      {:ok, %Plan{requested: requested, catalog: catalog, builds: builds}}
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
    al_requested = Enum.map(requested, &al_requirement/1)

    result =
      AL.run branch: branch.id do
        resolve(:package_resolver, ^provider_ids, ^al_requested, solution)
      end

    case result do
      {:atomic, {%{:"$solution" => solution}, _constraints, _state}} ->
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
           {expected_requirement,
            %{requirement: requirement, package: package, provider: provider_id}}
           when is_atom(package) and is_atom(provider_id) ->
             requirement == al_requirement(expected_requirement) and
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
          Enum.map(dependency_selections, fn %{
                                               requirement: _requirement,
                                               package: name,
                                               provider: _provider
                                             } ->
            {name, Map.fetch!(by_name, name)}
          end)

        dependency_inputs = Enum.map(dependencies, fn {name, build} -> {name, build.digest} end)

        digest =
          ContentAddress.digest({:package_build, 1, provider.source_digest, dependency_inputs})

        build = %BuildSpec{provider: provider, dependencies: dependencies, digest: digest}

        {Map.put(by_name, provider.document.name, build), builds ++ [build]}
      end)

    if map_size(by_name) == length(builds), do: {:ok, builds}, else: {:error, :invalid_build_plan}
  end

  defp al_requirement(name) when is_atom(name), do: name
  defp al_requirement({name, requirement}), do: %{package: name, requirement: requirement}
end
