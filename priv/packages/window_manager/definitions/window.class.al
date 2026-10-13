@window
#{
  super => value,
  ivars => [
    #{name => id},
    #{name => position, type => point},
    #{name => extent, type => point},
    #{name => content, type => phlow}
  ]
}.

window >> extends_to_x
| Self XReaches |
get Self extent Extent,
get Self position Pos,
x Extent XExtent,
x Pos XPoint,
= XReaches (+ XExtent XPoint).

window >> extends_to_y
| Self YReaches |
get Self extent Extent,
get Self position Pos,
y Extent YExtent,
y Pos YPoint,
= YReaches (+ YExtent YPoint).

window >> extends_to
| Self Reaches |
extends_to_x Self XReach,
extends_to_y Self YReach,
new point #{x => XReach, y => YReach} Reaches.

window >> id
| Self WinId |
get Self id WinId.
