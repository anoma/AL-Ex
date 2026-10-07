defmodule Examples.ALGenerative do
  @moduledoc """
  Generative sends: unbound-receiver dispatch hypothesises candidates via
  ordinary head unification, not just durable lookup. super: :value classes
  (number/list included) are tried directly -- clause heads are the whole
  spec, no construction step. Isa-constraint pinning, exclusivity, and
  witness construction from a labeled isa live here too; the open-open
  relational-link mechanism (`class`/`super`/`slot` with both sides
  unbound) is a separate, self-contained feature in `e_AL_pending_links.ex`.
  """

  use ExExample
  use AL
  import ExUnit.Assertions

  # `member(x, 1)` with `x` unbound: like Prolog's `member(1, L)`, backtracking
  # should generate open lists containing `1`, not just search existing objects.
  example member_is_bidirectional() do
    {:atomic, {b1, _constraints, state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        member X 1.
        """
      end

    [h1 | t1] = Map.get(b1, "$X")
    assert h1 == 1
    assert AL.Var.var?(t1)

    {:atomic, {b2, _constraints, _}} = next_solution(state)

    [h2, h3 | t2] = Map.get(b2, "$X")
    assert AL.Var.var?(h2)
    assert h3 == 1
    assert AL.Var.var?(t2)

    state
  end

  # [] candidate lets a recursive list method's base case terminate for an
  # unbound receiver -- else only ever growing cons cells.
  example reverse_grounds_empty_receiver() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        reverse X [].
        """
      end

    assert Map.get(bindings, "$X") == []
    :ok
  end

  # concat runs backwards to find a missing prefix -- recursion terminates
  # because the nested receiver can ground to [].
  example concat_finds_missing_prefix() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        concat X [1, 2] [0, 1, 2].
        """
      end

    assert Map.get(bindings, "$X") == [0]
    :ok
  end

  # reverse(x, y) fully unbound enumerates like Prolog: [] first, then every
  # one-element list, ...
  example reverse_enumerates_both_unbound() do
    {:atomic, {b1, _constraints, state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        reverse X Y.
        """
      end

    assert Map.get(b1, "$X") == []
    assert Map.get(b1, "$Y") == []

    {:atomic, {b2, _constraints, _}} = next_solution(state)

    x2 = Map.get(b2, "$X")
    y2 = Map.get(b2, "$Y")
    assert length(x2) == 1
    assert x2 == y2

    state
  end

  # unbound positions in z are freshened clause-parameter names, must show as
  # generic anonymous vars, not leak the clause's own param name (e.g. concat's
  # "second").
  example unbound_positions_show_as_anonymous_not_internal_names() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        send [] concat Z.
        """
      end

    [a, b] = Map.get(bindings, "$Z")
    assert a == b
    assert AL.Var.var?(a)
    refute AL.Var.name(a) =~ "second"
  end

  # value leg isn't :number-specific -- any class opts in via super: :value.
  # letter_chain has no durable instances, only passes if dispatch tries its
  # clauses directly. Map-wrapped, not a bare atom -- a durable identity is
  # always a bare atom, so a map-shaped member can never collide with one
  # (see durably_classifying_a_value_classs_own_literal_member_fails below
  # for what does).
  example custom_class_opts_into_value_dispatch() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @letter_chain
        #{super => value}.

        letter_chain >> next
        | #{class => letter_chain, letter => a} #{class => letter_chain, letter => b} |.

        letter_chain >> next
        | #{class => letter_chain, letter => b} #{class => letter_chain, letter => c} |.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        next X #{class => letter_chain, letter => b}.
        """
      end

    assert Map.get(bindings, "$X") == %{class: :letter_chain, letter: :a}
  end

  example unbound_send_stays_open_with_a_dispatch_constraint() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @lazy_dispatch_value
        #{super => value}.

        lazy_dispatch_value >> lazy_dispatch_probe
        | _Self reached |.
        """
      end

    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        lazy_dispatch_probe Receiver Result.
        """
      end

    assert AL.Var.var?(Map.fetch!(bindings, "$Receiver"))
    assert Map.fetch!(bindings, "$Result") == :reached

    assert %{
             isa: isa,
             dispatch: [%{selector: :lazy_dispatch_probe, provider: :lazy_dispatch_value}]
           } = Map.fetch!(constraints, "$Receiver")

    assert :lazy_dispatch_value in isa
  end

  example inherited_open_send_accepts_a_later_child_binding() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @lazy_dispatch_parent
        #{super => object}.

        lazy_dispatch_parent >> lazy_dispatch_inherited
        | _Self parent |.

        @lazy_dispatch_child
        #{super => lazy_dispatch_parent}.

        new lazy_dispatch_child #{name => lazy_dispatch_child_instance} Child.
        lazy_dispatch_inherited Receiver Result.
        = Receiver Child.
        """
      end

    assert Map.fetch!(bindings, "$Receiver") == :lazy_dispatch_child_instance
    assert Map.fetch!(bindings, "$Result") == :parent
  end

  example overridden_open_send_uses_the_later_receivers_selected_method() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @lazy_override_parent
        #{super => object}.

        lazy_override_parent >> lazy_override_probe
        | _Self parent |.

        @lazy_override_child
        #{super => lazy_override_parent}.

        lazy_override_child >> lazy_override_probe
        | _Self child |.

        new lazy_override_child #{name => lazy_override_child_instance} Child.
        lazy_override_probe Receiver Result.
        = Receiver Child.
        """
      end

    assert Map.fetch!(bindings, "$Receiver") == :lazy_override_child_instance
    assert Map.fetch!(bindings, "$Result") == :child
  end

  example open_dispatch_partitions_by_the_effective_provider() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @dispatch_partition_parent
        #{super => object}.

        dispatch_partition_parent >> dispatch_partition_probe
        | _Self parent |.

        @dispatch_partition_override
        #{super => dispatch_partition_parent}.

        dispatch_partition_override >> dispatch_partition_probe
        | _Self override |.

        @dispatch_partition_inheritor
        #{super => dispatch_partition_parent}.

        new dispatch_partition_parent #{name => dispatch_partition_parent_instance} _.
        new dispatch_partition_override #{name => dispatch_partition_override_instance} _.
        new dispatch_partition_inheritor #{name => dispatch_partition_inheritor_instance} _.
        findall [Receiver, Result] Answers {dispatch_partition_probe Receiver Result, label Receiver}.
        """
      end

    assert MapSet.new(Map.fetch!(bindings, "$Answers")) ==
             MapSet.new([
               [:dispatch_partition_parent_instance, :parent],
               [:dispatch_partition_override_instance, :override],
               [:dispatch_partition_inheritor_instance, :parent]
             ])
  end

  example labeling_intersecting_isa_constraints_selects_a_common_direct_class() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @label_left_parent
        #{super => value}.

        @label_right_parent
        #{super => value}.

        @label_common_child
        #{super => [label_left_parent, label_right_parent, value]}.

        label_common_child >> init
        | _Self _Args New |
        = New #{class => label_common_child}.

        isa Object label_left_parent.
        isa Object label_right_parent.
        label Object.
        """
      end

    assert Map.fetch!(bindings, "$Object") == %{class: :label_common_child}
  end

  # A bare atom in a value class's own literal clause is structurally
  # indistinguishable from durable identity -- rejected right at definition
  # time (:defmethod's own body), before it could ever be durably classified
  # into the same class and become reachable both ways for the same fact.
  example bare_atom_self_on_a_value_class_fails_at_definition_time() do
    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @letter_chain_antipattern
        #{super => value}.

        letter_chain_antipattern >> a
        | a |.
        """
      end

    :ok
  end

  # reaching the value leg pins self to that class -- not :number-specific.
  # letter_word's clause leaves self open; later bind to a non-letter_word
  # must fail, bind to a real one must succeed.
  example custom_value_class_pins_an_open_receiver_too() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @letter_word
        #{super => value}.

        letter_word >> letter_word_stays_open
        | Self |.

        vm_set_class letter_word_real_instance letter_word.
        """
      end

    {:aborted, _trace} =
      run branch: Examples.Support.branch() do
        ~AL"""
        letter_word_stays_open X.
        = X not_a_letter_word.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        letter_word_stays_open X.
        = X letter_word_real_instance.
        """
      end

    assert Map.get(bindings, "$X") == :letter_word_real_instance
  end

  # value candidate's isa constraint attaches before its clause runs, live for
  # the clause body, nested sends included: chain_from can call next while
  # self is still open, and confirm_class can ask self's class while
  # undetermined and get a real answer, no durable-table scan. Map-wrapped
  # members again, same reasoning as custom_class_opts_into_value_dispatch.
  example value_clause_body_sees_its_own_isa_constraint() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @letter_chain_reflective
        #{super => value}.

        letter_chain_reflective >> next
        | #{class => letter_chain_reflective, letter => a} #{class => letter_chain_reflective, letter => b} |.

        letter_chain_reflective >> next
        | #{class => letter_chain_reflective, letter => b} #{class => letter_chain_reflective, letter => c} |.

        letter_chain_reflective >> chain_from
        | Self First |
        next Self First.

        letter_chain_reflective >> confirm_class
        | Self Result |
        isa Self Result.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        chain_from X #{class => letter_chain_reflective, letter => b}.
        """
      end

    assert Map.get(bindings, "$X") == %{class: :letter_chain_reflective, letter: :a}

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        confirm_class Y C.
        """
      end

    assert Map.get(bindings, "$C") == :letter_chain_reflective
    assert AL.Var.var?(Map.get(bindings, "$Y"))
  end

  # Two unrelated `super: :value` classes are mutually exclusive on the same
  # var -- a value is single-classed by construction, the same invariant that
  # already ruled out :number/:list/:map coexisting. `class/2` (the ergonomic
  # `class` wrapper, inherited from :object) used to let this slip through:
  # `GetClass`'s no-witness-needed isa fast path unioned in a second,
  # contradictory class with no check at all.
  example unrelated_value_classes_conflict_on_the_same_var() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @left_value_class
        #{super => value}.

        @right_value_class
        #{super => value}.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X left_value_class.
        isa X right_value_class.
        """
      end

    :ok
  end

  # `isa_conflict?/3` used to only fire when the *incoming* class was itself
  # exclusive (a `:number`/`:list`/`:map`/`super: :value` shape class) --
  # pinning an unrelated, non-exclusive durable class (`super: :object`, not
  # `:value`) on top of an already shape-committed var sailed through
  # unchecked, producing an unsatisfiable isa set like `{:number,
  # :some_durable_class}` (nothing can be both a generative number-value and
  # a durable object). Found via `class(x, :program_execution)` on the AL.TransactionProgram.
  example exclusive_class_conflicts_with_unrelated_durable_class() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @ghost_value_class
        #{super => value}.

        @ghost_durable_class
        #{super => object}.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X ghost_value_class.
        isa X ghost_durable_class.
        """
      end

    :ok
  end

  # `:class` is inherited from :object, so an unbound receiver's dispatch
  # offers it from every generative candidate -- here, both the unrelated
  # value classes above. Before the fix, the wrong candidate's `class/2` call
  # silently succeeded (contradictory isa unioned in, no witness ever
  # constructed), so `findall` reported the same fact once per candidate
  # instead of once. Bug found via :blackjack package's :card class.
  example class_dispatch_does_not_report_ghost_duplicates() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @ghost_left
        #{super => value}.

        @ghost_right
        #{super => value}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        findall X Xs (isa X ghost_right).
        """
      end

    assert length(Map.get(bindings, "$Xs")) == 1
  end

  example labeling_an_isa_constrained_var_constructs_a_real_witness() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X card.
        label X.
        get X suit Suit.
        """
      end

    assert %{class: :card} = Map.get(bindings, "$X")
    assert AL.Var.var?(Map.get(bindings, "$Suit"))
    :ok
  end

  example labeling_a_list_selects_an_outer_constructor() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X list.
        label X.
        """
      end

    assert Map.get(bindings, "$X") == []

    {:atomic, {next_bindings, _constraints, _}} = next_solution(state)
    [_head | tail] = Map.get(next_bindings, "$X")
    assert AL.Var.var?(tail)
    :ok
  end

  example labeling_a_value_class_without_a_witness_fails() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @open_value_without_witness
        #{super => value}.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X open_value_without_witness.
        label X.
        """
      end

    :ok
  end

  example labeling_uses_transitive_value_inheritance() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @inherited_value_parent
        #{super => value, ivars => [#{name => payload}]}.

        @inherited_value_child
        #{super => inherited_value_parent}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        class X inherited_value_child.
        label X.
        """
      end

    assert %{class: :inherited_value_child} = Map.get(bindings, "$X")
    :ok
  end

  example labeling_a_number_uses_its_finite_constraint_domain() do
    {:atomic, {bindings, _constraints, state}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X number.
        >= X 2.
        <= X 3.
        label X.
        """
      end

    assert Map.get(bindings, "$X") == 2
    {:atomic, {next_bindings, _constraints, _}} = next_solution(state)
    assert Map.get(next_bindings, "$X") == 3
    :ok
  end

  example labeling_an_isa_with_only_a_durable_witness_finds_it() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @durable_witness_class
        #{super => object}.

        new durable_witness_class #{} Obj.
        """
      end

    obj = Map.get(bindings, "$Obj")

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X durable_witness_class.
        label X.
        """
      end

    assert Map.get(bindings, "$X") == obj
    :ok
  end

  example dispatch_finds_a_durable_witness_classed_as_a_descendant_of_a_known_isa() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @isa_descendant_parent
        #{super => object}.

        isa_descendant_parent >> isa_descendant_probe
        | Self hit |.

        @isa_descendant_child
        #{super => isa_descendant_parent}.

        new isa_descendant_child #{} Obj.
        """
      end

    obj = Map.get(bindings, "$Obj")

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X isa_descendant_parent.
        isa_descendant_probe X R.
        label X.
        """
      end

    assert Map.get(bindings, "$X") == obj
    assert Map.get(bindings, "$R") == :hit
    :ok
  end

  # No generative descendant and no durable object satisfy the isa -- fails
  # exactly like an unbounded numeric domain always has, not a crash.
  example labeling_an_isa_with_no_witness_fails() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @witnessless_durable_class
        #{super => object}.
        """
      end

    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa X witnessless_durable_class.
        label X.
        """
      end

    :ok
  end

  # `class`/`super`/`slot` with both sides open posting a pending
  # link + label/auto-propagate resolution is a self-contained feature --
  # see `e_AL_pending_links.ex`.

  # :value classes construct through the real new pipeline
  # (construct/allocate/init), not special-cased -- init discards the
  # scaffold, result stays as open as it started. No durable object created.
  example new_on_a_value_class_stays_open_not_durable() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @letter_symbol
        #{super => value}.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new letter_symbol Obj.
        """
      end

    assert AL.Var.var?(Map.get(bindings, "$Obj"))
  end

  # one clause, two directions: forward is ordinary dispatch (real square
  # computes area from side). Backward invents a square -- fresh instance
  # with side open, area's own body narrows it via generate-and-test
  # (between), same idiom as number's backward factorial.
  example squares_compute_area_forward_and_backward() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @square
        #{super => value, ivars => [#{name => side}]}.

        square >> init
        | Self Args New |
        get Args side Side,
        = New #{class => square, side => Side}.

        square >> get
        | Self K V |
        map_get Self K V.

        square >> area
        | #{class => square, side => Side} Result |
        ground Side -> = Result (* Side Side) ; {
          ground Result,
          between Self 1 Result Side,
          = Check (* Side Side),
          = Check Result
        }.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new square #{side => 4} Sq.
        area Sq A.
        """
      end

    assert Map.get(bindings, "$A") == 16

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        area X 16.
        """
      end

    invented = Map.get(bindings, "$X")
    assert invented.side == 4
  end

  # classic "count ways to make change": try the largest denomination again
  # or drop to the next-smaller. findall turns the backtracking search into
  # one list. Dispatched via a :coins instance, not the class atom itself --
  # method_scopes excludes a class/category/behaviour receiver from its own
  # scope chain, an ordinary instance doesn't hit that rule.
  # coin_change_oracle is the same algorithm in plain Elixir, cross-checked
  # against the AL search to prove every solution was found.
  example thirty_cents_change_via_backtracking() do
    {:atomic, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new class #{ivars => [], name => coins, super => object} _.

        coins >> change
        | Self 0 _Denoms [] |.

        coins >> change
        | Self Amount [C . Rest] [C . Combo] |
        >= Amount C,
        = Remaining (- Amount C),
        change Self Remaining [C . Rest] Combo.

        coins >> change
        | Self Amount [_C . Rest] Combo |
        > Amount 0,
        change Self Amount Rest Combo.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        new coins Coins.
        findall Combo All (change Coins 30 [25, 10, 5, 1] Combo).
        """
      end

    combos = Map.get(bindings, "$All")

    assert Enum.all?(combos, fn combo -> Enum.sum(combo) == 30 end)
    assert [25, 5] in combos
    assert [10, 10, 10] in combos
    assert List.duplicate(1, 30) in combos
    assert length(combos) == length(coin_change_oracle(30, [25, 10, 5, 1]))
  end

  defp coin_change_oracle(0, _denoms), do: [[]]
  defp coin_change_oracle(_amount, []), do: []

  defp coin_change_oracle(amount, [c | rest] = denoms) do
    with_c =
      if amount >= c,
        do: for(combo <- coin_change_oracle(amount - c, denoms), do: [c | combo]),
        else: []

    coin_change_oracle(amount, rest) ++ with_c
  end

  example unbound_but_constrained_vars_surface_in_constraints() do
    {:atomic, {bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        isa O class.
        """
      end

    assert AL.Var.var?(Map.get(bindings, "$O"))
    assert constraints == %{"$O" => %{isa: [:class]}}
    :ok
  end

  example unconstrained_vars_have_no_constraints_entry() do
    {:atomic, {_bindings, constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = X 5.
        """
      end

    assert constraints == %{}
    :ok
  end

  example labeling_a_durable_object_preserves_following_goals() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @labeled_vehicle
        #{super => object, ivars => [#{name => color}]}.

        new labeled_vehicle #{color => red, name => labeled_car} _.
        class Vehicle labeled_vehicle.
        label Vehicle.
        get Vehicle color Color.
        """
      end

    assert Map.fetch!(bindings, "$Vehicle") == :labeled_car
    assert Map.fetch!(bindings, "$Color") == :red
    :ok
  end

  example direct_class_constraints_narrow_unbound_receiver_dispatch() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @dispatch_vehicle
        #{super => value}.

        dispatch_vehicle >> dispatch_kind
        | _Self vehicle |.

        @dispatch_car
        #{super => [dispatch_vehicle, value]}.

        dispatch_car >> dispatch_kind
        | _Self car |.

        findall Kind Exact {class Receiver dispatch_vehicle, dispatch_kind Receiver Kind}.
        findall Kind Inherited {isa Receiver dispatch_vehicle, dispatch_kind Receiver Kind}.
        """
      end

    assert Map.get(bindings, "$Exact") == [:vehicle]
    assert Enum.sort(Map.get(bindings, "$Inherited")) == [:car, :vehicle]
  end

  example value_membership_uses_its_explicit_branch() do
    branch_id = Examples.Support.branch()
    branch = %AL.Branch{id: branch_id}

    {:atomic, _} =
      run branch: branch_id do
        ~AL"""
        @explicit_branch_value
        #{super => value}.

        explicit_branch_value >> identify
        | #{class => explicit_branch_value, name => member} member |.
        """
      end

    :erlang.trace(self(), true, [:call])
    :erlang.trace_pattern({AL.Branch, :head, 0}, true, [:local])

    try do
      assert {:atomic, true} =
               :mnesia.transaction(fn ->
                 AL.Dispatch.value_member?(
                   %{class: :explicit_branch_value, name: :member},
                   :explicit_branch_value,
                   branch
                 )
               end)

      refute_receive {:trace, _pid, :call, {AL.Branch, :head, []}}
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({AL.Branch, :head, 0}, false, [:local])
    end
  end
end
