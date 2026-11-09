@world
#{super => object, metaclass => object}.

world >> context_menu
| Self Wm Menu |
findall Item Items {
  window_entry Self Label View,
  lambda [] Open (new_window Wm #{content => View} _ _),
  new brick_menu_item #{header => Label, command => Open} Item
},
new brick_context_menu #{items => Items} Menu.

world >> window_entry
| _Self "REPL" View |
new brick_repl #{} Repl,
new phlow_xaml #{title => "REPL", brick => Repl} View.

world >> window_entry
| _Self "Class Viewer" View |
new phlow_views #{title => "Class Viewer", target => object, selector => class_view} View.

world >> new_workspace
| Self Visible Wm |
new wm #{visible_extent => Visible} Wm,
window_entry Self "REPL" View,
new_window Wm #{content => View} _ _.