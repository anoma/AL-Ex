@layout
#{super => object, ivars => [#{name => windows, type => observable_list}]}.

layout >> extent
| Self Ext |
get Self windows List,
get List contents [],
new point #{} Ext,
cut.

layout >> extent
| Self Ext |
get Self windows List,
get List contents Windows,
max_by Windows extends_to_x MaxWindowX,
max_by Windows extends_to_y MaxWindowY,
extends_to_y MaxWindowY ExtentY,
extends_to_x MaxWindowX ExtentX,
new point #{x => ExtentX, y => ExtentY} Ext.

layout >> to_xaml
| Self Text |
brick Self Brick,
to_xaml Brick Text.

layout >> init
| Self Fields Self |
get Fields windows _Windows -> = WithWindows Fields ; {
  new observable_list [] Windows,
  put Fields windows Windows WithWindows
},
call_next_method Self WithWindows Self.

layout >> brick
| Self Brick |
new brick_workspace #{target => Self} Brick.