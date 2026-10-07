defmodule AL.Package.Activation do
  alias AL.Package.Composition

  def plan(old_sources, new_sources, snapshot) do
    runtime = Composition.runtime_definition_sources(old_sources, new_sources, snapshot)

    with {:ok, old_documents} <- Composition.compose_build_documents(runtime ++ old_sources),
         {:ok, new_documents} <- Composition.compose_build_documents(runtime ++ new_sources) do
      deleted =
        old_documents
        |> Map.keys()
        |> Kernel.--(Map.keys(new_documents))
        |> Enum.sort_by(&:erlang.term_to_binary/1)

      definitions =
        new_documents |> Map.values() |> Enum.sort_by(&:erlang.term_to_binary(&1.owner))

      AL.Definition.Changes.plan(snapshot, definitions, deleted)
    end
  end
end
