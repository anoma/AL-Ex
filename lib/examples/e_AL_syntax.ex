defmodule Examples.ALSyntax do
  @moduledoc ~S"""
  I show AL's surface syntax: goals as a selector followed by its arguments,
  capitalised variables, lowercase atoms, `[...]` lists, `#{key => value}` maps,
  `{goal, ...}` blocks, `C -> T ; E` conditionals, `A ; B` alternatives,
  `@name #{...}.` class declarations and `owner >> selector | Head | Body.`
  method clauses. The clauses one source gives for a selector replace its
  earlier clauses; `defmethod` adds one more.
  """

  use ExExample
  use AL
  import ExUnit.Assertions
  import ExUnit.CaptureIO

  defp al(term), do: AL.Syntax.Printer.term(term)

  defp fresh_id(prefix) do
    suffix = System.unique_integer([:positive])
    String.to_atom("#{prefix}_#{suffix}")
  end

  defp counter_source(class) do
    """
    @#{al(class)} \#{super => object, ivars => [\#{default => 0, name => count}]}.

    #{al(class)} >> bump
    | Self By |
      # refuse to count down
      get Self count Count,
      < By 0 -> fail ; {= Next (+ Count By), set_slot Self count Next}.
    """
  end

  example a_class_defined_in_al_source_runs() do
    branch = Examples.Support.isolated_branch()
    class = fresh_id("syntax_counter")

    try do
      {:atomic, _} = AL.eval_source(counter_source(class), branch)

      {:atomic, {bindings, _constraints, _}} =
        AL.eval_source(
          "new #{al(class)} \#{} Counter.\nbump Counter 5.\nget Counter count Count.",
          branch
        )

      {:aborted, _} =
        AL.eval_source(
          "new #{al(class)} \#{} Counter.\nbump Counter 5.\nbump Counter -2.",
          branch
        )

      assert Map.get(bindings, :"$Count") == 5
    after
      AL.Branch.discard(branch)
    end
  end

  example a_conditional_without_else_fails_when_its_condition_fails() do
    {:aborted, _} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = X 1.
        > X 5 -> = Y big.
        """
      end

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = X 1.
        > X 5 -> = Y big ; = Y small.
        """
      end

    assert bindings[:"$Y"] == :small
    :ok
  end

  example alternatives_backtrack_into_their_second_branch() do
    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = X 1 ; = X 2.
        > X 1.
        """
      end

    assert bindings[:"$X"] == 2
    :ok
  end

  example a_method_retains_its_authored_source() do
    branch = Examples.Support.isolated_branch()
    class = fresh_id("syntax_counter")

    try do
      {:atomic, _} = AL.eval_source(counter_source(class), branch)

      output =
        capture_io(fn ->
          run branch: branch.id do
            ~AL"""
            listing ^class bump.
            """
          end
        end)

      assert output =~ "#{al(class)} >> bump\n| Self By |\n  # refuse to count down\n"

      {:ok, snapshot} = AL.Serialisation.Snapshot.capture(branch)
      {^class, document} = List.keyfind(AL.Serialisation.Snapshot.rendered(snapshot), class, 0)
      assert document =~ "#{al(class)} >> bump\n| Self By |\n# refuse to count down\n"
      output
    after
      AL.Branch.discard(branch)
    end
  end

  example a_source_replaces_the_clauses_it_defines() do
    branch = Examples.Support.isolated_branch()

    define = fn ->
      run branch: branch.id do
        ~AL"""
        @syntax_redefined
        #{super => object}.

        syntax_redefined >> pick
        | _ first |.

        syntax_redefined >> pick
        | _ second |.

        new syntax_redefined #{name => syntax_redefined_instance} _.
        """
      end
    end

    try do
      {:atomic, _} = define.()
      {:atomic, _} = define.()

      {:atomic, {bindings, _constraints, _}} =
        run branch: branch.id do
          ~AL"""
          findall P Picks (pick syntax_redefined_instance P).
          """
        end

      assert Map.get(bindings, :"$Picks") == [:first, :second]

      {:atomic, {bindings, _constraints, _}} =
        run branch: branch.id do
          ~AL"""
          defmethod syntax_redefined pick [_, third] {}.
          findall P Picks (pick syntax_redefined_instance P).
          """
        end

      assert Map.get(bindings, :"$Picks") == [:first, :second, :third]
      bindings
    after
      AL.Branch.discard(branch)
    end
  end

  example run_takes_pinned_elixir_values() do
    amount = 7

    {:atomic, {bindings, _constraints, _}} =
      run branch: Examples.Support.branch() do
        ~AL"""
        = Total (+ ^amount 3).
        = [First . Rest] [Total, ^amount].
        """
      end

    assert bindings[:"$Total"] == 10
    assert bindings[:"$First"] == 10
    assert bindings[:"$Rest"] == [7]
    :ok
  end

  example run_retains_its_source() do
    branch = Examples.Support.isolated_branch()

    try do
      {:atomic, _} =
        run branch: branch.id do
          ~AL"""
          @syntax_run_counter
          #{super => object}.

          syntax_run_counter >> greet
          | Self hi |.
          """
        end

      output =
        capture_io(fn ->
          run branch: branch.id do
            ~AL"""
            listing syntax_run_counter greet.
            """
          end
        end)

      assert output == "syntax_run_counter >> greet\n| Self hi |\n\n"
      output
    after
      AL.Branch.discard(branch)
    end
  end

  example every_installed_clause_round_trips_through_the_syntax() do
    {:atomic, clauses} =
      :mnesia.transaction(fn ->
        AL.Object.scan_oapply(
          AL.Var.var("object"),
          AL.Var.var("seq"),
          AL.Var.var("head"),
          AL.Var.var("body")
        )
      end)

    failures =
      for {:oapply, object, _seq, head, body} <- clauses,
          {head, body} = authored({head, body}),
          text = AL.Syntax.Printer.defmethod(:owner, :selector, head, body),
          round_trip(text) != {anonymous(head), anonymous(body)},
          do: {object, text, round_trip(text)}

    assert failures == []
    assert length(clauses) > 300
    length(clauses)
  end

  defp round_trip(text) do
    case AL.Syntax.parse(text <> ".") do
      {:ok, %{program: [_clear, %AL.Goal.OApply{args: [:owner, :selector, head, body]}]}} ->
        {anonymous(AL.Goal.to_stored(head)), anonymous(Enum.map(body, &AL.Goal.to_stored/1))}

      other ->
        other
    end
  end

  defp authored(term) do
    AL.Goal.map(term, fn
      {:"$fresh", base, _scope} -> authored(base)
      leaf -> leaf
    end)
  end

  defp anonymous(term),
    do: AL.Goal.map(term, fn leaf -> if AL.Var.var?(leaf), do: :_, else: leaf end)
end
