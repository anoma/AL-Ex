;; -*- lexical-binding: t; -*-

(require 'rx)

(defgroup al nil
  "Editing AL source."
  :group 'languages)

(defcustom al-indent-offset 2
  "Columns added for each open bracket."
  :type 'integer
  :group 'al)

(defcustom al-indent-on-save nil
  "Reindent the whole buffer before saving."
  :type 'boolean
  :group 'al)

(defface al-name-face
  `((t :inherit ,(if (facep 'elixir-atom-face) 'elixir-atom-face 'font-lock-builtin-face)))
  "Face for an atom that names something."
  :group 'al)

(defface al-definition-face
  '((t :foreground "#a9dc76"))
  "Face for the owner >> selector line of a method clause."
  :group 'al)

(defface al-occurrence-face
  '((t :inherit highlight))
  "Face for each occurrence of the variable at point within its clause."
  :group 'al)

(defvar al-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?_ "w" table)
    (modify-syntax-entry ?# "." table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?\" "\"" table)
    (modify-syntax-entry ?' "\"" table)
    (modify-syntax-entry ?\\ "\\" table)
    (dolist (char '(?| ?@ ?^ ?. ?, ?\; ?: ?= ?< ?> ?+ ?- ?* ?/))
      (modify-syntax-entry char "." table))
    table))

(defun al-syntax-propertize (start end)
  (goto-char start)
  (while (search-forward "#" end t)
    (let ((position (1- (point))))
      (unless (or (eq (char-after) ?{)
                  (nth 8 (save-excursion (syntax-ppss position))))
        (put-text-property position (1+ position)
                           'syntax-table (string-to-syntax "<"))))))

(defconst al-name (rx (or (seq (any "a-z") (* (any "a-zA-Z0-9_")))
                          (seq "'" (* (not (any "'"))) "'"))))

(defconst al-variable (rx symbol-start (any "A-Z_") (* (any "a-zA-Z0-9_"))))

(defconst al-font-lock-keywords
  `((,(rx-to-string `(seq bol (group "@" (? "+") (regexp ,al-name))))
     1 font-lock-type-face)
    (,(rx-to-string `(seq bol (group (regexp ,al-name)) (* space) (group ">>") (* space)
                          (group (regexp ,al-name))))
     (1 'al-definition-face)
     (2 'default)
     (3 'al-definition-face))
    (,(rx "^" (+ (any "a-zA-Z0-9_"))) . font-lock-preprocessor-face)
    (,(rx symbol-start "_" (* (any "a-zA-Z0-9_"))) . 'shadow)
    (,(rx symbol-start (any "a-z") (* (any "a-zA-Z0-9_")) symbol-end) . 'al-name-face)))

(defvar-local al-occurrences nil)

(defun al-clause-end-p ()
  (and (eq (char-after) ?.)
       (save-excursion
         (forward-char)
         (looking-at-p (rx (* blank) (or eol "#"))))
       (let ((state (syntax-ppss)))
         (and (zerop (car state)) (not (nth 8 state))))))

(defun al-clause-bounds ()
  (save-excursion
    (let ((here (point))
          start
          end)
      (while (and (not start) (search-backward "." nil t))
        (when (al-clause-end-p) (setq start (1+ (point)))))
      (goto-char here)
      (while (and (not end) (search-forward "." nil t))
        (backward-char)
        (if (al-clause-end-p)
            (setq end (1+ (point)))
          (forward-char)))
      (cons (or start (point-min)) (or end (point-max))))))

(defun al-variable-at-point ()
  (unless (nth 8 (syntax-ppss))
    (let ((symbol (thing-at-point 'symbol t))
          (case-fold-search nil))
      (when (and symbol
                 (string-match-p (rx bos (or (any "A-Z") (seq "_" (any "a-zA-Z0-9_")))
                                     (* (any "a-zA-Z0-9_")) eos)
                                 symbol))
        symbol))))

(defun al-highlight-occurrences ()
  (mapc #'delete-overlay al-occurrences)
  (setq al-occurrences nil)
  (let ((name (al-variable-at-point))
        (case-fold-search nil))
    (when name
      (let ((bounds (al-clause-bounds))
            (pattern (rx-to-string `(seq symbol-start ,name symbol-end))))
        (save-excursion
          (goto-char (car bounds))
          (while (re-search-forward pattern (cdr bounds) t)
            (unless (save-match-data
                      (save-excursion (nth 8 (syntax-ppss (match-beginning 0)))))
              (let ((overlay (make-overlay (match-beginning 0) (match-end 0))))
                (overlay-put overlay 'face 'al-occurrence-face)
                (push overlay al-occurrences)))))))))

(defun al-indentation ()
  (save-excursion
    (back-to-indentation)
    (let* ((state (syntax-ppss))
           (depth (car state)))
      (cond
       ((nth 3 state) nil)
       ((looking-at-p (rx (any ")]}"))) (* al-indent-offset (max 0 (1- depth))))
       (t (* al-indent-offset depth))))))

(defun al-indent-line ()
  (interactive)
  (let ((column (al-indentation)))
    (when column
      (if (<= (current-column) (current-indentation))
          (indent-line-to column)
        (save-excursion (indent-line-to column))))))

(defun al-indent-buffer ()
  (when al-indent-on-save
    (save-excursion (indent-region (point-min) (point-max)))))

(defconst al-imenu-expression
  `(("Classes" ,(rx-to-string `(seq bol "@" (? "+") (group (regexp ,al-name)))) 1)
    ("Methods" ,(rx-to-string `(seq bol (group (regexp ,al-name) (* space) ">>" (* space)
                                              (regexp ,al-name))))
     1)))

(define-derived-mode al-mode prog-mode "AL"
  "Major mode for AL source."
  :syntax-table al-mode-syntax-table
  (setq-local syntax-propertize-function #'al-syntax-propertize)
  (setq-local font-lock-defaults '(al-font-lock-keywords))
  (setq-local comment-start "# ")
  (setq-local comment-end "")
  (setq-local comment-start-skip (rx "#" (not (any "{")) (* space)))
  (setq-local indent-line-function #'al-indent-line)
  (setq-local indent-tabs-mode nil)
  (setq-local electric-indent-chars (append '(?\} ?\] ?\)) electric-indent-chars))
  (setq-local imenu-generic-expression al-imenu-expression)
  (add-hook 'before-save-hook #'al-indent-buffer nil t)
  (add-hook 'post-command-hook #'al-highlight-occurrences nil t))

(add-to-list 'auto-mode-alist '("\\.al\\'" . al-mode))

(provide 'al-mode)
