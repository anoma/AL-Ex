@interval_value
#{super: value, ivars: [#{name: lo}, #{name: hi}]}.

interval_value >> init
| Self Args New |
get_slots Args #{hi: Hi, lo: Lo},
Lo > Hi -> New = #{class: interval_value, hi: empty, lo: empty} ; New = #{class: interval_value, hi: Hi, lo: Lo}.

interval_value >> elem
| Self X |
get Self lo Lo,
not {Lo == empty},
get Self hi Hi,
Lo <= X,
X <= Hi.

interval_value >> intersection
| Self _Other New |
get Self lo empty,
New = #{class: interval_value, hi: empty, lo: empty}.

interval_value >> intersection
| Self Other New |
get Self lo Lo,
not {Lo == empty},
get Other lo empty,
New = #{class: interval_value, hi: empty, lo: empty}.

interval_value >> intersection
| Self Other New |
get Self lo Lo1,
not {Lo1 == empty},
get Other lo Lo2,
not {Lo2 == empty},
get Self hi Hi1,
get Other hi Hi2,
sort [Lo1, Lo2] [_, Lo],
sort [Hi1, Hi2] [Hi, _],
new interval_value #{hi: Hi, lo: Lo} New.