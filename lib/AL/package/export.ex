defmodule AL.Package.Export do
  def write(directory, manifest_text, definitions) do
    directory = Path.expand(directory)

    :global.trans({{__MODULE__, directory}, self()}, fn ->
      stage(directory, manifest_text, definitions)
    end)
  end

  defp stage(directory, manifest_text, definitions) do
    suffix = System.unique_integer([:positive, :monotonic])
    staging = "#{directory}.stage-#{suffix}"
    backup = "#{directory}.backup-#{suffix}"

    try do
      with :ok <- prepare(directory, staging),
           :ok <- write_staged(staging, manifest_text, definitions),
           :ok <- publish(directory, staging, backup) do
        :ok
      end
    after
      File.rm_rf(staging)
    end
  end

  defp prepare(directory, staging) do
    if File.exists?(directory) do
      case File.cp_r(directory, staging) do
        {:ok, _} -> :ok
        {:error, reason, path} -> {:error, {:package_export_copy, path, reason}}
      end
    else
      File.mkdir_p(staging)
    end
  end

  defp publish(directory, staging, backup) do
    existed = File.exists?(directory)

    with :ok <- if(existed, do: File.rename(directory, backup), else: :ok) do
      case File.rename(staging, directory) do
        :ok ->
          if existed, do: File.rm_rf(backup)
          :ok

        {:error, reason} ->
          case if(existed, do: File.rename(backup, directory), else: :ok) do
            :ok -> {:error, {:package_export_publish, directory, reason}}
            {:error, restore} -> {:error, {:package_export_restore, backup, reason, restore}}
          end
      end
    end
  end

  defp write_staged(directory, manifest_text, definitions) do
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
end
