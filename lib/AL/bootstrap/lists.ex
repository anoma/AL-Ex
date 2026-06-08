defmodule AL.Bootstrap.Lists do
  use AL

  def setup() do
    run do
      send(:class, :new, [%{name: :list, super: :object, slots: []}, _])

      defmethod(:list, :hd, [[h | _t], h]) do end
      defmethod(:list, :tl, [[_h | t], t]) do end

      set_method(:list, :concat, :list_concat)
      set_class(:list_concat, :behaviour)
      set_oapply(:list_concat, [[], second, second]) do end
      set_oapply(:list_concat, [[fh | ft], second, [fh | inner]]) do
        send(ft, :concat, [second, inner])
      end

      set_method(:list, :member, :list_member)
      set_class(:list_member, :behaviour)
      set_oapply(:list_member, [[x | _t], x]) do end
      set_oapply(:list_member, [[_h | t], x]) do
        send(t, :member, [x])
      end

      set_method(:list, :reverse, :list_reverse)
      set_class(:list_reverse, :behaviour)
      set_oapply(:list_reverse, [[], []]) do end
      set_oapply(:list_reverse, [[h | t], reversed]) do
        send(t, :reverse, [reversed_tl])
        send(reversed_tl, :concat, [[h], reversed])
      end

      set_method(:list, :map, :list_map)
      set_class(:list_map, :behaviour)
      set_oapply(:list_map, [[], _func, []]) do end
      set_oapply(:list_map, [[fh | ft], func, [sh | st]]) do
        send(fh, func, [sh])
        send(ft, :map, [func, st])
      end

      set_method(:list, :fold_left, :list_fold_left)
      set_class(:list_fold_left, :behaviour)
      set_oapply(:list_fold_left, [[], _func, acc, acc]) do end
      set_oapply(:list_fold_left, [[h | t], func, acc, result]) do
        send(acc, func, [h, next_acc])
        send(t, :fold_left, [func, next_acc, result])
      end

      set_method(:list, :fold_right, :list_fold_right)
      set_class(:list_fold_right, :behaviour)
      set_oapply(:list_fold_right, [[], _func, acc, acc]) do end
      set_oapply(:list_fold_right, [[h | t], func, acc, result]) do
        send(t, :fold_right, [func, acc, next_acc])
        send(next_acc, func, [h, result])
      end

      defmethod(:list, :flatten, [lists, result]) do
        send(lists, :fold_left, [:concat, [], result])
      end

      set_method(:list, :same_length, :list_same_length)
      set_class(:list_same_length, :behaviour)
      set_oapply(:list_same_length, [[], []]) do end
      set_oapply(:list_same_length, [[_fh | ft], [_sh | st]]) do
        send(ft, :same_length, [st])
      end
    end
  end
end
