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
        run branch: :examples do
          vm_format("~a~%", ["hello"])
        end
      end)

    assert output == "hello\n"
    :ok
  end

  example format_aesthetic_inspects_non_string_terms() do
    output =
      capture_io(fn ->
        run branch: :examples do
          vm_format("~a~%", [:on])
        end
      end)

    assert output == ":on\n"
    :ok
  end

  example format_decimal_prints_a_bound_var_resolved_value() do
    output =
      capture_io(fn ->
        run branch: :examples do
          is(x, 2 + 2)
          vm_format("x is ~d~%", [x])
        end
      end)

    assert output == "x is 4\n"
    :ok
  end

  example format_consumes_multiple_directives_left_to_right() do
    output =
      capture_io(fn ->
        run branch: :examples do
          vm_format("~a plus ~a is ~d~%", [2, 2, 4])
        end
      end)

    assert output == "2 plus 2 is 4\n"
    :ok
  end

  example format_tilde_tilde_is_a_literal_tilde_not_a_directive() do
    output =
      capture_io(fn ->
        run branch: :examples do
          vm_format("100~~", [])
        end
      end)

    assert output == "100~"
    :ok
  end

  example format_o_resolves_through_print_object_override() do
    output =
      capture_io(fn ->
        run branch: :examples do
          defclass :format_o_print_object_class, super: :object do
            defmethod(:print_object, [self, text]) do
              unify(text, "a shiny thing")
            end
          end

          new(:format_o_print_object_class, obj)
          vm_format("~o~%", [obj])
        end
      end)

    assert output == "a shiny thing\n"
    :ok
  end

  example format_o_falls_through_to_default_print_object() do
    output =
      capture_io(fn ->
        run branch: :examples do
          defclass :format_o_default_class, super: :object do
          end

          new(:format_o_default_class, obj)
          vm_format("~o~%", [obj])
        end
      end)

    assert output == ":format_o_default_class\n"
    :ok
  end

  example format_o_handles_multiple_directives_in_one_call() do
    output =
      capture_io(fn ->
        run branch: :examples do
          defclass :format_o_multi_class, super: :object do
            defmethod(:print_object, [self, text]) do
              unify(text, "widget")
            end
          end

          new(:format_o_multi_class, a)
          new(:format_o_multi_class, b)
          vm_format("~o and ~o~%", [a, b])
        end
      end)

    assert output == "widget and widget\n"
    :ok
  end

  example format_o_fails_when_print_object_has_no_matching_clause() do
    {:aborted, _reason} =
      run branch: :examples do
        defclass :format_o_no_match_class, super: :object do
          defmethod(:print_object, [:definitely_not_self, _text]) do
          end
        end

        new(:format_o_no_match_class, obj)
        vm_format("~o~%", [obj])
      end

    :ok
  end
end
