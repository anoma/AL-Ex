defmodule AL.Tooling do
  @moduledoc """
  Stable inspection boundary shared by external tooling.

  Results are JSON-safe maps. Snapshot reads use AL's structured APIs, while
  relational observations execute as ordinary AL runs and retain their history.
  """

  require AL

  @default_command_limit 200
  @maximum_command_limit 1_000
  @default_result_limit 100
  @maximum_result_limit 500
  @default_trace_limit 200
  @maximum_trace_limit 1_000

  @spec find_references(atom(), AL.Branch.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def find_references(target, branch \\ AL.Branch.head(), opts \\ [])

  def find_references(target, branch, opts) when is_atom(target) and is_list(opts) do
    with {:ok, offset, limit} <- result_page(opts),
         {:ok, bindings, state} <- reference_run(target, branch) do
      references =
        bindings
        |> references(target)
        |> Enum.sort_by(&reference_sort_key/1)

      {:ok,
       %{
         "target" => identity(target),
         "branch" => branch_name(branch),
         "observation" => observation(state),
         "references" => Enum.slice(references, offset, limit),
         "resultPage" => page(offset, limit, length(references))
       }}
    end
  end

  def find_references(_target, _branch, _opts), do: {:error, :invalid_reference_target}

  @spec inspect_failure(non_neg_integer(), AL.Branch.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def inspect_failure(tx, branch \\ AL.Branch.head(), opts \\ [])

  def inspect_failure(tx, branch, opts)
      when is_integer(tx) and tx >= 0 and is_list(opts) do
    offset = Keyword.get(opts, :trace_offset, 0)
    limit = Keyword.get(opts, :trace_limit, @default_trace_limit)

    if is_integer(offset) and offset >= 0 and is_integer(limit) and limit >= 1 and
         limit <= @maximum_trace_limit do
      with {:ok, bindings, state} <- failure_run(tx, branch),
           {:ok, failure} <- failure_from_bindings(bindings) do
        {:ok, failure_result(tx, branch, failure, state, offset, limit)}
      end
    else
      {:error, {:invalid_trace_page, @maximum_trace_limit}}
    end
  end

  def inspect_failure(_tx, _branch, _opts), do: {:error, :invalid_transaction}

  @spec search_definitions(String.t(), AL.Branch.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def search_definitions(query, branch \\ AL.Branch.head(), opts \\ [])

  def search_definitions(query, branch, opts) when is_binary(query) and is_list(opts) do
    with :ok <- validate_query(query),
         {:ok, offset, limit} <- result_page(opts),
         {:ok, snapshot} <- AL.Serialisation.Snapshot.capture(branch) do
      matches =
        snapshot.documents
        |> Enum.map(fn {_owner, document} -> definition_match(document, query) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1["owner"])

      {:ok,
       %{
         "query" => query,
         "branch" => branch_name(branch),
         "matches" => Enum.slice(matches, offset, limit),
         "resultPage" => page(offset, limit, length(matches))
       }}
    end
  end

  def search_definitions(_query, _branch, _opts), do: {:error, :invalid_search_query}

  @spec diff_branches(AL.Branch.t(), AL.Branch.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def diff_branches(from_branch, to_branch, opts \\ [])

  def diff_branches(from_branch, to_branch, opts) when is_list(opts) do
    with {:ok, offset, limit} <- result_page(opts),
         {:ok, from_snapshot} <- AL.Serialisation.Snapshot.capture(from_branch),
         {:ok, to_snapshot} <- AL.Serialisation.Snapshot.capture(to_branch) do
      changes = definition_changes(from_snapshot.documents, to_snapshot.documents)

      {:ok,
       %{
         "fromBranch" => branch_name(from_branch),
         "fromCommandPosition" => AL.Command.system_time(from_branch),
         "toBranch" => branch_name(to_branch),
         "toCommandPosition" => AL.Command.system_time(to_branch),
         "changes" => Enum.slice(changes, offset, limit),
         "resultPage" => page(offset, limit, length(changes))
       }}
    end
  end

  def diff_branches(_from_branch, _to_branch, _opts), do: {:error, :invalid_result_page}

  @spec inspect_object(term(), AL.Branch.t()) :: {:ok, map()} | {:error, term()}
  def inspect_object(object, branch \\ AL.Branch.head()) do
    with {:ok, bindings, state} <- object_run(object, branch) do
      object_result(object, branch, bindings, state)
    end
  end

  @spec inspect_method(term(), atom(), AL.Branch.t()) :: {:ok, map()} | {:error, term()}
  def inspect_method(owner, selector, branch \\ AL.Branch.head()) when is_atom(selector) do
    with {:ok, bindings, state} <- method_run(owner, selector, branch) do
      method_result(owner, selector, branch, bindings, state)
    end
  end

  @spec inspect_transaction(non_neg_integer(), AL.Branch.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def inspect_transaction(tx, branch \\ AL.Branch.head(), opts \\ [])

  def inspect_transaction(tx, branch, opts)
      when is_integer(tx) and tx >= 0 and is_list(opts) do
    offset = Keyword.get(opts, :command_offset, 0)
    limit = Keyword.get(opts, :command_limit, @default_command_limit)

    cond do
      not is_integer(offset) or offset < 0 ->
        {:error, :invalid_command_offset}

      not is_integer(limit) or limit < 1 or limit > @maximum_command_limit ->
        {:error, {:invalid_command_limit, @maximum_command_limit}}

      true ->
        with {:ok, bindings, state} <- transaction_run(tx, branch) do
          transaction_result(tx, branch, bindings, state, offset, limit)
        end
    end
  end

  def inspect_transaction(_tx, _branch, _opts), do: {:error, :invalid_transaction}

  @spec list_packages(AL.Branch.t()) :: {:ok, map()} | {:error, term()}
  def list_packages(branch \\ AL.Branch.head()) do
    with {:ok, bindings, state} <- packages_run(branch) do
      {:ok,
       %{
         "branch" => branch_name(branch),
         "observation" => observation(state),
         "packages" => package_summaries(binding(bindings, :packages), branch)
       }}
    end
  end

  @spec inspect_package(atom(), AL.Branch.t()) :: {:ok, map()} | {:error, term()}
  def inspect_package(name, branch \\ AL.Branch.head()) when is_atom(name) do
    with {:ok, bindings, state} <- package_run(name, branch) do
      package_result(name, branch, bindings, state)
    end
  end

  @spec explain_method_lookup(term(), atom(), AL.Branch.t()) ::
          {:ok, map()} | {:error, term()}
  def explain_method_lookup(receiver, selector, branch \\ AL.Branch.head())
      when is_atom(selector) do
    with {:ok, bindings, state} <- method_lookup_run(receiver, selector, branch) do
      {:ok, method_lookup_result(receiver, selector, branch, bindings, state)}
    end
  end

  defp reference_run(target, branch) do
    AL.run branch: branch.id do
      findall(class, [class(^target, class)], target_classes)
      findall(object, [class(object, ^target), label(object)], instances)
      findall(superclass, [super(^target, superclass)], supers)
      findall(subclass, [super(subclass, ^target)], subclasses)

      findall(
        [owner, selector, method_id],
        [vm_method(owner, selector, method_id)],
        method_bindings
      )

      findall(
        [method_id, sequence, head, body],
        [vm_clause(method_id, sequence, head, body)],
        clauses
      )
    end
    |> al_run_result()
  end

  defp failure_run(tx, branch) do
    AL.run branch: branch.id do
      findall(
        [transaction, status, reasons, sources],
        [
          class(transaction, :transaction),
          label(transaction),
          get(transaction, :tx, ^tx),
          get(transaction, :status, status),
          findall(reason, [get(transaction, :reason, reason)], reasons),
          findall(source, [listing(transaction, source)], sources)
        ],
        failures
      )
    end
    |> al_run_result()
  end

  defp object_run(object, branch) do
    AL.run branch: branch.id do
      findall(class, [class(^object, class)], object_classes)
      findall(superclass, [super(^object, superclass)], object_supers)
      findall([selector, method_id], [vm_method(^object, selector, method_id)], object_methods)

      findall(
        [sequence, head, body],
        [vm_clause(^object, sequence, head, body)],
        object_clauses
      )

      findall([key, value], [vm_get_slot(^object, key, value)], object_aos_slots)
      findall([key, value], [vm_get_slot(^object, key, value, :soa)], object_soa_slots)
    end
    |> al_run_result()
  end

  defp method_run(owner, selector, branch) do
    AL.run branch: branch.id do
      findall(
        [method_id, clauses, sources],
        [
          vm_method(^owner, ^selector, method_id),
          findall(
            [sequence, head, body],
            [vm_clause(method_id, sequence, head, body)],
            clauses
          ),
          findall(
            [sequence, text, provenance],
            [vm_method_source(method_id, sequence, text, provenance)],
            sources
          )
        ],
        inspected_methods
      )
    end
    |> al_run_result()
  end

  defp transaction_run(tx, branch) do
    AL.run branch: branch.id do
      findall(
        [transaction, status, reasons, slots],
        [
          class(transaction, :transaction),
          label(transaction),
          get(transaction, :tx, ^tx),
          get(transaction, :status, status),
          findall(reason, [get(transaction, :reason, reason)], reasons),
          findall([key, value], [vm_get_slot(transaction, key, value)], slots)
        ],
        inspected_transactions
      )

      findall(
        [text, origin],
        [vm_transaction_source(^tx, text, origin)],
        transaction_sources
      )

      findall(
        [time, operation],
        [vm_command(^tx, time, operation)],
        transaction_commands
      )
    end
    |> al_run_result()
  end

  defp packages_run(branch) do
    AL.run branch: branch.id do
      findall(
        [package, active_builds, builds, providers],
        [
          class(package, :package),
          label(package),
          findall(active_build, [active_build(package, active_build)], active_builds),
          findall(build, [class(build, package), label(build)], builds),
          findall(
            provider,
            [
              class(provider, :package_provider),
              label(provider),
              provides(provider, package)
            ],
            providers
          )
        ],
        packages
      )
    end
    |> al_run_result()
  end

  defp package_run(name, branch) do
    AL.run branch: branch.id do
      findall(
        [active_builds, builds, providers],
        [
          class(^name, :package),
          findall(active_build, [active_build(^name, active_build)], active_builds),
          findall(
            [build, slots],
            [
              class(build, ^name),
              label(build),
              findall([key, value], [vm_get_slot(build, key, value)], slots)
            ],
            builds
          ),
          findall(
            [provider, slots],
            [
              class(provider, :package_provider),
              label(provider),
              provides(provider, ^name),
              findall([key, value], [vm_get_slot(provider, key, value)], slots)
            ],
            providers
          )
        ],
        inspected_packages
      )
    end
    |> al_run_result()
  end

  defp method_lookup_run(receiver, selector, branch) do
    AL.run branch: branch.id do
      inheritance_chain(^receiver, lookup_scopes)

      findall(
        [scope, method_id, clauses],
        [
          member(lookup_scopes, scope),
          vm_method(scope, ^selector, method_id),
          findall(
            [sequence, head, body],
            [vm_clause(method_id, sequence, head, body)],
            clauses
          )
        ],
        lookup_providers
      )
    end
    |> al_run_result()
  end

  defp al_run_result({:atomic, {bindings, %AL{} = state}}), do: {:ok, bindings, state}
  defp al_run_result({:aborted, reason}), do: {:error, {:al_run_failed, reason}}
  defp al_run_result({:error, reason}), do: {:error, {:al_run_failed, reason}}

  defp references(bindings, target) do
    relation_references(bindings, target) ++ clause_references(bindings, target)
  end

  defp relation_references(bindings, target) do
    Enum.map(binding(bindings, :target_classes), fn class ->
      %{"kind" => "class", "object" => identity(target), "class" => identity(class)}
    end) ++
      Enum.map(binding(bindings, :instances), fn object ->
        %{"kind" => "instance", "object" => identity(object), "class" => identity(target)}
      end) ++
      Enum.map(binding(bindings, :supers), fn superclass ->
        %{
          "kind" => "superclass",
          "class" => identity(target),
          "superclass" => identity(superclass)
        }
      end) ++
      Enum.map(binding(bindings, :subclasses), fn subclass ->
        %{
          "kind" => "subclass",
          "class" => identity(subclass),
          "superclass" => identity(target)
        }
      end) ++ method_binding_references(binding(bindings, :method_bindings), target)
  end

  defp method_binding_references(rows, target) do
    Enum.flat_map(rows, fn [owner, selector, method_id] ->
      [
        if(owner == target,
          do: %{
            "kind" => "methodOwner",
            "owner" => identity(owner),
            "selector" => identity(selector),
            "methodId" => identity(method_id)
          }
        ),
        if(selector == target,
          do: %{
            "kind" => "selector",
            "owner" => identity(owner),
            "selector" => identity(selector),
            "methodId" => identity(method_id)
          }
        ),
        if(method_id == target,
          do: %{
            "kind" => "methodBinding",
            "owner" => identity(owner),
            "selector" => identity(selector),
            "methodId" => identity(method_id)
          }
        )
      ]
      |> Enum.reject(&is_nil/1)
    end)
  end

  defp clause_references(bindings, target) do
    method_owners =
      Map.new(binding(bindings, :method_bindings), fn [owner, selector, method_id] ->
        {method_id, {owner, selector}}
      end)

    Enum.flat_map(binding(bindings, :clauses), fn [method_id, sequence, head, body] ->
      {owner, selector} = Map.get(method_owners, method_id, {nil, nil})

      [{"head", term_paths(head, target)}, {"body", term_paths(body, target)}]
      |> Enum.flat_map(fn
        {_field, []} ->
          []

        {field, paths} ->
          [
            %{
              "kind" => "clause#{String.capitalize(field)}",
              "owner" => identity(owner),
              "selector" => identity(selector),
              "methodId" => identity(method_id),
              "clauseSequence" => sequence,
              "paths" => paths
            }
          ]
      end)
    end)
  end

  defp term_paths(term, target), do: term_paths(term, target, [])

  defp term_paths(term, target, path) when term == target,
    do: [Enum.reverse(path)]

  defp term_paths(term, target, path) when is_struct(term) do
    term
    |> Map.from_struct()
    |> term_paths(target, path)
  end

  defp term_paths(term, target, path) when is_map(term) do
    Enum.flat_map(term, fn {key, value} ->
      term_paths(key, target, ["key" | path]) ++
        term_paths(value, target, [identity(key) | path])
    end)
  end

  defp term_paths(term, target, path) when is_tuple(term) do
    term
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} -> term_paths(value, target, [index | path]) end)
  end

  defp term_paths([_head | _tail] = term, target, path) do
    list_term_paths(term, target, path, 0)
  end

  defp term_paths(_term, _target, _path), do: []

  defp list_term_paths([], _target, _path, _index), do: []

  defp list_term_paths([head | tail], target, path, index) do
    head_paths = term_paths(head, target, [index | path])

    tail_paths =
      if is_list(tail) do
        list_term_paths(tail, target, path, index + 1)
      else
        term_paths(tail, target, ["tail" | path])
      end

    head_paths ++ tail_paths
  end

  defp reference_sort_key(reference) do
    {
      reference["kind"],
      reference["owner"],
      reference["selector"],
      reference["clauseSequence"],
      Jason.encode!(reference)
    }
  end

  defp failure_from_bindings(bindings) do
    case binding(bindings, :failures) do
      [] ->
        {:error, :transaction_not_found}

      [[transaction, :failed, [reason | _], sources] | _] ->
        {:ok, %{transaction: transaction, reason: reason, sources: sources}}

      [[_transaction, status, _reasons, _sources] | _] ->
        {:error, {:transaction_not_failed, status}}
    end
  end

  defp failure_result(tx, branch, failure, state, offset, limit) do
    reason = failure.reason
    trace = if is_map(reason), do: Map.get(reason, :trace, []), else: []
    trace_page = Enum.slice(trace, offset, limit)

    %{
      "transaction" => tx,
      "object" => identity(failure.transaction),
      "branch" => branch_name(branch),
      "status" => "failed",
      "message" => if(is_map(reason), do: Map.get(reason, :message), else: nil),
      "causeKind" => cause_kind(reason),
      "reason" => reason |> without_failure_state() |> json_value(),
      "failedOn" => if(is_map(reason), do: json_value(Map.get(reason, :failed_on)), else: nil),
      "source" => List.first(failure.sources),
      "methodPath" => method_path(trace),
      "trace" => Enum.map(trace_page, &json_value/1),
      "tracePage" => page(offset, limit, length(trace)),
      "failureState" => failure_state(reason),
      "observation" => observation(state)
    }
  end

  defp without_failure_state(reason) when is_map(reason), do: Map.delete(reason, :state)
  defp without_failure_state(reason), do: reason

  defp cause_kind(%{reason: {kind, _rest}}) when is_atom(kind), do: Atom.to_string(kind)
  defp cause_kind(%{reason: reason}) when is_tuple(reason), do: reason |> elem(0) |> identity()
  defp cause_kind(_reason), do: nil

  defp method_path(trace) do
    Enum.flat_map(trace, fn
      {:method_call, _scope, receiver, selector, args, _constraints} ->
        [
          %{
            "receiver" => json_value(receiver),
            "selector" => identity(selector),
            "arguments" => json_value(args)
          }
        ]

      _other ->
        []
    end)
  end

  defp failure_state(%{state: %AL{} = state}) do
    %{
      "branch" => branch_name(state.branch),
      "reductions" => state.reductions,
      "choicepointDepth" => length(state.choicepoint_stack),
      "diagnostics" => json_value(state.diagnostics)
    }
  end

  defp failure_state(_reason), do: nil

  defp binding(bindings, :target_classes), do: Map.get(bindings, :"$target_classes", [])
  defp binding(bindings, :instances), do: Map.get(bindings, :"$instances", [])
  defp binding(bindings, :supers), do: Map.get(bindings, :"$supers", [])
  defp binding(bindings, :subclasses), do: Map.get(bindings, :"$subclasses", [])
  defp binding(bindings, :method_bindings), do: Map.get(bindings, :"$method_bindings", [])
  defp binding(bindings, :clauses), do: Map.get(bindings, :"$clauses", [])
  defp binding(bindings, :failures), do: Map.get(bindings, :"$failures", [])
  defp binding(bindings, :object_classes), do: Map.get(bindings, :"$object_classes", [])
  defp binding(bindings, :object_supers), do: Map.get(bindings, :"$object_supers", [])
  defp binding(bindings, :object_methods), do: Map.get(bindings, :"$object_methods", [])
  defp binding(bindings, :object_clauses), do: Map.get(bindings, :"$object_clauses", [])
  defp binding(bindings, :object_aos_slots), do: Map.get(bindings, :"$object_aos_slots", [])
  defp binding(bindings, :object_soa_slots), do: Map.get(bindings, :"$object_soa_slots", [])
  defp binding(bindings, :inspected_methods), do: Map.get(bindings, :"$inspected_methods", [])

  defp binding(bindings, :inspected_transactions),
    do: Map.get(bindings, :"$inspected_transactions", [])

  defp binding(bindings, :transaction_sources),
    do: Map.get(bindings, :"$transaction_sources", [])

  defp binding(bindings, :transaction_commands),
    do: Map.get(bindings, :"$transaction_commands", [])

  defp binding(bindings, :packages), do: Map.get(bindings, :"$packages", [])

  defp binding(bindings, :inspected_packages),
    do: Map.get(bindings, :"$inspected_packages", [])

  defp binding(bindings, :lookup_providers),
    do: Map.get(bindings, :"$lookup_providers", [])

  defp binding(bindings, :lookup_scopes), do: Map.get(bindings, :"$lookup_scopes", [])

  defp observation(%AL{} = state) do
    %{
      "transaction" => state.tx_id,
      "object" => identity(state.transaction_object)
    }
  end

  defp object_result(object, branch, bindings, state) do
    classes = binding(bindings, :object_classes)
    supers = binding(bindings, :object_supers)
    methods = binding(bindings, :object_methods)
    clauses = binding(bindings, :object_clauses)
    aos_slots = binding(bindings, :object_aos_slots)
    soa_slots = Enum.filter(binding(bindings, :object_soa_slots), &user_slot?/1)

    if classes == [] and supers == [] and methods == [] and clauses == [] and aos_slots == [] and
         soa_slots == [] do
      {:error, :object_not_found}
    else
      {:ok,
       %{
         "object" => identity(object),
         "branch" => branch_name(branch),
         "observation" => observation(state),
         "classes" => Enum.map(classes, &identity/1),
         "supers" => Enum.map(supers, &identity/1),
         "slots" =>
           Enum.sort_by(
             Enum.map(aos_slots, &slot(&1, :aos)) ++ Enum.map(soa_slots, &slot(&1, :soa)),
             &Jason.encode!/1
           ),
         "methods" => Enum.map(methods, &method_binding/1),
         "clauses" => Enum.map(clauses, &stored_clause/1)
       }}
    end
  end

  defp method_result(owner, selector, branch, bindings, state) do
    case binding(bindings, :inspected_methods) do
      [] ->
        {:error, :method_not_found}

      methods ->
        {:ok,
         %{
           "owner" => identity(owner),
           "selector" => identity(selector),
           "branch" => branch_name(branch),
           "observation" => observation(state),
           "bindings" => Enum.map(methods, &method_detail(&1, owner, selector))
         }}
    end
  end

  defp transaction_result(tx, branch, bindings, state, offset, limit) do
    case binding(bindings, :inspected_transactions) do
      [] ->
        {:error, :transaction_not_found}

      [[object, status, reasons, slots] | _] ->
        commands = binding(bindings, :transaction_commands) |> Enum.sort_by(&List.first/1)
        command_page = Enum.slice(commands, offset, limit)
        source = List.first(binding(bindings, :transaction_sources))

        {:ok,
         %{
           "transaction" => tx,
           "object" => identity(object),
           "branch" => branch_name(branch),
           "status" => atom_string(status),
           "reason" => json_value(List.first(reasons)),
           "slots" => slots |> pairs_to_map() |> json_value(),
           "source" => transaction_source(tx, source),
           "commands" => Enum.map(command_page, &command(&1, tx)),
           "commandPage" => page(offset, limit, length(commands)),
           "observation" => observation(state)
         }}
    end
  end

  defp package_summaries(packages, branch) do
    packages
    |> Enum.map(fn [name, active_builds, builds, providers] ->
      %{
        "name" => identity(name),
        "branch" => branch_name(branch),
        "activeBuild" => identity(List.first(active_builds)),
        "buildCount" => length(builds),
        "providerCount" => length(providers)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  defp package_result(name, branch, bindings, state) do
    case binding(bindings, :inspected_packages) do
      [] ->
        {:error, :package_not_found}

      [[active_builds, builds, providers] | _] ->
        {:ok,
         %{
           "name" => identity(name),
           "branch" => branch_name(branch),
           "activeBuild" => identity(List.first(active_builds)),
           "buildCount" => length(builds),
           "providerCount" => length(providers),
           "builds" => Enum.map(builds, &package_record/1),
           "providers" => Enum.map(providers, &package_record/1),
           "observation" => observation(state)
         }}
    end
  end

  defp method_lookup_result(receiver, selector, branch, bindings, state) do
    scopes = binding(bindings, :lookup_scopes)

    providers =
      binding(bindings, :lookup_providers)
      |> Enum.with_index()
      |> Enum.map(fn {[scope, method_id, clauses], order} ->
        %{
          "order" => order,
          "scope" => identity(scope),
          "methodId" => identity(method_id),
          "clauseCount" => length(clauses),
          "implementation" => if(clauses == [], do: "native", else: "clauses")
        }
      end)

    suggestions =
      if providers == [],
        do: Enum.map(AL.Dispatch.suggest(receiver, selector, branch), &Atom.to_string/1),
        else: []

    %{
      "receiver" => identity(receiver),
      "selector" => identity(selector),
      "branch" => branch_name(branch),
      "scopes" => Enum.map(scopes, &identity/1),
      "providers" => providers,
      "suggestions" => suggestions,
      "decision" =>
        "Providers are tried in order; the first provider with a clause matching the call arguments wins.",
      "observation" => observation(state)
    }
  end

  defp definition_match(document, query) do
    normalized_query = String.downcase(query)

    document_fields =
      [
        {"owner", identity(document.owner)},
        {"kind", Atom.to_string(document.kind)},
        {"comment", document.comment}
      ]

    matched_fields = matching_fields(document_fields, normalized_query)

    method_matches =
      document.methods
      |> Enum.with_index()
      |> Enum.flat_map(fn {method, clause_index} ->
        fields =
          [
            {"selector", identity(method.selector)},
            {"declaration", method.declaration},
            {"body", method.body}
          ]

        case matching_fields(fields, normalized_query) do
          [] ->
            []

          method_fields ->
            [
              %{
                "selector" => identity(method.selector),
                "clauseIndex" => clause_index,
                "matchedFields" => method_fields,
                "snippet" => matching_snippet(method.declaration <> "\n" <> method.body, query)
              }
            ]
        end
      end)

    if matched_fields == [] and method_matches == [] do
      nil
    else
      %{
        "owner" => identity(document.owner),
        "kind" => Atom.to_string(document.kind),
        "matchedFields" => matched_fields,
        "methods" => method_matches
      }
    end
  end

  defp matching_fields(fields, normalized_query) do
    fields
    |> Enum.filter(fn {_field, value} ->
      is_binary(value) and String.contains?(String.downcase(value), normalized_query)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp matching_snippet(text, query) do
    text
    |> String.split("\n")
    |> Enum.find(String.slice(text, 0, 240), fn line ->
      String.contains?(String.downcase(line), String.downcase(query))
    end)
    |> String.trim()
    |> String.slice(0, 240)
  end

  defp definition_changes(from_documents, to_documents) do
    (Map.keys(from_documents) ++ Map.keys(to_documents))
    |> Enum.uniq()
    |> Enum.sort_by(&identity/1)
    |> Enum.flat_map(fn owner ->
      case {Map.get(from_documents, owner), Map.get(to_documents, owner)} do
        {nil, to_document} ->
          [
            %{
              "owner" => identity(owner),
              "change" => "added",
              "definition" => definition_summary(to_document)
            }
          ]

        {from_document, nil} ->
          [
            %{
              "owner" => identity(owner),
              "change" => "removed",
              "definition" => definition_summary(from_document)
            }
          ]

        {document, document} ->
          []

        {from_document, to_document} ->
          [modified_definition(owner, from_document, to_document)]
      end
    end)
  end

  defp definition_summary(document) do
    %{
      "kind" => Atom.to_string(document.kind),
      "metaclass" => identity(document.metaclass),
      "supers" => Enum.map(document.supers, &identity/1),
      "ivars" => Enum.map(document.ivars, &identity/1),
      "methodCount" => length(document.methods),
      "selectors" => document.methods |> Enum.map(&identity(&1.selector)) |> Enum.uniq()
    }
  end

  defp modified_definition(owner, from_document, to_document) do
    metadata =
      [
        {"kind", Atom.to_string(from_document.kind), Atom.to_string(to_document.kind)},
        {"metaclass", identity(from_document.metaclass), identity(to_document.metaclass)},
        {"supers", Enum.map(from_document.supers, &identity/1),
         Enum.map(to_document.supers, &identity/1)},
        {"ivars", Enum.map(from_document.ivars, &identity/1),
         Enum.map(to_document.ivars, &identity/1)},
        {"comment", from_document.comment, to_document.comment}
      ]
      |> Enum.flat_map(fn
        {_field, value, value} -> []
        {field, from, to} -> [%{"field" => field, "from" => from, "to" => to}]
      end)

    %{
      "owner" => identity(owner),
      "change" => "modified",
      "metadata" => metadata,
      "methods" => method_changes(from_document.methods, to_document.methods)
    }
  end

  defp method_changes(from_methods, to_methods) do
    from = indexed_methods(from_methods)
    to = indexed_methods(to_methods)

    (Map.keys(from) ++ Map.keys(to))
    |> Enum.uniq()
    |> Enum.sort_by(fn {selector, occurrence} -> {identity(selector), occurrence} end)
    |> Enum.flat_map(fn {selector, occurrence} = key ->
      case {Map.get(from, key), Map.get(to, key)} do
        {nil, method} ->
          [method_change("added", selector, occurrence, nil, method)]

        {method, nil} ->
          [method_change("removed", selector, occurrence, method, nil)]

        {method, method} ->
          []

        {from_method, to_method} ->
          [method_change("modified", selector, occurrence, from_method, to_method)]
      end
    end)
  end

  defp indexed_methods(methods) do
    {indexed, _counts} =
      Enum.reduce(methods, {%{}, %{}}, fn method, {indexed, counts} ->
        occurrence = Map.get(counts, method.selector, 0)

        {
          Map.put(indexed, {method.selector, occurrence}, method),
          Map.put(counts, method.selector, occurrence + 1)
        }
      end)

    indexed
  end

  defp method_change(change, selector, occurrence, from_method, to_method) do
    %{
      "selector" => identity(selector),
      "occurrence" => occurrence,
      "change" => change,
      "declarationChanged" =>
        method_field(from_method, :declaration) != method_field(to_method, :declaration),
      "bodyChanged" => method_field(from_method, :body) != method_field(to_method, :body)
    }
  end

  defp method_field(nil, _field), do: nil
  defp method_field(method, field), do: Map.fetch!(method, field)

  defp validate_query(query) do
    if String.trim(query) == "", do: {:error, :invalid_search_query}, else: :ok
  end

  defp result_page(opts) do
    offset = Keyword.get(opts, :result_offset, 0)
    limit = Keyword.get(opts, :result_limit, @default_result_limit)

    if is_integer(offset) and offset >= 0 and is_integer(limit) and limit >= 1 and
         limit <= @maximum_result_limit do
      {:ok, offset, limit}
    else
      {:error, {:invalid_result_page, @maximum_result_limit}}
    end
  end

  defp page(offset, limit, total) do
    returned = min(max(total - offset, 0), limit)

    %{
      "offset" => offset,
      "limit" => limit,
      "returned" => returned,
      "total" => total,
      "hasMore" => offset + returned < total
    }
  end

  defp method_detail([method_id, clauses, sources], _owner, _selector) do
    sources_by_sequence =
      Map.new(sources, fn [sequence, text, provenance] ->
        {sequence, %{"text" => text, "provenance" => identity(provenance)}}
      end)

    %{
      "methodId" => identity(method_id),
      "implementation" => if(clauses == [], do: "native", else: "clauses"),
      "clauses" => Enum.map(clauses, &method_clause(&1, sources_by_sequence))
    }
  end

  defp method_clause([sequence, head, body], sources) do
    %{
      "clauseSequence" => sequence,
      "head" => json_value(head),
      "body" => json_value(body),
      "source" => Map.get(sources, sequence)
    }
  end

  defp method_binding([selector, method_id]) do
    %{"selector" => identity(selector), "methodId" => identity(method_id)}
  end

  defp stored_clause([clause_sequence, head, body]) do
    %{
      "clauseSequence" => clause_sequence,
      "head" => json_value(head),
      "body" => json_value(body)
    }
  end

  defp slot([key, value], storage) do
    %{
      "key" => json_value(key),
      "value" => json_value(value),
      "storage" => Atom.to_string(storage)
    }
  end

  defp user_slot?([key, _value]), do: user_slot_key?(key)

  defp user_slot_key?(:class), do: false
  defp user_slot_key?(:super), do: false
  defp user_slot_key?(:native), do: false
  defp user_slot_key?({:method, _selector}), do: false
  defp user_slot_key?(key) when is_integer(key), do: false
  defp user_slot_key?(_key), do: true

  defp package_record([id, slots]) do
    %{"id" => identity(id), "slots" => slots |> pairs_to_map() |> json_value()}
  end

  defp pairs_to_map(pairs), do: Map.new(pairs, fn [key, value] -> {key, value} end)

  defp transaction_source(_tx, nil), do: nil

  defp transaction_source(tx, [text, origin]) do
    %{"transaction" => tx, "text" => text, "origin" => json_value(origin)}
  end

  defp command([time, {operation, arguments}], tx) do
    %{
      "time" => time,
      "transaction" => tx,
      "operation" => Atom.to_string(operation),
      "arguments" => json_value(arguments)
    }
  end

  defp command([time, operation], tx) do
    %{
      "time" => time,
      "transaction" => tx,
      "operation" => "unknown",
      "arguments" => json_value(operation)
    }
  end

  defp atom_string(nil), do: nil
  defp atom_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_string(value), do: inspect(value)

  defp identity(nil), do: nil
  defp identity(value) when is_atom(value), do: Atom.to_string(value)
  defp identity(value), do: inspect(value)

  defp json_value(nil), do: nil
  defp json_value(value) when is_boolean(value) or is_number(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_value(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"base64" => Base.encode64(value)}
  end

  defp json_value([]), do: []

  defp json_value([_head | _tail] = value) do
    case json_list_parts(value, []) do
      {heads, []} ->
        Enum.map(heads, &json_value/1)

      {heads, tail} ->
        %{"improperList" => Enum.map(heads, &json_value/1), "tail" => json_value(tail)}
    end
  end

  defp json_value(value) when is_tuple(value) do
    %{"tuple" => value |> Tuple.to_list() |> Enum.map(&json_value/1)}
  end

  defp json_value(%module{} = value) do
    %{"struct" => Atom.to_string(module), "fields" => json_value(Map.from_struct(value))}
  end

  defp json_value(value) when is_map(value) do
    %{
      "entries" =>
        value
        |> Enum.sort_by(fn {key, _value} -> inspect(key) end)
        |> Enum.map(fn {key, entry_value} ->
          %{"key" => json_value(key), "value" => json_value(entry_value)}
        end)
    }
  end

  defp json_value(value), do: inspect(value, pretty: true, limit: 100)

  defp json_list_parts([], heads), do: {Enum.reverse(heads), []}
  defp json_list_parts([head | tail], heads), do: json_list_parts(tail, [head | heads])
  defp json_list_parts(tail, heads), do: {Enum.reverse(heads), tail}

  defp branch_name(%AL.Branch{id: id}), do: Atom.to_string(id)
end
