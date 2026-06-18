defmodule AL.Bootstrap.Lists do
  use AL

  def setup() do
    run do
      new(:class, %{name: :list, super: :object, slots: []}, _)

      defmethod(:list, :hd, [[h | _t], h]) do end
      defmethod(:list, :tl, [[_h | t], t]) do end

      set_method(:list, :concat, :list_concat)
      set_class(:list_concat, :behaviour)
      set_oapply(:list_concat, [[], second, second]) do end
      set_oapply(:list_concat, [[fh | ft], second, [fh | inner]]) do
        concat(ft, second, inner)
      end

      set_method(:list, :member, :list_member)
      set_class(:list_member, :behaviour)
      set_oapply(:list_member, [[x | _t], x]) do end
      set_oapply(:list_member, [[_h | t], x]) do
        member(t, x)
      end

      set_method(:list, :reverse, :list_reverse)
      set_class(:list_reverse, :behaviour)
      set_oapply(:list_reverse, [[], []]) do end
      set_oapply(:list_reverse, [[h | t], reversed]) do
        reverse(t, reversed_tl)
        concat(reversed_tl, [h], reversed)
      end

      set_method(:list, :map, :list_map)
      set_class(:list_map, :behaviour)
      set_oapply(:list_map, [[], _func, []]) do end
      set_oapply(:list_map, [[], _head, _body, []]) do end
      set_oapply(:list_map, [[fh | ft], func, [sh | st]]) do
        send(fh, func, [sh])
        map(ft, func, st)
      end
      set_oapply(:list_map, [[fh | ft], head, body, [sh | st]]) do
        call(head, body, [fh, sh])
        map(ft, head, body, st)
      end

      set_method(:list, :fold_left, :list_fold_left)
      set_class(:list_fold_left, :behaviour)
      set_oapply(:list_fold_left, [[], _func, acc, acc]) do end
      set_oapply(:list_fold_left, [[], _head, _body, acc, acc]) do end
      set_oapply(:list_fold_left, [[h | t], func, acc, result]) do
        send(acc, func, [h, next_acc])
        fold_left(t, func, next_acc, result)
      end
      set_oapply(:list_fold_left, [[h | t], head, body, acc, result]) do
        print(acc)
        call(head, body, [acc, h, next_acc])
        fold_left(t, head, body, next_acc, result)
      end

      set_method(:list, :fold_right, :list_fold_right)
      set_class(:list_fold_right, :behaviour)
      set_oapply(:list_fold_right, [[], _func, acc, acc]) do end
      set_oapply(:list_fold_right, [[], _head, _body, acc, acc]) do end
      set_oapply(:list_fold_right, [[h | t], func, acc, result]) do
        fold_right(t, func, acc, next_acc)
        send(next_acc, func, [h, result])
      end
      set_oapply(:list_fold_right, [[h | t], head, body, acc, result]) do
        fold_right(t, head, body, acc, next_acc)
        call(head, body, [next_acc, h, result])
      end

      defmethod(:list, :flatten, [lists, result]) do
        fold_left(lists, :concat, [], result)
      end

      set_method(:list, :same_length, :list_same_length)
      set_class(:list_same_length, :behaviour)
      set_oapply(:list_same_length, [[], []]) do end
      set_oapply(:list_same_length, [[_fh | ft], [_sh | st]]) do
        same_length(ft, st)
      end
    end
  end
end
