defmodule Examples.ALObjects do
  @moduledoc """
  I provide object creation and metaclass examples for AL
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  example defmethod() do
    {:atomic, {bindings, _}} =
      run do
        new(:class, %{name: :greeter, super: :ephemeral, slots: []}, _)

        defmethod(:greeter, :greet, [self, name]) do
        end

        new(:greeter, _, instance)
        greet(instance, :world)
      end

    assert Map.get(bindings, :"$instance") == %{class: :greeter}
    :ok
  end

  example make_point_object() do
    {:atomic, {bindings, result}} =
      run do
        new(:class, %{name: :point, super: :ephemeral, slots: []}, new_point_class)
        new(new_point_class, _, new_point_object)
        cut
      end

    assert Map.get(bindings, :"$new_point_class") == :point
    assert Map.get(bindings, :"$new_point_object") == %{class: :point}

    result
  end

  example metaclass_alloc_override() do
    {:atomic, {b, program_state}} =
      run do
        new(:class, %{name: :durable_meta, super: :object, slots: []}, _)

        defmethod(:durable_meta, :allocate, [self, args, name]) do
          map_get(args, :name, name)
          map_get(args, :slots, slots)

          class(self, meta)

          set_class(name, meta)
          set_super(name, :object)
          set_slots(name, slots)
        end

        new(:durable_meta, %{slots: [], name: :alloc_overriden}, obj)

        class(obj, obj_class)
      end

    assert is_atom(Map.get(b, :"$obj"))
    assert Map.get(b, :"$obj_class") == :durable_meta

    program_state
  end

  example defmethod_accretes_clauses() do
    {:atomic, _} =
      run do
        set_class(:multi, :object)
        defmethod(:multi, :pick, [self, :a, :first]) do end
        defmethod(:multi, :pick, [self, :b, :second]) do end
      end

    # both clauses are reachable on the same method
    {:atomic, {b1, _}} = run do pick(:multi, :a, r) end
    {:atomic, {b2, _}} = run do pick(:multi, :b, r) end

    assert Map.get(b1, :"$r") == :first
    assert Map.get(b2, :"$r") == :second

    # the two defmethods accreted clauses onto one id, not two separate methods
    {:atomic, {b3, _}} = run do findall(id, [method(:multi, :pick, id)], ids) end
    assert length(Enum.uniq(Map.get(b3, :"$ids"))) == 1
    :ok
  end

  example examine() do
    {:atomic, {bindings, program_state}} =
      run do
        examine(:class, info)
        map_get(info, :methods, methods)
        map_get(info, :classes, classes)
        map_get(info, :supers, supers)
      end

    assert Map.get(bindings, :"$classes") == [:class]
    assert Map.get(bindings, :"$supers") == [:object]

    program_state
  end

  # A send to an unbound receiver is a query over the store: it grounds `self`
  # to a concrete object that understands the method (and backtracks over the
  # rest), rather than running the body with `self` still an internal var.
  example anonymous_send_grounds_receiver() do
    {:atomic, _} =
      run do
        set_class(:ping_class, :object)
        defmethod(:ping_class, :ping, [self, :pong]) do end
        set_class(:ping_a, :ping_class)
        set_class(:ping_b, :ping_class)
      end

    {:atomic, {b, _}} = run do ping(o, r) end
    first = Map.get(b, :"$o")

    assert is_atom(first) and not AL.Var.var?(first)

    # backtracking enumerates the candidate receivers: every solution grounds
    # `self` to a concrete object (never a leaked internal var), and for our two
    # instances the method actually runs, binding its argument to :pong
    {:atomic, {b2, _}} = run do findall([o, r], [ping(o, r)], pairs) end
    pairs = Map.get(b2, :"$pairs")

    assert Enum.all?(pairs, fn [o, _r] -> is_atom(o) and not AL.Var.var?(o) end)
    assert [:ping_a, :pong] in pairs
    assert [:ping_b, :pong] in pairs
    :ok
  end
end
