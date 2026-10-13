@layout
#{super => value, ivars => [#{name => windows}]}.

layout >> extent
| Self Ext |
get Self windows [],
new point #{} Ext.

layout >> extent
| Self Ext |
get Self windows Windows,
max_by Windows extends_to_x MaxWindowX,
max_by Windows extends_to_y MaxWindowY,
extends_to_y MaxWindowY ExtentY,
extends_to_x MaxWindowX ExtentX,
new point #{x => ExtentX, y => ExtentY} Ext.

layout >> close
| _Self _Wm _Request _NewLayout |
fail.

layout >> placement_changes
| Self Prev ChangedWindows RemovedWindows |
get Self windows CurrWindows,
get Prev windows PrevWindows,
findall Window ChangedWindows {member CurrWindows Window, not {member PrevWindows Window}},
map CurrWindows id CurrIds,
findall Window RemovedWindows {
  member PrevWindows Window,
  id Window WinId,
  not {member CurrIds WinId}
}.

layout >> place_window
| _Self _Wm _Request _NewLayout |
fail.

layout >> resize
| _Self _Wm _NewLayout |
fail.
