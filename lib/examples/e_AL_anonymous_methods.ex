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

  example a_do_block_is_a_goals_argument_to_any_send() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        defmethod(:list, :lambda, [head, method, body]) do
          new(:anonymous_method, %{args: [], head: head, body: body}, method)
        end

        lambda([x, doubled], twice) do
          doubled = [x, x]
        end

        run(twice, [:a, result])
      end

    assert Map.get(bindings, :"$result") == [:a, :a]
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

  example stores_a_lambda_in_a_durable_slot() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        defclass :lambda_holder,
          super: :object,
          ivars: [%{name: :condition, type: :anonymous_method}] do
        end

        lambda([input, output], condition) do
          output = [input]
        end

        new(:lambda_holder, %{name: :stored_lambda, condition: condition}, _holder)
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        get(:stored_lambda, :condition, condition)
        run(condition, [:durable, result])
      end

    assert bindings[:"$result"] == [:durable]
    :ok
  end
end
