defmodule AL.JAM.Format do
  alias AL.Goal

  def execute(control, args, store) do
    control = AL.Var.subst(control, store)
    args = AL.Var.subst(args, store)

    case plan(control, args) do
      {_control, _args, []} ->
        {:output, render(control, args)}

      {next_control, next_args, sends} ->
        prints =
          Enum.map(sends, fn {object, printed} ->
            %Goal.Implies{
              condition: [%Goal.Send{object: object, method: :print_object, args: [printed]}],
              then: [],
              otherwise: [%Goal.Fail{}]
            }
          end)

        {:goals, prints ++ [%Goal.Format{control: next_control, args: next_args}]}
    end
  end

  defp render(control, args) do
    control
    |> String.graphemes()
    |> render_directives(args, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp render_directives([], _args, acc), do: acc

  defp render_directives(["~", "a" | rest], [arg | args], acc),
    do: render_directives(rest, args, [aesthetic(arg) | acc])

  defp render_directives(["~", "d" | rest], [arg | args], acc),
    do: render_directives(rest, args, [decimal(arg) | acc])

  defp render_directives(["~", "%" | rest], args, acc),
    do: render_directives(rest, args, ["\n" | acc])

  defp render_directives(["~", "~" | rest], args, acc),
    do: render_directives(rest, args, ["~" | acc])

  defp render_directives([g | rest], args, acc), do: render_directives(rest, args, [g | acc])

  defp plan(control, args) do
    {control_acc, args_acc, pending_acc} =
      plan_directives(String.graphemes(control), args, [], [], [])

    {
      control_acc |> Enum.reverse() |> IO.iodata_to_binary(),
      Enum.reverse(args_acc),
      Enum.reverse(pending_acc)
    }
  end

  defp plan_directives([], _args, control_acc, args_acc, pending_acc),
    do: {control_acc, args_acc, pending_acc}

  defp plan_directives(["~", "a" | rest], [arg | args], control_acc, args_acc, pending_acc),
    do: plan_directives(rest, args, ["~a" | control_acc], [arg | args_acc], pending_acc)

  defp plan_directives(["~", "d" | rest], [arg | args], control_acc, args_acc, pending_acc),
    do: plan_directives(rest, args, ["~d" | control_acc], [arg | args_acc], pending_acc)

  defp plan_directives(["~", "o" | rest], [arg | args], control_acc, args_acc, pending_acc) do
    fresh_var = AL.Var.var("format_object_#{AL.fresh_scope()}")

    plan_directives(
      rest,
      args,
      ["~a" | control_acc],
      [fresh_var | args_acc],
      [{arg, fresh_var} | pending_acc]
    )
  end

  defp plan_directives(["~", "%" | rest], args, control_acc, args_acc, pending_acc),
    do: plan_directives(rest, args, ["~%" | control_acc], args_acc, pending_acc)

  defp plan_directives(["~", "~" | rest], args, control_acc, args_acc, pending_acc),
    do: plan_directives(rest, args, ["~~" | control_acc], args_acc, pending_acc)

  defp plan_directives([g | rest], args, control_acc, args_acc, pending_acc),
    do: plan_directives(rest, args, [g | control_acc], args_acc, pending_acc)

  defp aesthetic(term) when is_binary(term), do: term
  defp aesthetic(term), do: inspect(term)

  defp decimal(term) when is_integer(term), do: Integer.to_string(term)
  defp decimal(term), do: inspect(term)
end
