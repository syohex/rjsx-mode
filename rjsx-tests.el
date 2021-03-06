;;; tjsx-tests.el --- Tests for rjsx-mode.    -*- lexical-binding: t -*-

;; Copyright (C) 2016 Felipe Ochoa

;;;; Commentary:

;;

;;;; Code:

(load-file "./js2-tests.el")
(require 'rjsx-mode)
(require 'cl-lib)
(require 'ert)

(defun js2-mode--and-parse ()  ;; No point in advising, so we just overwrite this internal function
  (rjsx-mode)
  (js2-reparse))

(js2-deftest-parse no-attr-no-children-self-closing
  "<div/>;")

(js2-deftest-parse no-attr-no-children-self-closing
  "<div></div>;")

(js2-deftest-parse no-children-self-closing
  "<div a=\"1\" b={123} {...props}/>;")

(js2-deftest-parse no-attr-xml-child
  "<div><span/></div>;")

(js2-deftest-parse no-attr-text-child
  "<div>Hello world</div>;")

(js2-deftest-parse no-attr-expr-child
  "<div>{coolVar ? 'abc' : 'xyz'}</div>;")

(js2-deftest-parse ultra-nested
  "<div a={<span>{fall ? <b>Fell</b> : <img src=\"abc\"/>}</span>}></div>;")

(js2-deftest-parse hidden-behind-and
  "<div>{cond && <span/>}</div>;")

(js2-deftest-parse ns-tag
  "<xml:a/>;")

(js2-deftest-parse ns-tag-with-dashes
  "<xml-lmx-m:a-b-c/>;")

(js2-deftest-parse ns-tag-with-dashes-at-end
  "<xml-lmx-:a-b-/>;")

(js2-deftest-parse ns-attr
  "<xml:a lmx:attr=\"1\"/>;")

(js2-deftest-parse ns-attr-with-dashes-at-end
  "<xml:a lmx:attr-=\"1\"/>;")

(js2-deftest-parse ns-attr-with-dashes-at-end-of-ns
  "<xml:a lmx-:attr=\"1\"/>;")

(js2-deftest-parse member-tag
  "<Module.Component/>;")

(js2-deftest-parse member-tag-many
  "<Module.Component.Sub1.Sub2/>;")

(js2-deftest-parse complex
  "<form onSubmit={this.handleSubmit} className={className}>
  <input type=\"text\"
         onChange={this.getChangeHandler(\"name\")}
         placeholder=\"Project name\"
         className={errors.name ? \"invalid\" : \"\"}
         ref={c => this._topInput = c}/>
    {errors.name && <span className=\"error\">{errors.name}</span>}
    {   } Empty is OK as child, but warning is issued
    {/* Node with comment gets no warning */}
    hello <div { } /> This should be a spread, so error
    <div empty={}  /> Empty attributes are not allowed
    {React.Children.count(this.props.children) === 1
        ? <OnlyChild {...this.props}>{this.props.children}</OnlyChild>
        : React.Children.map(this.props.children, (child, index) => (
            <li key={index} undefinedProp={notDefined}>
              {index === 0 && <span className=\"first\"/>}
              {React.cloneElement(child, {toolTip: <Tooltip index={index} />})}
            </li>
        ))
    }
</form>"
  :errors-count 2
  :warnings-count 1
  :syntax-error "{ }")

(js2-deftest-parse empty-child
  "<div>{}</div>;"
  :warnings-count 1)

(js2-deftest-parse empty-child-with-comment
  "<div>{/* this is a comment */}</div>;"
  :warnings-count 0
  :reference "<div>{}</div>;")

;;; Now we test all of the malformed bits:

(defun jsx-test--forms (forms)
  "Test the parsing of FORMS.
FORMS must be a list of (CODE-STRING SYNTAX-ERROR &optional ERRORS-COUNT)
forms, where the values are as in `js2-parse-string'."
  (ert-with-test-buffer (:name 'origin)
    (dolist (form forms)
      (cl-destructuring-bind (code-string syntax-error &optional (errors-count 1)) form
        (erase-buffer)
        (let* ((ast (js2-test-string-to-ast code-string))
               (errors (js2-ast-root-errors ast)))
          (should (= errors-count (length errors)))
          (cl-destructuring-bind (_ pos len) (car (last errors))
            (should (string= syntax-error (substring code-string
                                                     (1- pos) (+ pos len -1))))))
        (message (format "Completed test for: %s" code-string))))))

(cl-defmacro jsx-deftest (name &rest forms)
  "Define a new test for compactly checking multiple strings' parsing.
The test is named rjsx-NAME.  FORMS is a list of (CODE-STRING
SYNTAX-ERROR ERRORS-COUNT) forms, where the values are as in
`js2-parse-string'.  `:expect-fail' can be inserted anywhere between
between the forms to split the test into two: forms before the marker
are expected to pass and forms after the marker are expected to fail.
Currently only forms with syntax errors are supported.

\(fn NAME PASS-FORMS... [:expect-fail FAIL-FORMS...])"
  (declare (indent defun))
  (let (fail-forms pass-forms found-marker)
    (dolist (form forms)
      (if (eq :expect-fail form)
          (if found-marker
              (error "Received multiple :expect-fail markers")
            (setq found-marker t))
        (if found-marker
            (push form fail-forms)
          (push form pass-forms))))
    (setq fail-forms (nreverse fail-forms)
          pass-forms (nreverse pass-forms))
    (let* ((i 0)
           (tests (nconc
                   (and pass-forms
                        (list `(ert-deftest ,(intern (format "rjsx-%s" name)) ()
                                (jsx-test--forms ',pass-forms))))
                   (mapcar
                    (lambda (form)
                      `(ert-deftest ,(intern (format "rjsx-%s-expected-fail-%d" name (cl-incf i))) ()
                         :expected-result :failed
                         (jsx-test--forms '(,form))))
                    fail-forms))))
      (cl-case (length tests)
        (0 (error "Did not specify any forms"))
        (1 (car tests))
        (t `(progn ,@tests))))))

(defvar rjsx--find-test-regexp
  (concat "^\\s-*(rjsx-deftest"
          find-function-space-re
          "%s\\(\\s-\\|$\\)")
  "The regexp the `find-function' mechanisms use for finding RJSX test definitions.")

(push '(rjsx-deftest . rjsx--find-test-regexp) find-function-regexp-alist)

(defun rjsx-find-test-advice (orig-fn test-name)
  "Advice for `ert-find-test-other-window' (ORIG-FN) to find TEST-NAME."
  (interactive (list (ert-read-test-name-at-point "Find test definition: ")))
  (if (string-match "^rjsx-\\([a-z-]+?\\)\\(-expected-fail\\)?$" (symbol-name test-name))
      (let* ((file (symbol-file test-name 'ert-deftest))
             (buffer-point (find-definition-noselect (intern (match-string 1 (symbol-name test-name)))
                                                     'rjsx-deftest
                                                     file))
             (switch-fn 'switch-to-buffer-other-window)
             ;; The rest of this let-form was copy-pasted from
             ;; `find-funciton-do-it' to be able to override the
             ;; buffer-finding bit
             (orig-point (point))
             (orig-buffers (buffer-list))
             ;(buffer-point (save-excursion (find-definition-noselect symbol type)))
             (new-buf (car buffer-point))
             (new-point (cdr buffer-point)))
        (when buffer-point
          (when (memq new-buf orig-buffers)
            (push-mark orig-point))
          (funcall switch-fn new-buf)
          (when new-point (goto-char new-point))
          (recenter find-function-recenter-line)
          (run-hooks 'find-function-after-hook)))
    (funcall orig-fn test-name)))

(advice-add 'ert-find-test-other-window :around #'rjsx-find-test-advice)


;; Tag problems

(jsx-deftest mismatched-tags
  ("<div></vid>" "</vid>")
  ("<div-></vid->" "</vid->")
  ("<div-></div>" "</div>")
  ("<div-name></divname>" "</divname>")
  ("<ns:div></div>" "</div>")
  ("<ns-:div></ns:div>" "</ns:div>")
  ("<ns-a:div></nsa:div>" "</nsa:div>")
  ("<ns-a:div-></ns-a:div>" "</ns-a:div>"))

(js2-deftest-parse invalid-tag-member-and-ns-self-closing
  "<xml:Component.Child/>"
  :errors-count 2 ; tag parsed as xml:Component, then erratic ., then Child as attr missing value
  :syntax-error ".") ;; TODO: report the error over the entire tag

(js2-deftest-parse invalid-ns-tag-with-double-dashes
  "<xml-lmx--m:a-b-c/>;"
  :errors-count 2 ; tag parsed as xml-lmx, then erratic decrement, then missing attr value
  :syntax-error "--") ;; TODO: report the error over the entire tag

(js2-deftest-parse invalid-tag-whitespace-before-dash
  "<div -attr/>"
  :errors-count 2 ; spurious dash followed by missing value
  :syntax-error "-")

(js2-deftest-parse missing-closing-lt-self-closing
  "<div/"
  :syntax-error "<div/")

(js2-deftest-parse invalid-tag-name
  "<123 />"
  :errors-count 3
  :syntax-error "123")

(js2-deftest-parse invalid-tag-name-only-ns
  "<abc: />"
  :syntax-error "abc:")

(js2-deftest-parse invalid-attr-name-only-ns
  "<xyz abc:={1} />"
  :syntax-error "abc:")

;; Make sure we don't hang with unclosed tags

(js2-deftest-parse falls-off-a-cliff-but-doesnt-hang
  "const Component = ({prop}) => <span>;\n\nexport default Component;"
  :syntax-error ";\n\nexport default Component;")

(js2-deftest-parse falls-off-a-cliff-but-doesnt-hang-even-with-braces
  "const Component = ({prop}) => <span>;\n\nexport { Component };"
  :syntax-error ";")

(js2-deftest-parse falls-off-a-cliff-but-doesnt-hang-even-with-other-jsx
  "const Component = ({prop}) => <span>;\nconst C2 = () => <span></span>\n\n"
  :errors-count 2  ; 1 from the stray > in the arrow function and 1 from the missing closer
  :syntax-error ";\nconst C2 = () =>")

(js2-deftest-parse falls-off-a-cliff-in-recursive-parse
  "const Component = ({prop}) => <div>{pred && <span>};\n\nexport { Component }"
  :errors-count 2
  :syntax-error "}")

;; Malformed attributes have a number of permutations:
;;
;; A/ Missing equals sign, missing value, missing right curly, bad expression
;; B/ Before another attribute (spread vs expr vs string) or
;;    at the end of the tag (self-closing or not)
;; C/ No dashes in its name, ends in a dash, dashes but not at the end
;; D/ With a namespaced name or not
;;
;; Combinatorial explosion! 4 * 5 * 3 * 2 = 120!

;; Here are all the missing equals sign tests:
(jsx-deftest attr-missing-equals-sign-no-dashes
  ("<div attr {...attr2}/>" "attr")
  ("<div attr/>" "attr")
  ("<div attr></div>" "attr")
  ("<div attr attr2={123}/>" "attr")
  ("<div attr attr2=\"123\"/>" "attr"))

(jsx-deftest attr-missing-equals-sign-ends-in-dash
  ("<div attr- attr2=\"123\"/>" "attr-")
  ("<div attr- attr2={123}/>" "attr-")
  ("<div attr- {...attr2}/>" "attr-")
  ("<div attr-/>" "attr-")
  ("<div attr-></div>" "attr-"))

(jsx-deftest attr-missing-equals-sign-interior-dashes
  ("<div attr-name {...attr2}/>" "attr-name")
  ("<div attr-name/>" "attr-name")
  ("<div attr-name></div>" "attr-name")
  ("<div attr-name attr2={123}/>" "attr-name")
  ("<div attr-name attr2=\"123\"/>" "attr-name"))

(jsx-deftest attr-missing-equals-sign-no-dashes-namespaced
  ("<div ns:attr {...attr2}/>" "ns:attr")
  ("<div ns:attr/>" "ns:attr")
  ("<div ns:attr></div>" "ns:attr")
  ("<div ns:attr attr2={123}/>" "ns:attr")
  ("<div ns:attr attr2=\"123\"/>" "ns:attr"))

(jsx-deftest attr-missing-equals-sign-ends-in-dash-namespaced
  ("<div ns:attr- {...attr2}/>" "ns:attr-")
  ("<div ns:attr-/>" "ns:attr-")
  ("<div ns:attr-></div>" "ns:attr-")
  ("<div ns:attr- attr2={123}/>" "ns:attr-")
  ("<div ns:attr- attr2=\"123\"/>" "ns:attr-"))

(jsx-deftest attr-missing-equals-sign-interior-dashes-namespaced
  ("<div ns:attr-name {...attr2}/>" "ns:attr-name")
  ("<div ns:attr-name/>" "ns:attr-name")
  ("<div ns:attr-name></div>" "ns:attr-name")
  ("<div ns:attr-name attr2={123}/>" "ns:attr-name")
  ("<div ns:attr-name attr2=\"123\"/>" "ns:attr-name"))

;; Here are all the missing values sign tests:
(jsx-deftest attr-missing-value-no-dashes
  ("<div attr= attr2={123}/>" "attr=")
  ("<div attr= attr2=\"123\"/>" "attr=")
  ("<div attr=/>" "attr=")
  :expect-fail
  ("<div attr= {...attr2}/>" "attr=") ; spread parsed as attribute value
  ("<div attr=></div>" "attr=")) ; JS2 parses the => as an arrow

(jsx-deftest attr-missing-value-ends-in-dash
  ("<div attr-= attr2={123}/>" "attr-=")
  ("<div attr-= attr2=\"123\"/>" "attr-=")
  ("<div attr-=/>" "attr-=")
  :expect-fail
  ("<div attr-= {...attr2}/>" "attr-=")
  ("<div attr-=></div>" "attr-="))

(jsx-deftest attr-missing-value-interior-dashes
  ("<div attr-name= attr2={123}/>" "attr-name=")
  ("<div attr-name= attr2=\"123\"/>" "attr-name=")
  ("<div attr-name=/>" "attr-name=")
  :expect-fail
  ("<div attr-name= {...attr2}/>" "attr-name=")
  ("<div attr-name=></div>" "attr-name="))

(jsx-deftest attr-missing-value-no-dashes-namespaced
  ("<div ns:attr= attr2={123}/>" "ns:attr=")
  ("<div ns:attr= attr2=\"123\"/>" "ns:attr=")
  ("<div ns:attr=/>" "ns:attr=")
  :expect-fail
  ("<div ns:attr= {...attr2}/>" "ns:attr=")
  ("<div ns:attr=></div>" "ns:attr="))

(jsx-deftest attr-missing-value-ends-in-dash-namespaced
  ("<div ns:attr-= attr2={123}/>" "ns:attr-=")
  ("<div ns:attr-= attr2=\"123\"/>" "ns:attr-=")
  ("<div ns:attr-=/>" "ns:attr-=")
  :expect-fail
  ("<div ns:attr-= {...attr2}/>" "ns:attr-=")
  ("<div ns:attr-=></div>" "ns:attr-="))

(jsx-deftest attr-missing-value-interior-dashes-namespaced
  ("<div ns:attr-name= attr2={123}/>" "ns:attr-name=")
  ("<div ns:attr-name= attr2=\"123\"/>" "ns:attr-name=")
  ("<div ns:attr-name=/>" "ns:attr-name=")
  :expect-fail
  ("<div ns:attr-name= {...attr2}/>" "ns:attr-name=")
  ("<div ns:attr-name=></div>" "ns:attr-name="))

;; Missing right curly in attribute
(jsx-deftest attr-missing-rc-no-dashes
  :expect-fail
  ("<div attr={123 {...attr2}/>" "attr={123")
  ("<div attr={123 attr2={123}/>" "attr={123")
  ("<div attr={123 attr2=\"123\"/>" "attr={123")
  ("<div attr={123/>" "attr={123")
  ("<div attr={123></div>" "attr={123"))

(jsx-deftest attr-missing-rc-ends-in-dash
  :expect-fail
  ("<div attr-={123 {...attr2}/>" "attr-={123")
  ("<div attr-={123 attr2={123}/>" "attr-={123")
  ("<div attr-={123 attr2=\"123\"/>" "attr-={123")
  ("<div attr-={123/>" "attr-={123")
  ("<div attr-={123></div>" "attr-={123"))

(jsx-deftest attr-missing-rc-interior-dashes
  :expect-fail
  ("<div attr-name={123 {...attr2}/>" "attr-name={123")
  ("<div attr-name={123 attr2={123}/>" "attr-name={123")
  ("<div attr-name={123 attr2=\"123\"/>" "attr-name={123")
  ("<div attr-name={123/>" "attr-name={123")
  ("<div attr-name={123></div>" "attr-name={123"))

(jsx-deftest attr-missing-rc-no-dashes-namespaced
  :expect-fail
  ("<div ns:attr={123 {...attr2}/>" "ns:attr={123")
  ("<div ns:attr={123 attr2={123}/>" "ns:attr={123")
  ("<div ns:attr={123 attr2=\"123\"/>" "ns:attr={123")
  ("<div ns:attr={123/>" "ns:attr={123")
  ("<div ns:attr={123></div>" "ns:attr={123"))

(jsx-deftest attr-missing-rc-ends-in-dash-namespaced
  :expect-fail
  ("<div ns:attr-={123 {...attr2}/>" "ns:attr-={123")
  ("<div ns:attr-={123 attr2={123}/>" "ns:attr-={123")
  ("<div ns:attr-={123 attr2=\"123\"/>" "ns:attr-={123")
  ("<div ns:attr-={123/>" "ns:attr-={123")
  ("<div ns:attr-={123></div>" "ns:attr-={123"))

(jsx-deftest attr-missing-rc-interior-dashes-namespaced
  :expect-fail
  ("<div ns:attr-name={123 {...attr2}/>" "ns:attr-name={123")
  ("<div ns:attr-name={123 attr2={123}/>" "ns:attr-name={123")
  ("<div ns:attr-name={123 attr2=\"123\"/>" "ns:attr-name={123")
  ("<div ns:attr-name={123/>" "ns:attr-name={123")
  ("<div ns:attr-name={123></div>" "ns:attr-name={123"))


;; Here are all the bad values sign tests:
(jsx-deftest attr-bad-value-no-dashes
  ("<div attr={&&} attr2={123}/>" "{&&}")
  ("<div attr={&&} {...attr2}/>" "{&&}")
  ("<div attr={&&} attr2=\"123\"/>" "{&&}")
  ("<div attr={&&}/>" "{&&}")
  ("<div attr={&&}></div>" "{&&}"))

(jsx-deftest attr-bad-value-ends-in-dash
  ("<div attr-={&&} {...attr2}/>" "{&&}")
  ("<div attr-={&&} attr2={123}/>" "{&&}")
  ("<div attr-={&&} attr2=\"123\"/>" "{&&}")
  ("<div attr-={&&}/>" "{&&}")
  ("<div attr-={&&}></div>" "{&&}"))

(jsx-deftest attr-bad-value-interior-dashes
  ("<div attr-name={&&} {...attr2}/>" "{&&}")
  ("<div attr-name={&&} attr2={123}/>" "{&&}")
  ("<div attr-name={&&} attr2=\"123\"/>" "{&&}")
  ("<div attr-name={&&}/>" "{&&}")
  ("<div attr-name={&&}></div>" "{&&}"))

(jsx-deftest attr-bad-value-no-dashes-namespaced
  ("<div ns:attr={&&} {...attr2}/>" "{&&}")
  ("<div ns:attr={&&} attr2={123}/>" "{&&}")
  ("<div ns:attr={&&} attr2=\"123\"/>" "{&&}")
  ("<div ns:attr={&&}/>" "{&&}")
  ("<div ns:attr={&&}></div>" "{&&}"))

(jsx-deftest attr-bad-value-ends-in-dash-namespaced
  ("<div ns:attr-={&&} {...attr2}/>" "{&&}")
  ("<div ns:attr-={&&} attr2={123}/>" "{&&}")
  ("<div ns:attr-={&&} attr2=\"123\"/>" "{&&}")
  ("<div ns:attr-={&&}/>" "{&&}")
  ("<div ns:attr-={&&}></div>" "{&&}"))

(jsx-deftest attr-bad-value-interior-dashes-namespaced
  ("<div ns:attr-name={&&} {...attr2}/>" "{&&}")
  ("<div ns:attr-name={&&} attr2={123}/>" "{&&}")
  ("<div ns:attr-name={&&} attr2=\"123\"/>" "{&&}")
  ("<div ns:attr-name={&&}/>" "{&&}")
  ("<div ns:attr-name={&&}></div>" "{&&}"))

;; Invalid jsx-strings

(js2-deftest-parse invalid-jsx-string-in-attr
  "<div a=\"He said, \\\"Don't you worry child\\\"\"/>"
  :syntax-error "\"He said, \\\"Don't you worry child\\\"\"")

(js2-deftest-parse invalid-jsx-string-in-attr-single-quotes
  "<div a='He said, \"Don\\'t you worry child\"'/>"
  :syntax-error "'He said, \"Don\\'t you worry child\"'")

;; Spread-specific errors also have some combinatorial complexity:
;; A/ Missing value or bad value or good value
;; B/ With or without dots
;; C/ With or without right curly (except if good value and dots are there)
;; D/ Before another attribute (spread vs expr vs string) or
;;    at the end of the tag (self-closing or not)
;;
;; Total = (3 * 2 * 2 - 1) * 5 = 55

(jsx-deftest spread-no-value-no-dots-no-rc
  :expect-fail
  ("<div { {...other}/>" "{")
  ("<div { attr={123}/>" "{")
  ("<div { attr=\"123\"/>" "{")
  ("<div { />" "{")
  ("<div { ></div>" "{"))

(jsx-deftest spread-no-value-no-dots-with-rc
  ("<div {} {...other}/>" "{}")
  ("<div {} attr={123}/>" "{}")
  ("<div {} attr=\"123\"/>" "{}")
  ("<div {} />" "{}")
  ("<div {} ></div>" "{}"))

(jsx-deftest spread-no-value-with-dots-no-rc
  :expect-fail
  ("<div {... {...other}/>" "{...")
  ("<div {... attr={123}/>" "{...")
  ("<div {... attr=\"123\"/>" "{...")
  ("<div {... />" "{...")
  ("<div {... ></div>" "{..."))

(jsx-deftest spread-no-value-with-dots-with-rc
  ("<div {...} />" "{...}")
  ("<div {...} attr={123}/>" "{...}")
  ("<div {...} {...other}/>" "{...}")
  ("<div {...} attr=\"123\"/>" "{...}")
  ("<div {...} ></div>" "{...}"))

(jsx-deftest spread-bad-value-no-dots-no-rc
  :expect-fail
  ("<div {&& {...other}/>" "{&&")
  ("<div {&& attr={123}/>" "{&&")
  ("<div {&& attr=\"123\"/>" "{&&")
  ("<div {&& />" "{&&")
  ("<div {&& ></div>" "{&&"))

(jsx-deftest spread-bad-value-no-dots-with-rc
  ("<div {&&} {...other}/>" "{&&}")
  ("<div {&&} attr={123}/>" "{&&}")
  ("<div {&&} attr=\"123\"/>" "{&&}")
  ("<div {&&} />" "{&&}")
  ("<div {&&} ></div>" "{&&}"))

(jsx-deftest spread-bad-value-with-dots-with-rc
  ("<div {...&&} {...other}/>" "{...&&}")
  ("<div {...&&} attr={123}/>" "{...&&}")
  ("<div {...&&} attr=\"123\"/>" "{...&&}")
  ("<div {...&&} />" "{...&&}")
  ("<div {...&&} ></div>" "{...&&}"))

(jsx-deftest spread-good-value-no-dots-no-rc
  :expect-fail
  ("<div {{a: 123} {...other}/>" "{{a: 123}")
  ("<div {{a: 123} attr={123}/>" "{{a: 123}")
  ("<div {{a: 123} attr=\"123\"/>" "{{a: 123}")
  ("<div {{a: 123} />" "{{a: 123}")
  ("<div {{a: 123} ></div>" "{{a: 123}"))

(jsx-deftest spread-good-value-no-dots-with-rc
  ("<div {{a: 123}} {...other}/>" "{{a: 123}}")
  ("<div {{a: 123}} attr={123}/>" "{{a: 123}}")
  ("<div {{a: 123}} attr=\"123\"/>" "{{a: 123}}")
  ("<div {{a: 123}} />" "{{a: 123}}")
  ("<div {{a: 123}} ></div>" "{{a: 123}}"))


;; Other odds and ends


(ert-deftest rjsx-node-opening-tag ()
  (ert-with-test-buffer (:name 'origin)
    (dolist (test '(("<div/>" "div" "div")
                    ("<div></div>" "div" "div")
                    ("<div></vid>" "div" "div")
                    ("<C-d-e:f-g-h-></C-d-e:f-g-h->" "C-d-e:f-g-h" "C-d-e:f-g-h")
                    ("<C.D.E></C.D.E>" "C.D.E" "C.D.E")
                    ("<C-a.D-a.E-a/>" "C-a.D-a.E-a" nil)))
      (erase-buffer)
      (js2-visit-ast
       (js2-test-string-to-ast (car test))
       (lambda (node end-p)
         (when (not end-p)
           (cond
            ((rjsx-node-p node)
             (should (string= (cadr test) (rjsx-node-opening-tag-name node))))
            ((rjsx-closing-tag-p node)
             (should (string= (caddr test) (rjsx-closing-tag-full-name node))))))
         nil)))))

;;; rjsx-tests.el ends here
