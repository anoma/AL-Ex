defmodule AL.Package.Discovery do
  @moduledoc "I read package channels and bundles into catalogs without mutating AL."

  alias AL.Package.Catalog
  alias AL.Package.Channel
  alias AL.Package.ContentAddress
  alias AL.Package.Document
  alias AL.Package.Provider
  alias AL.Serialisation.Document, as: DefinitionDocument

  @spec manifest(Path.t()) :: {:ok, Document.t()} | {:error, term()}
  def manifest(directory) do
    path = Path.join(directory, "package.al")

    with {:ok, text} <- read(path), do: Document.parse(text)
  end

  @spec discover([{atom(), term()}]) :: {:ok, Catalog.t()} | {:error, term()}
  def discover(specs) when is_list(specs) do
    with :ok <- validate_channel_specs(specs),
         {:ok, discovered} <- discover_channels(specs) do
      channels = Enum.map(discovered, &elem(&1, 0))
      providers = Enum.flat_map(discovered, &elem(&1, 1))
      {:ok, %Catalog{channels: channels, providers: providers}}
    end
  end

  @spec provider(Path.t()) :: {:ok, Provider.t()} | {:error, term()}
  def provider(directory) do
    directory = Path.expand(directory)

    with {:ok, provider} <- read_provider(directory) do
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
        ContentAddress.digest(
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
      case read_provider(directory) do
        {:ok, provider} -> {:cont, {:ok, [provider | providers]}}
        {:error, reason} -> {:halt, {:error, {:invalid_package_provider, directory, reason}}}
      end
    end)
    |> case do
      {:ok, providers} -> {:ok, Enum.reverse(providers)}
      error -> error
    end
  end

  defp read_provider(directory) do
    manifest_path = Path.join(directory, "package.al")

    with {:ok, manifest_text} <- read(manifest_path),
         {:ok, document} <- Document.parse(manifest_text),
         {:ok, definitions} <- read_definitions(directory) do
      source_digest =
        ContentAddress.digest(
          {:package_source, 1, manifest_text, Enum.map(definitions, &{&1.path, &1.text})}
        )

      {:ok,
       %Provider{
         channel: nil,
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

  defp resolve_location({:priv, path}),
    do: Application.app_dir(:al, Path.join("priv", path))

  defp resolve_location(path) when is_binary(path), do: Path.expand(path)

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, {:file_read, path, reason}}
    end
  end

  defp duplicated?(values), do: length(values) != length(Enum.uniq(values))
end
