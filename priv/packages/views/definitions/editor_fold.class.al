@editor_fold
#{
  super => value,
  ivars => [
    #{name => start, default => 0, type => number},
    #{name => end, default => 0, type => number},
    #{name => title, default => "", type => string},
    #{name => folded, default => false, domain => [false, true]}
  ]
}.

editor_fold >> refresh
| Self _Text Self |.
