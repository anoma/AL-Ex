defmodule Examples.ALFormat do
  @moduledoc """
  I provide examples for `vm_format` -- a small, Prolog-`format/2`-shaped
  subset of directives (`~a`, `~d`, `~o`, `~%`, `~~`), not full Common Lisp
  FORMAT. Writes straight to stdout via `IO.write`, no bindings produced.

  `~o` resolves its argument through `:print_object` (a real send) before
  formatting it as `~a` would -- unlike the other directives, which are
  plain Elixir functions, this one splices a goal and re-runs Format once
  it resolves. See Goal.Format's interp clause in lib/AL.ex.
  """

  use ExExample
  use AL
  import ExUnit.Assertions
  import ExUnit.CaptureIO

  example format_aesthetic_prints_a_string_with_no_quotes() do
    output =
      capture_io(fn ->
        run branch: Examples.Support.branch() do
          ~AL"""
          vm_format "~a~%" ["hello"].
          """
        end
      end)

    assert output == "hello\n"
    :ok
  end

  example format_aesthetic_inspects_non_string_terms() do
    output =
      capture_io(fn ->
        run branch: Examples.Support.branch() do
          ~AL"""
          vm_format "~a~%" [on].
          """
        end
      end)

    assert output == ":on\n"
    :ok
  end

  example format_decimal_prints_a_bound_var_resolved_value() do
    output =
      capture_io(fn ->
        run branch: Examples.Support.branch() do
          ~AL"""
          = X (+ 2 2).
          vm_format "x is ~d~%" [X].
          """
        end
      end)

    assert output == "x is 4\n"
    :ok
  end

  example format_consumes_multiple_directives_left_to_right() do
    output =
      capture_io(fn ->
        run branch: Examples.Support.branch() do
          ~AL"""
          vm_format "~a plus ~a is ~d~%" [2, 2, 4].
          """
        end
      end)

    assert output == "2 plus 2 is 4\n"
    :ok
  end

  example format_tilde_tilde_is_a_literal_tilde_not_a_directive() do
    output =
      capture_io(fn ->
        run branch: Examples.Support.branch() do
          ~AL"""
          vm_format "100~~" [].
          """
        end
      end)

    assert output == "100~"
    :ok
  end

  example format_o_resolves_through_print_object_override() do
    output =
      capture_io(fn ->
        run branch: Examples.Support.branch() do
          ~AL"""
          @format_o_print_object_class
          #{super => object}.

          format_o_print_object_class >> print_object
          | Self Text |
          = Text "a shiny thing".

          new format_o_print_object_class Obj.
          vm_format "~o~%" [Obj].
          """
        end
      end)

    assert output == "a shiny thing\n"
    :ok
  end

  example format_o_falls_through_to_default_print_object() do
    output =
      capture_io(fn ->
        run branch: Examples.Support.branch() do
          ~AL"""
          @format_o_default_class
          #{super => object}.

          new format_o_default_class Obj.
          vm_format "~o~%" [Obj].
          """
        end
      end)

    assert output == ":format_o_default_class\n"
    :ok
  end

  example format_o_handles_multiple_directives_in_one_call() do
    output =
      capture_io(fn ->
        run branch: Examples.Support.branch() do
          ~AL"""
          @format_o_multi_class
          #{super => object}.

          format_o_multi_class >> print_object
          | Self Text |
          = Text "widget".

          new format_o_multi_class A.
          new format_o_multi_class B.
          vm_format "~o and ~o~%" [A, B].
          """
        end
      end)

    assert output == "widget and widget\n"
    :ok
  end

  example format_o_fails_when_print_object_has_no_matching_clause() do
    {:aborted, _reason} =
      run branch: Examples.Support.branch() do
        ~AL"""
        @format_o_no_match_class
        #{super => object}.

        format_o_no_match_class >> print_object
        | definitely_not_self _Text |.

        new format_o_no_match_class Obj.
        vm_format "~o~%" [Obj].
        """
      end

    :ok
  end
end
