defmodule Examples.ALPlans do
  use ExExample
  import ExUnit.Assertions

  defp with_branch(callback) do
    parent = %AL.Branch{id: Examples.Support.branch()}
    branch = AL.Branch.fork(:tip, parent)

    try do
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          @query_probe #{super => value}.
          query_probe >> pipeline
          | Self Output |
          select Self token Output.
          query_probe >> select
          | Self Kind Output |
          dispatch Self Kind Output.
          query_probe >> dispatch
          | _Self Kind Output |
          atom Kind,
          = Output Kind.
          """,
          branch
        )

      callback.(branch)
    after
      AL.Branch.discard(branch)
    end
  end

  defp run(selector, args, branch, opts \\ []) do
    AL.eval(
      [%AL.Goal.Send{object: %{class: :query_probe}, method: selector, args: args}],
      nil,
      branch,
      opts
    )
  end

  example known_facts_eliminate_a_chain_of_calls_and_its_atom_filter() do
    with_branch(fn branch ->
      receiver = %{class: :query_probe}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :pipeline), branch)
        end)

      assert plan.inlined == 2
      assert length(elem(plan.compiled, 0)) == 1

      assert {:atomic, {%{"$Output" => :token}, _, _}} =
               run(:pipeline, [{:"$var", "Output"}], branch)
    end)
  end

  example inlined_equalities_evaluate_arithmetic_and_retain_unresolved_constraints() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_probe >> calculated
                 | Self Output |
                 = Local (+ 2 3),
                 dispatch Self number Tag,
                 = Output [Local, Tag].
                 query_probe >> constrained
                 | Self Output |
                 = Local (+ Input 3),
                 dispatch Self number Tag,
                 = Input 2,
                 = Output [Local, Tag].
                 """,
                 branch
               )

      for selector <- [:calculated, :constrained] do
        assert {:atomic, {%{"$Output" => [5, :number]}, _, _}} =
                 run(selector, [{:"$var", "Output"}], branch)
      end
    end)
  end

  example method_edits_invalidate_an_inlined_dependency() do
    with_branch(fn branch ->
      assert {:atomic, _} = run(:pipeline, [{:"$var", "Output"}], branch)

      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> dispatch
          | _Self _Kind Output |
          = Output changed.
          """,
          branch
        )

      assert {:atomic, {%{"$Output" => :changed}, _, _}} =
               run(:pipeline, [{:"$var", "Output"}], branch)
    end)
  end

  example known_compound_fields_and_local_argument_lists_disappear_from_a_plan() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> route
          | Self Output |
          invoke Self (choose answer) Output.
          query_probe >> invoke
          | Self Request Output |
          functor Request Selector Arguments,
          concat Arguments [Output] All,
          send Self Selector All.
          query_probe >> choose
          | _Self Tag Output |
          = Output Tag.
          """,
          branch
        )

      receiver = %{class: :query_probe}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :route), branch)
        end)

      assert plan.inlined >= 4
      [%AL.JAM.CompiledClause{code: code}] = elem(plan.compiled, 0)
      assert tuple_size(code) == 1

      assert {:atomic, {%{"$Output" => :answer}, _, _}} =
               run(:route, [{:"$var", "Output"}], branch)
    end)
  end

  example a_call_site_guards_receiver_values_sharing_a_dispatch_class() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 string >> query_echo
                 | Self Output |
                 query_value Self Output.
                 string >> query_value
                 | Self Output |
                 = Output Self.
                 findall Value Values {member ["one", "two"] Text, query_echo Text Value}.
                 """,
                 branch
               )

      assert bindings["$Values"] == ["one", "two"]
    end)
  end

  example alternatives_retain_answer_order_and_duplicate_answers() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> choices
          | Self Value |
          pick Self Value.
          query_probe >> pick
          | _Self Value |
          = Value first.
          query_probe >> pick
          | _Self Value |
          = Value first.
          query_probe >> pick
          | _Self Value |
          = Value second.
          findall Value Values {choices #{class => query_probe} Value}.
          """,
          branch
        )

      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {choices #{class => query_probe} Value}.
                 """,
                 branch
               )

      assert bindings["$Values"] == [:first, :first, :second]
    end)
  end

  example class_metadata_assumptions_are_guarded() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> typed
          | Self Output |
          classify Self query_marker Output.
          query_probe >> classify
          | _Self Input Output |
          class Input list,
          = Output yes.
          """,
          branch
        )

      assert {:aborted, _} = run(:typed, [{:"$var", "Output"}], branch)
      %AL{result: {:atomic, _}} = AL.run("vm_set_class query_marker list.", branch)

      assert {:atomic, {%{"$Output" => :yes}, _, _}} =
               run(:typed, [{:"$var", "Output"}], branch)
    end)
  end

  example slot_plans_recheck_ivar_specifications_and_method_overrides() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, {%{"$Obj" => object}, _, _}}} =
               AL.run(
                 ~S"""
                 @slot_plan_probe #{
                   super => object,
                   ivars => [#{name => first}, #{name => second}]
                 }.
                 slot_plan_probe >> write_many
                 | Self |
                 set_slot Self first 1,
                 set_slot Self second 2.
                 new slot_plan_probe Obj.
                 """,
                 branch
               )

      args = [bindings: %{"Obj" => object}]

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(object, :write_many), branch)
        end)

      assert Enum.any?(elem(plan.compiled, 0), fn clause ->
               Enum.any?(Tuple.to_list(clause.code), fn
                 {:mutation, :slot_batch, _} -> true
                 _ -> false
               end)
             end)

      assert %AL{result: {:atomic, _}} = AL.run("write_many Obj.", branch, args)

      assert %AL{result: {:aborted, _}} =
               AL.run(
                 ~S"""
                 write_many Obj,
                 set_slot slot_plan_probe ivars [#{name => first}],
                 write_many Obj.
                 """,
                 branch,
                 args
               )

      assert %AL{result: {:atomic, _}} = AL.run("write_many Obj.", branch, args)

      assert %AL{result: {:atomic, _}} =
               AL.run(~S"set_slot slot_plan_probe ivars [#{name => first}].", branch)

      assert %AL{result: {:aborted, _}} = AL.run("write_many Obj.", branch, args)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"set_slot slot_plan_probe ivars [#{name => first}, #{name => second}].",
                 branch
               )

      assert %AL{result: {:atomic, _}} = AL.run("write_many Obj.", branch, args)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 slot_plan_probe >> validate_slot
                 | _Self _Key _Value |
                 fail.
                 """,
                 branch
               )

      assert %AL{result: {:aborted, _}} = AL.run("write_many Obj.", branch, args)
    end)
  end

  example slot_plan_preserves_declared_domains_and_mixed_storage() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, {%{"$Obj" => object}, _, _}}} =
               AL.run(
                 ~S"""
                 @slot_constraint_probe #{
                   super => object,
                   ivars => [#{name => first, domain => [1]}, #{name => second, storage => soa}]
                 }.
                 slot_constraint_probe >> write_many
                 | Self First |
                 set_slot Self first First,
                 set_slot Self second 2.
                 new slot_constraint_probe Obj.
                 """,
                 branch
               )

      assert %AL{result: {:aborted, _}} =
               AL.run("write_many Obj 3.", branch, bindings: %{"Obj" => object})

      assert %AL{result: {:atomic, _}} =
               AL.run("write_many Obj 1.", branch, bindings: %{"Obj" => object})

      assert %AL{result: {:atomic, _}} =
               AL.run("get Obj first 1, get Obj second 2.", branch, bindings: %{"Obj" => object})
    end)
  end

  example ground_set_slots_expands_to_public_writes_with_separate_commands() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, {%{"$Obj" => object}, _, _}}} =
               AL.run(
                 ~S"""
                 @slot_map_probe #{
                   super => object,
                   ivars => [#{name => first}, #{name => second}]
                 }.
                 slot_map_probe >> write_map
                 | Self |
                 set_slots Self #{first => 1, second => 2}.
                 new slot_map_probe Obj.
                 """,
                 branch
               )

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(object, :write_map), branch)
        end)

      assert Enum.any?(elem(plan.compiled, 0), fn clause ->
               Enum.any?(Tuple.to_list(clause.code), fn
                 {:mutation, :slot_batch, _} -> true
                 _ -> false
               end)
             end)

      assert %AL{result: {:atomic, {_, _, state}}} =
               AL.run("write_map Obj.", branch, bindings: %{"Obj" => object})

      {:atomic, commands} =
        :mnesia.transaction(fn -> AL.Command.commands_for_transaction(state.tx_id, branch) end)

      writes =
        Enum.filter(commands, fn
          {:command, _, _, {:set_slot, {^object, _, _, :aos}}} -> true
          _ -> false
        end)

      assert length(writes) == 2

      assert %AL{result: {:atomic, _}} =
               AL.run("get Obj first 1, get Obj second 2.", branch, bindings: %{"Obj" => object})

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 slot_map_probe >> set_slots
                 | Self _Slots |
                 set_slot Self first 9.
                 """,
                 branch
               )

      assert %AL{result: {:atomic, _}} =
               AL.run("write_map Obj, get Obj first 9, get Obj second 2.", branch,
                 bindings: %{"Obj" => object}
               )

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 slot_map_probe >> validate_slot
                 | _Self _Key _Value |
                 fail.
                 """,
                 branch
               )

      assert %AL{result: {:aborted, _}} =
               AL.run("write_map Obj.", branch, bindings: %{"Obj" => object})
    end)
  end

  example effects_stop_planning_before_a_later_class_read() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> changing
          | Self Output |
          change Self,
          after_change Self Output.
          query_probe >> change
          | _Self |
          vm_set_class query_marker list.
          query_probe >> after_change
          | _Self Output |
          class query_marker list,
          = Output yes.
          """,
          branch
        )

      assert {:atomic, {%{"$Output" => :yes}, _, _}} =
               run(:changing, [{:"$var", "Output"}], branch)
    end)
  end

  example cuts_retain_their_method_boundary() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> bounded
          | Self Value |
          limited Self Value.
          query_probe >> limited
          | Self Value |
          option Self Value,
          cut.
          query_probe >> option
          | _Self Value |
          = Value first.
          query_probe >> option
          | _Self Value |
          = Value second.
          """,
          branch
        )

      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {bounded #{class => query_probe} Value}.
                 """,
                 branch
               )

      assert bindings["$Values"] == [:first]
    end)
  end

  example uncertain_head_matching_retains_the_callee_s_missing_method_behavior() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> outer
          | Self Value |
          leaf Self Value.
          query_probe >> leaf
          | _Self wanted |.
          query_probe >> does_not_understand
          | _Self leaf [wrong] |.
          """,
          branch
        )

      assert {:atomic, _} = run(:outer, [:wrong], branch)
    end)
  end

  example a_region_propagates_a_local_selector_across_equality_and_calls() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> region_route
          | Self Output |
          = Selector select,
          send Self Selector [token, Output].
          """,
          branch
        )

      receiver = %{class: :query_probe}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :region_route), branch)
        end)

      assert plan.inlined == 2
      [%AL.JAM.CompiledClause{code: code}] = elem(plan.compiled, 0)
      assert tuple_size(code) == 1

      assert {:atomic, {%{"$Output" => :token}, _, _}} =
               run(:region_route, [{:"$var", "Output"}], branch)
    end)
  end

  example a_region_resumes_local_propagation_after_an_opaque_operation() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> region_boundary
          | Self Input Output |
          boundary_body Self Input Output.
          query_probe >> boundary_body
          | _Self Input Output |
          ground Input,
          = Local (chosen Input),
          functor Local Name Arguments,
          = Output [Name, Arguments].
          """,
          branch
        )

      receiver = %{class: :query_probe}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :region_boundary), branch)
        end)

      [%AL.JAM.CompiledClause{code: code}] = elem(plan.compiled, 0)
      assert tuple_size(code) == 2

      assert {:atomic, {%{"$Output" => [:chosen, [:value]]}, _, _}} =
               run(:region_boundary, [:value, {:"$var", "Output"}], branch)

      assert {:aborted, _} =
               run(:region_boundary, [{:"$var", "Input"}, {:"$var", "Output"}], branch)
    end)
  end

  example escaped_variables_keep_unification_and_suspension_behavior() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> region_suspended
          | Self Output |
          suspended_body Self Output.
          query_probe >> suspended_body
          | _Self Output |
          freeze Local {= Output Local},
          = Local awake.
          """,
          branch
        )

      assert {:atomic, {%{"$Output" => :awake}, _, _}} =
               run(:region_suspended, [{:"$var", "Output"}], branch)
    end)
  end

  example failure_after_a_boundary_retains_the_preceding_operation() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> region_failure
          | Self Input |
          failing_body Self Input.
          query_probe >> failing_body
          | _Self Input |
          ground Input,
          atom [].
          """,
          branch
        )

      receiver = %{class: :query_probe}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :region_failure), branch)
        end)

      [%AL.JAM.CompiledClause{code: code}] = elem(plan.compiled, 0)
      assert [{:ground, _}, :fail] = Tuple.to_list(code)
      assert {:aborted, _} = run(:region_failure, [:value], branch)
    end)
  end

  example region_equality_preserves_aliases_visible_to_the_caller() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> region_alias
          | Self Input Output |
          alias_body Self Input Output.
          query_probe >> alias_body
          | _Self Input Output |
          = Local Input,
          = Output Local,
          = Input token.
          """,
          branch
        )

      assert {:atomic, {bindings, _, _}} =
               run(:region_alias, [{:"$var", "Input"}, {:"$var", "Output"}], branch)

      assert Map.fetch!(bindings, "$Input") == :token
      assert Map.fetch!(bindings, "$Output") == :token

      assert {:aborted, _} =
               run(:region_alias, [:wrong, {:"$var", "Output"}], branch)
    end)
  end

  example rejected_region_expansion_retains_the_profitable_prefix() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> region_fallback
          | Self Output |
          fallback_body Self Output.
          query_probe >> fallback_body
          | Self Output |
          = Tag fixed,
          fallback_pick Self Tag Output.
          query_probe >> fallback_pick
          | _Self fixed Output |
          = Output first.
          query_probe >> fallback_pick
          | _Self fixed Output |
          = Output second.
          """,
          branch
        )

      receiver = %{class: :query_probe}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :region_fallback), branch)
        end)

      assert plan.inlined == 1
      assert length(elem(plan.compiled, 0)) == 1

      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {region_fallback #{class => query_probe} Value}.
                 """,
                 branch
               )

      assert bindings["$Values"] == [:first, :second]
    end)
  end

  example a_selector_established_by_both_alternatives_eliminates_the_send_after_their_join() do
    with_branch(fn branch ->
      %AL{result: {:atomic, _}} =
        AL.run(
          ~S"""
          query_probe >> joined
          | Self Output |
          joined_body Self Output.
          query_probe >> joined_body
          | Self Output |
          (= Selector select ; = Selector select),
          send Self Selector [token, Output].
          """,
          branch
        )

      receiver = %{class: :query_probe}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :joined), branch)
        end)

      assert plan.inlined >= 3
      [%AL.JAM.CompiledClause{code: code}] = elem(plan.compiled, 0)

      refute Enum.any?(Tuple.to_list(code), fn
               {:send, _, _, _, _} -> true
               {:send_local, _, _} -> true
               _ -> false
             end)

      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {joined #{class => query_probe} Value}.
                 """,
                 branch
               )

      assert bindings["$Values"] == [:token, :token]
    end)
  end

  defp provider_plan(branch) do
    receiver = %{class: :query_probe}

    {:atomic, plan} =
      :mnesia.transaction(fn ->
        AL.JAM.IR.Plan.compile(AL.JAM.IR.Call.new(receiver, :inherited), branch)
      end)

    plan
  end

  defp providers(branch) do
    assert %AL{result: {:atomic, _}} =
             AL.run(
               ~S"""
               @query_base #{super => value}.
               @query_middle #{super => query_base}.
               @query_probe #{super => query_middle}.
               query_base >> inherited
               | _Self Input Output |
               = Input [Output . _].
               query_middle >> inherited
               | Self Input Output |
               call_next_method Self Input Output,
               dif Output excluded.
               query_probe >> inherited
               | Self Input Output |
               call_next_method Self Input Output,
               dif Output forbidden.
               """,
               branch
             )
  end

  example nested_provider_regions_preserve_constraints_alternatives_and_invalidation() do
    with_branch(fn branch ->
      providers(branch)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_probe >> inherited_wrapper
                 | Self Input Output |
                 inherited Self Input Output.
                 """,
                 branch
               )

      receiver = %{class: :query_probe}

      {:atomic, plan} =
        :mnesia.transaction(fn ->
          AL.JAM.IR.Plan.compile(
            AL.JAM.IR.Call.new(receiver, :inherited_wrapper),
            branch
          )
        end)

      assert plan.compiled != nil
      assert map_size(plan.providers) == 1

      assert {:atomic, {%{"$Output" => :ok}, _, _}} =
               run(:inherited_wrapper, [[:ok], {:"$var", "Output"}], branch)

      assert {:atomic, {bindings, _, _}} =
               run(:inherited_wrapper, [{:"$var", "Input"}, :ok], branch)

      assert [:ok | _] = bindings["$Input"]

      assert {:aborted, _} =
               run(:inherited_wrapper, [[:excluded], {:"$var", "Output"}], branch)

      assert {:aborted, _} =
               run(:inherited_wrapper, [[:forbidden], {:"$var", "Output"}], branch)

      assert {:atomic, {_, constraints, _}} =
               run(:inherited_wrapper, [{:"$var", "Input"}, {:"$var", "Output"}], branch)

      assert constraints != %{}

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_base >> inherited
                 | _Self _Input Output |
                 {= Output first} ; {= Output excluded} ; {= Output second}.
                 """,
                 branch
               )

      assert {:atomic, false} = :mnesia.transaction(fn -> AL.JAM.IR.Plan.valid?(plan, branch) end)

      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {inherited_wrapper #{class => query_probe} ignored Value}.
                 """,
                 branch
               )

      assert bindings["$Values"] == [:first, :second]
    end)
  end

  example provider_regions_preserve_open_arguments_and_constraints() do
    with_branch(fn branch ->
      providers(branch)
      plan = provider_plan(branch)
      assert plan.compiled != nil
      assert plan.inlined == 2
      assert map_size(plan.providers) == 1

      assert {:atomic, {%{"$Output" => :ok}, _, _}} =
               run(:inherited, [[:ok], {:"$var", "Output"}], branch)

      assert {:atomic, {bindings, _, _}} =
               run(:inherited, [{:"$var", "Input"}, :ok], branch)

      assert [:ok | _] = bindings["$Input"]

      assert {:aborted, _} =
               run(:inherited, [[:excluded], {:"$var", "Output"}], branch)

      assert {:aborted, _} =
               run(:inherited, [[:forbidden], {:"$var", "Output"}], branch)

      assert {:atomic, {_, constraints, _}} =
               run(:inherited, [{:"$var", "Input"}, {:"$var", "Output"}], branch)

      assert constraints != %{}
    end)
  end

  example provider_plans_invalidate_on_inherited_method_edits_and_superclass_changes() do
    with_branch(fn branch ->
      providers(branch)
      plan = provider_plan(branch)

      assert {:atomic, _} =
               run(:inherited, [[:old], {:"$var", "Output"}], branch)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_base >> inherited
                 | _Self _Input Output |
                 = Output changed.
                 """,
                 branch
               )

      assert {:atomic, false} = :mnesia.transaction(fn -> AL.JAM.IR.Plan.valid?(plan, branch) end)

      assert {:atomic, {%{"$Output" => :changed}, _, _}} =
               run(:inherited, [[:old], {:"$var", "Output"}], branch)

      plan = provider_plan(branch)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 @query_other #{super => value}.
                 query_other >> inherited
                 | _Self _Input Output |
                 = Output other.
                 @query_middle #{super => query_other}.
                 """,
                 branch
               )

      assert {:atomic, false} = :mnesia.transaction(fn -> AL.JAM.IR.Plan.valid?(plan, branch) end)

      assert {:atomic, {%{"$Output" => :other}, _, _}} =
               run(:inherited, [[:old], {:"$var", "Output"}], branch)
    end)
  end

  example provider_fusion_retains_alternatives_inside_a_single_provider_body() do
    with_branch(fn branch ->
      providers(branch)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_base >> inherited
                 | _Self _Input Output |
                 {= Output first} ; {= Output second}.
                 """,
                 branch
               )

      assert provider_plan(branch).compiled != nil

      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {inherited #{class => query_probe} ignored Value}.
                 """,
                 branch
               )

      assert bindings["$Values"] == [:first, :second]
    end)
  end

  example multiple_provider_clauses_retain_dispatch_alternatives() do
    with_branch(fn branch ->
      providers(branch)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_base >> inherited
                 | _Self _Input first |.
                 query_base >> inherited
                 | _Self _Input second |.
                 """,
                 branch
               )

      assert provider_plan(branch).compiled == nil

      assert %AL{result: {:atomic, {bindings, _, _}}} =
               AL.run(
                 ~S"""
                 findall Value Values {inherited #{class => query_probe} ignored Value}.
                 """,
                 branch
               )

      assert bindings["$Values"] == [:first, :second]
    end)
  end

  example provider_effects_before_next_and_provider_cuts_retain_method_boundaries() do
    with_branch(fn branch ->
      providers(branch)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_middle >> inherited
                 | Self Input Output |
                 vm_set_class query_marker list,
                 call_next_method Self Input Output.
                 """,
                 branch
               )

      assert provider_plan(branch).compiled == nil

      assert {:atomic, _} =
               run(:inherited, [[:ok], {:"$var", "Output"}], branch)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_middle >> inherited
                 | Self Input Output |
                 call_next_method Self Input Output,
                 cut.
                 """,
                 branch
               )

      assert provider_plan(branch).compiled == nil

      assert {:atomic, _} =
               run(:inherited, [[:ok], {:"$var", "Output"}], branch)
    end)
  end

  example provider_plans_stay_branch_local_and_next_forwards_a_changed_receiver() do
    with_branch(fn branch ->
      providers(branch)

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 query_base >> inherited
                 | Self _Input Output |
                 = Output Self.
                 query_middle >> inherited
                 | _Self Input Output |
                 call_next_method replacement Input Output.
                 """,
                 branch
               )

      assert provider_plan(branch).compiled != nil

      assert {:atomic, {%{"$Output" => :replacement}, _, _}} =
               run(:inherited, [:ignored, {:"$var", "Output"}], branch)

      child = AL.Branch.fork(:tip, branch)

      try do
        assert %AL{result: {:atomic, _}} =
                 AL.run(
                   ~S"""
                   query_base >> inherited
                   | _Self _Input Output |
                   = Output child.
                   """,
                   child
                 )

        assert {:atomic, {%{"$Output" => :child}, _, _}} =
                 run(:inherited, [:ignored, {:"$var", "Output"}], child)

        assert {:atomic, {%{"$Output" => :replacement}, _, _}} =
                 run(:inherited, [:ignored, {:"$var", "Output"}], branch)
      after
        AL.Branch.discard(child)
      end
    end)
  end
end
