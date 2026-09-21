defmodule AL.Trace.Derivation do
  @moduledoc false

  @spec build(AL.t()) :: [map()]
  def build(%{
        trace: %AL.Trace{events: events},
        active_choicepoint: %{store: store}
      }) do
    [%{tree: tree}] =
      events
      |> Enum.reverse()
      |> Enum.reduce([context(nil, nil, nil)], &step/2)

    materialize_tree(tree, store)
  end

  @spec method_values(map() | [map()], atom()) :: [{term(), [term()]}]
  def method_values(roots, method) do
    roots
    |> List.wrap()
    |> Enum.flat_map(&method_nodes(&1, method))
    |> Enum.flat_map(fn %{label: {self, ^method, args}, children: answers} ->
      Enum.map(answers, fn answer ->
        {resolve(self, answer.derived), Enum.map(args, &resolve(&1, answer.derived))}
      end)
    end)
    |> Enum.uniq()
  end

  defp context(id, kind, condition), do: context(id, kind, condition, nil)

  defp context(id, kind, condition, output),
    do: %{
      id: id,
      kind: kind,
      condition: condition,
      output: output,
      tree: empty_tree(),
      proofs: []
    }

  defp empty_tree(), do: %{stack: [], nodes: %{}, roots: [], scopes: %{}}

  defp step(event, contexts) do
    case AL.Trace.payload(event) do
      {:collection_begin, id, kind, condition, output} ->
        [context(id, kind, condition, output) | contexts]

      {:collection_solution, id, store} ->
        [%{id: ^id} = current | rest] = contexts
        proof = current.tree |> materialize_tree(store, true) |> nest_continuations()
        [%{current | proofs: merge_forest(current.proofs, proof)} | rest]

      {:collection_end, id} ->
        [%{id: ^id} = current, parent | rest] = contexts

        answer = %{
          kind: :answer,
          clause: nil,
          derived: nil,
          derived_term: current.output,
          children: strip_trace_ids(current.proofs)
        }

        collection = %{
          kind: :collection,
          label: {current.kind, current.condition},
          constraints_in: %{},
          children: [answer]
        }

        [%{parent | tree: import_tree(collection, parent.tree)} | rest]

      payload ->
        [current | rest] = contexts
        [%{current | tree: tree_step(payload, current.tree)} | rest]
    end
  end

  defp tree_step({:method_call, scope, self, method, args, constraints_in}, tree),
    do: open_call(tree, scope, :method, {self, method, args}, constraints_in)

  defp tree_step({:clause_call, scope, method, call_args, constraints_in}, tree) do
    case current_call_and_choice(tree) do
      {call_key, choice_key} ->
        call = Map.fetch!(tree.nodes, call_key)
        choice = Map.fetch!(tree.nodes, choice_key)

        if call.kind == :method and is_nil(choice.clause_call) do
          nodes =
            Map.put(tree.nodes, choice_key, %{
              choice
              | clause_call: {method, call_args},
                constraints_in: constraints_in
            })

          scopes = Map.put(tree.scopes, scope, %{call: call_key, choice: choice_key})
          %{tree | stack: [scope | tree.stack], nodes: nodes, scopes: scopes}
        else
          open_call(tree, scope, :clause, clause_label(method, call_args), constraints_in)
        end

      nil ->
        open_call(tree, scope, :clause, clause_label(method, call_args), constraints_in)
    end
  end

  defp tree_step({:clause_chosen, scope, clause}, tree) do
    case Map.get(tree.scopes, scope) do
      nil ->
        tree

      %{choice: choice_key} ->
        %{tree | nodes: Map.update!(tree.nodes, choice_key, &%{&1 | clause: clause})}
    end
  end

  defp tree_step({tag, scope, derived}, tree) when tag in [:method_exit, :clause_exit] do
    case Map.get(tree.scopes, scope) do
      nil ->
        tree

      %{call: call_key, choice: choice_key} ->
        nodes =
          tree.nodes
          |> Map.update!(choice_key, &%{&1 | derived: derived, succeeded: true, failed: false})
          |> Map.update!(call_key, &%{&1 | failed: false})

        %{tree | stack: unwind(tree.stack, scope), nodes: nodes}
    end
  end

  defp tree_step({tag, scope}, tree) when tag in [:method_redo, :clause_redo],
    do: restart_call(tree, scope)

  defp tree_step({tag, scope}, tree) when tag in [:method_fail, :clause_fail] do
    case Map.get(tree.scopes, scope) do
      nil ->
        tree

      %{call: call_key, choice: choice_key} ->
        nodes =
          tree.nodes
          |> Map.update!(choice_key, &%{&1 | failed: true, succeeded: false})
          |> maybe_fail_call(call_key, tag)

        %{tree | stack: unwind(tree.stack, scope), nodes: nodes}
    end
  end

  defp tree_step({:constraint, goal, constraints_in, derived}, tree),
    do: attach_constraint(goal, constraints_in, derived, tree)

  defp tree_step(_payload, tree), do: tree

  defp maybe_fail_call(nodes, call_key, :method_fail),
    do: Map.update!(nodes, call_key, &%{&1 | failed: true})

  defp maybe_fail_call(nodes, _call_key, :clause_fail), do: nodes

  defp open_call(tree, scope, kind, label, constraints_in) do
    call_key = {:call, scope}
    choice_key = make_ref()

    call = %{
      kind: kind,
      label: label,
      constraints_in: constraints_in,
      owner_scope: scope,
      failed: false,
      parent: nil,
      child_scopes: [choice_key]
    }

    answer = new_answer(call_key)
    tree = attach_step(tree, call_key, call)

    %{
      tree
      | stack: [scope | tree.stack],
        nodes: Map.put(tree.nodes, choice_key, answer),
        scopes: Map.put(tree.scopes, scope, %{call: call_key, choice: choice_key})
    }
  end

  defp new_answer(call_key) do
    %{
      kind: :answer,
      clause: nil,
      clause_call: nil,
      constraints_in: %{},
      derived: nil,
      succeeded: false,
      failed: false,
      parent: call_key,
      child_scopes: []
    }
  end

  defp attach_constraint(goal, constraints_in, derived, tree) do
    key = make_ref()

    node = %{
      kind: :constraint,
      label: goal,
      constraints_in: constraints_in,
      derived: derived,
      derived_finalized: true,
      parent: nil,
      child_scopes: [],
      failed: false
    }

    attach_step(tree, key, node)
  end

  defp attach_step(tree, key, node) do
    case current_choice_key(tree) do
      nil ->
        %{tree | nodes: Map.put(tree.nodes, key, node), roots: [key | tree.roots]}

      parent ->
        nodes =
          tree.nodes
          |> Map.put(key, %{node | parent: parent})
          |> Map.update!(parent, &%{&1 | child_scopes: [key | &1.child_scopes]})

        %{tree | nodes: nodes}
    end
  end

  defp current_choice_key(%{stack: [scope | _], scopes: scopes}),
    do: scopes |> Map.fetch!(scope) |> Map.fetch!(:choice)

  defp current_choice_key(%{stack: []}), do: nil

  defp current_call_and_choice(tree) do
    case tree.stack do
      [scope | _] ->
        %{call: call, choice: choice} = Map.fetch!(tree.scopes, scope)
        {call, choice}

      [] ->
        nil
    end
  end

  defp restart_call(tree, scope) do
    case Map.get(tree.scopes, scope) do
      nil ->
        tree

      %{call: call_key} ->
        tree = rewind_call(tree, call_key)
        choice_key = make_ref()
        answer = new_answer(call_key)

        nodes =
          tree.nodes
          |> Map.put(choice_key, answer)
          |> Map.update!(call_key, &%{&1 | child_scopes: [choice_key], failed: false})

        scopes =
          Map.new(tree.scopes, fn
            {id, %{call: ^call_key} = info} -> {id, %{info | choice: choice_key}}
            entry -> entry
          end)

        %{tree | stack: [scope | ancestor_scopes(call_key, nodes)], nodes: nodes, scopes: scopes}
    end
  end

  defp rewind_call(tree, call_key) do
    case Map.fetch!(tree.nodes, call_key).parent do
      nil ->
        %{tree | roots: Enum.drop_while(tree.roots, &(&1 != call_key))}

      parent_choice ->
        %{tree | nodes: invalidate_choice_path(tree.nodes, parent_choice, call_key)}
    end
  end

  defp invalidate_choice_path(nodes, choice_key, child_key) do
    choice = Map.fetch!(nodes, choice_key)
    children = Enum.drop_while(choice.child_scopes, &(&1 != child_key))

    nodes =
      Map.put(nodes, choice_key, %{
        choice
        | child_scopes: children,
          derived: nil,
          succeeded: false
      })

    case choice.parent do
      nil ->
        nodes

      parent_call ->
        case Map.fetch!(nodes, parent_call).parent do
          nil -> nodes
          parent_choice -> invalidate_choice_path(nodes, parent_choice, parent_call)
        end
    end
  end

  defp ancestor_scopes(call_key, nodes) do
    case Map.fetch!(nodes, call_key).parent do
      nil ->
        []

      parent_choice ->
        parent_call = Map.fetch!(nodes, parent_choice).parent

        case Map.fetch!(nodes, parent_call).owner_scope do
          nil -> ancestor_scopes(parent_call, nodes)
          scope -> [scope | ancestor_scopes(parent_call, nodes)]
        end
    end
  end

  defp unwind(stack, scope) do
    if scope in stack,
      do: stack |> Enum.drop_while(&(&1 != scope)) |> Enum.drop(1),
      else: stack
  end

  defp clause_label(method, call_args) do
    case call_args do
      [self | args] -> {self, method, args}
      other -> {other, method, []}
    end
  end

  defp materialize_tree(tree, store), do: materialize_tree(tree, store, false)

  defp visible?(key, nodes) do
    node = Map.fetch!(nodes, key)

    case node.kind do
      :answer -> node.succeeded and not node.failed
      :constraint -> not node.failed
      _call -> not node.failed and Enum.any?(node.child_scopes, &visible?(&1, nodes))
    end
  end

  defp materialize_tree(tree, store, trace_ids) do
    tree.roots
    |> Enum.reverse()
    |> Enum.filter(&visible?(&1, tree.nodes))
    |> Enum.map(&materialize(&1, tree.nodes, store, trace_ids))
  end

  defp materialize(key, nodes, store, trace_ids) do
    node = Map.fetch!(nodes, key)

    children =
      node.child_scopes
      |> Enum.reverse()
      |> Enum.filter(&visible?(&1, nodes))
      |> Enum.map(&materialize(&1, nodes, store, trace_ids))

    materialized =
      case node.kind do
        :answer ->
          derived =
            cond do
              not is_nil(node.derived) -> node.derived
              not is_nil(Map.get(node, :derived_term)) -> describe(node.derived_term, store)
              true -> %{}
            end

          %{kind: :answer, clause: node.clause, derived: derived, children: children}

        :constraint ->
          derived = if node.derived_finalized, do: node.derived, else: describe(node.label, store)

          %{
            kind: :constraint,
            label: node.label,
            constraints_in: node.constraints_in,
            derived: derived,
            children: children
          }

        _call ->
          %{
            kind: node.kind,
            label: node.label,
            constraints_in: node.constraints_in,
            children: children
          }
      end

    if trace_ids,
      do: Map.put(materialized, :trace_id, trace_identity(key, materialized)),
      else: materialized
  end

  defp trace_identity(key, %{kind: :answer, derived: derived}), do: {key, derived}
  defp trace_identity(key, _node), do: key

  defp import_tree(node, tree) do
    key = make_ref()
    tree = attach_step(tree, key, imported_node(node))
    import_children(node.children, key, tree)
  end

  defp import_children(children, parent, tree) do
    Enum.reduce(children, tree, fn child, acc ->
      key = make_ref()
      imported = %{imported_node(child) | parent: parent}

      nodes =
        acc.nodes
        |> Map.put(key, imported)
        |> Map.update!(parent, &%{&1 | child_scopes: [key | &1.child_scopes]})

      import_children(child.children, key, %{acc | nodes: nodes})
    end)
  end

  defp imported_node(%{kind: :answer} = node) do
    %{
      kind: :answer,
      clause: node.clause,
      clause_call: nil,
      constraints_in: %{},
      derived: node.derived,
      derived_term: Map.get(node, :derived_term),
      succeeded: true,
      failed: false,
      parent: nil,
      child_scopes: []
    }
  end

  defp imported_node(%{kind: :constraint} = node) do
    %{
      kind: :constraint,
      label: node.label,
      constraints_in: node.constraints_in,
      derived: node.derived,
      derived_finalized: true,
      failed: false,
      parent: nil,
      child_scopes: []
    }
  end

  defp imported_node(node) do
    %{
      kind: node.kind,
      label: node.label,
      constraints_in: node.constraints_in,
      owner_scope: nil,
      failed: false,
      parent: nil,
      child_scopes: []
    }
  end

  defp merge_forest(existing, incoming) do
    Enum.reduce(incoming, existing, fn node, merged ->
      case Enum.find_index(merged, &(&1.trace_id == node.trace_id)) do
        nil -> merged ++ [node]
        index -> List.update_at(merged, index, &merge_node(&1, node))
      end
    end)
  end

  defp merge_node(existing, incoming) do
    %{incoming | children: merge_forest(existing.children, incoming.children)}
  end

  defp nest_continuations([]), do: []

  defp nest_continuations([node | rest]) do
    node = %{node | children: nest_continuations(node.children)}

    if answer_container?(node) and rest != [] do
      continuation = nest_continuations(rest)

      answers =
        Enum.map(node.children, fn answer ->
          %{answer | children: answer.children ++ continuation}
        end)

      [%{node | children: answers}]
    else
      [node | nest_continuations(rest)]
    end
  end

  defp answer_container?(%{kind: kind, children: [%{kind: :answer} | _]})
       when kind in [:method, :clause, :collection],
       do: true

  defp answer_container?(_node), do: false

  defp strip_trace_ids(nodes) when is_list(nodes), do: Enum.map(nodes, &strip_trace_ids/1)

  defp strip_trace_ids(node) do
    node
    |> Map.delete(:trace_id)
    |> Map.update!(:children, &strip_trace_ids/1)
  end

  defp describe(_term, nil), do: nil

  defp describe(term, store),
    do: term |> AL.Var.find_vars() |> Map.new(fn var -> {var, AL.describe_var(var, store)} end)

  defp method_nodes(%{kind: :method, label: {_, method, _}} = node, method),
    do: [node | Enum.flat_map(node.children, &method_nodes(&1, method))]

  defp method_nodes(node, method), do: Enum.flat_map(node.children, &method_nodes(&1, method))

  defp resolve(term, derived) do
    case derived && Map.get(derived, term) do
      {:bound, value} -> value
      _ -> term
    end
  end
end
