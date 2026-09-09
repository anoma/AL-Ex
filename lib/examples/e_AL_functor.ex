defmodule Examples.ALFunctor do
  @moduledoc """
  I provide `functor/3` and `call_term/1` examples. `functor` is Prolog's
  `functor/3` crossed with `=..` — a ground tuple decomposes into its first
  element (`name`) and the rest as a list (`args`); `name`/`args` ground with
  the term unbound construct the reverse. Atomic terms (non-tuples) decompose
  to themselves with `args = []`. `call_term` is Prolog's `call/1`: a ground
  compound term is re-dispatched as a `send`, functor as selector, first arg
  as receiver.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example decomposes_a_ground_tuple() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        functor(term, :foo, [1, 2])
        functor(term, name, args)
      end

    assert Map.get(bindings, :"$name") == :foo
    assert Map.get(bindings, :"$args") == [1, 2]
  end

  example decomposes_an_atomic_term() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        functor(3, name, args)
      end

    assert Map.get(bindings, :"$name") == 3
    assert Map.get(bindings, :"$args") == []
  end

  example constructs_a_tuple_from_name_and_args() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        functor(term, :foo, [1, 2])
      end

    assert Map.get(bindings, :"$term") == {:foo, 1, 2}
  end

  example constructs_an_atomic_term_from_empty_args() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        functor(term, 3, [])
      end

    assert Map.get(bindings, :"$term") == 3
  end

  example fails_when_nothing_is_ground() do
    {:aborted, _} =
      run branch: :examples do
        functor(term, name, args)
      end

    :ok
  end

  example calls_a_constructed_term_as_a_send() do
    {:atomic, {bindings, _state}} =
      run branch: :examples do
        defmethod(:number, :triple, [self, result]) do
          is(result, self * 3)
        end

        functor(term, :triple, [7, out])
        call_term(term)
      end

    assert Map.get(bindings, :"$out") == 21
  end

  example call_term_fails_with_no_receiver() do
    {:aborted, _} =
      run branch: :examples do
        functor(term, :does_not_understand, [])
        call_term(term)
      end

    :ok
  end
end
