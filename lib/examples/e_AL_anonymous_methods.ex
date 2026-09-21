defmodule Examples.ALAnonymousMethods do
  @moduledoc """
  I exercise first-class anonymous method values and callable behaviours.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example accumulates_arguments_before_running() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        new(
          :anonymous_method,
          %{args: [], head: [first, second, result], body: [result = [first, second]]},
          method
        )

        add_arg(method, :a, partially_applied)
        run(partially_applied, [:b, result])
      end

    assert Map.get(bindings, :"$result") == [:a, :b]
    :ok
  end

  example runs_an_existing_method_object() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        method(:number, :factorial, factorial)
        run(factorial, [5, result])
      end

    assert Map.get(bindings, :"$result") == 120
    :ok
  end
end
