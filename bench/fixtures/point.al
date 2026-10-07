@point
#{super => value, ivars => [#{name => x}, #{name => y}]}.

point >> x
| Self X |
get Self x X.

point >> sum
| Self Sum |
get Self x X,
get Self y Y,
= Sum (+ X Y).
