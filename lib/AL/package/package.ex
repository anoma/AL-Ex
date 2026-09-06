defmodule AL.Package do
  @moduledoc """
  I define and install AL packages. A package is a durable object created as the
  receipt of running its definitions, authored with `defpackage/3`.
  """

  def source(self = %AL.Object{}) do
    branch = %AL.Branch{id: AL.Object.branch_id(self)}

    case :mnesia.transaction(fn ->
           case installation_tx(self, branch) do
             {:ok, tx} ->
               id = transaction_id(tx, branch)

               case AL.SourceStore.text(id, branch) do
                 {:source_text, ^id, text, _origin} -> {:ok, text}
                 :absent -> {:error, :source_unavailable}
               end

             other ->
               other
           end
         end) do
      {:atomic, result} -> result
      _ -> :not_package
    end
  end

  def source_rows(self = %AL.Object{}) do
    branch = %AL.Branch{id: AL.Object.branch_id(self)}

    case :mnesia.transaction(fn ->
           case installation_tx(self, branch) do
             {:ok, tx} -> AL.Source.transaction_method_rows(transaction_id(tx, branch), branch)
             _ -> []
           end
         end) do
      {:atomic, rows} -> rows
      _ -> []
    end
  end

  defp transaction_id({:transaction, tx}, _branch), do: tx

  defp transaction_id(tx, branch) when is_atom(tx) do
    case AL.Object.read_slots(tx, branch) do
      [{:slots, _, %{tx: command_tx}}] when is_integer(command_tx) -> command_tx
      _ -> tx
    end
  end

  defp transaction_id(tx, _branch), do: tx

  defp installation_tx(self, branch) do
    if :package in AL.Dispatch.MethodOrder.method_scopes(self.id, branch) do
      case AL.Object.read_slots(self.id, branch) do
        [{:slots, _, %{tx: tx}}] -> {:ok, tx}
        _ -> {:error, :source_unavailable}
      end
    else
      :not_package
    end
  end

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

    source_ast = {:defpackage, [], [name, opts, [do: body]]}
    source = Macro.to_string(source_ast)
    origin = %{kind: :package, file: __CALLER__.file, line: __CALLER__.line}

    quote do
      def __package__ do
        %{name: unquote(name), version: unquote(version), deps: unquote(deps)}
      end

      def install do
        AL.Package.retain_install(unquote(source), unquote(Macro.escape(origin)), fn ->
          AL.run do
            unquote(program)
          end
        end)
      end
    end
  end

  def retain_install(text, origin, install) do
    branch = AL.Branch.head()

    :mnesia.transaction(fn ->
      tx = AL.Command.system_time(branch)

      case install.() do
        {:atomic, result} ->
          retain_transaction_source(result, text, origin, branch)

          if AL.SourceStore.text(tx, branch) == :absent do
            AL.SourceStore.put_text(tx, text, origin, branch)
          end

          result

        {:aborted, reason} ->
          :mnesia.abort(reason)

        {:error, reason} ->
          :mnesia.abort(reason)
      end
    end)
  end

  defp retain_transaction_source(
         {_bindings, %AL{transaction_object: object}},
         text,
         origin,
         branch
       )
       when is_atom(object) do
    case AL.Object.read_slots(object, branch) do
      [{:slots, _, %{tx: command_tx}}] when is_integer(command_tx) ->
        if AL.SourceStore.text(command_tx, branch) == :absent do
          AL.SourceStore.put_text(command_tx, text, origin, branch)
        end

      _ ->
        :ok
    end
  end

  defp retain_transaction_source(_result, _text, _origin, _branch), do: :ok

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
           Enum.any?(AL.Object.scan_class(:"$p", :package), fn {:class, p, _seq, :package} ->
             match?([{:slots, ^p, %{name: ^name}}], AL.Object.read_slots(p))
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
    branch = AL.Branch.head()

    case :mnesia.transaction(fn ->
           case find_package(name) do
             {_p, %{tx: tx}} ->
               AL.Command.commands_for_transaction(transaction_id(tx, branch), branch)

             _ ->
               nil
           end
         end) do
      {:atomic, nil} ->
        {:error, :not_installed}

      {:atomic, commands} ->
        commands
        |> Enum.reverse()
        |> Enum.flat_map(&inverse/1)
        |> AL.eval(nil, branch)

      other ->
        other
    end
  end

  defp dependents(name) do
    {:atomic, names} =
      :mnesia.transaction(fn ->
        for {:class, p, _seq, :package} <- AL.Object.scan_class(:"$p", :package),
            {:slots, ^p, %{name: dependent, deps: deps}} <- AL.Object.read_slots(p),
            name in deps,
            do: dependent
      end)

    names
  end

  defp find_package(name) do
    Enum.find_value(AL.Object.scan_class(:"$p", :package), fn {:class, p, _seq, :package} ->
      case AL.Object.read_slots(p) do
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
      {:set_slot, {o, k, _v, _store}} -> [%AL.Goal.RetractSlot{object: o, key: k}]
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
