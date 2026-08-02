defmodule AL.Package.Sudoku do
  use AL.Package

  defpackage :sudoku, version: 1, deps: [:bootstrap] do
    # :value, not durable — a puzzle is scratch, and self already being a
    # map means it's already its own printable/reified form.
    defclass :sudoku, super: :value, ivars: [:rows] do
      defmethod(:get_slot, [self, k, v]) do
        vm_map_get(self, k, v)
      end

      # givens: 9x9 list of 0..9, 0 = blank. Blanks come out open via
      # ordinary unification against build_row's fresh output list.
      defmethod(:init, [self, args, new]) do
        vm_map_get(args, :givens, givens)
        build_rows(givens, rows)
        constrain_rows(rows)
        unify(new, %{class: :sudoku, rows: rows})
      end

      defmethod(:solve, [self, solved]) do
        get_slot(self, :rows, rows)
        label_rows(rows)
        unify(solved, rows)
      end
    end

    # Below: list-shaped helpers, :list-scoped (dispatch goes by the
    # receiver's own type, not by which block a defmethod sits in).
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

    # rows -> 3 row-bands -> each row chunked into 3 -> zip into 9 boxes
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

    defmethod(:list, :label_rows, [[]])

    defmethod(:list, :label_rows, [[row | rest]]) do
      label_range(row, 1, 9)
      label_rows(rest)
    end
  end
end
