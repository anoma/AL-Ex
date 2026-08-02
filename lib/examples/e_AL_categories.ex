defmodule Examples.ALCategories do
  @moduledoc """
  `:object :import` -- binds a shared implementation onto a class with no
  super edge. Logtalk-style categories.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # import attaches methods for a class's instances to resolve, same as any
  # defmethod(SomeClass, ...) -- sending to the class atom itself doesn't work
  # (a class isn't an instance of itself).
  example import_shares_implementation_without_inheritance() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :greeter_behaviour, metaclass: :category, super: :object do
          defmethod(:greet, [self, :hello]) do
          end
        end

        defclass :cat_a, super: :object, ivars: [], categories: [:greeter_behaviour] do
        end

        defclass :cat_b, super: :object, ivars: [], categories: [:greeter_behaviour] do
        end

        new(:cat_a, instance_a)
        new(:cat_b, instance_b)

        greet(instance_a, greeting_a)
        greet(instance_b, greeting_b)
      end

    assert Map.get(bindings, :"$greeting_a") == :hello
    assert Map.get(bindings, :"$greeting_b") == :hello
    :ok
  end

  example import_creates_no_super_edge() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :shared_behaviour, metaclass: :category, super: :object do
          defmethod(:trait, [self, :shared_trait]) do
          end
        end

        defclass :import_a, super: :object, ivars: [], categories: [:shared_behaviour] do
        end

        defclass :import_b, super: :object, ivars: [], categories: [:shared_behaviour] do
        end

        not [super(:import_a, :import_b)]
        not [super(:import_b, :import_a)]
        not [super(:import_a, :shared_behaviour)]

        unify(unrelated, true)
      end

    assert Map.get(bindings, :"$unrelated") == true
    :ok
  end

  example category_is_reflectively_queryable() do
    {:atomic, {bindings, _}} =
      run branch: :examples do
        defclass :reflect_behaviour, metaclass: :category, super: :object do
        end

        class(:reflect_behaviour, kind)
      end

    assert Map.get(bindings, :"$kind") == :category
    :ok
  end

  # a category is a durable :object-classed thing, like a class atom -- must
  # not be offered as an unbound-receiver candidate for its own methods, only
  # copied onto importers. method_scopes's self-prefix guard covers :class but
  # missed :category/:behaviour until this showed up live.
  example category_is_not_offered_as_an_unbound_receiver_candidate() do
    {:atomic, {b1, _}} =
      run branch: :examples do
        defclass :counts_behaviour, metaclass: :category, super: :object do
          defmethod(:count, [self, 0]) do
          end
        end

        defclass :countable, super: :object, ivars: [], categories: [:counts_behaviour] do
        end

        new(:countable, instance)

        findall(s, [count(s, 0)], candidates)
      end

    candidates = Map.get(b1, :"$candidates")
    refute :counts_behaviour in candidates
    assert Map.get(b1, :"$instance") in candidates
    :ok
  end
end
