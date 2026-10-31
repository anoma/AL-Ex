@phlow_class_methods
#{super => phlow_xaml, ivars => [#{name => target}]}.

phlow_class_methods >> to_map
| Self Map |
get Self target Target,
new brick_class_methods #{target => Target} Brick,
put Self brick Brick View,
call_next_method View Map,
cut.
