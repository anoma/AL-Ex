defmodule AL.Package.SourceSnapshot do
  @moduledoc "I represent the current live source of one active package build."

  alias AL.Definition.Document
  alias AL.Definition.Document, as: DefinitionDocument
  alias AL.Definition.Snapshot
  alias __MODULE__, as: SourceSnapshot

  @enforce_keys [:package, :build, :provider, :documents]
  defstruct [:package, :build, :provider, :documents]

  @type t() :: %__MODULE__{
          package: atom(),
          build: atom(),
          provider: atom() | nil,
          documents: [Document.t()]
        }
  def current(name, state) do
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

  defp duplicated?(values), do: length(values) != length(Enum.uniq(values))
end
