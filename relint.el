;;; relint.el --- Elisp regexp mistake finder   -*- lexical-binding: t -*-

;; Copyright (C) 2019-2020 Free Software Foundation, Inc.

;; Author: Mattias Engdegård <mattiase@acm.org>
;; Version: 1.13
;; Package-Requires: ((xr "1.15") (emacs "26.1"))
;; URL: https://github.com/mattiase/relint
;; Keywords: lisp, regexps

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Scan elisp files for regexp strings and reports potential errors,
;; including deprecated syntax and bad practice.
;; Also check the regexp-like skip-set arguments to
;; `skip-chars-forward' and `skip-chars-backward', and syntax codes for
;; `skip-syntax-forward' and `skip-syntax-backward'.
;;
;; How to use:
;;
;; * Inside Emacs:
;;
;;   M-x relint-file            (check a single elisp file)
;;   M-x relint-directory       (check all .el files in a directory tree)
;;   M-x relint-current-buffer  (check current buffer)
;;
;;   In the `*relint*' buffer, pressing "g" will re-run the same check.
;;
;; * From batch mode:
;;
;;   emacs -batch -l relint.el -f relint-batch FILES-AND-DIRS...
;;
;;   where options for finding relint and xr need to be added after
;;   `-batch', either `-f package-initialize' or `-L DIR'.

;; Bugs:
;;
;;   Since there is no sure way to know whether a particular string is a
;;   regexp, the code has to guess a lot, and will likely miss quite a
;;   few. It tries to minimise the amount of false positives.
;;   In other words, it is a nothing but a hack.

;;; News:

;; Version 1.13:
;; - Look in function/macro doc strings to find regexp arguments and
;;   return values
;; - Detect binding and mutation of some known regexp variables
;; - Detect regexps as arguments to `syntax-propertize-rules'
;; - More font-lock-keywords variables are scanned for regexps
;; - `relint-batch' no longer outputs a summary if there were no errors
;; Version 1.12:
;; - Improved detection of regexps in defcustom declarations
;; - Better suppression of false positives
;; - Nonzero exit status upon error in `relint-batch'
;; Version 1.11:
;; - Improved evaluator, now handling limited local variable mutation
;; - Bug fixes
;; - Test suite
;; Version 1.10:
;; - Check arguments to `skip-syntax-forward' and `skip-syntax-backward'
;; - Add error suppression mechanism
;; Version 1.9:
;; - Limited tracking of local variables in regexp finding
;; - Recognise new variable `literal' and `regexp' rx clauses
;; - Detect more regexps in defcustom declarations
;; - Requires xr 1.13
;; Version 1.8:
;; - Updated diagnostics list
;; - Requires xr 1.12
;; Version 1.7:
;; - Expanded regexp-generating heuristics
;; - Some `defalias' are now followed
;; - All diagnostics are now documented (see README.org)
;; Version 1.6:
;; - Add `relint-current-buffer'
;; - Show relative file names in *relint*
;; - Extended regexp-generating heuristics, warning about suspiciously-named
;;   variables used as skip-sets
;; - "-patterns" and "-pattern-list" are no longer interesting variable
;;   suffixes
;; Version 1.5:
;; - Substantially improved evaluator, able to evaluate some functions and
;;   macros defined in the same file, even when passed as parameters
;; - Detect regexps spliced into [...]
;; - Check bad skip-set provenance
;; - The *relint* buffer now uses a new relint-mode for better usability,
;;   with "g" bound to `relint-again'
;; Version 1.4:
;; - First version after name change to `relint'

;;; Code:

(require 'xr)
(require 'compile)
(require 'cl-lib)

(defvar relint--error-buffer)
(defvar relint--quiet)
(defvar relint--error-count)
(defvar relint--suppression-count)

(defun relint--get-error-buffer ()
  (let ((buf (get-buffer-create "*relint*")))
    (with-current-buffer buf
      (unless (eq major-mode 'relint-mode)
        (relint-mode))
      (let ((inhibit-read-only t))
        (compilation-forget-errors)
        (erase-buffer)))
    buf))

(defun relint--add-to-error-buffer (string)
  (with-current-buffer relint--error-buffer
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert string))))

(defun relint--skip-whitespace ()
  (when (looking-at (rx (1+ (or blank "\n" "\f"
                                (seq ";" (0+ nonl))))))
    (goto-char (match-end 0))))

(defun relint--go-to-pos-path (toplevel-pos path)
  "Move point to TOPLEVEL-POS and PATH (reversed list of list
indices to follow to target)."
  (goto-char toplevel-pos)
  (let ((p (reverse path)))
    (while p
      (relint--skip-whitespace)
      (let ((skip (car p)))
        ;; Enter next sexp and skip past the `skip' first sexps inside.
        (cond
         ((looking-at (rx (or "'" "#'" "`" ",@" ",")))
          (goto-char (match-end 0))
          (setq skip (1- skip)))
         ((looking-at (rx "("))
          (forward-char 1)))
        (while (> skip 0)
          (relint--skip-whitespace)
          (if (looking-at (rx "."))
              (progn
                (goto-char (match-end 0))
                (relint--skip-whitespace)
                (cond
                 ((looking-at (rx (or "'" "#'" "`" ",@" ",")))
                  ;; Sugar after dot represents one sexp.
                  (goto-char (match-end 0))
                  (setq skip (1- skip)))
                 ((looking-at (rx "("))
                  ;; `. (' represents zero sexps.
                  (goto-char (match-end 0)))))
            (forward-sexp)
            (setq skip (1- skip)))))
      (setq p (cdr p))))
  (relint--skip-whitespace))

(defun relint--pos-line-col-from-toplevel-pos-path (toplevel-pos path)
  "Compute (POSITION LINE COLUMN) from TOPLEVEL-POS and PATH (reversed
list of list indices to follow to target)."
  (save-excursion
    (relint--go-to-pos-path toplevel-pos path)
    (list (point)
          (line-number-at-pos (point) t)
          (1+ (current-column)))))

(defun relint--suppression (pos message)
  "Whether there is a suppression for MESSAGE at POS."
  (save-excursion
    ;; On a preceding line, look for a comment on the form
    ;;
    ;; relint suppression: SUBSTRING
    ;;
    ;; where SUBSTRING is a substring of MESSAGE. There can be
    ;; multiple suppression lines preceding a line of code with
    ;; several errors.
    (goto-char pos)
    (forward-line -1)
    (let ((matched nil))
      (while (and
              (not (setq matched
                         (and
                          (looking-at (rx (0+ blank) (1+ ";") (0+ blank)
                                          "relint suppression:" (0+ blank)
                                          (group (0+ nonl)
                                                 (not (any "\n" blank)))))
                          (let ((substr (match-string 1)))
                            (string-match-p (regexp-quote substr) message)))))
              (looking-at (rx bol
                              (0+ blank) (opt ";" (0+ nonl))
                              eol))
              (not (bobp)))
        (forward-line -1))
      matched)))

(defun relint--output-error (string)
  (if (and noninteractive (not relint--error-buffer))
      (message "%s" string)
    (relint--add-to-error-buffer (concat string "\n"))))

(defun relint--report (file pos path message)
  (let ((pos-line-col (relint--pos-line-col-from-toplevel-pos-path pos path)))
    (if (relint--suppression (nth 0 pos-line-col) message)
        (setq relint--suppression-count (1+ relint--suppression-count))
      (relint--output-error
       (format "%s:%d:%d: %s"
               file (nth 1 pos-line-col) (nth 2 pos-line-col) message))))
  (setq relint--error-count (1+ relint--error-count)))

(defun relint--escape-string (str escape-printable)
  (replace-regexp-in-string
   (rx (any cntrl "\177-\377" ?\\ ?\"))
   (lambda (s)
     (let ((c (logand (string-to-char s) #xff)))
       (or (cdr (assq c '((?\b . "\\b")
                          (?\t . "\\t")
                          (?\n . "\\n")
                          (?\v . "\\v")
                          (?\f . "\\f")
                          (?\r . "\\r")
                          (?\e . "\\e"))))
           (if (memq c '(?\\ ?\"))
               (if escape-printable (string ?\\ c) (string c))
             (format "\\%03o" c)))))
   str t t))

(defun relint--quote-string (str)
  (concat "\"" (relint--escape-string str t) "\""))

(defun relint--caret-string (string pos)
  (let ((quoted-pos
         (length (relint--escape-string (substring string 0 pos) t))))
    (concat (make-string quoted-pos ?.) "^")))

(defun relint--check-string (string checker name file pos path)
  (let ((complaints
         (condition-case err
             (mapcar (lambda (warning)
                       (let ((ofs (car warning)))
                         (format "In %s: %s (pos %d)\n  %s\n   %s"
                                 name (cdr warning) ofs
                                 (relint--quote-string string)
                                 (relint--caret-string string ofs))))
                     (funcall checker string))
           (error (list (format "In %s: Error: %s: %s"
                                name  (cadr err)
                                (relint--quote-string string)))))))
    (dolist (msg complaints)
      (relint--report file pos path msg))))

(defun relint--check-skip-set (skip-set-string name file pos path)
  (relint--check-string skip-set-string #'xr-skip-set-lint name file pos path))

(defun relint--check-re-string (re name file pos path)
  (relint--check-string re #'xr-lint name file pos path))
  
(defun relint--check-syntax-string (syntax name file pos path)
  (relint--check-string syntax #'relint--syntax-string-lint name file pos path))

(defconst relint--syntax-codes
  '((?-  . whitespace)
    (?\s . whitespace)
    (?.  . punctuation)
    (?w  . word)
    (?W  . word)       ; undocumented
    (?_  . symbol)
    (?\( . open-parenthesis)
    (?\) . close-parenthesis)
    (?'  . expression-prefix)
    (?\" . string-quote)
    (?$  . paired-delimiter)
    (?\\ . escape)
    (?/  . character-quote)
    (?<  . comment-start)
    (?>  . comment-end)
    (?|  . string-delimiter)
    (?!  . comment-delimiter)))

(defun relint--syntax-string-lint (syntax)
  "Check the syntax-skip string SYNTAX.  Return list of complaints."
  (let ((errs nil)
        (start (if (string-prefix-p "^" syntax) 1 0)))
    (when (member syntax '("" "^"))
      (push (cons start "Empty syntax string") errs))
    (let ((seen nil))
      (dolist (i (number-sequence start (1- (length syntax))))
        (let* ((c (aref syntax i))
               (sym (cdr (assq c relint--syntax-codes))))
          (if sym
              (if (memq sym seen)
                  (push (cons i (relint--escape-string
                                 (format "Duplicated syntax code `%c'" c)
                                 nil))
                        errs)
                (push sym seen))
            (push (cons i (relint--escape-string
                           (format "Invalid char `%c' in syntax string" c)
                           nil))
                  errs)))))
    (nreverse errs)))

(defvar relint--variables nil
  "Alist of global variable definitions.
Each element is either (NAME expr EXPR), for unevaluated expressions,
or (NAME val VAL), for values.")

;; List of variables that have been checked, so that we can avoid
;; checking direct uses of it.
(defvar relint--checked-variables)

;; Alist of functions taking regexp argument(s).
;; The names map to a list of the regexp argument indices.
(defvar relint--regexp-functions)

;; List of functions defined in the current file, each element on the
;; form (FUNCTION ARGS BODY), where ARGS is the lambda list and BODY
;; its body expression list.
(defvar relint--function-defs)

;; List of macros defined in the current file, each element on the
;; form (MACRO ARGS BODY), where ARGS is the lambda list and BODY its
;; body expression list.
(defvar relint--macro-defs)

;; Alist of alias definitions in the current file.
(defvar relint--alias-defs)

;; Alist of local variables. Each element is either (NAME VALUE),
;; where VALUE is the (evaluated) value, or just (NAME) if the binding
;; exists but the value is unknown.
(defvar relint--locals)

(defvar relint--eval-mutables nil
  "List of local variables mutable in the current evaluation context.")

(defconst relint--safe-functions
  '(cons list append
    concat
    car cdr caar cadr cdar cddr car-safe cdr-safe nth nthcdr
    caaar cdaar cadar cddar caadr cdadr caddr cdddr
    format format-message
    regexp-quote regexp-opt regexp-opt-charset
    reverse
    member memq memql remove remq member-ignore-case
    assoc assq rassoc rassq assoc-string
    identity
    string make-string make-list
    substring
    length safe-length
    symbol-name
    intern intern-soft make-symbol
    null not xor
    eq eql equal
    string-equal string= string< string-lessp string> string-greaterp
    compare-strings
    char-equal string-match-p
    string-match split-string
    wildcard-to-regexp
    combine-and-quote-strings split-string-and-unquote
    string-to-multibyte string-as-multibyte string-to-unibyte string-as-unibyte
    string-join string-trim-left string-trim-right string-trim
    string-prefix-p string-suffix-p
    string-blank-p string-remove-prefix string-remove-suffix
    vector aref elt vconcat
    char-to-string string-to-char
    number-to-string string-to-number int-to-string
    string-to-list string-to-vector string-or-null-p
    upcase downcase capitalize
    purecopy copy-sequence copy-alist copy-tree
    flatten-tree
    member-ignore-case
    last butlast number-sequence
    plist-get plist-member
    1value
    consp atom stringp symbolp listp nlistp booleanp
    integerp numberp natnump fixnump bignump characterp zerop
    sequencep vectorp arrayp
    + - * / % mod 1+ 1- max min < <= = > >= /= abs
    ash lsh logand logior logxor)
  "Functions that are safe to call during evaluation.
Except for altering the match state, these are side-effect-free
and reasonably pure (some depend on variables in fairly uninteresting ways,
like `case-fold-search').
More functions could be added if there is evidence that it would
help in evaluating more regexp strings.")

(defconst relint--safe-alternatives
  '((nconc    . append)
    (delete   . remove)
    (delq     . remq)
    (nreverse . reverse)
    (nbutlast . butlast))
"Alist mapping non-safe functions to semantically equivalent safe
alternatives.")

(defconst relint--safe-cl-alternatives
  '((cl-delete-duplicates . cl-remove-duplicates)
    (cl-delete            . cl-remove)
    (cl-delete-if         . cl-remove-if)
    (cl-delete-if-not     . cl-remove-if-not)
    (cl-nsubstitute       . cl-substitute)
    (cl-nunion            . cl-union)
    (cl-nintersection     . cl-intersection)
    (cl-nset-difference   . cl-set-difference)
    (cl-nset-exclusive-or . cl-set-exclusive-or)
    (cl-nsublis           . cl-sublis))
"Alist mapping non-safe cl functions to semantically equivalent safe
alternatives. They may still require wrapping their function arguments.")

(defun relint--rx-safe (rx)
  "Return RX safe to translate; throw 'relint-eval 'no-value if not."
  (cond
   ((atom rx) rx)
   ;; These cannot contain rx subforms.
   ((memq (car rx) '(any in char not-char not backref
                     syntax not-syntax category))
    rx)
   ;; We ignore the differences in evaluation time between `eval' and
   ;; `regexp', and just use what environment we have.
   ((eq (car rx) 'eval)
    (let ((arg (relint--eval (cadr rx))))
      ;; For safety, make sure the result isn't another evaluating form.
      (when (and (consp arg)
                 (memq (car arg) '(literal eval regexp regex)))
        (throw 'relint-eval 'no-value))
      arg))
   ((memq (car rx) '(literal regexp regex))
    (let ((arg (relint--eval (cadr rx))))
      (if (stringp arg)
          (list (car rx) arg)
        (throw 'relint-eval 'no-value))))
   (t (cons (car rx) (mapcar #'relint--rx-safe (cdr rx))))))

(defun relint--eval-rx (args)
  "Evaluate an `rx-to-string' expression."
  (let ((safe-args (cons (relint--rx-safe (car args))
                         (cdr args))))
    (condition-case nil
        (apply #'rx-to-string safe-args)
      (error (throw 'relint-eval 'no-value)))))

(defun relint--apply (formals actuals body)
  "Bind FORMALS to ACTUALS and evaluate BODY."
  (let ((bindings nil))
    (while formals
      (cond
       ((eq (car formals) '&rest)
        (push (cons (cadr formals) (list actuals)) bindings)
        (setq formals nil))
       ((eq (car formals) '&optional)
        (setq formals (cdr formals)))
       (t
        (push (cons (car formals) (list (car actuals))) bindings)
        (setq formals (cdr formals))
        (setq actuals (cdr actuals)))))
    ;; This results in dynamic binding, but that doesn't matter for our
    ;; purposes.
    (let ((relint--locals (append bindings relint--locals))
          (relint--eval-mutables (append (mapcar #'car bindings)
                                         relint--eval-mutables)))
      (relint--eval-body body))))

(defun relint--no-value (&rest _)
  "A function that fails when called."
  (throw 'relint-eval 'no-value))

(defun relint--wrap-function (form)
  "Transform an evaluated function (typically a symbol or lambda expr)
into something that can be called safely."
  (cond
   ((symbolp form)
    (if (memq form relint--safe-functions)
        form
      (or (cdr (assq form relint--safe-alternatives))
          (let ((def (cdr (assq form relint--function-defs))))
            (if def
                (let ((formals (car def))
                      (body (cadr def)))
                  (lambda (&rest args)
                    (relint--apply formals args body)))
              'relint--no-value)))))
   ((and (consp form) (eq (car form) 'lambda))
    (let ((formals (cadr form))
          (body (cddr form)))
      (lambda (&rest args)
        (relint--apply formals args body))))
   (t 'relint--no-value)))

(defun relint--wrap-cl-keyword-args (args)
  "Wrap the function arguments :test, :test-not, :key in ARGS."
  (let ((test     (plist-get args :test))
        (test-not (plist-get args :test-not))
        (key      (plist-get args :key))
        (ret (copy-sequence args)))
    (when test
      (plist-put ret :test     (relint--wrap-function test)))
    (when test-not
      (plist-put ret :test-not (relint--wrap-function test-not)))
    (when key
      (plist-put ret :key      (relint--wrap-function key)))
    ret))

(defun relint--eval-to-binding (form)
  "Evaluate a form, returning (VALUE) on success or nil on failure."
  (let ((val (catch 'relint-eval
               (list (relint--eval form)))))
    (if (eq val 'no-value) nil val)))

(defun relint--eval-body (body)
  "Evaluate a list of forms; return result of last form."
  (if (consp body)
      (progn
        (while (consp (cdr body))
          (relint--eval (car body))
          (setq body (cdr body)))
        (if (cdr body)
            (throw 'relint-eval 'no-value)
          (relint--eval (car body))))
    (if body
        (throw 'relint-eval 'no-value)
      nil)))

(defun relint--eval (form)
  "Evaluate a form. Throw 'relint-eval 'no-value if something could
not be evaluated safely."
  (if (atom form)
      (cond
       ((booleanp form) form)
       ((keywordp form) form)
       ((symbolp form)
        (let ((local (assq form relint--locals)))
          (if local
              (if (cdr local)
                  (cadr local)
                (throw 'relint-eval 'no-value))
            (let ((binding (assq form relint--variables)))
              (if binding
                  (if (eq (cadr binding) 'val)
                      (caddr binding)
                    (let ((val (relint--eval (caddr binding))))
                      (setcdr binding (list 'val val))
                      val))
                  (throw 'relint-eval 'no-value))))))
       (t form))
    (let ((head (car form))
          (body (cdr form)))
      (cond
       ((eq head 'quote)
        (if (and (consp (car body))
                 (eq (caar body) '\,))     ; In case we are inside a backquote.
            (throw 'relint-eval 'no-value)
          (car body)))
       ((memq head '(function cl-function))
        ;; Treat cl-function like plain function (close enough).
        (car body))
       ((eq head 'lambda)
        form)

       ;; Functions considered safe.
       ((memq head relint--safe-functions)
        (let ((args (mapcar #'relint--eval body)))
          ;; Catching all errors isn't wonderful, but sometimes a global
          ;; variable argument has an unsuitable default value which is
          ;; supposed to have been changed at the expression point.
          (condition-case nil
              (apply head args)
            (error (throw 'relint-eval 'no-value)))))

       ;; replace-regexp-in-string: wrap the rep argument if it's a function.
       ((eq head 'replace-regexp-in-string)
        (let ((all-args (mapcar #'relint--eval body)))
          (let* ((rep-arg (cadr all-args))
                 (rep (if (stringp rep-arg)
                          rep-arg
                        (relint--wrap-function rep-arg)))
                 (args (append (list (car all-args) rep) (cddr all-args))))
            (condition-case nil
                (apply head args)
              (error (throw 'relint-eval 'no-value))))))

       ;; alist-get: wrap the optional fifth argument (testfn).
       ((eq head 'alist-get)
        (let* ((all-args (mapcar #'relint--eval body))
               (args (if (< (length all-args) 5)
                         all-args
                       (append (butlast all-args (- (length all-args) 4))
                               (list (relint--wrap-function
                                      (nth 4 all-args)))))))
          (condition-case nil
              (apply head args)
            (error (throw 'relint-eval 'no-value)))))

       ((eq head 'if)
        (let ((condition (relint--eval (car body))))
          (let ((then-part (nth 1 body))
                (else-tail (nthcdr 2 body)))
            (cond (condition
                   (relint--eval then-part))
                  (else-tail
                   (relint--eval-body else-tail))))))

       ((eq head 'and)
        (if body
            (let ((val (relint--eval (car body))))
              (if (and val (cdr body))
                  (relint--eval (cons 'and (cdr body)))
                val))
          t))

       ((eq head 'or)
        (if body
            (let ((val (relint--eval (car body))))
              (if (and (not val) (cdr body))
                  (relint--eval (cons 'or (cdr body)))
                val))
          nil))
       
       ((eq head 'cond)
        (and body
             (let ((clause (car body)))
               (if (consp clause)
                   (let ((val (relint--eval (car clause))))
                     (if val
                         (if (cdr clause)
                             (relint--eval-body (cdr clause))
                           val)
                       (relint--eval (cons 'cond (cdr body)))))
                 ;; Syntax error
                 (throw 'relint-eval 'no-value)))))

       ((memq head '(progn ignore-errors eval-when-compile eval-and-compile))
        (relint--eval-body body))

       ;; Hand-written implementation of `cl-assert' -- good enough.
       ((eq head 'cl-assert)
        (unless (relint--eval (car body))
          (throw 'relint-eval 'no-value)))

       ((eq head 'prog1)
        (let ((val (relint--eval (car body))))
          (relint--eval-body (cdr body))
          val))

       ((eq head 'prog2)
        (relint--eval (car body))
        (let ((val (relint--eval (cadr body))))
          (relint--eval-body (cddr body))
          val))

       ;; delete-dups: Work on a copy of the argument.
       ((eq head 'delete-dups)
        (let ((arg (relint--eval (car body))))
          (delete-dups (copy-sequence arg))))

       ;; Safe macros that expand to pure code, and their auxiliary macros.
       ((memq head '(when unless
                     \` backquote-list*
                     pcase pcase-let pcase-let* pcase--flip
                     cl-case cl-loop cl-flet cl-flet* cl-labels))
        (relint--eval (macroexpand form)))

       ;; catch: as long as nobody throws, this naïve code is fine.
       ((eq head 'catch)
        (relint--eval-body (cdr body)))

       ;; condition-case: as long as there is no error...
       ((eq head 'condition-case)
        (relint--eval (cadr body)))

       ;; cl--block-wrapper: works like identity, more or less.
       ((eq head 'cl--block-wrapper)
        (relint--eval (car body)))

       ;; Functions taking a function as first argument.
       ((memq head '(apply funcall mapconcat
                     cl-some cl-every cl-notany cl-notevery))
        (let ((fun (relint--wrap-function (relint--eval (car body))))
              (args (mapcar #'relint--eval (cdr body))))
          (condition-case nil
              (apply head fun args)
            (error (throw 'relint-eval 'no-value)))))
       
       ;; Functions with functions as keyword arguments :test, :test-not, :key
       ((memq head '(cl-remove-duplicates cl-remove cl-substitute cl-member
                     cl-find cl-position cl-count cl-mismatch cl-search
                     cl-union cl-intersection cl-set-difference
                     cl-set-exclusive-or cl-subsetp
                     cl-assoc cl-rassoc
                     cl-sublis))
        (let ((args (relint--wrap-cl-keyword-args
                     (mapcar #'relint--eval body))))
          (condition-case nil
              (apply head args)
            (error (throw 'relint-eval 'no-value)))))
       
       ;; Functions taking a function as first argument,
       ;; and with functions as keyword arguments :test, :test-not, :key
       ((memq head '(cl-reduce cl-remove-if cl-remove-if-not
                     cl-find-if cl-find-if not
                     cl-position-if cl-position-if-not
                     cl-count-if cl-count-if-not
                     cl-member-if cl-member-if-not
                     cl-assoc-if cl-assoc-if-not
                     cl-rassoc-if cl-rassoc-if-not))
        (let ((fun (relint--wrap-function (relint--eval (car body))))
              (args (relint--wrap-cl-keyword-args
                     (mapcar #'relint--eval (cdr body)))))
          (condition-case nil
              (apply head fun args)
            (error (throw 'relint-eval 'no-value)))))

       ;; mapcar, mapcan, mapc: accept missing items in the list argument.
       ((memq head '(mapcar mapcan mapc))
        (let* ((fun (relint--wrap-function (relint--eval (car body))))
               (arg (relint--eval-list (cadr body)))
               (seq (if (listp arg)
                        (remq nil arg)
                      arg)))
          (condition-case nil
              (funcall head fun seq)
            (error (throw 'relint-eval 'no-value)))))

       ;; sort: accept missing items in the list argument.
       ((eq head 'sort)
        (let* ((arg (relint--eval-list (car body)))
               (seq (cond ((listp arg) (remq nil arg))
                          ((sequencep arg) (copy-sequence arg))
                          (arg)))
               (pred (relint--wrap-function (relint--eval (cadr body)))))
          (condition-case nil
              (sort seq pred)
            (error (throw 'relint-eval 'no-value)))))

       ;; rx, rx-to-string: check for lisp expressions in constructs first,
       ;; then apply.
       ((eq head 'rx)
        (relint--eval-rx (list (cons 'seq body) t)))

       ((eq head 'rx-to-string)
        (let ((args (mapcar #'relint--eval body)))
          (relint--eval-rx args)))

       ;; setq: set local variables if permitted.
       ((eq head 'setq)
        (if (and (symbolp (car body)) (consp (cdr body)))
            (let* ((name (car body))
                   ;; FIXME: Consider using relint--eval-to-binding instead,
                   ;; tolerating unevaluatable expressions.
                   (val (relint--eval (cadr body))))
              ;; Somewhat dubiously, we ignore the side-effect for
              ;; non-local (or local non-mutable) variables and hope
              ;; it doesn't matter.
              (when (memq name relint--eval-mutables)
                (let ((local (assq name relint--locals)))
                  (setcdr local (list val))))
              (if (cddr body)
                  (relint--eval (cons 'setq (cddr body)))
                val))
          (throw 'relint-eval 'no-value)))  ; Syntax error.

       ((eq head 'push)
        (let* ((expr (car body))
               (name (cadr body))
               (local (assq name relint--locals)))
          (if (and (memq name relint--eval-mutables)
                   (cdr local))
              (let ((new-val (cons (relint--eval expr) (cadr local))))
                (setcdr local (list new-val))
                new-val)
            (throw 'relint-eval 'no-value))))

       ((eq head 'pop)
        (let* ((name (car body))
               (local (assq name relint--locals)))
          (if (and (memq name relint--eval-mutables)
                   (cdr local)
                   (consp (cadr local)))
              (let ((val (cadr local)))
                (setcdr local (list (cdr val)))
                (car val))
            (throw 'relint-eval 'no-value))))

       ;; let and let*: do not permit multi-expression bodies, since they
       ;; will contain necessary side-effects that we don't handle.
       ((eq head 'let)
        (let ((bindings
               (mapcar (lambda (binding)
                         (if (consp binding)
                             (cons (car binding)
                                   (relint--eval-to-binding (cadr binding)))
                           (cons binding (list nil))))
                       (car body))))
          (let ((relint--locals (append bindings relint--locals))
                (relint--eval-mutables (append (mapcar #'car bindings)
                                               relint--eval-mutables)))
            (relint--eval-body (cdr body)))))

       ((eq head 'let*)
        (let ((bindings (car body)))
          (if bindings
              (let* ((bindspec (car bindings))
                     (binding
                      (if (consp bindspec)
                          (cons (car bindspec)
                                (relint--eval-to-binding (cadr bindspec)))
                        (cons bindspec (list nil))))
                     (relint--locals (cons binding relint--locals))
                     (relint--eval-mutables
                      (cons (car binding) relint--eval-mutables)))
                (relint--eval `(let* ,(cdr bindings) ,@(cdr body))))
            (relint--eval-body (cdr body)))))

       ;; dolist: simulate its operation. We could also expand it,
       ;; but this is somewhat faster.
       ((eq head 'dolist)
        (unless (and (>= (length body) 2)
                     (consp (car body)))
          (throw 'relint-eval 'no-value))
        (let ((var (nth 0 (car body)))
              (seq-arg (nth 1 (car body)))
              (res-arg (nth 2 (car body))))
          (unless (symbolp var)
            (throw 'relint-eval 'no-value))
          (let ((seq (relint--eval-list seq-arg)))
            (while (consp seq)
              (let ((relint--locals (cons (list var (car seq))
                                          relint--locals)))
                (relint--eval-body (cdr body)))
              (setq seq (cdr seq))))
          (and res-arg (relint--eval res-arg))))

       ;; while: this slows down simulation noticeably, but catches some
       ;; mistakes.
       ((eq head 'while)
        (let ((condition (car body))
              (loops 0))
          (while (and (relint--eval condition)
                      (< loops 100))
            (relint--eval-body (cdr body))
            (setq loops (1+ loops)))
          nil))

       ;; Loose comma: can occur if we unwittingly stumbled into a backquote
       ;; form. Just eval the arg and hope for the best.
       ((eq head '\,)
        (relint--eval (car body)))

       ;; functionp: be optimistic, for determinism
       ((eq head 'functionp)
        (let ((arg (relint--eval (car body))))
          (cond
           ((symbolp arg) (not (memq arg '(nil t))))
           ((consp arg) (eq (car arg) 'lambda)))))

       ;; featurep: only handle features that we are reasonably sure about,
       ;; to avoid depending too much on the particular host Emacs.
       ((eq head 'featurep)
        (let ((arg (relint--eval (car body))))
          (cond ((eq arg 'xemacs) nil)
                ((memq arg '(emacs mule)) t)
                (t (throw 'relint-eval 'no-value)))))

       ;; Locally defined functions: try evaluating.
       ((assq head relint--function-defs)
        (let* ((fn (cdr (assq head relint--function-defs)))
               (formals (car fn))
               (fn-body (cadr fn)))
          (let ((args (mapcar #'relint--eval body)))
            (relint--apply formals args fn-body))))

       ;; Locally defined macros: try expanding.
       ((assq head relint--macro-defs)
        (let ((args body))
          (let* ((macro (cdr (assq head relint--macro-defs)))
                 (formals (car macro))
                 (macro-body (cadr macro)))
            (relint--eval
             (relint--apply formals args macro-body)))))

       ;; Alias: substitute and try again.
       ((assq head relint--alias-defs)
        (relint--eval (cons (cdr (assq head relint--alias-defs))
                            body)))

       ((assq head relint--safe-alternatives)
        (relint--eval (cons (cdr (assq head relint--safe-alternatives))
                            body)))

       ((assq head relint--safe-cl-alternatives)
        (relint--eval (cons (cdr (assq head relint--safe-cl-alternatives))
                            body)))
       
       (t
        ;;(relint--output-error (format "eval rule missing: %S" form))
        (throw 'relint-eval 'no-value))))))

(defun relint--eval-or-nil (form)
  "Evaluate FORM. Return nil if something prevents it from being evaluated."
  (let ((val (catch 'relint-eval (relint--eval form))))
    (if (eq val 'no-value)
        nil
      val)))

(defun relint--eval-list-body (body)
  (and (consp body)
       (progn
         (while (consp (cdr body))
           (relint--eval-list (car body))
           (setq body (cdr body)))
         (relint--eval-list (car body)))))

(defun relint--eval-list (form)
  "Evaluate a form as far as possible, attempting to keep its list structure
even if all subexpressions cannot be evaluated. Parts that cannot be
evaluated are nil."
  (cond
   ((symbolp form)
    (and form
         (let ((local (assq form relint--locals)))
           (if local
               (and (cdr local) (cadr local))
             (let ((binding (assq form relint--variables)))
               (and binding
                    (if (eq (cadr binding) 'val)
                        (caddr binding)
                      ;; Since we are only doing a list evaluation, don't
                      ;; update the variable here.
                      (relint--eval-list (caddr binding)))))))))
   ((atom form)
    form)
   ((memq (car form) '(progn ignore-errors eval-when-compile eval-and-compile))
    (relint--eval-list-body (cdr form)))

   ;; Pure structure-generating functions: Apply even if we cannot evaluate
   ;; all arguments (they will be nil), because we want a reasonable
   ;; approximation of the structure.
   ((memq (car form) '(list append cons reverse remove remq))
    (apply (car form) (mapcar #'relint--eval-list (cdr form))))

   ((eq (car form) 'delete-dups)
    (let ((arg (relint--eval-list (cadr form))))
      (delete-dups (copy-sequence arg))))

   ((memq (car form) '(purecopy copy-sequence copy-alist))
    (relint--eval-list (cadr form)))

   ((memq (car form) '(\` backquote-list*))
    (relint--eval-list (macroexpand form)))

   ((assq (car form) relint--safe-alternatives)
    (relint--eval-list (cons (cdr (assq (car form) relint--safe-alternatives))
                             (cdr form))))

   (t
    (relint--eval-or-nil form))))

(defun relint--get-list (form)
  "Convert something to a list, or nil."
  (let ((val (relint--eval-list form)))
    (and (consp val) val)))
  
(defun relint--get-string (form)
  "Convert something to a string, or nil."
  (let ((val (relint--eval-or-nil form)))
    (and (stringp val) val)))

(defun relint--check-re (form name file pos path)
  (let ((re (relint--get-string form)))
    (when re
      (relint--check-re-string re name file pos path))))

(defun relint--check-list (form name file pos path)
  "Check a list of regexps."
  ;; Don't use dolist -- mustn't crash on improper lists.
  (let ((l (relint--get-list form)))
    (while (consp l)
      (when (stringp (car l))
        (relint--check-re-string (car l) name file pos path))
      (setq l (cdr l)))))

(defun relint--check-list-any (form name file pos path)
  "Check a list of regexps or conses whose car is a regexp."
  (dolist (elem (relint--get-list form))
    (cond
     ((stringp elem)
      (relint--check-re-string elem name file pos path))
     ((and (consp elem)
           (stringp (car elem)))
      (relint--check-re-string (car elem) name file pos path)))))

(defun relint--check-alist-any (form name file pos path)
  "Check an alist whose cars or cdrs may be regexps."
  (dolist (elem (relint--get-list form))
    (when (consp elem)
      (when (stringp (car elem))
        (relint--check-re-string (car elem) name file pos path))
      (when (stringp (cdr elem))
        (relint--check-re-string (cdr elem) name file pos path)))))

(defun relint--check-alist-cdr (form name file pos path)
  "Check an alist whose cdrs are regexps."
  (dolist (elem (relint--get-list form))
    (when (and (consp elem)
               (stringp (cdr elem)))
      (relint--check-re-string (cdr elem) name file pos path))))

(defun relint--check-font-lock-keywords (form name file pos path)
  "Check a font-lock-keywords list.  A regexp can be found in an element,
or in the car of an element."
  (dolist (elem (relint--get-list form))
    (cond
     ((stringp elem)
      (relint--check-re-string elem name file pos path))
     ((and (consp elem)
           (stringp (car elem)))
      (let* ((tag (and (symbolp (cdr elem)) (cdr elem)))
             (ident (if tag (format "%s (%s)" name tag) name)))
        (relint--check-re-string (car elem) ident file pos path))))))

(defun relint--check-compilation-error-regexp-alist-alist (form name
                                                           file pos path)
  (dolist (elem (relint--get-list form))
    (if (cadr elem)
        (relint--check-re-string
         (cadr elem)
         (format "%s (%s)" name (car elem))
         file pos path))))

(defun relint--check-rules-list (form name file pos path)
  "Check a variable on `align-mode-rules-list' format"
  (dolist (rule (relint--get-list form))
    (when (and (consp rule)
               (symbolp (car rule)))
      (let* ((rule-name (car rule))
             (re-form (cdr (assq 'regexp (cdr rule))))
             (re (relint--get-string re-form)))
        (when (stringp re)
          (relint--check-re-string 
           re (format "%s (%s)" name rule-name) file pos path))))))

(defconst relint--known-regexp-variables
  '(page-delimiter paragraph-separate paragraph-start
    sentence-end comment-start-skip comment-end-skip)
  "List of known (global or buffer-local) regexp variables.")

(defconst relint--known-regexp-returning-functions
  '(regexp-quote regexp-opt regexp-opt-charset
    rx rx-to-string wildcard-to-regexp read-regexp
    char-fold-to-regexp find-tag-default-as-regexp
    find-tag-default-as-symbol-regexp sentence-end
    word-search-regexp)
  "List of functions known to return a regexp.")

;; List of functions believed to return a regexp.
(defvar relint--regexp-returning-functions)

(defun relint--regexp-generators (expr expanded)
  "List of regexp-generating functions and variables used in EXPR.
EXPANDED is a list of expanded functions, to prevent recursion."
  (cond
   ((symbolp expr)
    (and (not (memq expr '(nil t)))
         ;; Check both variable contents and name.
         (or (let ((def (assq expr relint--variables)))
               (and def
                    (eq (cadr def) 'expr)
                    (relint--regexp-generators (caddr def) expanded)))
             (and (or (memq expr relint--known-regexp-variables)
                      ;; This is guesswork, but effective.
                      (string-match-p
                       (rx (or (seq bos (or "regexp" "regex"))
                               (or "-regexp" "-regex" "-re"))
                           eos)
                       (symbol-name expr)))
                  (list expr)))))
   ((atom expr) nil)
   ((memq (car expr) relint--regexp-returning-functions)
    (list (car expr)))
   ((memq (car expr) '(looking-at re-search-forward re-search-backward
                       string-match string-match-p looking-back looking-at-p))
    nil)
   ((null (cdr (last expr)))
    (let* ((head (car expr))
           (args (if (memq head '(if when unless while))
                     (cddr expr)
                   (cdr expr)))
           (alias (assq head relint--alias-defs)))
      (if alias
          (relint--regexp-generators (cons (cdr alias) (cdr expr)) expanded)
        (append (mapcan (lambda (x) (relint--regexp-generators x expanded))
                        args)
                (let ((fun (assq head relint--function-defs)))
                  (and fun (not (memq head expanded))
                       (mapcan (lambda (x)
                                 (relint--regexp-generators
                                  x (cons head expanded)))
                               (caddr fun))))))))))

(defun relint--check-non-regexp-provenance (skip-function form file pos path)
  (let ((reg-gen (relint--regexp-generators form nil)))
    (when reg-gen
      (relint--report file pos path
                      (format "`%s' cannot be used for arguments to `%s'"
                              (car reg-gen) skip-function)))))

(defun relint--check-format-mixup (template args file pos path)
  "Look for a format expression that suggests insertion of a regexp
into a character alternative: [%s] where the corresponding format
parameter is regexp-generating."
  (let ((nargs (length args))
        (index 0)
        (start 0))
    (while (and (< index nargs)
                (string-match (rx
                               "%"
                               (opt (1+ digit) "$")
                               (0+ (any "+ #" ?-))
                               (0+ digit)
                               (opt "." (0+ digit))
                               (group (any "%sdioxXefgcS")))
                              template start))
      (let ((percent (match-beginning 0))
            (type (string-to-char (match-string 1 template)))
            (next (match-end 0)))
        (when (and (eq type ?s)
                   ;; Find preceding `[' before %s
                   (string-match-p
                    (rx
                     bos
                     (* (or (not (any "\\" "["))
                            (seq "\\" anything)))
                     "["
                     (* (not (any "]")))
                     eos)
                    (substring template start percent)))
          (let ((reg-gen (relint--regexp-generators (nth index args) nil)))
            (when reg-gen
              (relint--report
               file pos (cons (+ index 2) path)
               (format
                "Value from `%s' cannot be spliced into `[...]'"
                (car reg-gen))))))
        (unless (eq type ?%)
          (setq index (1+ index)))
        (setq start next)))))

(defun relint--check-concat-mixup (args file pos path)
  "Look for concat args that suggest insertion of a regexp into a
character alternative: `[' followed by a regexp-generating expression."
  (let ((index 1))
    (while (consp args)
      (let ((arg (car args)))
        (when (and (stringp arg)
                   (cdr args)
                   (string-match-p (rx (or bos (not (any "\\")))
                                       (0+ "\\\\")
                                       "["
                                       (0+ (not (any "]")))
                                       eos)
                                   arg))
          (let ((reg-gen (relint--regexp-generators (cadr args) nil)))
            (when reg-gen
              (relint--report
               file pos (cons (1+ index) path)
               (format
                "Value from `%s' cannot be spliced into `[...]'"
                (car reg-gen)))))))
      (setq index (1+ index))
      (setq args (cdr args)))))

(defun relint--regexp-args-from-doc (doc-string)
  "Extract regexp arguments (as a list of symbols) from DOC-STRING."
  (let ((start 0)
        (found nil))
    (while (string-match (rx (any "rR")
                             (or (seq  "egex" (opt "p"))
                                 (seq "egular" (+ (any " \n\t")) "expression"))
                             (+ (any " \n\t"))
                             (group (+ (any "A-Z" ?-))))
                         doc-string start)
      (push (intern (downcase (match-string 1 doc-string))) found)
      (setq start (match-end 0)))
    found))

(defun relint--check-form-recursively-1 (form file pos path)
  (pcase form
    (`(,(or 'defun 'defmacro 'defsubst)
       ,name ,args . ,body)
     (when (symbolp name)
       (let ((doc-args nil))
         (when (string-match-p (rx (or  "-regexp" "-regex" "-re") eos)
                               (symbol-name name))
           (push name relint--regexp-returning-functions))
         ;; Examine doc string if any.
         (when (stringp (car body))
           (setq doc-args (relint--regexp-args-from-doc (car body)))
           (when (and (not (memq name relint--regexp-returning-functions))
                      (let ((case-fold-search t))
                        (string-match-p
                         (rx (or bos
                                 (seq (or "return" "generate" "make")
                                      (opt "s")
                                      (+ (any " \n\t"))))
                             (opt (or "a" "the") (+ (any " \n\t")))
                             (or "regex"
                                 (seq "regular"
                                      (+ (any " \n\t"))
                                      "expression")))
                         (car body))))
             (push name relint--regexp-returning-functions))
           (setq body (cdr body)))
         ;; Skip declarations.
         (while (and (consp (car body))
                     (memq (caar body) '(interactive declare)))
           (setq body (cdr body)))
         ;; Save the function or macro for possible use.
         (push (list name args body)
               (if (eq (car form) 'defmacro)
                   relint--macro-defs
                 relint--function-defs))

         ;; If any argument looks like a regexp, remember it so that it can be
         ;; checked in calls.
         (when (consp args)
           (let ((indices nil)
                 (index 0))
             (while args
               (let ((arg (car args)))
                 (when (symbolp arg)
                   (cond
                    ((eq arg '&optional))   ; Treat optional args as regular.
                    ((eq arg '&rest)
                     (setq args nil))       ; Ignore &rest args.
                    (t
                     (when (or (memq arg doc-args)
                               (string-match-p
                                (rx (or (or "regexp" "regex" "-re"
                                            "pattern")
                                        (seq bos "re"))
                                    eos)
                                (symbol-name arg)))
                       (push index indices))
                     (setq index (1+ index)))))
                 (setq args (cdr args))))
             (when indices
               (push (cons name (reverse indices))
                     relint--regexp-functions)))))))
    (`(defalias ,name-arg ,def-arg . ,_)
     (let ((name (relint--eval-or-nil name-arg))
           (def  (relint--eval-or-nil def-arg)))
       (when (and name def)
         (push (cons name def) relint--alias-defs))))
    (_
     (let ((index 0))
       (while (consp form)
         (when (consp (car form))
           (relint--check-form-recursively-1
            (car form) file pos (cons index path)))
         (setq form (cdr form))
         (setq index (1+ index)))))))

(defun relint--check-defcustom-type (type name file pos path)
  (pcase type
    (`(const . ,rest)
     ;; Skip keywords.
     (while (and rest (symbolp (car rest)))
       (setq rest (cddr rest)))
     (when rest
       (relint--check-re (car rest) name file pos path)))
    (`(,(or 'choice 'radio) . ,choices)
     (dolist (choice choices)
       (relint--check-defcustom-type choice name file pos path)))))

(defun relint--check-defcustom-re (form name file pos path)
  (let ((args (nthcdr 4 form))
        (index 5))
    (while (consp args)
      (pcase args
        (`(:type ,type)
         (relint--check-defcustom-type (relint--eval-or-nil type)
                                       name file pos (cons index path)))
        (`(:options ,options)
         (relint--check-list options name file pos (cons index path))))
      (setq index (+ index 2))
      (setq args (cddr args)))))

(defun relint--defcustom-type-regexp-p (type)
  "Whether the defcustom type TYPE indicates a regexp."
  (pcase type
    ('regexp t)
    (`(regexp . ,_) t)
    (`(string :tag ,tag . ,_)
     (let ((case-fold-search t))
       (string-match-p (rx bos
                           (opt (or "the" "a") " ")
                           (or "regex" "regular expression"))
                       tag)))
    (`(,(or 'choice 'radio) . ,rest)
     (cl-some #'relint--defcustom-type-regexp-p rest))))

(defun relint--check-and-eval-let-binding (binding mutables file pos path)
  "Check the let-binding BINDING, which is probably (NAME EXPR) or NAME,
and evaluate EXPR. On success return (NAME VALUE); if evaluation failed,
return (NAME); on syntax error, return nil."
  (cond ((symbolp binding)
         (cons binding (list nil)))
        ((and (consp binding)
              (symbolp (car binding))
              (consp (cdr binding)))
         (relint--check-form-recursively-2
          (cadr binding) mutables file pos (cons 1 path))
         (let ((val (catch 'relint-eval
                      (list (relint--eval (cadr binding))))))
           (when (and (consp val)
                      (stringp (car val))
                      (memq (car binding) relint--known-regexp-variables))
             ;; Setting a special buffer-local regexp.
             (relint--check-re (car val) (car binding) file pos (cons 1 path)))
           (cons (car binding)
                 (if (eq val 'no-value)
                     nil
                   val))))))

(defun relint--check-let* (bindings body mutables file pos path index)
  "Check the BINDINGS and BODY of a `let*' form."
  (if bindings
      (let ((b (relint--check-and-eval-let-binding
                (car bindings) mutables file pos (cons index (cons 1 path)))))
        (if b
            (let ((relint--locals (cons b relint--locals)))
              (relint--check-let* (cdr bindings) body (cons (car b) mutables)
                                  file pos path (1+ index)))
          (relint--check-let* (cdr bindings) body mutables
                              file pos path (1+ index))))
    (let ((index 2))
      (while (consp body)
        (when (consp (car body))
          (relint--check-form-recursively-2
           (car body) mutables file pos (cons index path)))
        (setq body (cdr body))
        (setq index (1+ index))))))

(defun relint--check-form-recursively-2 (form mutables file pos path)
"Check FORM (at FILE, POS, PATH) recursively.
MUTABLES is a list of lexical variables in a scope which FORM may mutate
directly."
  (pcase form
    (`(let ,(and (pred listp) bindings) . ,body)
     (let* ((i 0)
            (bindings-path (cons 1 path))
            (new-bindings nil)
            (body-mutables mutables))
       (while (consp bindings)
         (let ((b (relint--check-and-eval-let-binding
                   (car bindings) mutables file pos (cons i bindings-path))))
           (when b
             (push b new-bindings)
             (push (car b) body-mutables))
           (setq i (1+ i))
           (setq bindings (cdr bindings))))
       (let ((relint--locals
              (append new-bindings relint--locals))
             (index 2))
         (while (consp body)
           (when (consp (car body))
             (relint--check-form-recursively-2
              (car body) body-mutables file pos (cons index path)))
           (setq body (cdr body))
           (setq index (1+ index))))))
    (`(let* ,(and (pred listp) bindings) . ,body)
     (relint--check-let* bindings body mutables file pos path 0))
    (`(,(or 'setq 'setq-local) . ,args)
     ;; Only mutate lexical variables in the mutation list, which means
     ;; that this form will be executed exactly once during their remaining
     ;; lifetime. Other lexical vars will just be invalidated since we
     ;; don't know anything about the control flow.
     (let ((i 2))
       (while (and (consp args) (consp (cdr args)) (symbolp (car args)))
         (let ((name (car args))
               (expr (cadr args)))
           (relint--check-form-recursively-2
            expr mutables file pos (cons i path))
           (cond
            ((memq name relint--known-regexp-variables)
             (relint--check-re expr name file pos (cons i path)))
            ((memq name '(font-lock-defaults font-lock-keywords))
             (relint--check-font-lock-keywords expr name
                                               file pos (cons i path)))
            (t
             ;; Invalidate the variable if it was local; otherwise, ignore.
             (let ((local (assq name relint--locals)))
               (when local
                 (setcdr local
                         (and (memq name mutables)
                              (let ((val (catch 'relint-eval
                                           (list (relint--eval expr)))))
                                (and (not (eq val 'no-value))
                                     val)))))))))
         (setq args (cddr args))
         (setq i (+ i 2)))))
    (`(push ,expr ,(and (pred symbolp) name))
     ;; Treat (push EXPR NAME) as (setq NAME (cons EXPR NAME)).
     (relint--check-form-recursively-2 expr mutables file pos (cons 1 path))
     (let ((local (assq name relint--locals)))
       (when local
         (setcdr local
                 (let ((old-val (cdr local)))
                   (and old-val
                        (memq name mutables)
                        (let ((val (catch 'relint-eval
                                     (list (cons (relint--eval expr)
                                                 (car old-val))))))
                          (and (consp val)
                               val))))))))
    (`(pop ,(and (pred symbolp) name))
     ;; Treat (pop NAME) as (setq NAME (cdr NAME)).
     (let ((local (assq name relint--locals)))
       (when (and local (memq name mutables))
         (let ((old-val (cadr local)))
           (when (consp old-val)
             (setcdr local (list (cdr old-val))))))))
    (`(,(or 'if 'and 'or 'when 'unless) ,(and (pred consp) arg1) . ,rest)
     ;; Only first arg is executed unconditionally.
     ;; FIXME: A conditional in the tail position of its environment binding
     ;; has the exactly-once property wrt its body; use it!
     (relint--check-form-recursively-2 arg1 mutables file pos (cons 1 path))
     (let ((i 2))
       (while (consp rest)
         (when (consp (car rest))
           (relint--check-form-recursively-2
            (car rest) nil file pos (cons i path)))
         (setq rest (cdr rest))
         (setq i (1+ i)))))
    (`(,(or 'defun 'defsubst 'defmacro) ,_ ,(and (pred listp) arglist) . ,body)
     ;; Create local bindings for formal arguments (with unknown values).
     (let* ((argnames (mapcan (lambda (arg)
                                (and (symbolp arg)
                                     (not (memq arg '(&optional &rest)))
                                     (list arg)))
                              arglist))
            (relint--locals (append (mapcar #'list argnames) relint--locals)))
       (let ((i 3))
         (while (consp body)
           (when (consp (car body))
             (relint--check-form-recursively-2
              (car body) argnames file pos (cons i path)))
           (setq body (cdr body))
           (setq i (1+ i))))))
    (`(lambda ,(and (pred listp) arglist) . ,body)
     ;; Create local bindings for formal arguments (with unknown values).
     (let* ((argnames (mapcan (lambda (arg)
                                (and (symbolp arg)
                                     (not (memq arg '(&optional &rest)))
                                     (list arg)))
                              arglist))
            (relint--locals (append (mapcar #'list argnames) relint--locals)))
       (let ((i 2))
         (while (consp body)
           (when (consp (car body))
             (relint--check-form-recursively-2
              (car body) argnames file pos (cons i path)))
           (setq body (cdr body))
           (setq i (1+ i))))))
    (_ 
     (pcase form
       (`(,(or 'looking-at 're-search-forward 're-search-backward
               'string-match 'string-match-p 'looking-back 'looking-at-p
               'replace-regexp-in-string 'replace-regexp
               'query-replace-regexp
               'posix-looking-at 'posix-search-backward 'posix-search-forward
               'posix-string-match
               'load-history-filename-element
               'kill-matching-buffers
               'keep-lines 'flush-lines 'how-many)
          ,re-arg . ,_)
        (unless (and (symbolp re-arg)
                     (memq re-arg relint--checked-variables))
          (relint--check-re re-arg (format "call to %s" (car form))
                            file pos (cons 1 path))))
       (`(,(or 'split-string 'split-string-and-unquote
               'string-trim-left 'string-trim-right 'string-trim
               'directory-files-recursively)
          ,_ ,re-arg . ,rest)
        (unless (and (symbolp re-arg)
                     (memq re-arg relint--checked-variables))
          (relint--check-re re-arg (format "call to %s" (car form))
                            file pos (cons 2 path)))
        ;; string-trim has another regexp argument (trim-right, arg 3)
        (when (and (eq (car form) 'string-trim)
                   (car rest))
          (let ((right (car rest)))
            (unless (and (symbolp right)
                         (memq right relint--checked-variables))
              (relint--check-re right (format "call to %s" (car form))
                                file pos (cons 3 path)))))
        ;; split-string has another regexp argument (trim, arg 4)
        (when (and (eq (car form) 'split-string)
                   (cadr rest))
          (let ((trim (cadr rest)))
            (unless (and (symbolp trim)
                         (memq trim relint--checked-variables))
              (relint--check-re trim (format "call to %s" (car form))
                                file pos (cons 4 path))))))
       (`(,(or 'skip-chars-forward 'skip-chars-backward)
          ,skip-arg . ,_)
        (let ((str (relint--get-string skip-arg)))
          (when str
            (relint--check-skip-set str (format "call to %s" (car form))
                                    file pos (cons 1 path))))
        (relint--check-non-regexp-provenance
         (car form) skip-arg file pos (cons 1 path))
        )
       (`(,(or 'skip-syntax-forward 'skip-syntax-backward) ,arg . ,_)
        (let ((str (relint--get-string arg)))
          (when str
            (relint--check-syntax-string str (format "call to %s" (car form))
                                         file pos (cons 1 path))))
        (relint--check-non-regexp-provenance
         (car form) arg file pos (cons 1 path))
        )
       (`(concat . ,args)
        (relint--check-concat-mixup args file pos path))
       (`(format ,template-arg . ,args)
        (let ((template (relint--get-string template-arg)))
          (when template
            (relint--check-format-mixup template args file pos path))))
       (`(,(or 'defvar 'defconst 'defcustom)
          ,name ,re-arg . ,rest)
        (let ((type (and (eq (car form) 'defcustom)
                         (relint--eval-or-nil (plist-get (cdr rest) :type)))))
          (when (symbolp name)
            (cond
             ((or (relint--defcustom-type-regexp-p type)
                  (string-match-p (rx (or "-regexp" "-regex" "-re" "-pattern")
                                      eos)
                                  (symbol-name name)))
              (relint--check-re re-arg name file pos (cons 2 path))
              (when (eq (car form) 'defcustom)
                (relint--check-defcustom-re form name file pos path))
              (push name relint--checked-variables))
             ((and (consp type)
                   (eq (car type) 'alist)
                   (relint--defcustom-type-regexp-p
                    (plist-get (cdr type) :key-type)))
              (relint--check-list-any re-arg name file pos (cons 2 path))
              (push name relint--checked-variables))
             ((and (consp type)
                   (eq (car type) 'alist)
                   (relint--defcustom-type-regexp-p
                    (plist-get (cdr type) :value-type)))
              (relint--check-alist-cdr re-arg name file pos (cons 2 path))
              (push name relint--checked-variables))
             ((or (and (consp type)
                       (eq (car type) 'repeat)
                       (relint--defcustom-type-regexp-p (cadr type)))
                  (string-match-p (rx (or (or "-regexps" "-regexes")
                                          (seq (or "-regexp" "-regex" "-re")
                                               "-list"))
                                      eos)
                                  (symbol-name name)))
              (relint--check-list re-arg name file pos (cons 2 path))
              (push name relint--checked-variables))
             ((string-match-p (rx "font-lock-keywords")
                              (symbol-name name))
              (relint--check-font-lock-keywords re-arg name file pos
                                                (cons 2 path))
              (push name relint--checked-variables))
             ((eq name 'compilation-error-regexp-alist-alist)
              (relint--check-compilation-error-regexp-alist-alist
               re-arg name file pos (cons 2 path))
              (push name relint--checked-variables))
             ((string-match-p (rx (or "-regexp" "-regex" "-re" "-pattern")
                                  "-alist" eos)
                              (symbol-name name))
              (relint--check-alist-any re-arg name file pos (cons 2 path))
              (push name relint--checked-variables))
             ((string-match-p (rx "-mode-alist" eos)
                              (symbol-name name))
              (relint--check-list-any re-arg name file pos (cons 2 path))
              (push name relint--checked-variables))
             ((string-match-p (rx "-rules-list" eos)
                              (symbol-name name))
              (relint--check-rules-list re-arg name file pos (cons 2 path))
              (push name relint--checked-variables))
             ;; Doc string starting with "regexp" etc.
             ((and (stringp (car rest))
                   (let ((case-fold-search t))
                     (string-match-p
                      (rx bos
                          (opt (or "when" "if")
                               (* " ")
                               (or "not" "non")
                               (* (any "- "))
                               "nil"
                               (* (any " ,")))
                          (opt (or "specify" "specifies")
                               " ")
                          (opt (or "a" "the" "this") " ")
                          (or "regex" "regular expression"))
                      (car rest))))
              (relint--check-re re-arg name file pos (cons 2 path))
              (when (eq (car form) 'defcustom)
                (relint--check-defcustom-re form name file pos path))
              (push name relint--checked-variables))
             )

            (let* ((old (assq name relint--variables))
                   (new
                    (or (and old
                             ;; Redefinition of the same variable: eagerly
                             ;; evaluate the new expression in case it uses
                             ;; the old value.
                             (let ((val (catch 'relint-eval
                                          (list (relint--eval re-arg)))))
                               (and (consp val)
                                    (cons 'val val))))
                        (list 'expr re-arg))))
              (push (cons name new) relint--variables)))))
       (`(font-lock-add-keywords ,_ ,keywords . ,_)
        (relint--check-font-lock-keywords
         keywords (car form) file pos (cons 2 path)))
       (`(set (make-local-variable ',name) ,expr)
        (cond ((memq name relint--known-regexp-variables)
               (relint--check-re expr name file pos (cons 2 path)))
              ((memq name '(font-lock-defaults font-lock-keywords))
               (relint--check-font-lock-keywords expr name
                                                 file pos (cons 2 path)))))
       (`(define-generic-mode ,name ,_ ,_ ,font-lock-list ,auto-mode-list . ,_)
        (let ((origin (format "define-generic-mode %s" name)))
          (relint--check-font-lock-keywords font-lock-list origin
                                            file pos (cons 4 path))
          (relint--check-list auto-mode-list origin file pos (cons 5 path))))
       (`(,(or 'syntax-propertize-rules 'syntax-propertize-precompile-rules)
          . ,rules)
        (let ((index 1))
          (dolist (item rules)
            (when (consp item)
              (relint--check-re (car item)
                                (format "call to %s" (car form))
                                file pos (cons 0 (cons index path))))
            (setq index (1+ index)))))
       (`(,name . ,args)
        (let ((alias (assq name relint--alias-defs)))
          (when alias
            (relint--check-form-recursively-2
             (cons (cdr alias) args) mutables file pos path))))
       )

     ;; Check calls to remembered functions with regexp arguments.
     (when (consp form)
       (let ((indices (cdr (assq (car form) relint--regexp-functions))))
         (when indices
           (let ((index 0)
                 (args (cdr form)))
             (while (and indices (consp args))
               (when (= index (car indices))
                 (unless (and (symbolp (car args))
                              (memq (car args) relint--checked-variables))
                   (relint--check-re (car args)
                                     (format "call to %s" (car form))
                                     file pos (cons (1+ index) path)))
                 (setq indices (cdr indices)))
               (setq args (cdr args))
               (setq index (1+ index)))))))

     ;; FIXME: All function applications, and some macros / special forms
     ;; (prog{1,2,n}, save-excursion...) could be scanned with full
     ;; mutables since all args are evaluated once.
     (let ((index 0))
       (while (consp form)
         (when (consp (car form))
           ;; Check subforms with the assumption that nothing can be mutated,
           ;; since we don't really know what is evaluated when.
           (relint--check-form-recursively-2
            (car form) nil file pos (cons index path)))
         (setq form (cdr form))
         (setq index (1+ index)))))))

(defun relint--show-errors ()
  (unless (or noninteractive relint--quiet)
    (let ((pop-up-windows t))
      (display-buffer relint--error-buffer)
      (sit-for 0))))

(defun relint--read-buffer (file)
  "Read top-level forms from the current buffer.
Return a list of (FORM . STARTING-POSITION)."
  (goto-char (point-min))
  (let ((pos nil)
        (keep-going t)
        (read-circle nil)
        (forms nil))
    (while keep-going
      (setq pos (point))
      (let ((form nil))
        (condition-case err
            (setq form (read (current-buffer)))
          (end-of-file
           (setq keep-going nil))
          (invalid-read-syntax
           (cond
            ((equal (cadr err) "#")
             (goto-char pos)
             (forward-sexp 1))
            (t
             (relint--report file (point) nil (prin1-to-string err))
             (setq keep-going nil))))
          (error
           (relint--report file (point) nil (prin1-to-string err))
           (setq keep-going nil)))
        (when (consp form)
          (push (cons form pos) forms))))
    (nreverse forms)))

(defun relint--scan-current-buffer (file)
  (let ((errors-before relint--error-count))
    (let ((forms (relint--read-buffer file))
          (relint--variables nil)
          (relint--checked-variables nil)
          (relint--regexp-functions nil)
          (relint--regexp-returning-functions
           relint--known-regexp-returning-functions)
          (relint--function-defs nil)
          (relint--macro-defs nil)
          (relint--alias-defs nil)
          (relint--locals nil)
          (case-fold-search nil))
      (dolist (form forms)
        (relint--check-form-recursively-1 (car form) file (cdr form) nil))
      (dolist (form forms)
        (relint--check-form-recursively-2 (car form) nil file (cdr form) nil)))
    (when (> relint--error-count errors-before)
      (relint--show-errors))))

(defun relint--scan-file (file base-dir)
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert-file-contents file)
    (relint--scan-current-buffer (file-relative-name file base-dir))))
        
(defvar relint-last-target nil
  "The last file, directory or buffer on which relint was run.")

(defun relint--init (target base-dir error-buffer quiet)
  (setq relint--quiet quiet)
  (setq relint--error-count 0)
  (setq relint--suppression-count 0)
  (if noninteractive
      (setq relint--error-buffer error-buffer)
    (setq relint--error-buffer (or error-buffer (relint--get-error-buffer)))
    (with-current-buffer relint--error-buffer
      (unless quiet
        (let ((inhibit-read-only t))
          (insert (format "Relint results for %s\n" target))
          (relint--show-errors)))
      (setq relint-last-target target)
      (setq default-directory base-dir))))

(defun relint--finish ()
  (let* ((supp relint--suppression-count)
         (errors (- relint--error-count supp))
         (msg (format "%d error%s%s"
                      errors (if (= errors 1) "" "s")
                      (if (zerop supp)
                          ""
                        (format " (%s suppressed)" supp)))))
    (unless (or relint--quiet (and noninteractive (zerop errors)))
      (unless noninteractive
        (relint--add-to-error-buffer (format "\nFinished -- %s.\n" msg)))
      (message "relint: %s." msg))))

(defun relint-again ()
  "Re-run relint on the same file, directory or buffer as last time."
  (interactive)
  (cond ((bufferp relint-last-target)
         (with-current-buffer relint-last-target
           (relint-current-buffer)))
        ((file-directory-p relint-last-target)
         (relint-directory relint-last-target))
        ((file-readable-p relint-last-target)
         (relint-file relint-last-target))
        (t (error "No target"))))

(defvar relint-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map compilation-minor-mode-map)
    (define-key map "n" 'next-error-no-select)
    (define-key map "p" 'previous-error-no-select)
    (define-key map "g" 'relint-again)
    map)
  "Keymap for relint buffers.")

(define-compilation-mode relint-mode "Relint"
  "Mode for relint output."
  (setq-local relint-last-target nil))

(defun relint--scan-files (files target base-dir)
  (relint--init target base-dir nil nil)
  (dolist (file files)
    ;;(relint--output-error (format "Scanning %s" file))
    (relint--scan-file file base-dir))
  (relint--finish))

(defun relint--tree-files (dir)
  (directory-files-recursively
   dir (rx bos (not (any ".")) (* anything) ".el" eos)))

(defun relint--scan-buffer (buffer error-buffer quiet)
  "Scan BUFFER for regexp errors.
Diagnostics to ERROR-BUFFER, or if nil to *relint*.
If QUIET, don't emit messages."
  (unless (eq (buffer-local-value 'major-mode buffer) 'emacs-lisp-mode)
    (error "Relint: can only scan elisp code (use emacs-lisp-mode)"))
  (relint--init buffer default-directory error-buffer quiet)
  (with-current-buffer buffer
    (save-excursion
      (relint--scan-current-buffer (buffer-name))))
  (relint--finish))


;;;###autoload
(defun relint-file (file)
  "Scan FILE, an elisp file, for regexp-related errors."
  (interactive "fRelint elisp file: ")
  (relint--scan-files (list file) file (file-name-directory file)))

;;;###autoload
(defun relint-directory (dir)
  "Scan all *.el files in DIR for regexp-related errors."
  (interactive "DRelint directory: ")
  (message "Finding .el files in %s..." dir)
  (let ((files (relint--tree-files dir)))
    (message "Scanning files...")
    (relint--scan-files files dir dir)))

;;;###autoload
(defun relint-current-buffer ()
  "Scan the current buffer for regexp errors.
The buffer must be in emacs-lisp-mode."
  (interactive)
  (relint--scan-buffer (current-buffer) nil nil))

(defun relint-batch ()
  "Scan elisp source files for regexp-related errors.
Call this function in batch mode with files and directories as
command-line arguments.  Files are scanned; directories are
searched recursively for *.el files to scan.
When done, Emacs terminates with a nonzero status if anything worth
complaining about was found, zero otherwise."
  (unless noninteractive
    (error "`relint-batch' is only for use with -batch"))
  (relint--scan-files (mapcan (lambda (arg)
                                (if (file-directory-p arg)
                                    (relint--tree-files arg)
                                  (list arg)))
                              command-line-args-left)
                      nil default-directory)
  (setq command-line-args-left nil)
  (kill-emacs (if (> relint--error-count relint--suppression-count) 1 0)))

(provide 'relint)

;;; relint.el ends here
