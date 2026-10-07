defmodule AL.Package.Publication do
  def plan(name, build, provider, document, dependency_inputs) do
    digest =
      AL.Package.ContentAddress.digest(
        {:package_build, 1, provider.source_digest, dependency_inputs}
      )

    requirements =
      Enum.map(document.deps, fn
        {package, requirement} -> %{package: package, requirement: requirement}
        package -> package
      end)

    slots = %{
      version: document.version,
      requirements: requirements,
      digest: digest,
      provider: provider.id,
      status: :complete
    }

    source = "set_slots #{AL.Syntax.Printer.term(build)} #{AL.Syntax.Printer.term(slots)}."

    origin = %{
      kind: :package_publication,
      package: name,
      build: build,
      provider: provider.id,
      source_digest: provider.source_digest,
      digest: digest,
      channel: provider.channel.name,
      channel_revision: provider.channel.revision
    }

    %{chunks: [{source, nil}], origin: origin, result: %{provider: provider.id, digest: digest}}
  end
end
