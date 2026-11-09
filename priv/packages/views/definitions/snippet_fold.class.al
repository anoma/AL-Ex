@snippet_fold
#{
  super => editor_fold,
  ivars => [
    #{name => title, default => "…", type => string},
    #{name => folded, default => true, domain => [false, true]}
  ]
}.

snippet_fold >> refresh
| Self Text Updated |
string_codes Text Codes,
utf16_size Self Codes 0 End,
line_size Self Codes 0 Start,
put Self start Start WithStart,
put WithStart end End Updated.

snippet_fold >> utf16_size
| _Self [] Size Size |.

snippet_fold >> utf16_size
| Self [Code . Rest] Size End |
<= Code 65535,
= Next (+ Size 1),
utf16_size Self Rest Next End.

snippet_fold >> utf16_size
| Self [Code . Rest] Size End |
> Code 65535,
= Next (+ Size 2),
utf16_size Self Rest Next End.

snippet_fold >> utf16_width
| _Self Code 1 |
<= Code 65535.

snippet_fold >> utf16_width
| _Self Code 2 |
> Code 65535.

snippet_fold >> line_size
| _Self [] Size Size |.

snippet_fold >> line_size
| _Self [10 . _Rest] Size Size |.

snippet_fold >> line_size
| _Self [13 . _Rest] Size Size |.

snippet_fold >> line_size
| Self [Code . Rest] Size End |
dif Code 10,
dif Code 13,
utf16_width Self Code Width,
= Next (+ Size Width),
line_size Self Rest Next End.
