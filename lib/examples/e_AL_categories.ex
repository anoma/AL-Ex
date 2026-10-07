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
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @greeter_behaviour
        #{super => object, metaclass => category}.

        greeter_behaviour >> greet
        | Self hello |.

        @cat_a
        #{super => object, categories => [greeter_behaviour]}.

        @cat_b
        #{super => object, categories => [greeter_behaviour]}.

        new cat_a InstanceA.
        new cat_b InstanceB.
        greet InstanceA GreetingA.
        greet InstanceB GreetingB.
        """
      end

    assert Map.get(bindings, "$GreetingA") == :hello
    assert Map.get(bindings, "$GreetingB") == :hello
    :ok
  end

  example import_creates_no_super_edge() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @shared_behaviour
        #{super => object, metaclass => category}.

        shared_behaviour >> trait
        | Self shared_trait |.

        @import_a
        #{super => object, categories => [shared_behaviour]}.

        @import_b
        #{super => object, categories => [shared_behaviour]}.

        not (super import_a import_b).
        not (super import_b import_a).
        not (super import_a shared_behaviour).
        = Unrelated true.
        """
      end

    assert Map.get(bindings, "$Unrelated") == true
    :ok
  end

  example category_is_reflectively_queryable() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @reflect_behaviour
        #{super => object, metaclass => category}.

        class reflect_behaviour Kind.
        """
      end

    assert Map.get(bindings, "$Kind") == :category
    :ok
  end

  # a category is a durable :object-classed thing, like a class atom -- must
  # not be offered as an unbound-receiver candidate for its own methods, only
  # copied onto importers. method_scopes's self-prefix guard covers :class but
  # missed :category/:behaviour until this showed up live.
  example category_is_not_offered_as_an_unbound_receiver_candidate() do
    {:atomic, {b1, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @counts_behaviour
        #{super => object, metaclass => category}.

        counts_behaviour >> count
        | Self 0 |.

        @countable
        #{super => object, categories => [counts_behaviour]}.

        new countable Instance.
        findall S Candidates {count S 0, label S}.
        """
      end

    candidates = Map.get(b1, "$Candidates")
    refute :counts_behaviour in candidates
    assert Map.get(b1, "$Instance") in candidates
    :ok
  end
end
