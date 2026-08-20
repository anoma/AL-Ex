defmodule Examples.ALFormat do
  @moduledoc """
  I provide examples for `vm_format` -- a small, Prolog-`format/2`-shaped
  subset of directives (`~a`, `~d`, `~%`, `~~`), not full Common Lisp
  FORMAT. Writes straight to stdout via `IO.write`, no bindings produced.
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
          vm_is(x, 2 + 2)
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
end
