defmodule AL.Package.Document do
  @moduledoc "The safe, literal manifest for one portable AL package bundle."

  @enforce_keys [:name, :version, :deps]
  defstruct [:name, :version, :deps]

  @type dependency() :: atom() | {atom(), term()}
  @type t() :: %__MODULE__{
          name: atom(),
          version: pos_integer(),
          deps: [dependency()]
        }

  @type parse_error() :: {:invalid_package_document, String.t()}

  @spec render(t()) :: String.t()
  def render(%__MODULE__{} = document) do
    deps =
      Enum.map(document.deps, fn
        {name, requirement} -> [name, requirement]
        name -> name
      end)

    "defpackage " <>
      AL.Syntax.Printer.term(document.name) <>
      " " <> AL.Syntax.Printer.term(%{version: document.version, deps: deps}) <> ".\n"
  end

  @spec parse(String.t()) :: {:ok, t()} | {:error, parse_error()}
  def parse(text) when is_binary(text) do
    with {:ok, name, options} <- read(text),
         :ok <- fields(options),
         :ok <- ground(options),
         document = %__MODULE__{name: name, version: options.version, deps: deps(options.deps)},
         :ok <- validate(document) do
      {:ok, document}
    end
  end

  def parse(_text), do: invalid("document must be text")

  defp read(text) do
    case AL.Syntax.package(text) do
      {:ok, name, options} -> {:ok, name, options}
      {:error, message} -> invalid(message)
    end
  end

  defp fields(options) do
    if Enum.sort(Map.keys(options)) == [:deps, :version],
      do: :ok,
      else: invalid("a manifest declares exactly version: and deps:")
  end

  defp ground(options) do
    if AL.Goal.reduce(options, false, &(&2 or AL.Var.var?(&1))),
      do: invalid("a manifest cannot hold variables"),
      else: :ok
  end

  defp deps(deps) when is_list(deps) do
    Enum.map(deps, fn
      [name, requirement] -> {name, requirement}
      name -> name
    end)
  end

  defp deps(deps), do: deps

  defp validate(%__MODULE__{} = document) do
    with :ok <- positive_integer(document.version, "version must be a positive integer"),
         :ok <- dependencies(document.deps) do
      :ok
    end
  end

  defp dependencies(value) when is_list(value) do
    cond do
      not Enum.all?(value, &valid_dependency?/1) ->
        invalid("deps must contain package names or [name, requirement] pairs")

      duplicated?(Enum.map(value, &dependency_name/1)) ->
        invalid("dependency names must be unique")

      true ->
        :ok
    end
  end

  defp dependencies(_value), do: invalid("deps must be a list")

  defp valid_dependency?(name) when is_atom(name), do: true

  defp valid_dependency?({name, _requirement}) when is_atom(name), do: true

  defp valid_dependency?(_dependency), do: false

  defp dependency_name(name) when is_atom(name), do: name
  defp dependency_name({name, _requirement}), do: name

  defp duplicated?(values), do: length(values) != length(Enum.uniq(values))

  defp positive_integer(value, _message) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(_value, message), do: invalid(message)

  defp invalid(message), do: {:error, {:invalid_package_document, message}}
end
