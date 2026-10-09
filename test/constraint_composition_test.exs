defmodule AL.ConstraintCompositionTest do
  use ExUnit.Case, async: true

  setup do
    branch = AL.TestBranch.fork()
    on_exit(fn -> AL.Branch.discard(branch) end)

    assert {:atomic, _} =
             AL.run(
               ~S"""
               @audit_parent #{super => object}.
               @audit_other #{super => object}.
               @audit_child_a #{super => audit_parent}.
               @audit_child_b #{super => audit_parent}.
               @audit_record #{super => object, ivars => [#{name => tag}, #{name => level, storage => soa}]}.
               new audit_record #{name => audit_one, tag => one, level => 7} _.
               new audit_record #{name => audit_two, tag => two, level => 9} _.
               @audit_value #{super => value, ivars => [#{name => price, domain => [2,3,4]}, #{name => quantity, domain => [1,2,3]}]}.
               audit_value >> total
               | Self Total |
               get Self price Price,
               get Self quantity Quantity,
               = Total (* Price Quantity).
               @audit_discounted #{super => audit_value}.
               audit_discounted >> total
               | Self Total |
               call_next_method Self Raw,
               = Total (- Raw 1).
               """,
               branch
             )

    %{branch: branch}
  end

  test "superclass constraints validate both endpoints and all edges", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]],
        source <- [
          "super C P, = P audit_parent, = C audit_other.",
          "super C P, = C audit_other, = P audit_parent.",
          "super C A, super C B, = A audit_other, = B audit_parent, = C audit_child_a.",
          "super C A, super D B, = C D, = A audit_other, = B audit_parent, = C audit_child_a."
        ] do
      assert {:aborted, _} = AL.run(source, branch, opts)
    end

    for opts <- [[], [trace: [:vm]]] do
      assert {:atomic, {%{"$Answers" => answers}, _, _}} =
               AL.run(
                 "super C P, = P audit_parent, findall C Answers {label C}.",
                 branch,
                 opts
               )

      assert Enum.sort(answers) == [:audit_child_a, :audit_child_b]

      assert {:atomic, _} =
               AL.run(
                 "super C A, super C B, = C audit_child_a, = A audit_parent, = B audit_parent.",
                 branch,
                 opts
               )
    end
  end

  test "product constraints preserve solutions across posting modes", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]],
        equation <- [
          "= 6 (* P Q)",
          "= (* P Q) 6",
          "= T (* P Q), = T 6"
        ] do
      source =
        "findall [P,Q] Answers {in_domain P [2,3,4], in_domain Q [1,2,3], #{equation}, label P, label Q}."

      assert {:atomic, {%{"$Answers" => [[2, 3], [3, 2]]}, _, _}} =
               AL.run(source, branch, opts)
    end
  end

  test "numeric bounds reject nonnumbers regardless of posting order", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]],
        term <- ["nope", "[]", "nil"],
        source <- [
          ">= X 0, = X #{term}.",
          "= X #{term}, >= X 0."
        ] do
      assert {:aborted, _} = AL.run(source, branch, opts)
    end

    assert {:atomic, {%{"$Answers" => [1, 2]}, _, _}} =
             AL.run(
               "findall X Answers {in_domain X [1,nope,2], >= X 0, label X}.",
               branch
             )
  end

  test "automatic slots preserve storage through binding labeling and copying", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]],
        source <- [
          "get O level V, = O audit_one.",
          "get audit_one level V, = O audit_one.",
          "slot O level V, = O audit_one.",
          "slot O level V, = V 7, label O.",
          "slot O level V, = Alias O, = Alias audit_one.",
          "slot O level V, copy_term [O,V] [C,W] Goals, variant Goals [(slot C level W)], = O audit_one."
        ] do
      assert {:atomic, {%{"$O" => :audit_one, "$V" => 7}, _, _}} =
               AL.run(source, branch, opts)
    end

    assert {:atomic, {%{"$Answers" => answers}, _, _}} =
             AL.run(
               "findall [O,V] Answers {slot O level V, label O}.",
               branch
             )

    assert Enum.sort(answers) == [[:audit_one, 7], [:audit_two, 9]]

    assert {:aborted, _} = AL.run("slot O level V aos, = O audit_one.", branch)

    assert {:atomic, _} =
             AL.run(
               "slot O tag V aos, copy_term [O,V] [C,W] Goals, variant Goals [(slot C tag W aos)], = O audit_one, = V one.",
               branch
             )
  end

  test "value object methods compose with inherited arithmetic and shared variables", %{
    branch: branch
  } do
    for opts <- [[], [trace: [:vm]]],
        {class, total} <- [{"audit_value", 6}, {"audit_discounted", 5}] do
      source =
        "findall [P,Q] Answers {new #{class} V, total V #{total}, get V price P, get V quantity Q, label P, label Q}."

      assert {:atomic, {%{"$Answers" => [[2, 3], [3, 2]]}, _, _}} =
               AL.run(source, branch, opts)
    end

    assert {:atomic, {%{"$Answers" => answers}, _, _}} =
             AL.run(
               "findall [P,A,B] Answers {new audit_value X, new audit_value Y, get X price P, get Y price P, get X quantity A, get Y quantity B, total X TX, total Y TY, = 12 (+ TX TY), dif A B, label P, label A, label B}.",
               branch
             )

    assert answers == [[3, 1, 3], [3, 3, 1], [4, 1, 2], [4, 2, 1]]
  end

  test "export staging rejects symlinked directories without modifying their targets" do
    root = Path.join(System.tmp_dir!(), "al-export-links-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    bundle = Path.join(root, "bundle")
    external = Path.join(root, "external")
    File.mkdir_p!(bundle)
    File.mkdir_p!(external)
    File.write!(Path.join(external, "old.class.al"), "old")
    File.ln_s!(external, Path.join(bundle, "definitions"))
    File.mkdir_p!(Path.join(bundle, "blocked"))

    assert {:error, {:package_export_symlink, _}} =
             AL.Package.Export.write(bundle, "new", [
               %{path: "definitions/new.class.al", text: "new"},
               %{path: "blocked", text: "fail"}
             ])

    assert File.ls!(external) == ["old.class.al"]
    assert File.read!(Path.join(external, "old.class.al")) == "old"
  end

  test "class relationships survive either endpoint binding and residual copying", %{
    branch: branch
  } do
    for opts <- [[], [trace: [:vm]]], relation <- ["class", "isa"] do
      for source <- [
            "#{relation} O C, = O audit_one, = C audit_other.",
            "#{relation} O C, = C audit_other, = O audit_one.",
            "#{relation} O C, = Alias O, = Alias audit_one, = C audit_other."
          ] do
        assert {:aborted, reason} = AL.run(source, branch, opts)
        assert is_map(reason)
      end

      assert {:atomic, _} =
               AL.run(
                 "#{relation} O C, copy_term C Copy Goals, member Goals (#{relation} _ Copy).",
                 branch,
                 opts
               )
    end

    assert {:atomic, {%{"$C" => :audit_record}, _, _}} =
             AL.run("class O C, = O audit_one.", branch)
  end

  test "copied provider constraints reject overrides without executing methods", %{branch: branch} do
    assert {:atomic, _} =
             AL.run(
               ~S"""
               @audit_colour #{super => value}.
               audit_colour >> colour
               | _Self red |.
               audit_colour >> forbidden
               | _Self |
               fail.
               @audit_blue #{super => audit_colour}.
               audit_blue >> colour
               | _Self blue |.
               """,
               branch
             )

    for opts <- [[], [trace: [:vm]]] do
      assert {:aborted, reason} =
               AL.run(
                 ~S"colour O red, copy_term O C Goals, call [C] Goals [C], = C #{class => audit_blue}.",
                 branch,
                 opts
               )

      assert is_map(reason)

      assert {:atomic, _} =
               AL.run(
                 ~S"selected_provider O forbidden audit_colour, = O #{class => audit_blue}.",
                 branch,
                 opts
               )

      assert {:atomic, {%{"$P" => :audit_blue}, _, _}} =
               AL.run(
                 ~S"selected_provider #{class => audit_blue} colour P.",
                 branch,
                 opts
               )

      assert {:atomic, _} =
               AL.run(
                 ~S"colour O red, copy_term O C Goals, call [C] Goals [C], = C #{class => audit_colour}.",
                 branch,
                 opts
               )
    end
  end

  test "slot propagation preserves value receivers and enumerates both stores", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]],
        source <- [
          ~S"slot O tag V, = V one, = O #{tag => one}.",
          ~S"= V one, slot O tag V, = O #{tag => one}."
        ] do
      assert {:atomic, {%{"$O" => %{tag: :one}}, _, _}} = AL.run(source, branch, opts)
    end

    assert {:atomic, {%{"$V" => 7}, _, _}} =
             AL.run("slot audit_one K V, = K level.", branch)

    assert {:atomic, {%{"$Answers" => answers}, _, _}} =
             AL.run("findall [K,V] Answers {slot audit_one K V}.", branch)

    assert Enum.sort(answers) == [[:level, 7], [:tag, :one]]
  end

  test "integer requirements survive cancellation and copied residuals", %{branch: branch} do
    for opts <- [[], [trace: [:vm]]], value <- ["nope", "1.5"] do
      for source <- [
            "= 0 (- X X), = X #{value}.",
            ">= X X, = X #{value}.",
            "= 0 (- X X), copy_term X C Goals, call [C] Goals [C], = C #{value}."
          ] do
        assert {:aborted, reason} = AL.run(source, branch, opts)
        assert is_map(reason)
      end
    end

    assert {:atomic, {%{"$X" => 3}, _, _}} = AL.run("= 0 (- X X), = X 3.", branch)

    assert {:atomic, {%{"$Answers" => [2, 3]}, _, _}} =
             AL.run("findall X Answers {> X 1, < X 4, label X}.", branch)
  end

  test "provider relations use current dispatch order and survive the goal codec", %{
    branch: branch
  } do
    assert {:atomic, _} =
             AL.run(
               ~S"""
               @provider_left #{super => value}.
               @provider_right #{super => value}.
               @provider_child #{super => [provider_left, provider_right]}.
               provider_left >> choice
               | _Self left |.
               provider_right >> choice
               | _Self right |.
               selected_provider #{class => provider_child} choice provider_left.
               """,
               branch
             )

    assert {:atomic, _} =
             AL.run(
               ~S"""
               @provider_child #{super => [provider_right, provider_left]}.
               selected_provider #{class => provider_child} choice provider_right.
               """,
               branch
             )

    assert {:aborted, _} =
             AL.run(
               ~S"selected_provider #{class => provider_child} choice provider_left.",
               branch
             )

    goal = %AL.Goal.SelectedProvider{
      object: AL.Var.var("Receiver"),
      selector: :choice,
      provider: :provider_right
    }

    assert goal == goal |> AL.Goal.to_stored() |> AL.Goal.from_stored()
    assert {:selected_provider, _} = AL.Goal.call_form(goal)
    assert {:ok, _} = AL.Syntax.parse(AL.Syntax.Printer.term(goal) <> ".")
  end
end
