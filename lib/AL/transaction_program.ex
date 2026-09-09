defmodule AL.TransactionProgram do
  @moduledoc """
  I define named transaction programs with `defprogram/3` and retain their execution receipts.
  """

  def configured do
    Application.get_env(:al, :transaction_programs, [])
  end

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
      _ -> :not_program_execution
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
    scopes = AL.Dispatch.MethodOrder.method_scopes(self.id, branch)

    if Enum.any?(receipt_classes(branch), &(&1 in scopes)) do
      case AL.Object.read_slots(self.id, branch) do
        [{:slots, _, %{tx: tx}}] -> {:ok, tx}
        _ -> {:error, :source_unavailable}
      end
    else
      :not_program_execution
    end
  end

  defmacro __using__(_opts) do
    quote do
      require AL
      import AL.TransactionProgram, only: [defprogram: 3]
    end
  end

  defmacro defprogram(name, opts, do: body) do
    version = Keyword.get(opts, :version, 1)
    deps = Keyword.get(opts, :deps, [])

    statements =
      case body do
        {:__block__, _, list} -> list
        single -> [single]
      end

    receipt =
      quote do
        new(
          :program_execution,
          %{
            name: unquote(name),
            version: unquote(version),
            deps: unquote(deps),
            redef: true
          },
          _
        )
      end

    program = {:__block__, [], statements ++ [receipt]}

    source_ast = {:defprogram, [], [name, opts, [do: body]]}
    source = Macro.to_string(source_ast)
    origin = %{kind: :transaction_program, file: __CALLER__.file, line: __CALLER__.line}

    quote do
      def __program__ do
        %{name: unquote(name), version: unquote(version), deps: unquote(deps)}
      end

      def install do
        :ok = AL.TransactionProgram.ensure_execution_class()

        AL.TransactionProgram.retain_install(unquote(source), unquote(Macro.escape(origin)), fn ->
          if function_exported?(__MODULE__, :__prepare_program_install__, 0) do
            :ok = apply(__MODULE__, :__prepare_program_install__, [])
          end

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
    :ok = ensure_execution_class()
    by_name = Map.new(modules, fn m -> {metadata(m).name, m} end)

    modules
    |> order(by_name)
    |> Enum.each(fn m ->
      program = metadata(m)
      ensure_current(program.name, program.version, &m.install/0)
    end)
  end

  @spec installed?(atom(), AL.Branch.t()) :: boolean()
  def installed?(name, branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn ->
           Enum.any?(execution_rows(branch), fn {:class, p, _seq, _class} ->
             match?([{:slots, ^p, %{name: ^name}}], AL.Object.read_slots(p, branch))
           end)
         end) do
      {:atomic, installed?} -> installed?
      _ -> false
    end
  end

  @spec current?(atom(), pos_integer(), AL.Branch.t()) :: boolean()
  def current?(name, version, branch \\ AL.Branch.head()) do
    case :mnesia.transaction(fn ->
           Enum.any?(execution_rows(branch), fn {:class, execution, _seq, _class} ->
             match?(
               [{:slots, ^execution, %{name: ^name, version: ^version}}],
               AL.Object.read_slots(execution, branch)
             )
           end)
         end) do
      {:atomic, current?} -> current?
      _ -> false
    end
  end

  @spec ensure(atom(), (-> any())) :: :ok
  def ensure(name, install) do
    if installed?(name) do
      :ok
    else
      case install.() do
        {:atomic, _} ->
          :ok

        {:aborted, reason} ->
          raise "AL transaction program #{inspect(name)} failed to install: #{explain(reason)}"
      end
    end
  end

  @spec ensure_current(atom(), pos_integer(), (-> any())) :: :ok
  def ensure_current(name, version, install) do
    if current?(name, version) do
      :ok
    else
      case install.() do
        {:atomic, _} ->
          :ok

        {:aborted, reason} ->
          raise "AL transaction program #{inspect(name)} failed to install: #{explain(reason)}"
      end
    end
  end

  defp explain(%{message: message}), do: message
  defp explain(reason), do: inspect(reason)

  @doc """
  I retract the supported facts a transaction program installed by reversing the commands of its
  install transaction (recorded in the receipt's `:tx` slot). I refuse if another
  installed transaction program depends on this one.
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
           case find_execution(name) do
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
        for {:class, p, _seq, _class} <- execution_rows(),
            {:slots, ^p, %{name: dependent, deps: deps}} <- AL.Object.read_slots(p),
            name in deps,
            do: dependent
      end)

    names
  end

  defp find_execution(name) do
    Enum.find_value(execution_rows(), fn {:class, p, _seq, _class} ->
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
    name = metadata(m).name

    cond do
      name in seen ->
        {ordered, seen}

      name in stack ->
        raise "AL transaction program dependency cycle: #{inspect(Enum.reverse([name | stack]))}"

      true ->
        {ordered, seen} =
          Enum.reduce(metadata(m).deps, {ordered, seen}, fn dep, acc ->
            case Map.fetch(by_name, dep) do
              {:ok, dep_module} ->
                visit(dep_module, by_name, acc, [name | stack])

              :error ->
                raise "AL transaction program #{inspect(name)} depends on unknown #{inspect(dep)}"
            end
          end)

        {[m | ordered], MapSet.put(seen, name)}
    end
  end

  defp metadata(module) do
    Code.ensure_loaded!(module)

    module.__program__()
  end

  defp receipt_classes(branch) do
    if legacy_receipt_class?(branch),
      do: [:program_execution, :package],
      else: [:program_execution]
  end

  defp legacy_receipt_class?(branch) do
    case AL.Object.read_slots(:package, branch) do
      [{:slots, :package, %{ivars: [:name, :version, :deps, :tx]}}] -> true
      _ -> false
    end
  end

  defp execution_rows(branch \\ AL.Branch.head()) do
    receipt_classes(branch)
    |> Enum.flat_map(&AL.Object.scan_class(:"$execution", &1, branch))
    |> Enum.uniq_by(fn {:class, object, _seq, _class} -> object end)
  end

  def ensure_execution_class do
    branch = AL.Branch.head()

    result =
      :mnesia.transaction(fn ->
        if legacy_receipt_class?(branch) do
          program_execution_definition =
            if AL.Object.scan_class(:program_execution, :class, branch) == [] do
              """
              new(:class, %{name: :program_execution, super: :object, ivars: [:name, :version, :deps, :tx]}, _)
              import(:program_execution, :package)
              """
            else
              ""
            end

          receipt_migration =
            AL.Object.scan_class(AL.Var.var("legacy_program_receipt"), :package, branch)
            |> Enum.map_join("\n", fn {:class, receipt, _seq, :package} ->
              """
              vm_retract_class(#{inspect(receipt)}, :package)
              vm_set_class(#{inspect(receipt)}, :program_execution)
              """
            end)

          source =
            program_execution_definition <>
              receipt_migration <>
              """
              delete_class(:package)
              """

          case AL.eval_source(source, branch) do
            {:atomic, _} -> :ok
            {:aborted, reason} -> :mnesia.abort(reason)
          end
        else
          :ok
        end
      end)

    case result do
      {:atomic, :ok} -> :ok
      {:aborted, reason} -> raise "AL program execution receipt setup failed: #{explain(reason)}"
    end
  end
end
