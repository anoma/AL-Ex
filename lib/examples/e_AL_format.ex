defmodule Examples.ALFormat do
  use ExExample
  use AL
  import ExUnit.Assertions

  example format_prints_a_string_with_no_quotes() do
    {:atomic, {bindings, _, _}} =
      run(
        ~S"""
        format "~a~%" ["hello"] Text.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Text"] == "hello\n"
    :ok
  end

  example format_prints_al_terms() do
    {:atomic, {bindings, _, _}} =
      run(
        ~S"""
        format "~a~%" [object] Text.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Text"] == "object\n"
    :ok
  end

  example format_prints_a_bound_var_resolved_value() do
    {:atomic, {bindings, _, _}} =
      run(
        ~S"""
        = X (+ 2 2).
        format "x is ~a~%" [X] Text.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Text"] == "x is 4\n"
    :ok
  end

  example format_consumes_multiple_directives_left_to_right() do
    {:atomic, {bindings, _, _}} =
      run(
        ~S"""
        format "~a plus ~a is ~a~%" [2, 2, 4] Text.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Text"] == "2 plus 2 is 4\n"
    :ok
  end

  example format_tilde_tilde_is_a_literal_tilde_not_a_directive() do
    {:atomic, {bindings, _, _}} =
      run(
        ~S"""
        format "100~~" [] Text.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Text"] == "100~"
    :ok
  end

  example format_object_resolves_through_print_object_override() do
    {:atomic, {bindings, _, _}} =
      run(
        ~S"""
        @format_object_print_object_class
        #{super => object}.

        format_object_print_object_class >> print_object
        | Self Text |
        = Text "a shiny thing".

        new format_object_print_object_class Obj.
        format "~a~%" [Obj] Text.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Text"] == "a shiny thing\n"
    :ok
  end

  example format_object_falls_through_to_default_print_object() do
    {:atomic, {bindings, _, _}} =
      run(
        ~S"""
        @format_object_default_class
        #{super => object}.

        new format_object_default_class Obj.
        print_object Obj IdText,
        atom_string Obj IdText.
        format "~a~%" [list] Text.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Text"] == "list\n"
    :ok
  end

  example format_object_handles_multiple_directives_in_one_call() do
    {:atomic, {bindings, _, _}} =
      run(
        ~S"""
        @format_object_multi_class
        #{super => object}.

        format_object_multi_class >> print_object
        | Self Text |
        = Text "widget".

        new format_object_multi_class A.
        new format_object_multi_class B.
        format "~a and ~a~%" [A, B] Text.
        """,
        branch: Examples.Support.branch()
      )

    assert bindings["$Text"] == "widget and widget\n"
    :ok
  end

  example format_object_fails_when_print_object_has_no_matching_clause() do
    {:aborted, _reason} =
      run(
        ~S"""
        @format_object_no_match_class
        #{super => object}.

        format_object_no_match_class >> print_object
        | definitely_not_self _Text |.

        new format_object_no_match_class Obj.
        format "~a~%" [Obj] Text.
        """,
        branch: Examples.Support.branch()
      )

    :ok
  end
end
