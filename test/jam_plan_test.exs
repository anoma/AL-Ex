defmodule AL.JAM.PlanTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.Branch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    {:atomic, _} =
      AL.eval_source(
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

    %{branch: branch}
  end

  defp run(selector, args, branch, opts \\ []) do
    AL.eval(
      [%AL.Goal.Send{object: %{class: :query_probe}, method: selector, args: args}],
      nil,
      branch,
      opts
    )
  end

  test "known facts eliminate a chain of calls and its atom filter", %{branch: branch} do
    receiver = %{class: :query_probe}

    {:atomic, plan} =
      :mnesia.transaction(fn ->
        AL.JAM.IR.Plan.compile(receiver, :pipeline, [{receiver, 0}], branch)
      end)

    assert plan.inlined == 2
    assert length(elem(plan.compiled, 0)) == 1

    assert {:atomic, {%{"$Output" => :token}, _, _}} =
             run(:pipeline, [{:"$var", "Output"}], branch)
  end

  test "inlined equalities evaluate arithmetic and retain unresolved constraints", %{
    branch: branch
  } do
    assert {:atomic, _} =
             AL.eval_source(
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
  end

  test "method edits invalidate an inlined dependency", %{branch: branch} do
    assert {:atomic, _} = run(:pipeline, [{:"$var", "Output"}], branch)

    {:atomic, _} =
      AL.eval_source(
        ~S"""
        query_probe >> dispatch
        | _Self _Kind Output |
        = Output changed.
        """,
        branch
      )

    assert {:atomic, {%{"$Output" => :changed}, _, _}} =
             run(:pipeline, [{:"$var", "Output"}], branch)
  end

  test "known compound fields and local argument lists disappear from a plan", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
        AL.JAM.IR.Plan.compile(receiver, :route, [{receiver, 0}], branch)
      end)

    assert plan.inlined >= 4
    [{_, _, _, _, code, _}] = elem(plan.compiled, 0)
    assert tuple_size(code) == 1
    assert {:atomic, {%{"$Output" => :answer}, _, _}} = run(:route, [{:"$var", "Output"}], branch)
  end

  test "a call site guards receiver values sharing a dispatch class", %{branch: branch} do
    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
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
  end

  test "alternatives retain answer order and duplicate answers", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Value Values {choices #{class => query_probe} Value}.
               """,
               branch
             )

    assert bindings["$Values"] == [:first, :first, :second]
  end

  test "class metadata assumptions are guarded", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
    {:atomic, _} = AL.eval_source("vm_set_class query_marker list.", branch)
    assert {:atomic, {%{"$Output" => :yes}, _, _}} = run(:typed, [{:"$var", "Output"}], branch)
  end

  test "effects stop planning before a later class read", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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

    assert {:atomic, {%{"$Output" => :yes}, _, _}} = run(:changing, [{:"$var", "Output"}], branch)
  end

  test "cuts retain their method boundary", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Value Values {bounded #{class => query_probe} Value}.
               """,
               branch
             )

    assert bindings["$Values"] == [:first]
  end

  test "uncertain head matching retains the callee's missing-method behavior", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
  end

  test "a region propagates a local selector across equality and calls", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
        AL.JAM.IR.Plan.compile(receiver, :region_route, [{receiver, 0}], branch)
      end)

    assert plan.inlined == 2
    [{_, _, _, _, code, _}] = elem(plan.compiled, 0)
    assert tuple_size(code) == 1

    assert {:atomic, {%{"$Output" => :token}, _, _}} =
             run(:region_route, [{:"$var", "Output"}], branch)
  end

  test "a region resumes local propagation after an opaque operation", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
        AL.JAM.IR.Plan.compile(receiver, :region_boundary, [{receiver, 0}], branch)
      end)

    [{_, _, _, _, code, _}] = elem(plan.compiled, 0)
    assert tuple_size(code) == 2

    assert {:atomic, {%{"$Output" => [:chosen, [:value]]}, _, _}} =
             run(:region_boundary, [:value, {:"$var", "Output"}], branch)

    assert {:aborted, _} =
             run(:region_boundary, [{:"$var", "Input"}, {:"$var", "Output"}], branch)
  end

  test "escaped variables keep unification and suspension behavior", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
  end

  test "failure after a boundary retains the preceding operation", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
        AL.JAM.IR.Plan.compile(receiver, :region_failure, [{receiver, 0}], branch)
      end)

    [{_, _, _, _, code, _}] = elem(plan.compiled, 0)
    assert [{:ground, _}, :fail] = Tuple.to_list(code)
    assert {:aborted, _} = run(:region_failure, [:value], branch)
  end

  test "region equality preserves aliases visible to the caller", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
    assert {:aborted, _} = run(:region_alias, [:wrong, {:"$var", "Output"}], branch)
  end

  test "rejected region expansion retains the profitable prefix", %{branch: branch} do
    {:atomic, _} =
      AL.eval_source(
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
        AL.JAM.IR.Plan.compile(receiver, :region_fallback, [{receiver, 0}], branch)
      end)

    assert plan.inlined == 1
    assert length(elem(plan.compiled, 0)) == 1

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Value Values {region_fallback #{class => query_probe} Value}.
               """,
               branch
             )

    assert bindings["$Values"] == [:first, :second]
  end

  test "a selector established by both alternatives eliminates the send after their join", %{
    branch: branch
  } do
    {:atomic, _} =
      AL.eval_source(
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
        AL.JAM.IR.Plan.compile(receiver, :joined, [{receiver, 0}], branch)
      end)

    assert plan.inlined >= 3
    [{_, _, _, _, code, _}] = elem(plan.compiled, 0)

    refute Enum.any?(Tuple.to_list(code), fn
             {:send, _, _, _, _} -> true
             {:send_local, _, _} -> true
             _ -> false
           end)

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Value Values {joined #{class => query_probe} Value}.
               """,
               branch
             )

    assert bindings["$Values"] == [:token, :token]
  end

  defp provider_plan(branch) do
    receiver = %{class: :query_probe}

    {:atomic, plan} =
      :mnesia.transaction(fn ->
        AL.JAM.IR.Plan.compile(receiver, :inherited, [{receiver, 0}], branch)
      end)

    plan
  end

  defp providers(branch) do
    assert {:atomic, _} =
             AL.eval_source(
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

  test "nested provider regions preserve constraints, alternatives and invalidation", %{
    branch: branch
  } do
    providers(branch)

    assert {:atomic, _} =
             AL.eval_source(
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
        AL.JAM.IR.Plan.compile(receiver, :inherited_wrapper, [{receiver, 0}], branch)
      end)

    assert plan.compiled != nil
    assert map_size(plan.providers) == 1

    assert {:atomic, {%{"$Output" => :ok}, _, _}} =
             run(:inherited_wrapper, [[:ok], {:"$var", "Output"}], branch)

    assert {:atomic, {bindings, _, _}} =
             run(:inherited_wrapper, [{:"$var", "Input"}, :ok], branch)

    assert [:ok | _] = bindings["$Input"]
    assert {:aborted, _} = run(:inherited_wrapper, [[:excluded], {:"$var", "Output"}], branch)
    assert {:aborted, _} = run(:inherited_wrapper, [[:forbidden], {:"$var", "Output"}], branch)

    assert {:atomic, {_, constraints, _}} =
             run(:inherited_wrapper, [{:"$var", "Input"}, {:"$var", "Output"}], branch)

    assert constraints != %{}

    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               query_base >> inherited
               | _Self _Input Output |
               {= Output first} ; {= Output excluded} ; {= Output second}.
               """,
               branch
             )

    assert {:atomic, false} = :mnesia.transaction(fn -> AL.JAM.IR.Plan.valid?(plan, branch) end)

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Value Values {inherited_wrapper #{class => query_probe} ignored Value}.
               """,
               branch
             )

    assert bindings["$Values"] == [:first, :second]
  end

  test "provider regions preserve open arguments and constraints", %{branch: branch} do
    providers(branch)
    plan = provider_plan(branch)
    assert plan.compiled != nil
    assert plan.inlined == 2
    assert map_size(plan.providers) == 1

    assert {:atomic, {%{"$Output" => :ok}, _, _}} =
             run(:inherited, [[:ok], {:"$var", "Output"}], branch)

    assert {:atomic, {bindings, _, _}} = run(:inherited, [{:"$var", "Input"}, :ok], branch)
    assert [:ok | _] = bindings["$Input"]
    assert {:aborted, _} = run(:inherited, [[:excluded], {:"$var", "Output"}], branch)
    assert {:aborted, _} = run(:inherited, [[:forbidden], {:"$var", "Output"}], branch)

    assert {:atomic, {_, constraints, _}} =
             run(:inherited, [{:"$var", "Input"}, {:"$var", "Output"}], branch)

    assert constraints != %{}
  end

  test "provider plans invalidate on inherited method edits and superclass changes", %{
    branch: branch
  } do
    providers(branch)
    plan = provider_plan(branch)
    assert {:atomic, _} = run(:inherited, [[:old], {:"$var", "Output"}], branch)

    assert {:atomic, _} =
             AL.eval_source(
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

    assert {:atomic, _} =
             AL.eval_source(
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
  end

  test "provider fusion retains alternatives inside a single provider body", %{branch: branch} do
    providers(branch)

    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               query_base >> inherited
               | _Self _Input Output |
               {= Output first} ; {= Output second}.
               """,
               branch
             )

    assert provider_plan(branch).compiled != nil

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Value Values {inherited #{class => query_probe} ignored Value}.
               """,
               branch
             )

    assert bindings["$Values"] == [:first, :second]
  end

  test "multiple provider clauses retain dispatch alternatives", %{branch: branch} do
    providers(branch)

    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               query_base >> inherited
               | _Self _Input first |.
               query_base >> inherited
               | _Self _Input second |.
               """,
               branch
             )

    assert provider_plan(branch).compiled == nil

    assert {:atomic, {bindings, _, _}} =
             AL.eval_source(
               ~S"""
               findall Value Values {inherited #{class => query_probe} ignored Value}.
               """,
               branch
             )

    assert bindings["$Values"] == [:first, :second]
  end

  test "provider effects before next and provider cuts retain method boundaries", %{
    branch: branch
  } do
    providers(branch)

    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               query_middle >> inherited
               | Self Input Output |
               vm_set_class query_marker list,
               call_next_method Self Input Output.
               """,
               branch
             )

    assert provider_plan(branch).compiled == nil
    assert {:atomic, _} = run(:inherited, [[:ok], {:"$var", "Output"}], branch)

    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               query_middle >> inherited
               | Self Input Output |
               call_next_method Self Input Output,
               cut.
               """,
               branch
             )

    assert provider_plan(branch).compiled == nil
    assert {:atomic, _} = run(:inherited, [[:ok], {:"$var", "Output"}], branch)
  end

  test "provider plans stay branch local and next forwards a changed receiver", %{branch: branch} do
    providers(branch)

    assert {:atomic, _} =
             AL.eval_source(
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
    on_exit(fn -> AL.Branch.discard(child) end)

    assert {:atomic, _} =
             AL.eval_source(
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
  end
end
