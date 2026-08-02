defmodule AL.Package.Sudoku do
  use AL.Package

  defpackage :sudoku, version: 1, deps: [:bootstrap] do
    # No durable identity needed — a puzzle instance is scratch, not
    # something meant to survive as a standalone Mnesia-registered object.
    # Like :mapset/:interval, self is just a map carrying its own :class tag
    # (`:get_slot` reads it directly), not a bare list — real construction
    # logic in :init is fine for :value (:mapset/:interval both have it
    # too, e.g. :interval checking `lo > hi`); the actual test is "does self
    # need durable identity," not "does init do real work."
    new(:class, %{name: :sudoku, super: :value, ivars: [:rows]}, _)

    defmethod(:sudoku, :get_slot, [self, k, v]) do
      vm_map_get(self, k, v)
    end

    # `givens` is a 9x9 list of 0..9 — 0 marks a blank. A blank position's
    # output cell comes out of ordinary unification against `build_row`'s
    # still-open output list (no gensym needed — same idiom `length_of_size`
    # etc. already use to grow a fresh list). Constraints post once here,
    # not deferred to :solve.
    defmethod(:sudoku, :init, [self, args, new]) do
      vm_map_get(args, :givens, givens)
      build_rows(givens, rows)
      constrain_rows(rows)
      unify(new, %{class: :sudoku, rows: rows})
    end

    # Every helper below takes a list (or list of lists) as its first
    # argument, not a :sudoku-shaped self — dispatch resolves method scope
    # from the *receiver's own runtime type*, not from which class block a
    # defmethod is written under, so these are :list-scoped (same as
    # mapset.ex's list_to_elems/map_insert living under :list/:map while
    # defined inside the :mapset package block).
    defmethod(:list, :build_rows, [[], []])

    defmethod(:list, :build_rows, [[given_row | given_rest], [row | rest]]) do
      build_row(given_row, row)
      build_rows(given_rest, rest)
    end

    defmethod(:list, :build_row, [[], []])

    defmethod(:list, :build_row, [[0 | gs], [cell | cs]]) do
      cell >= 1
      cell <= 9
      build_row(gs, cs)
    end

    defmethod(:list, :build_row, [[n | gs], [n | cs]]) do
      n > 0
      build_row(gs, cs)
    end

    defmethod(:list, :constrain_rows, [rows]) do
      each_all_dif(rows)
      transpose(rows, cols)
      each_all_dif(cols)
      boxes(rows, bs)
      each_all_dif(bs)
    end

    defmethod(:list, :each_all_dif, [[]])

    defmethod(:list, :each_all_dif, [[group | rest]]) do
      all_dif(group)
      each_all_dif(rest)
    end

    # 9x9 rows -> nine 3x3 boxes: chunk the rows into 3 row-bands, chunk
    # each row within a band into 3 column-groups of 3, then zip the three
    # rows' matching column-groups together into one 9-cell box per group.
    defmethod(:list, :boxes, [rows, boxes]) do
      chunks3(rows, bands)
      bands_boxes(bands, box_groups)
      flatten(box_groups, boxes)
    end

    defmethod(:list, :chunks3, [[], []])

    defmethod(:list, :chunks3, [[a, b, c | rest], [[a, b, c] | chunks]]) do
      chunks3(rest, chunks)
    end

    defmethod(:list, :bands_boxes, [[], []])

    defmethod(:list, :bands_boxes, [[band | bands], [bs | rest]]) do
      band_boxes(band, bs)
      bands_boxes(bands, rest)
    end

    defmethod(:list, :band_boxes, [[r1, r2, r3], [box1, box2, box3]]) do
      chunks3(r1, [a1, a2, a3])
      chunks3(r2, [b1, b2, b3])
      chunks3(r3, [c1, c2, c3])
      concat(a1, b1, ab1)
      concat(ab1, c1, box1)
      concat(a2, b2, ab2)
      concat(ab2, c2, box2)
      concat(a3, b3, ab3)
      concat(ab3, c3, box3)
    end

    defmethod(:sudoku, :solve, [self, solved]) do
      get_slot(self, :rows, rows)
      label_rows(rows)
      unify(solved, rows)
    end

    defmethod(:list, :label_rows, [[]])

    defmethod(:list, :label_rows, [[row | rest]]) do
      label_range(row, 1, 9)
      label_rows(rest)
    end
  end
end
