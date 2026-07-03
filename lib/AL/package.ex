defmodule AL.Package do
  @moduledoc """
  I define and install AL packages. A package is a durable object created as the
  receipt of running its definitions, authored with `defpackage/3`.
  """

  defmacro __using__(_opts) do
    quote do
      require AL
      import AL.Package, only: [defpackage: 3]
    end
  end

  defmacro defpackage(name, opts, do: body) do
    version = Keyword.get(opts, :version, 1)
    deps = Keyword.get(opts, :deps, [])

    statements =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    receipt =
      quote do
        new(:package, %{name: unquote(name), version: unquote(version), deps: unquote(deps)}, _)
      end

    program = {:__block__, [], statements ++ [receipt]}

    quote do
      def __package__ do
        %{name: unquote(name), version: unquote(version), deps: unquote(deps)}
      end

      def install do
        AL.run do
          unquote(program)
        end
      end
    end
  end

  @spec install_all([module()]) :: :ok
  def install_all(modules) do
    by_name = Map.new(modules, fn m -> {m.__package__().name, m} end)

    modules
    |> order(by_name)
    |> Enum.each(fn m -> ensure(m.__package__().name, &m.install/0) end)
  end

  @spec installed?(atom()) :: boolean()
  def installed?(name) do
    case :mnesia.transaction(fn ->
           Enum.any?(AL.Object.scan_class(:"$p", :package), fn {:class, p, :package} ->
             match?([{:slots, ^p, %{name: ^name}}], :mnesia.read(:slots, p))
           end)
         end) do
      {:atomic, installed?} -> installed?
      _ -> false
    end
  end

  @spec ensure(atom(), (-> any())) :: :ok
  def ensure(name, install) do
    if installed?(name) do
      :ok
    else
      # An install program that fails aborts its transaction rather than raising,
      # which would otherwise leave a half-installed package behind silently. Turn
      # that abort into a loud crash so a broken package can't pass for installed.
      case install.() do
        {:atomic, _} ->
          :ok

        {:aborted, reason} ->
          raise "AL package #{inspect(name)} failed to install: #{explain(reason)}"
      end
    end
  end

  # Prefer the legible failure message AL's interpreter now attaches; fall back to
  # inspecting whatever the abort carried.
  defp explain(%{message: message}), do: message
  defp explain(reason), do: inspect(reason)

  @doc """
  I retract everything a package installed by reversing the commands of its
  install transaction (recorded in the receipt's `:tx` slot). I refuse if another
  installed package depends on this one.
  """
  @spec uninstall(atom()) :: {:atomic, any()} | {:aborted, term()} | {:error, term()}
  def uninstall(name) do
    case dependents(name) do
      [] -> do_uninstall(name)
      deps -> {:error, {:depended_on_by, deps}}
    end
  end

  defp do_uninstall(name) do
    case :mnesia.transaction(fn ->
           case find_package(name) do
             {_p, %{tx: tx}} -> AL.Command.commands_for_transaction(tx)
             _ -> nil
           end
         end) do
      {:atomic, nil} -> {:error, :not_installed}
      {:atomic, commands} -> commands |> Enum.reverse() |> Enum.flat_map(&inverse/1) |> AL.eval()
      other -> other
    end
  end

  defp dependents(name) do
    {:atomic, names} =
      :mnesia.transaction(fn ->
        for {:class, p, :package} <- AL.Object.scan_class(:"$p", :package),
            {:slots, ^p, %{name: dependent, deps: deps}} <- :mnesia.read(:slots, p),
            name in deps,
            do: dependent
      end)

    names
  end

  defp find_package(name) do
    Enum.find_value(AL.Object.scan_class(:"$p", :package), fn {:class, p, :package} ->
      case :mnesia.read(:slots, p) do
        [{:slots, ^p, %{name: ^name} = slots}] -> {p, slots}
        _ -> nil
      end
    end)
  end

  defp inverse({:command, _t, _tx, command}) do
    case command do
      {:set_class, {o, c}} -> [%AL.Goal.RetractClass{object: o, class: c}]
      {:set_super, {o, s}} -> [%AL.Goal.RetractSuper{object: o, super: s}]
      {:set_method, {o, n, id}} -> [%AL.Goal.RetractMethod{object: o, name: n, id: id}]
      {:set_oapply, {o, _seq, h, _b}} -> [%AL.Goal.RetractOapply{object: o, head: h}]
      {:set_slots, {o, s}} -> [%AL.Goal.RetractSlots{object: o, slots: s}]
      _ -> []
    end
  end

  defp order(modules, by_name) do
    {ordered, _seen} =
      Enum.reduce(modules, {[], MapSet.new()}, fn m, acc -> visit(m, by_name, acc, []) end)

    Enum.reverse(ordered)
  end

  defp visit(m, by_name, {ordered, seen}, stack) do
    name = m.__package__().name

    cond do
      name in seen ->
        {ordered, seen}

      name in stack ->
        raise "AL package dependency cycle: #{inspect(Enum.reverse([name | stack]))}"

      true ->
        {ordered, seen} =
          Enum.reduce(m.__package__().deps, {ordered, seen}, fn dep, acc ->
            case Map.fetch(by_name, dep) do
              {:ok, dep_module} -> visit(dep_module, by_name, acc, [name | stack])
              :error -> raise "AL package #{inspect(name)} depends on unknown #{inspect(dep)}"
            end
          end)

        {[m | ordered], MapSet.put(seen, name)}
    end
  end
end
