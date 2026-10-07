defmodule AL.CleanupCorrectnessTest do
  use ExUnit.Case, async: true

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)
    %{branch: branch}
  end

  test "nil remains bound through aliases and subsequent goals", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]] do
      assert {:atomic, {%{"$X" => nil, "$Y" => nil}, _, _}} =
               AL.eval_source("= X nil, = Y X.", branch, opts)

      assert {:aborted, _} = AL.eval_source("= X nil, = X 42.", branch, opts)
    end
  end

  test "literal match-spec atoms never broaden reads or retractions", %{branch: branch} do
    assert {:atomic, {%{"$Victim" => victim}, _, _}} =
             AL.eval_source(~S"@audit_class #{super => object}. new audit_class Victim.", branch)

    for atom <- [:_, :"$1", :"$2"] do
      assert {:atomic, []} =
               :mnesia.transaction(fn -> AL.Object.scan_class(atom, :audit_class, branch) end)

      assert {:atomic, _} =
               AL.eval_source("vm_set_class #{AL.Syntax.Printer.term(atom)} audit_class.", branch)

      assert {:atomic, [{:class, ^atom, _, :audit_class}]} =
               :mnesia.transaction(fn -> AL.Object.scan_class(atom, :audit_class, branch) end)

      assert {:atomic, _} =
               AL.eval_source("vm_set_super #{AL.Syntax.Printer.term(atom)} object.", branch)

      source = "vm_retract_class #{AL.Syntax.Printer.term(atom)} audit_class."
      assert {:atomic, _} = AL.eval_source(source, branch)

      assert {:atomic, []} =
               :mnesia.transaction(fn -> AL.Object.scan_class(atom, :audit_class, branch) end)

      assert {:atomic, [{:super, ^atom, _, :object}]} =
               :mnesia.transaction(fn -> AL.Object.scan_super(atom, :object, branch) end)

      assert {:atomic, [{:class, ^victim, _, :audit_class}]} =
               :mnesia.transaction(fn -> AL.Object.scan_class(victim, :audit_class, branch) end)
    end
  end

  test "query literals remain literal inside compound patterns" do
    variable = AL.Var.var("Value")

    spec =
      AL.Mnesia.specification({:row, variable, %{value: variable, literals: [:_, :"$1", :"$2"]}})

    row = {:row, :a, %{value: :a, literals: [:_, :"$1", :"$2"]}}
    mismatch = {:row, :a, %{value: :b, literals: [:_, :"$1", :"$2"]}}
    assert :ets.match_spec_run([row, mismatch], :ets.match_spec_compile(spec)) == [row]
  end

  test "export failure leaves the original bundle intact" do
    directory =
      Path.join(System.tmp_dir!(), "al-export-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)
    File.mkdir_p!(Path.join(directory, "definitions/blocked.class.al"))
    File.write!(Path.join(directory, "package.al"), "old manifest")
    File.write!(Path.join(directory, "definitions/first.class.al"), "old definition")

    assert {:error, _} =
             AL.Package.Export.write(directory, "new manifest", [
               %{path: "definitions/first.class.al", text: "new definition"},
               %{path: "definitions/blocked.class.al", text: "blocked"}
             ])

    assert File.read!(Path.join(directory, "package.al")) == "old manifest"
    assert File.read!(Path.join(directory, "definitions/first.class.al")) == "old definition"
  end

  test "forall preserves captures without disabling unrelated direct outputs", %{branch: branch} do
    alias AL.Goal
    output = AL.Var.var("Output")
    local = AL.Var.var("Local")

    body = [
      %Goal.OApply{method_id: :vm_map_put, args: [%{}, :key, :value, local]},
      %Goal.Forall{condition: [%Goal.Pass{}], body: [%Goal.Pass{}]},
      %Goal.Eq{a: output, b: local}
    ]

    {[%AL.JAM.CompiledClause{locals: locals, code: code}], _} =
      AL.JAM.Compiler.compile([{:oapply, :probe, 0, [output], body}])

    assert {:local, index, {:map_put, _, _, _, _}} = elem(code, 0)
    refute Enum.any?(locals, fn {slot, _} -> slot == index end)

    assert {:atomic, _} =
             AL.eval_source(
               ~S"""
               @scope_probe #{super => value}.
               scope_probe >> build
               | _Self Output |
               vm_map_put #{} key value Local,
               forall {member [a, b] Item} {atom Item},
               = Output Local.
               """,
               branch
             )

    for opts <- [[], [trace: [:vm]]] do
      assert {:atomic, {%{"$Output" => %{key: :value}}, _, _}} =
               AL.eval_source(~S"build #{class => scope_probe} Output.", branch, opts)
    end
  end
end
