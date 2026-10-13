@point
#{
  super => value,
  ivars => [
    #{default => 0, name => x, type => number},
    #{default => 0, name => y, type => number}
  ]
}.

point >> y
| Self YPoint |
get Self y YPoint.

point >> x
| Self XPoint |
get Self x XPoint.
