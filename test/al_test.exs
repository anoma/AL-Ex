{:ok, modules} = :application.get_key(:al, :modules)

serial = [
  Examples.ALObjects,
  Examples.ALNative,
  Examples.ALBranch,
  Examples.ALClauses,
  Examples.ALSource,
  Examples.ALFreshening,
  Examples.ALGuarded,
  Examples.ALMaps,
  Examples.ALTransactionPrograms,
  Examples.ALPackages,
  Examples.ALGtBridge,
  Examples.ALJAM,
  Examples.ALJAMCompiler
]

for module <- Enum.sort(modules),
    String.starts_with?(Atom.to_string(module), "Elixir.Examples.AL"),
    Code.ensure_loaded?(module),
    function_exported?(module, :__examples__, 0),
    ExExample.execution_order(module) != [] do
  Module.create(
    Module.concat(module, Test),
    quote do
      use AL.ExampleCase, for: unquote(module), async: unquote(module not in serial)
    end,
    Macro.Env.location(__ENV__)
  )
end
