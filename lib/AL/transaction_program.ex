defmodule AL.TransactionProgram do
  @moduledoc """
  I load named transaction programs from `priv/programs/*.al` and retain their execution receipts.
  """

  def configured do
    :al
    |> Application.get_env(:transaction_programs, [])
    |> Enum.map(&load/1)
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

    if :program_execution in scopes do
      case AL.Object.read_slots(self.id, branch) do
        [{:slots, _, %{tx: tx}}] -> {:ok, tx}
        _ -> {:error, :source_unavailable}
      end
    else
      :not_program_execution
    end
  end

  @enforce_keys [:name, :version, :deps, :text, :origin]
  defstruct [:name, :version, :deps, :text, :origin]

  @type t() :: %__MODULE__{
          name: atom(),
          version: term(),
          deps: [atom()],
          text: String.t(),
          origin: AL.SourceStore.origin()
        }

  @spec load(atom()) :: t()
  def load(name) when is_atom(name) do
    file = Path.join(["priv", "programs", "#{name}.al"])
    path = Path.join(:code.priv_dir(:al), Path.relative_to(file, "priv"))
    program = from_source(File.read!(path), %{kind: :transaction_program, file: file})

    if program.name != name,
      do: raise("AL transaction program file #{path} declares #{inspect(program.name)}")

    program
  end

  @spec from_source(String.t(), AL.SourceStore.origin()) :: t()
  def from_source(text, origin) do
    case AL.Syntax.parse_program(text) do
      {:ok, %{name: name, version: version, deps: deps}, _result} ->
        %__MODULE__{name: name, version: version, deps: deps, text: text, origin: origin}

      {:error, error} ->
        raise "AL transaction program source is invalid: #{Exception.message(error)}"
    end
  end

  @spec install(t()) :: {:atomic, term()} | {:aborted, term()}
  def install(%__MODULE__{} = program) do
    retain_install(program.text, program.origin, fn ->
      {:ok, _declaration, result} = AL.Syntax.parse_program(program.text)

      receipt = %AL.Goal.Send{
        object: :program_execution,
        method: :new,
        args: [
          %{name: program.name, version: program.version, deps: program.deps},
          AL.Var.var(:_)
        ]
      }

      AL.eval_captured(
        %{result | program: result.program ++ [receipt]},
        program.text,
        program.origin,
        nil,
        AL.Branch.head(),
        []
      )
    end)
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

  @spec install_all([t()]) :: :ok
  def install_all(programs) do
    by_name = Map.new(programs, fn program -> {program.name, program} end)

    programs
    |> order(by_name)
    |> Enum.each(fn program ->
      ensure_installed(program)
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

  @spec ensure_installed(t()) :: :ok
  def ensure_installed(%__MODULE__{} = program),
    do: ensure(program.name, fn -> install(program) end)

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

  defp order(programs, by_name) do
    {ordered, _seen} =
      Enum.reduce(programs, {[], MapSet.new()}, fn program, acc ->
        visit(program, by_name, acc, [])
      end)

    Enum.reverse(ordered)
  end

  defp visit(program, by_name, {ordered, seen}, stack) do
    name = program.name

    cond do
      name in seen ->
        {ordered, seen}

      name in stack ->
        raise "AL transaction program dependency cycle: #{inspect(Enum.reverse([name | stack]))}"

      true ->
        {ordered, seen} =
          Enum.reduce(program.deps, {ordered, seen}, fn dep, acc ->
            case Map.fetch(by_name, dep) do
              {:ok, dependency} ->
                visit(dependency, by_name, acc, [name | stack])

              :error ->
                raise "AL transaction program #{inspect(name)} depends on unknown #{inspect(dep)}"
            end
          end)

        {[program | ordered], MapSet.put(seen, name)}
    end
  end

  defp execution_rows(branch \\ AL.Branch.head()),
    do: AL.Object.scan_class({:"$var", "execution"}, :program_execution, branch)
end
