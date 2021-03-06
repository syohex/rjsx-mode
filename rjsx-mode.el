;;; rjsx-mode.el --- Real support for JSX    -*- lexical-binding: t -*-

;; Copyright (C) 2016 Felipe Ochoa

;; Author: Felipe Ochoa <felipe@fov.space>
;; URL: https://github.com/felipeochoa/rjsx-mode/
;; Package-Requires: ((emacs "24.4") (js2-mode "20160623") (cl-lib "0.5"))
;; Version: 1.0
;; Keywords: languages

;;; Commentary:
;; Defines a minor mode `rjsx-mode' that swaps out js2-mode's
;; XML parsing (made for E4X) with a JSX parser

;;; Code:

(require 'cl-lib)
(require 'js2-mode)

(defgroup rjsx-mode nil
  "Support for JSX."
  :group 'js2-mode)

;;;###autoload
(define-derived-mode rjsx-mode js2-jsx-mode "RJSX"
  "Major mode for editing JSX files."
  :lighter ":RJSX"
  :group 'rjsx-mode)

;;;###autoload (add-to-list 'auto-mode-alist '("\\.jsx\\'" . rjsx-mode))

(defun rjsx-parse-xml-initializer (orig-fun)
  "Dispatch the xml parser based on variable `rjsx-mode' being active or not.
This function is used to advise `js2-parse-xml-initializer' (ORIG-FUN) using
the `:around' combinator.  JS2-PARSER is the original XML parser."
  (if (eq major-mode 'rjsx-mode)
      (rjsx-parse-top-xml)
    (apply orig-fun nil)))

(advice-add 'js2-parse-xml-initializer :around #'rjsx-parse-xml-initializer)

(defun rjsx-unadvice-js2 ()
  "Remove the rjsx advice on the js2 parser.  This will cause rjsx to stop working globally."
  (advice-remove 'js2-parse-xml-initializer #'rjsx-parse-xml-initializer))


;;Token types for XML nodes. Never returned by scanner
(defvar rjsx-JSX            (+ 1 js2-num-tokens))
(defvar rjsx-JSX-CLOSE      (+ 2 js2-num-tokens))
(defvar rjsx-JSX-IDENT      (+ 3 js2-num-tokens))
(defvar rjsx-JSX-MEMBER     (+ 4 js2-num-tokens))
(defvar rjsx-JSX-ATTR       (+ 5 js2-num-tokens))
(defvar rjsx-JSX-SPREAD     (+ 6 js2-num-tokens))
(defvar rjsx-JSX-TEXT       (+ 7 js2-num-tokens))
(defvar rjsx-JSX-EXPRESSION (+ 8 js2-num-tokens))

(js2-msg "msg.bad.jsx.ident" "invalid JSX identifier")
(js2-msg "msg.invalid.jsx.string" "invalid JSX string (cannot contain delimiter in string body)")
(js2-msg "msg.mismatched.close.tag" "mismatched closing JSX tag; expected `%s'")
(js2-msg "msg.no.gt.in.opener" "missing '>' in opening tag")
(js2-msg "msg.no.gt.in.closer" "missing '>' in closing tag")
(js2-msg "msg.no.gt.after.slash" "missing '>' after '/' in self-closing tag")
(js2-msg "msg.no.rc.after.spread" "missing '}' after spread-prop")
(js2-msg "msg.no.equals.after.jsx.prop" "missing '=' after prop `%s'")
(js2-msg "msg.no.value.after.jsx.prop" "missing value after prop `%s'")
(js2-msg "msg.no.dots.in.prop.spread" "missing `...' in spread prop")
(js2-msg "msg.no.rc.after.expr" "missing '}' after expression")
(js2-msg "msg.empty.expr" "empty '{}' expression")


(defface rjsx-tag
  '((t . (:inherit font-lock-function-name-face)))
  "`rjsx-mode' face used to highlight JSX tag names."
  :group 'rjsx-mode)

(defface rjsx-attr
  '((t . (:inherit font-lock-variable-name-face)))
  "`rjsx-mode' face used to highlight JSX attribute names."
  :group 'rjsx-mode)


;; TODO: define js2-printers for all of the structs
(cl-defstruct (rjsx-node
               (:include js2-node (type rjsx-JSX))
               (:constructor nil)
               (:constructor make-rjsx-node
                             (&key (pos (js2-current-token-beg))
                                   len
                                   name
                                   rjsx-props
                                   kids)))
  name         ; AST node containing the parsed xml name
  rjsx-props    ; linked list of AST nodes (both attributes and spreads)
  kids         ; linked list of child xml nodes
  closing-tag) ; AST node with the tag closer


(put 'cl-struct-rjsx-node 'js2-visitor 'rjsx-node-visit)
(put 'cl-struct-rjsx-node 'js2-printer 'rjsx-node-print)
(defun rjsx-node-visit (ast callback)
  "Visit the `rjsx-node' children of AST, invoking CALLBACK on them."
  (js2-visit-ast (rjsx-node-name ast) callback)
  (dolist (prop (rjsx-node-rjsx-props ast))
    (js2-visit-ast prop callback))
  (dolist (prop (rjsx-node-kids ast))
    (js2-visit-ast prop callback))
  (when (rjsx-node-closing-tag ast)
    (js2-visit-ast (rjsx-node-closing-tag ast) callback)))

(defun rjsx-node-print (node indent-level)
  "Print the `rjsx-node' NODE at indent level INDENT-LEVEL."
  (insert (js2-make-pad indent-level) "<")
  (js2-print-ast (rjsx-node-name node) 0)
  (dolist (attr (rjsx-node-rjsx-props node))
    (insert " ")
    (js2-print-ast attr 0))
  (let ((closer (rjsx-node-closing-tag node)))
    (if (null closer)
        (insert "/>")
      (insert ">")
      (dolist (child (rjsx-node-kids node))
          (js2-print-ast child 0))
      (js2-print-ast closer indent-level))))

(defun rjsx-node-opening-tag-name (node)
  "Return a string with NODE's opening tag including any namespace and member operations."
  (let ((name-n (rjsx-node-name node)))
    (if (rjsx-member-p name-n) (rjsx-member-full-name name-n)
      (rjsx-identifier-full-name name-n))))

(defun rjsx-node-push-prop (n rjsx-prop)
  "Extend rjsx-node N's rjsx-props with js2-node RJSX-PROP.
Sets JSX-PROPS's parent to N."
  (let ((rjsx-props (rjsx-node-rjsx-props n)))
    (if rjsx-props
        (setcdr rjsx-props (nconc (cdr rjsx-props) (list rjsx-prop)))
      (setf (rjsx-node-rjsx-props n) (list rjsx-prop))))
  (js2-node-add-children n rjsx-prop))

(defun rjsx-node-push-child (n kid)
  "Extend rjsx-node N's children with js2-node KID.
Sets KID's parent to N."
  (let ((kids (rjsx-node-kids n)))
    (if kids
        (setcdr kids (nconc (cdr kids) (list kid)))
      (setf (rjsx-node-kids n) (list kid))))
  (js2-node-add-children n kid))


(cl-defstruct (rjsx-closing-tag
               (:include js2-node (type rjsx-JSX-CLOSE))
               (:constructor nil)
               (:constructor make-rjsx-closing-tag (&key pos len name)))
  name) ; A rjsx-identifier or rjsx-member node

(put 'cl-struct-rjsx-closing-tag 'js2-visitor 'rjsx-closing-tag-visit)
(put 'cl-struct-rjsx-closing-tag 'js2-printer 'rjsx-closing-tag-print)

(defun rjsx-closing-tag-visit (ast callback)
  "Visit the `rjsx-closing-tag' children of AST, invoking CALLBACK on them."
  (js2-visit-ast (rjsx-closing-tag-name ast) callback))

(defun rjsx-closing-tag-print (node indent-level)
  "Print the `rjsx-closing-tag' NODE at INDENT-LEVEL."
  (insert (js2-make-pad indent-level) "</" (rjsx-closing-tag-full-name node) ">"))

(defun rjsx-closing-tag-full-name (n)
  "Return the string with N's fully-namespaced name, or just name if it's not namespaced."
  (let ((child (rjsx-closing-tag-name n)))
    (if (rjsx-member-p child)
        (rjsx-member-full-name child)
      (rjsx-identifier-full-name child))))

(cl-defstruct (rjsx-identifier
               (:include js2-node (type rjsx-JSX-IDENT))
               (:constructor nil)
               (:constructor make-rjsx-identifier (&key (pos (js2-current-token-beg))
                                                           len namespace name)))
  (namespace nil)
  name)

(put 'cl-struct-rjsx-identifier 'js2-visitor 'js2-visit-none)
(put 'cl-struct-rjsx-identifier 'js2-printer 'rjsx-identifier-print)

(defun rjsx-identifier-print (node indent-level)
  "Print the `rjsx-identifier' NODE at INDENT-LEVEL."
  (insert (js2-make-pad indent-level) (rjsx-identifier-full-name node)))

(defun rjsx-identifier-full-name (n)
  "Return the string with N's fully-namespaced name, or just name if it's not namespaced."
  (if (rjsx-identifier-namespace n)
      (format "%s:%s" (rjsx-identifier-namespace n) (rjsx-identifier-name n))
    (rjsx-identifier-name n)))

(cl-defstruct (rjsx-member
               (:include js2-node (type rjsx-JSX-MEMBER))
               (:constructor nil)
               (:constructor make-rjsx-member (&key pos len dots-pos idents)))
  dots-pos  ; List of positions of each dot
  idents)   ; List of rjsx-identifier nodes

(put 'cl-struct-rjsx-member 'js2-visitor 'js2-visit-none)
(put 'cl-struct-rjsx-member 'js2-printer 'rjsx-member-print)

(defun rjsx-member-print (node indent-level)
  "Print the `rjsx-member' NODE at INDENT-LEVEL."
  (insert (js2-make-pad indent-level) (rjsx-member-full-name node)))

(defun rjsx-member-full-name (n)
  "Return the string with N's combined names together."
  (mapconcat 'rjsx-identifier-full-name (rjsx-member-idents n) "."))

(cl-defstruct (rjsx-attr
               (:include js2-node (type rjsx-JSX-ATTR))
               (:constructor nil)
               (:constructor make-rjsx-attr (&key (pos (js2-current-token-beg))
                                                     len name value)))
  name    ; a rjsx-identifier
  value)  ; a js2-expression

(put 'cl-struct-rjsx-attr 'js2-visitor 'rjsx-attr-visit)
(put 'cl-struct-rjsx-attr 'js2-printer 'rjsx-attr-print)

(defun rjsx-attr-visit (ast callback)
  "Visit the `rjsx-attr' children of AST, invoking CALLBACK on them."
  (js2-visit-ast (rjsx-attr-name ast) callback)
  (js2-visit-ast (rjsx-attr-value ast) callback))

(defun rjsx-attr-print (node indent-level)
  "Print the `rjsx-attr' NODE at INDENT-LEVEL."
  (js2-print-ast (rjsx-attr-name node) indent-level)
  (insert "=")
  (js2-print-ast (rjsx-attr-value node) 0))

(cl-defstruct (rjsx-spread
               (:include js2-node (type rjsx-JSX-SPREAD))
               (:constructor nil)
               (:constructor make-rjsx-spread (&key pos len expr)))
  expr)  ; a js2-expression

(put 'cl-struct-rjsx-spread 'js2-visitor 'rjsx-spread-visit)
(put 'cl-struct-rjsx-spread 'js2-printer 'rjsx-spread-print)

(defun rjsx-spread-visit (ast callback)
  "Visit the `rjsx-spread' children of AST, invoking CALLBACK on them."
  (js2-visit-ast (rjsx-spread-expr ast) callback))

(defun rjsx-spread-print (node indent-level)
  "Print the `rjsx-spread' NODE at INDENT-LEVEL."
  (insert (js2-make-pad indent-level) "{...")
  (js2-print-ast (rjsx-spread-expr node) 0)
  (insert "}"))

(cl-defstruct (rjsx-wrapped-expr
               (:include js2-node (type rjsx-JSX-TEXT))
               (:constructor nil)
               (:constructor make-rjsx-wrapped-expr (&key pos len child)))
  child)

(put 'cl-struct-rjsx-wrapped-expr 'js2-visitor 'rjsx-wrapped-expr-visit)
(put 'cl-struct-rjsx-wrapped-expr 'js2-printer 'rjsx-wrapped-expr-print)

(defun rjsx-wrapped-expr-visit (ast callback)
  "Visit the `rjsx-wrapped-expr' child of AST, invoking CALLBACK on them."
  (js2-visit-ast (rjsx-wrapped-expr-child ast) callback))

(defun rjsx-wrapped-expr-print (node indent-level)
  "Print the `rjsx-wrapped-expr' NODE at INDENT-LEVEL."
  (insert (js2-make-pad indent-level) "{")
  (js2-print-ast (rjsx-wrapped-expr-child node) indent-level)
  (insert "}"))

(cl-defstruct (rjsx-text
               (:include js2-node (type rjsx-JSX-TEXT))
               (:constructor nil)
               (:constructor make-rjsx-text (&key (pos (js2-current-token-beg))
                                                     (len (js2-current-token-len))
                                                     value)))
  value)  ; a string

(put 'cl-struct-rjsx-text 'js2-visitor 'js2-visit-none)
(put 'cl-struct-rjsx-text 'js2-printer 'rjsx-text-print)

(defun rjsx-text-print (node _indent-level)
  "Print the `rjsx-text' NODE at INDENT-LEVEL."
  ;; Text nodes include whitespace
  (insert (rjsx-text-value node)))

(defvar rjsx-print-debug-message nil "If t will print out debug messages.")
;(setq rjsx-print-debug-message t) (add-hook 'js2-jsx-mode-hook 'rjsx-mode)
(defmacro rjsx-maybe-message (&rest args)
  "If debug is enabled, call `message' with ARGS."
  `(when rjsx-print-debug-message
     (message ,@args)))


(js2-deflocal rjsx-in-xml nil "Variable used to track which xml parsing function is the outermost one.")

(defun rjsx-parse-top-xml ()
  "Parse a top level XML fragment.
This is the entry point when ‘js2-parse-unary-expr’ finds a '<' character"
  (rjsx-maybe-message "Parsing a new xml fragment%s" (if rjsx-in-xml ", recursively" ""))
  ;; If there are imbalanced tags, we just need to bail out to the
  ;; topmost JSX parser and let js2 handle the EOF. Our custom scanner
  ;; will throw `t' if it finds the EOF, which it ordinarily wouldn't
  (let (pn)
    (when (catch 'rjsx-eof-while-parsing
            (let ((rjsx-in-xml t)) ;; We use dynamic scope to handle xml > expr > xml nestings
              (setq pn (rjsx-parse-xml)))
            nil)
      (rjsx-maybe-message "Caught a signal. Rethrowing?: `%s'" rjsx-in-xml)
      (if rjsx-in-xml
          (throw 'rjsx-eof-while-parsing t)
        ;; We subtract 1 since js2 sets the cursor the the point after point-max
        (setq pn (make-js2-error-node :len (1- (js2-current-token-len))))
        (js2-report-error "msg.syntax" nil (js2-node-pos pn) (js2-node-len pn))))
    (rjsx-maybe-message "Returning from top xml function: %s" pn)
    pn))

(defun rjsx-parse-xml ()
  "Parse a complete xml node from start to end tag."
  (let ((pn (make-rjsx-node)) self-closing name-n name-str child child-name-str)
    ;; If there are parse errors here
    (rjsx-maybe-message "cleared <")
    (setf (rjsx-node-name pn) (setq name-n (rjsx-parse-member-or-ns 'rjsx-tag)))
    (if (js2-error-node-p name-n)
        (progn (rjsx-maybe-message "could not parse tag name")
               (make-js2-error-node :pos (js2-node-pos pn) :len (1+ (js2-node-len name-n))))
      (setq name-str (if (rjsx-member-p name-n) (rjsx-member-full-name name-n)
                       (rjsx-identifier-full-name name-n)))
      (rjsx-maybe-message "cleared tag name: '%s'" name-str)
      ;; Now parse the attributes
      (rjsx-parse-attributes pn)
      (rjsx-maybe-message "cleared attributes")
      (setf (js2-node-len pn) (- (js2-current-token-end) (js2-node-pos pn)))
      ;; Now parse either a self closing tag or the end of the opening tag
      (rjsx-maybe-message "next type: `%s'" (js2-peek-token))
      (if (setq self-closing (js2-match-token js2-DIV))
          ;; TODO: make sure there's no whitespace between / and >
          (js2-must-match js2-GT "msg.no.gt.after.slash"
                          (js2-node-pos pn) (- (js2-current-token-end) (js2-node-pos pn)))
        (js2-must-match js2-GT "msg.no.gt.in.opener" (js2-node-pos pn) (js2-node-len pn)))
      (rjsx-maybe-message "cleared opener closer, self-closing: %s" self-closing)
      (if self-closing
          (setf (js2-node-len pn) (- (js2-current-token-end) (js2-node-pos pn)))
        (while (not (rjsx-closing-tag-p (setq child (rjsx-parse-child))))
          ;; rjsx-parse-child calls our scanner, which always moves
          ;; forward at least one character. If it hits EOF, it
          ;; signals to our caller, so we don't have to worry about infinite loops here
          (rjsx-maybe-message "parsed child")
          (rjsx-node-push-child pn child)
          (if (= 0 (js2-node-len child)) ; TODO: Does this ever happen?
              (js2-get-token)))
        (setq child-name-str (rjsx-closing-tag-full-name child))
        (unless (string= name-str child-name-str)
          (js2-report-error "msg.mismatched.close.tag" name-str (js2-node-pos child) (js2-node-len child)))
        (rjsx-maybe-message "cleared children for `%s'" name-str)
        (js2-node-add-children pn child)
        (setf (rjsx-node-closing-tag pn) child))
      (rjsx-maybe-message "Returning completed XML node")
      pn)))

(defun rjsx-parse-attributes (parent)
  "Parse all attributes, including key=value and {...spread}, and add them to PARENT."
  ;; Getting this function to not hang in the loop proved tricky. The
  ;; key is that `rjsx-parse-spread' and `rjsx-parse-single-attr' both
  ;; return `js2-error-node's if they fail to consume any tokens,
  ;; which signals to us that we just need to discard one token and
  ;; keep going.
  (let (attr
        (loop-terminators (list js2-DIV js2-GT js2-EOF js2-ERROR)))
    (while (not (memql (js2-peek-token) loop-terminators))
      (rjsx-maybe-message "Starting loop. Next token type: %s\nToken pos: %s" (js2-peek-token) (js2-current-token-beg))
      (setq attr
       (if (js2-match-token js2-LC)
           (or (rjsx-check-for-empty-curlies t)
               (prog1 (rjsx-parse-spread)
                 (rjsx-maybe-message "Parsed spread")))
         (rjsx-maybe-message "Parsing single attr")
         (rjsx-parse-single-attr)))
      (when (js2-error-node-p attr) (js2-get-token))
                                        ; TODO: We should make this conditional on
                                        ; `js2-recover-from-parse-errors'
      (rjsx-node-push-prop parent attr))))


(cl-defun rjsx-check-for-empty-curlies (&optional dont-consume-rc &key check-for-comments warning)
  "If the following token is '}' set empty curly errors.
If DONT-CONSUME-RC is non-nil, the matched right curly token
won't be consumed.  Returns a `js2-error-node' if the curlies are
empty or nil otherwise.  If CHECK-FOR-COMMENTS (a &KEY argument)
is non-nil, this will check for comments inside the curlies and
returns a `js2-empty-expr-node' if any are found.  If WARNING (a
&key argument) is non-nil, reports the empty curlies as a warning
and not an error and also returns a `js2-empty-expr-node'.
Assumes the current token is a '{'."
  (let ((beg (js2-current-token-beg)) end len)
    (when (js2-match-token js2-RC)
      (setq end (js2-current-token-end))
      (setq len (- end beg))
      (when dont-consume-rc
        (js2-unget-token))
      (if check-for-comments (rjsx-maybe-message "Checking for comments between %d and %d" beg end))
      (unless (and check-for-comments
                   (dolist (comment js2-scanned-comments)
                     (rjsx-maybe-message "Comment at %d, length=%d"
                                         (js2-node-pos comment)
                                         (js2-node-len comment))
                     ;; TODO: IF comments are in reverse document order, we should be able to
                     ;; bail out early and know we didn't find one
                     (when (and (>= (js2-node-pos comment) beg)
                                (<= (+ (js2-node-pos comment) (js2-node-len comment)) end))
                       (cl-return-from rjsx-check-for-empty-curlies
                         (make-js2-empty-expr-node :pos beg :len (- end beg))))))
        (if warning
            (progn (js2-report-warning "msg.empty.expr" nil beg len)
                   (make-js2-empty-expr-node :pos beg :len (- end beg)))
          (js2-report-error "msg.empty.expr" nil beg len)
          (make-js2-error-node :pos beg :len len))))))


(defun rjsx-parse-spread ()
  "Parse an {...props} attribute."
  (let ((pn (make-rjsx-spread :pos (js2-current-token-beg)))
        (beg (js2-current-token-beg))
        missing-dots expr)
    (setq missing-dots (not (js2-match-token js2-TRIPLEDOT)))
    ;; parse-assign-expr will go crazy if we're looking at `} /', so we
    ;; check for an empty spread first
    (if (js2-match-token js2-RC)
        (setq expr (make-js2-error-node :len 1))
      (setq expr (js2-parse-assign-expr))
      (when (js2-error-node-p expr)
        (pop js2-parsed-errors)))       ; We'll add our own error
    (unless (or (js2-match-token js2-RC) (js2-error-node-p expr))
      (js2-report-error "msg.no.rc.after.spread" nil
                        beg (- (js2-current-token-end) beg)))
    (setf (rjsx-spread-expr pn) expr)
    (setf (js2-node-len pn) (- (js2-current-token-end) (js2-node-pos pn)))
    (js2-node-add-children pn expr)
    (if (js2-error-node-p expr)
        (js2-report-error "msg.syntax" nil beg (- (js2-current-token-end) beg))
      (when missing-dots
        (js2-report-error "msg.no.dots.in.prop.spread" nil beg (js2-node-len pn))))
    (if (= 0 (js2-node-len pn))  ; TODO: Is this ever possible?
        (make-js2-error-node :pos beg :len 0)
      pn)))

(defun rjsx-parse-single-attr ()
  "Parse an 'a=b' JSX attribute and return the corresponding XML node."
  (let ((pn (make-rjsx-attr)) name value beg)
    (setq name (rjsx-parse-identifier 'rjsx-attr)) ; Won't consume token on error
    (if (js2-error-node-p name)
        name
      (setf (rjsx-attr-name pn) name)
      (setq beg (js2-node-pos name))
      (js2-node-add-children pn name)
      (rjsx-maybe-message "Got the name for the attr: `%s'" (rjsx-identifier-full-name name))
      (if (js2-match-token js2-ASSIGN)  ; Won't consume on error
          (progn
            (rjsx-maybe-message "Matched the equals sign")
            (if (js2-match-token js2-LC)
                (setq value (rjsx-parse-wrapped-expr nil t))
              (if (js2-match-token js2-STRING)
                  (setq value (rjsx-parse-string))
                (js2-report-error "msg.no.value.after.jsx.prop" (rjsx-identifier-full-name name)
                                  beg (- (js2-current-token-end) beg))
                (setq value (make-js2-error-node :pos beg :len (js2-current-token-len))))))
        (js2-report-error "msg.no.equals.after.jsx.prop" (rjsx-identifier-full-name name)
                          beg (- (js2-current-token-end) beg))
        (setq value (make-js2-error-node :pos beg :len (- (js2-current-token-end) beg))))
      (rjsx-maybe-message "value type: `%s'" (js2-node-type value))
      (setf (rjsx-attr-value pn) value)
      (setf (js2-node-len pn) (- (js2-node-end value) (js2-node-pos pn)))
      (js2-node-add-children pn value)
      (rjsx-maybe-message "Finished single attribute.")
      pn)))

(defun rjsx-parse-wrapped-expr (allow-empty skip-to-rc)
  "Parse a curly-brace-wrapped JS expression.
If ALLOW-EMPTY is non-nil, will warn for empty braces, otherwise
will signal a syntax error.  If it does not find a right curly
and SKIP-TO-RC is non-nil, after the expression, consumes tokens
until the end of the JSX node"
  (rjsx-maybe-message "parsing wrapped expression")
  (let (pn
        (beg (js2-current-token-beg))
        (child (rjsx-check-for-empty-curlies nil
                                             :check-for-comments allow-empty
                                             :warning allow-empty)))
    (if child
        (if allow-empty
            (make-rjsx-wrapped-expr :pos beg :len (js2-node-len child) :child child)
          child) ;; Will be an error node in this case
      (setq child (js2-parse-assign-expr))
      (rjsx-maybe-message "parsed expression, type: `%s'" (js2-node-type child))
      (setq pn (make-rjsx-wrapped-expr :pos beg :child child))
      (js2-node-add-children pn child)
      (when (js2-error-node-p child)
        (pop js2-parsed-errors)) ; We'll record our own message after checking for RC
      (if (js2-match-token js2-RC)
          (rjsx-maybe-message "matched } after expression")
        (rjsx-maybe-message "did not match } after expression")
        (when skip-to-rc
          (while (not (memql (js2-get-token) (list js2-RC js2-EOF js2-DIV js2-GT)))
            (rjsx-maybe-message "Skipped over `%s'" (js2-current-token-string)))
          (when (memq (js2-current-token-type) (list js2-DIV js2-GT))
            (js2-unget-token)))
        (unless (js2-error-node-p child)
          (js2-report-error "msg.no.rc.after.expr" nil beg
                            (- (js2-current-token-beg) beg))))
      (when (js2-error-node-p child)
        (js2-report-error "msg.syntax" nil beg (- (js2-current-token-end) beg)))
      (setf (js2-node-len pn) (- (js2-current-token-end) beg))
      pn)))

(defun rjsx-parse-string ()
  "Verify that current token is a valid JSX string.
Returns a `js2-error-node' if TOKEN-STRING is not a valid JSX
string, otherwise returns a `js2-string-node'.  (Strings are
invalid if they contain the delimiting quote character inside)"
  (rjsx-maybe-message "Parsing string")
  (let* ((token (js2-current-token))
         (beg (js2-token-beg token))
         (len (- (js2-token-end token) beg))
         (token-string (js2-token-string token)) ;; JS2 does not include the quote-chars
         (quote-char (char-before (js2-token-end token))))
    (if (cl-position quote-char token-string)
        (progn
          (js2-report-error "msg.invalid.jsx.string" nil beg len)
          (make-js2-error-node :pos beg :len len))
      (make-js2-string-node :pos beg :len len :value token-string))))

(cl-defun rjsx-parse-identifier (&optional face &key (allow-ns t))
  "Parse a possibly namespaced identifier and fontify with FACE if given.
Returns a `js2-error-node' if unable to parse.  If the &key
argument ALLOW-NS is nil, does not allow namespaced names."
  (if (js2-must-match-name "msg.bad.jsx.ident")
      (let ((pn (make-rjsx-identifier))
            (beg (js2-current-token-beg))
            (name-parts (list (js2-current-token-string)))
            (allow-colon allow-ns)
            (continue t)
            (prev-token-end (js2-current-token-end))
            matched-colon)
        (while (and continue
                    (or (and (memq (js2-peek-token) (list js2-SUB js2-ASSIGN_SUB))
                             (prog2  ; Ensure no whitespace between previous name and this dash
                                 (js2-get-token)
                                 (eq prev-token-end (js2-current-token-beg))
                               (js2-unget-token)))
                        (and allow-colon (= (js2-peek-token) js2-COLON))))
          (if (setq matched-colon (js2-match-token js2-COLON))
              (setf (rjsx-identifier-namespace pn) (apply #'concat (nreverse name-parts))
                    allow-colon nil
                    name-parts (list))
            (when (= (js2-get-token) js2-ASSIGN_SUB) ; Otherwise it's a js2-SUB
              (setf (js2-token-end (js2-current-token)) (1- (js2-current-token-end))
                    (js2-token-type (js2-current-token)) js2-SUB
                    (js2-token-string (js2-current-token)) "-"
                    js2-ts-cursor (1+ (js2-current-token-beg))
                    js2-ti-lookahead 0))
            (push "-" name-parts))
          (setq prev-token-end (js2-current-token-end))
          (if (js2-match-token js2-NAME)
              (if (eq prev-token-end (js2-current-token-beg))
                  (progn (push (js2-current-token-string) name-parts)
                         (setq prev-token-end (js2-current-token-end)))
                (js2-unget-token)
                (setq continue nil))
            (when (= js2-COLON (js2-current-token-type))
              (js2-report-error "msg.bad.jsx.ident" nil beg (- (js2-current-token-end) beg)))
            ;; We only keep going if this is an `ident-ending-with-dash-colon:'
            (setq continue (and (not matched-colon) (= (js2-peek-token) js2-COLON)))))
        (when face
          (js2-set-face beg (js2-current-token-end) face 'record))
        (setf (js2-node-len pn) (- (js2-current-token-end) beg)
              (rjsx-identifier-name pn) (apply #'concat (nreverse name-parts)))
        pn)
    (make-js2-error-node :len (js2-current-token-len))))

(defun rjsx-parse-member-or-ns (&optional face)
  "Parse a dotted expression or a namespaced identifier and fontify with FACE if given."
  (let ((ident (rjsx-parse-identifier face)))
    (cond
     ((js2-error-node-p ident) ident)
     ((rjsx-identifier-namespace ident) ident)
     (t (rjsx-parse-member ident face)))))

(defun rjsx-parse-member (ident &optional face)
  "Parse a dotted member expression starting with IDENT and fontify with FACE.
IDENT is the `rjsx-identifier' node for the first item in the
member expression.  Returns a `js2-error-node' if unable to
parse."
  (let (idents dots-pos pn end)
    (setq pn (make-rjsx-member :pos (js2-node-pos ident)))
    (setq end (js2-current-token-end))
    (push ident idents)
    (while (and (js2-match-token js2-DOT) (not (js2-error-node-p ident)))
      (push (js2-current-token-beg) dots-pos)
      (setq end (js2-current-token-end))
      (setq ident (rjsx-parse-identifier nil :allow-ns nil))
      (push ident idents)
      (unless (js2-error-node-p ident)
        (setq end (js2-current-token-end)))
      (js2-node-add-children pn ident))
    (setf (rjsx-member-idents pn) (nreverse idents)
          (rjsx-member-dots-pos pn) (nreverse dots-pos)
          (js2-node-len pn) (- end (js2-node-pos pn)))
    (when face
      (js2-set-face (js2-node-pos pn) end face 'record))
    pn))


(defun rjsx-parse-child ()
  "Parse an XML child node.
Child nodes include plain (unquoted) text, other XML elements,
and {}-bracketed expressions.  Return the parsed child."
  (let ((tt (rjsx-get-next-xml-token)))
    (rjsx-maybe-message "child type `%s'" tt)
    (cond
     ((= tt js2-LT)
      (rjsx-maybe-message "xml-or-close")
      (rjsx-parse-xml-or-closing-tag))

     ((= tt js2-LC)
      (rjsx-maybe-message "parsing expression { %s" (js2-peek-token))
      (rjsx-parse-wrapped-expr t nil))

     ((= tt rjsx-JSX-TEXT)
      (rjsx-maybe-message "text node: '%s'" (js2-current-token-string))
      (make-rjsx-text :value (js2-current-token-string)))

     ((= tt js2-ERROR)
      (make-js2-error-node :len (js2-current-token-len)))

     (t (error "Unexpected token type: %s" (js2-peek-token))))))

(defun rjsx-parse-xml-or-closing-tag ()
  "Parse a JSX tag, which could be a child or a closing tag.
Return the parsed child, which is a `rjsx-closing-tag' if a
closing tag was parsed."
  (let ((beg (js2-current-token-beg)) pn)
    (if (js2-match-token js2-DIV)
        (progn (setq pn (make-rjsx-closing-tag :pos beg :name (rjsx-parse-member-or-ns 'rjsx-tag)))
               (if (js2-must-match js2-GT "msg.no.gt.in.closer" beg (- (js2-current-token-end) beg))
                   (rjsx-maybe-message "parsed closing tag")
                 (rjsx-maybe-message "missing closing `>'"))
               (setf (js2-node-len pn) (- (js2-current-token-end) beg))
               pn)
      (rjsx-maybe-message "parsing a child XML item")
      (rjsx-parse-xml))))

(defun rjsx-get-next-xml-token ()
  "Scan through the XML text and push one token onto the stack."
  (setq js2-ts-string-buffer nil)  ; for recording the text
  (when (> js2-ti-lookahead 0)
    (setq js2-ts-cursor (js2-current-token-end))
    (setq js2-ti-lookahead 0))

  (let ((token (js2-new-token 0))
        c)
    (rjsx-maybe-message "Running the xml scanner")
    (catch 'return
      (while t
        (setq c (js2-get-char))
        (rjsx-maybe-message "'%s' (%s)" (if (= c js2-EOF_CHAR) "EOF" (char-to-string c)) c)
        (cond
         ((or (= c ?}) (= c ?>))
          (js2-set-string-from-buffer token)
          (setf (js2-token-type token) js2-ERROR)
          (js2-report-scan-error "msg.syntax" t)
          (throw 'return js2-ERROR))

         ((or (= c ?<) (= c ?{))
          (js2-unget-char)
          (if js2-ts-string-buffer
              (progn
                (js2-set-string-from-buffer token)
                (setf (js2-token-type token) rjsx-JSX-TEXT)
                (rjsx-maybe-message "created rjsx-JSX-TEXT token: `%s'" (js2-token-string token))
                (throw 'return rjsx-JSX-TEXT))
            (js2-get-char)
            (js2-set-string-from-buffer token)
            (setf (js2-token-type token) (if (= c ?<) js2-LT js2-LC))
            (setf (js2-token-string token) (string c))
            (throw 'return (js2-token-type token))))

         ((= c js2-EOF_CHAR)
          (js2-set-string-from-buffer token)
          (rjsx-maybe-message "Hit EOF. Current buffer: `%s'" (js2-token-string token))
          (setf (js2-token-type token) js2-ERROR)
          (rjsx-maybe-message "Scanner hit EOF. Panic!")
          (throw 'rjsx-eof-while-parsing t))
         (t (js2-add-to-string c)))))))

(provide 'rjsx-mode)
;;; rjsx-mode.el ends here
