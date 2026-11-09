defmodule Examples.ALPlanStore do
  use ExExample
  import ExUnit.Assertions
  alias AL.PlanStore
  alias AL.PlanStore.Implementation

  defp with_branch(fun) do
    branch = AL.Branch.fork()

    try do
      fun.(branch)
    after
      AL.Branch.discard(branch)
    end
  end

  defp transaction(fun) do
    :mnesia.transaction(fn -> AL.ResolutionCache.with_transaction_cache(fun) end)
  end

  defp method(branch, compute) do
    PlanStore.fetch_method(branch, :store_probe, compute)
  end

  example code_is_retained_between_transactions() do
    with_branch(fn branch ->
      assert {:atomic, original} =
               transaction(fn -> method(branch, fn -> Enum.to_list(1..1000) end) end)

      assert {:atomic, reused} =
               transaction(fn -> method(branch, fn -> flunk("recomputed") end) end)

      assert :erts_debug.same(original, reused)
    end)
  end

  example unsuccessful_compilation_is_retried_after_invalidation() do
    with_branch(fn branch ->
      assert {:atomic, :ok} =
               transaction(fn ->
                 assert PlanStore.fetch(branch, :store_probe, %{}, fn -> nil end) == nil

                 assert PlanStore.fetch(branch, :store_probe, %{}, fn ->
                          flunk("repeated unsuccessful compilation")
                        end) == nil

                 PlanStore.invalidate_method(branch, :store_probe)
                 assert method(branch, fn -> :replacement end) == :replacement
                 :ok
               end)
    end)
  end

  example implementation_choices_are_shared_and_recheck_dependencies() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 @selection_probe #{super => value}.
                 selection_probe >> payload
                 | _Self original |.
                 """,
                 branch
               )

      assert {:atomic, {dependency, implementation}} =
               transaction(fn ->
                 {:ok, _, dependency} =
                   AL.Dispatch.target(%{class: :selection_probe}, :payload, branch)

                 implementation =
                   PlanStore.select(branch, :store_probe, fn _ -> true end, fn ->
                     %Implementation{
                       code: :original,
                       dependencies: %{
                         {:method, %{class: :selection_probe}, :payload} =>
                           {dependency, AL.JAM.Clauses.cached_scan_clauses(dependency, branch)}
                       }
                     }
                   end)

                 {dependency, implementation}
               end)

      assert {:atomic, ^implementation} =
               Task.async(fn ->
                 transaction(fn ->
                   PlanStore.select(branch, :store_probe, fn _ -> true end, fn ->
                     flunk("recomputed implementation choice")
                   end)
                 end)
               end)
               |> Task.await()

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 selection_probe >> payload
                 | _Self updated |.
                 """,
                 branch
               )

      assert {:atomic, %Implementation{code: :replacement}} =
               transaction(fn ->
                 refute {dependency, AL.JAM.Clauses.cached_scan_clauses(dependency, branch)} ==
                          implementation.dependencies[
                            {:method, %{class: :selection_probe}, :payload}
                          ]

                 PlanStore.select(branch, :store_probe, fn _ -> true end, fn ->
                   %Implementation{code: :replacement}
                 end)
               end)
    end)
  end

  example unchanged_implementations_are_reconsidered_for_more_informative_arguments() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 @selection_probe #{super => value}.
                 selection_probe >> checked_payload
                 | _Self Input Output |
                 payload Input Output.
                 selection_probe >> payload
                 | Self Output |
                 get Self payload Output.
                 """,
                 branch
               )

      receiver = %{class: :selection_probe}
      input = AL.Var.var("Input")
      output = AL.Var.var("Output")

      assert {:atomic, %Implementation{} = unchanged} =
               transaction(fn ->
                 AL.JAM.IR.Plan.compile(
                   AL.JAM.IR.Call.new(receiver, :checked_payload, [input, output]),
                   branch
                 )
               end)

      assert AL.JAM.IR.Call.satisfies?(
               AL.JAM.IR.Call.new(receiver, :checked_payload, [
                 %{class: :selection_probe, payload: :token},
                 output
               ]),
               unchanged.requirements
             )

      for argument <- [input, input, %{class: :selection_probe, payload: :token}] do
        assert {:atomic, :ok} =
                 transaction(fn ->
                   {:ok, _, method} = AL.Dispatch.target(receiver, :checked_payload, branch)
                   original = AL.JAM.Compiler.fetch_method(method, branch)

                   {selected, _} =
                     AL.JAM.IR.Plan.select(
                       original,
                       receiver,
                       :checked_payload,
                       [argument, output],
                       method,
                       branch
                     )

                   assert selected == original == (argument == input)
                   if argument == input, do: assert(:erts_debug.same(selected, original))
                   :ok
                 end)
      end

      for trace <- [[], [:domino]] do
        assert %AL{result: {:atomic, {%{"$Output" => :token}, _, _}}} =
                 AL.run("checked_payload Receiver Value Output.", branch,
                   bindings: %{
                     "Receiver" => receiver,
                     "Value" => %{class: :selection_probe, payload: :token}
                   },
                   trace: trace
                 )
      end
    end)
  end

  example existing_implementations_are_retained_when_rewriting_is_limited() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 @selection_probe #{super => value}.
                 selection_probe >> repeat
                 | _Self . Arguments |
                 = Arguments [Value, Value].
                 selection_probe >> choices
                 | Self A B C D E |
                 choose Self A,
                 choose Self B,
                 choose Self C,
                 choose Self D,
                 choose Self E.
                 selection_probe >> choose
                 | _Self left |.
                 selection_probe >> choose
                 | _Self right |.
                 """,
                 branch
               )

      receiver = %{class: :selection_probe}

      for {selector, names} <- [repeat: ["Input", "Output"], choices: ["A", "B", "C", "D", "E"]] do
        assert {:atomic, :ok} =
                 transaction(fn ->
                   {:ok, _, method} = AL.Dispatch.target(receiver, selector, branch)
                   original = AL.JAM.Compiler.fetch_method(method, branch)
                   call = AL.JAM.IR.Call.new(receiver, selector, Enum.map(names, &AL.Var.var/1))

                   assert :erts_debug.same(
                            AL.JAM.IR.Plan.compile(call, branch).code,
                            original
                          )

                   :ok
                 end)
      end

      for trace <- [[], [:domino]] do
        assert %AL{result: {:atomic, {%{"$Output" => :token, "$Answers" => answers}, _, _}}} =
                 AL.run(
                   "repeat Receiver token Output, findall [A, B, C, D, E] Answers {choices Receiver A B C D E}.",
                   branch,
                   bindings: %{"Receiver" => receiver},
                   trace: trace
                 )

        assert length(answers) == 32
        assert length(Enum.uniq(answers)) == 32
      end
    end)
  end

  example another_process_can_replace_an_implementation() do
    with_branch(fn branch ->
      assert {:atomic, :original} = transaction(fn -> method(branch, fn -> :original end) end)

      assert {:atomic, :replacement} =
               Task.async(fn ->
                 transaction(fn ->
                   PlanStore.invalidate_method(branch, :store_probe)
                   method(branch, fn -> :replacement end)
                 end)
               end)
               |> Task.await()

      assert {:atomic, :replacement} =
               transaction(fn -> method(branch, fn -> flunk("recomputed") end) end)
    end)
  end

  example an_aborted_replacement_keeps_the_previous_implementation() do
    with_branch(fn branch ->
      assert {:atomic, :original} = transaction(fn -> method(branch, fn -> :original end) end)

      assert {:aborted, :rollback} =
               transaction(fn ->
                 assert method(branch, fn -> flunk("recomputed") end) == :original
                 PlanStore.invalidate_method(branch, :store_probe)
                 assert method(branch, fn -> :aborted end) == :aborted
                 :mnesia.abort(:rollback)
               end)

      assert {:atomic, :original} =
               transaction(fn -> method(branch, fn -> flunk("recomputed") end) end)
    end)
  end

  example unsuccessful_compilation_does_not_store_an_implementation() do
    with_branch(fn branch ->
      assert {:atomic, nil} =
               transaction(fn -> PlanStore.fetch(branch, :store_probe, %{}, fn -> nil end) end)

      assert {:atomic, []} =
               transaction(fn -> PlanStore.implementations(branch, :store_probe) end)

      assert {:atomic, :original} = transaction(fn -> method(branch, fn -> :original end) end)

      assert {:atomic, nil} =
               transaction(fn ->
                 PlanStore.fetch(branch, :store_probe, %{arguments: [%{value: :token}]}, fn ->
                   nil
                 end)
               end)

      assert {:atomic, [%Implementation{code: :original, requirements: requirements}]} =
               transaction(fn -> PlanStore.implementations(branch, :store_probe) end)

      assert requirements == %{}
    end)
  end

  example missing_implementations_do_not_exclude_another_reader() do
    with_branch(fn branch ->
      parent = self()

      readers =
        for _ <- 1..2 do
          Task.async(fn ->
            transaction(fn ->
              assert PlanStore.fetch(branch, :store_probe, %{}, fn -> nil end) == nil
              send(parent, {:reading, self()})

              receive do
                :release -> :ok
              end
            end)
          end)
        end

      try do
        for _ <- readers, do: assert_receive({:reading, _}, 5_000)
      after
        for reader <- readers, do: send(reader.pid, :release)
        for reader <- readers, do: assert({:atomic, :ok} = Task.await(reader))
      end
    end)
  end

  example variants_keep_newest_first_order_when_replaced() do
    with_branch(fn branch ->
      assert {:atomic, [:third, :second, :first]} =
               transaction(fn ->
                 for {variant, code} <- [first: :first, second: :second, third: :third] do
                   PlanStore.select(branch, :store_probe, fn _ -> false end, fn ->
                     %Implementation{code: code, requirements: %{variant: variant}}
                   end)
                 end

                 Enum.map(PlanStore.implementations(branch, :store_probe), & &1.code)
               end)

      assert {:atomic, [:replacement, :third, :second]} =
               transaction(fn ->
                 PlanStore.select(branch, :store_probe, fn _ -> false end, fn ->
                   %Implementation{code: :replacement, requirements: %{variant: :first}}
                 end)

                 Enum.map(PlanStore.implementations(branch, :store_probe), & &1.code)
               end)

      assert {:atomic, [:newest, :replacement, :second]} =
               transaction(fn ->
                 PlanStore.select(branch, :store_probe, fn _ -> false end, fn ->
                   %Implementation{code: :newest, requirements: %{variant: :third}}
                 end)

                 Enum.map(PlanStore.implementations(branch, :store_probe), & &1.code)
               end)

      assert {:atomic, []} =
               transaction(fn ->
                 PlanStore.invalidate_method(branch, :store_probe)
                 PlanStore.implementations(branch, :store_probe)
               end)
    end)
  end

  example deferred_queries_distinguish_variants_with_the_same_requirements() do
    with_branch(fn branch ->
      assert {:atomic, [:second, :first]} =
               transaction(fn ->
                 for {token, code} <- [{1, :first}, {2, :second}] do
                   PlanStore.select(branch, :store_probe, fn _ -> false end, fn ->
                     %Implementation{
                       code: code,
                       requirements: %{variant: :shared},
                       deferred_queries: %{token: token}
                     }
                   end)
                 end

                 Enum.map(PlanStore.implementations(branch, :store_probe), & &1.code)
               end)

      assert {:atomic, [:replacement, :second]} =
               transaction(fn ->
                 PlanStore.select(branch, :store_probe, fn _ -> false end, fn ->
                   %Implementation{
                     code: :replacement,
                     requirements: %{variant: :shared},
                     deferred_queries: %{token: 1}
                   }
                 end)

                 Enum.map(PlanStore.implementations(branch, :store_probe), & &1.code)
               end)
    end)
  end

  example implementations_are_branch_local() do
    with_branch(fn branch ->
      with_branch(fn other ->
        assert {:atomic, :first} = transaction(fn -> method(branch, fn -> :first end) end)
        assert {:atomic, :second} = transaction(fn -> method(other, fn -> :second end) end)

        assert {:atomic, :first} =
                 transaction(fn -> method(branch, fn -> flunk("recomputed") end) end)
      end)
    end)
  end

  example original_and_specialised_code_belong_to_the_same_method() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 @stored_probe #{super => value}.
                 stored_probe >> read
                 | Self Output |
                 payload Self Output.
                 stored_probe >> payload
                 | Self Output |
                 get Self payload Output.
                 """,
                 branch
               )

      receiver = %{class: :stored_probe, payload: :token}
      output = AL.Var.var("Output")

      assert {:atomic, :ok} =
               transaction(fn ->
                 {:ok, _, method} = AL.Dispatch.target(receiver, :read, branch)
                 original = AL.JAM.Compiler.fetch_method(method, branch)

                 {specialised, requirements} =
                   AL.JAM.IR.Plan.select(original, receiver, :read, [output], method, branch)

                 implementations = PlanStore.implementations(branch, method)

                 assert Enum.any?(implementations, fn implementation ->
                          implementation.code == original and implementation.requirements == %{}
                        end)

                 assert Enum.any?(implementations, fn implementation ->
                          implementation.code == specialised and
                            Map.get(implementation.requirements, :dispatch) ==
                              AL.JAM.IR.Call.new(receiver, :read, [output]).dispatch and
                            implementation.requirements.arguments == requirements
                        end)

                 assert length(implementations) == 2

                 assert Enum.all?(
                          implementations,
                          &match?(%Implementation{code: code} when not is_nil(code), &1)
                        )

                 :ok
               end)

      for trace <- [[], [:domino]], payload <- [:first, :second] do
        assert %AL{result: {:atomic, {%{"$Output" => ^payload}, _, _}}} =
                 AL.run("read Receiver Output.", branch,
                   bindings: %{"Receiver" => %{receiver | payload: payload}},
                   trace: trace
                 )
      end
    end)
  end

  example receiver_independent_plans_are_shared_across_durable_objects() do
    with_branch(fn branch ->
      assert %AL{result: {:atomic, {%{"$First" => first, "$Second" => second}, _, _}}} =
               AL.run(
                 ~S"""
                 @sharing_probe #{super => object, ivars => [#{name => payload}]}.
                 sharing_probe >> initial_value
                 | _Self Value |
                 member [zero] Value.
                 sharing_probe >> stored_value
                 | Self Value |
                 get Self payload Value.
                 new sharing_probe First.
                 new sharing_probe Second.
                 set_slot First payload first.
                 set_slot Second payload second.
                 """,
                 branch
               )

      assert {:atomic, {first_plan, second_plan, independent, dependent}} =
               transaction(fn ->
                 {:ok, _, independent_method} =
                   AL.Dispatch.target(first, :initial_value, branch)

                 original = AL.JAM.Compiler.fetch_method(independent_method, branch)
                 variable = AL.Var.var("Value")

                 {first_plan, _} =
                   AL.JAM.IR.Plan.select(
                     original,
                     first,
                     :initial_value,
                     [variable],
                     independent_method,
                     branch
                   )

                 {second_plan, _} =
                   AL.JAM.IR.Plan.select(
                     original,
                     second,
                     :initial_value,
                     [variable],
                     independent_method,
                     branch
                   )

                 {:ok, _, dependent_method} = AL.Dispatch.target(first, :stored_value, branch)
                 original = AL.JAM.Compiler.fetch_method(dependent_method, branch)

                 for receiver <- [first, second] do
                   AL.JAM.IR.Plan.select(
                     original,
                     receiver,
                     :stored_value,
                     [variable],
                     dependent_method,
                     branch
                   )
                 end

                 {first_plan, second_plan, PlanStore.implementations(branch, independent_method),
                  PlanStore.implementations(branch, dependent_method)}
               end)

      assert :erts_debug.same(first_plan, second_plan)

      assert Enum.count(independent, fn entry ->
               match?(%{dispatch: {:shared_method, _}}, entry.requirements)
             end) == 1

      assert Enum.count(dependent, fn entry ->
               match?(%{dispatch: _}, entry.requirements)
             end) == 2

      assert %AL{result: {:atomic, {%{"$FirstValue" => :first, "$SecondValue" => :second}, _, _}}} =
               AL.run("stored_value First FirstValue, stored_value Second SecondValue.", branch,
                 bindings: %{"First" => first, "Second" => second}
               )

      assert %AL{result: {:atomic, _}} =
               AL.run(
                 ~S"""
                 sharing_probe >> initial_value
                 | _Self Value |
                 member [one] Value.
                 """,
                 branch
               )

      assert %AL{result: {:atomic, {%{"$FirstValue" => :one, "$SecondValue" => :one}, _, _}}} =
               AL.run("initial_value First FirstValue, initial_value Second SecondValue.", branch,
                 bindings: %{"First" => first, "Second" => second}
               )
    end)
  end

  example dispatch_selection_skips_unrelated_receivers() do
    with_branch(fn branch ->
      assert {:atomic, :second} =
               transaction(fn ->
                 for receiver <- [:first, :second, :third] do
                   PlanStore.select(branch, :store_probe, fn _ -> false end, fn ->
                     %Implementation{
                       code: receiver,
                       requirements: %{dispatch: {receiver, :probe}, arguments: []}
                     }
                   end)
                 end

                 PlanStore.select_for_dispatch(
                   branch,
                   :store_probe,
                   [{:second, :probe}],
                   fn entry ->
                     assert entry.code == :second
                     true
                   end,
                   fn -> flunk("recompiled") end
                 ).code
               end)

      assert {:atomic, :replacement} =
               transaction(fn ->
                 PlanStore.select(branch, :store_probe, fn _ -> false end, fn ->
                   %Implementation{
                     code: :replacement,
                     requirements: %{dispatch: {:second, :probe}, arguments: []}
                   }
                 end)

                 PlanStore.select_for_dispatch(
                   branch,
                   :store_probe,
                   [{:second, :probe}],
                   fn entry -> entry.code == :replacement end,
                   fn -> flunk("recompiled") end
                 ).code
               end)

      assert {:atomic, :external} =
               Task.async(fn ->
                 transaction(fn ->
                   PlanStore.select(branch, :store_probe, fn _ -> false end, fn ->
                     %Implementation{
                       code: :external,
                       requirements: %{dispatch: {:second, :probe}, arguments: []}
                     }
                   end).code
                 end)
               end)
               |> Task.await()

      assert {:atomic, :external} =
               transaction(fn ->
                 PlanStore.select_for_dispatch(
                   branch,
                   :store_probe,
                   [{:second, :probe}],
                   fn entry -> entry.code == :external end,
                   fn -> flunk("recompiled") end
                 ).code
               end)

      assert {:atomic, nil} =
               transaction(fn ->
                 PlanStore.invalidate_method(branch, :store_probe)

                 PlanStore.select_for_dispatch(
                   branch,
                   :store_probe,
                   [{:second, :probe}],
                   fn _ -> true end,
                   fn -> nil end
                 )
               end)
    end)
  end
end
