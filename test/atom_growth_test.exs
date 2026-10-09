defmodule AL.AtomGrowthTest do
  use ExUnit.Case, async: false

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "parsing new variable names does not intern atoms" do
    {:ok, _} = AL.Syntax.parse("= Warmup 1.")
    prefix = "AtomAudit#{System.unique_integer([:positive])}"
    source = Enum.map_join(1..500, "\n", &"= #{prefix}_#{&1} #{&1}.")
    before = :erlang.system_info(:atom_count)
    assert {:ok, parsed} = AL.Syntax.parse(source)
    added = :erlang.system_info(:atom_count) - before

    assert MapSet.size(AL.Var.find_vars(parsed.program)) == 500
    assert added == 0
    assert_raise ArgumentError, fn -> String.to_existing_atom(prefix <> "_1") end
    assert_raise ArgumentError, fn -> String.to_existing_atom("$" <> prefix <> "_1") end
  end

  test "the AL grammar enumerates variable names as binaries without interning them", %{
    branch: branch
  } do
    name = "GrammarVariable#{System.unique_integer([:positive])}"
    source = "findall Parsed Results {parse variable_syntax (expr Parsed) \"#{name}\"}."
    assert {:atomic, {%{"$Results" => results}, _, _}} = AL.run(source, branch)
    assert results == [%AL.Goal.Compound{name: :var, args: [name]}]
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    assert_raise ArgumentError, fn -> String.to_existing_atom("$" <> name) end
  end

  test "stored method variables and output bindings retain binary names", %{branch: branch} do
    name = "StoredVariable#{System.unique_integer([:positive])}"

    source =
      "@binary_variable_probe \#{super => value}.\nbinary_variable_probe >> echo\n| _Self #{name} #{name} |."

    assert {:atomic, _} = AL.run(source, branch)

    assert {:atomic, variables} =
             :mnesia.transaction(fn ->
               [{:method, _, _, method}] =
                 AL.Object.scan_method(
                   :binary_variable_probe,
                   :echo,
                   AL.Var.var("Method"),
                   branch
                 )

               AL.Object.scan_oapply(
                 method,
                 AL.Var.var("Seq"),
                 AL.Var.var("Head"),
                 AL.Var.var("Body"),
                 branch
               )
               |> AL.Var.find_vars()
             end)

    assert Enum.any?(variables, &(AL.Var.name(&1) == name))
    assert Enum.all?(variables, &is_binary(AL.Var.name(&1)))
    assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    assert_raise ArgumentError, fn -> String.to_existing_atom("$" <> name) end

    assert {:atomic, {%{"$Value" => "$Value"}, _, _}} =
             AL.run(
               ~S"""
               = Value "$Value".
               """,
               branch
             )
  end

  test "scheduling allocates runtime variables without interning names", %{branch: branch} do
    schedule = fn ->
      AL.JAM.Relation.execute(:schedule_transaction, [:pending, :effect, [], []], %{}, branch)
    end

    schedule.()
    schedule.()
    before = :erlang.system_info(:atom_count)
    results = for _ <- 1..100, do: schedule.()
    added = :erlang.system_info(:atom_count) - before

    variables =
      Enum.map(results, fn {:goals, %{}, [%AL.Goal.Send{args: [_, variable]}]} -> variable end)

    assert length(Enum.uniq(variables)) == 100
    assert Enum.all?(variables, &AL.Var.var?/1)
    assert added == 0
  end

  test "repeated definition snapshots do not intern fresh query names", %{branch: branch} do
    capture = fn ->
      {:ok, snapshot} = AL.Definition.Snapshot.capture(branch)
      AL.Definition.Snapshot.rendered(snapshot)
    end

    expected = capture.()
    assert capture.() == expected
    before = :erlang.system_info(:atom_count)
    results = for _ <- 1..5, do: capture.()
    added = :erlang.system_info(:atom_count) - before

    assert Enum.all?(results, &(&1 == expected))
    assert added == 0
  end

  test "repeated object creation only interns its object and transaction identities", %{
    branch: branch
  } do
    create = fn ->
      {:atomic, {bindings, _, _}} = AL.run("new object X.", branch)
      Map.fetch!(bindings, "$X")
    end

    create.()
    create.()
    before = :erlang.system_info(:atom_count)
    objects = for _ <- 1..10, do: create.()
    added = :erlang.system_info(:atom_count) - before

    assert length(Enum.uniq(objects)) == 10
    assert added in 10..20
  end
end
