(live-add-pack-lib "nrepl")
(require 'nrepl )

(defun live-windows-hide-eol ()
 "Do not show ^M in files containing mixed UNIX and DOS line endings."
 (interactive)
 (setq buffer-display-table (make-display-table))
 (aset buffer-display-table ?\^M []))


(when (eq system-type 'windows-nt)
  (add-hook 'nrepl-mode-hook 'live-windows-hide-eol ))

(add-hook 'nrepl-interaction-mode-hook
          (lambda ()
            (nrepl-turn-on-eldoc-mode)
            (enable-paredit-mode)))

(add-hook 'nrepl-mode-hook
          (lambda ()
            (nrepl-turn-on-eldoc-mode)
            (enable-paredit-mode)
            (define-key nrepl-mode-map
              (kbd "{") 'paredit-open-curly)
            (define-key nrepl-mode-map
              (kbd "}") 'paredit-close-curly)))

(setq nrepl-popup-stacktraces nil)
(setq nrepl-popup-stacktraces-in-repl nil)
(add-to-list 'same-window-buffer-names "*nrepl*")

;;Auto Complete
(live-add-pack-lib "ac-nrepl")
(require 'ac-nrepl )
(add-hook 'nrepl-mode-hook 'ac-nrepl-setup)
(add-hook 'nrepl-interaction-mode-hook 'ac-nrepl-setup)

(eval-after-load "auto-complete"
  '(add-to-list 'ac-modes 'nrepl-mode))

;; specify the print length to be 100 to stop infinite sequences killing things.
(defun live-nrepl-set-print-length ()
  (nrepl-send-string-sync "(set! *print-length* 100)" "clojure.core"))

(add-hook 'nrepl-connected-hook 'live-nrepl-set-print-length)

;;; Monkey Patch nREPL with better behaviour:

(defun live-nrepl-err-handler (buffer ex root-ex session)
  "Make an error handler for BUFFER, EX, ROOT-EX and SESSION."
  ;; TODO: use ex and root-ex as fallback values to display when pst/print-stack-trace-not-found
  (let ((replp (equal 'nrepl-mode (buffer-local-value 'major-mode buffer))))
    (if (or (and nrepl-popup-stacktraces-in-repl replp)
            (and nrepl-popup-stacktraces (not replp)))
        (lexical-let ((nrepl-popup-on-error nrepl-popup-on-error)
                      (err-buffer (nrepl-popup-buffer nrepl-error-buffer t)))
          (with-current-buffer buffer
            (nrepl-send-string "(if-let [pst+ (clojure.core/resolve 'clj-stacktrace.repl/pst+)]
                        (pst+ *e) (clojure.stacktrace/print-stack-trace *e))"
                               (nrepl-make-response-handler err-buffer
                                                            '()
                                                            (lambda (err-buffer str)
                                                              (with-current-buffer err-buffer (goto-char (point-max)))
                                                              (nrepl-emit-into-popup-buffer err-buffer str)
                                                              (with-current-buffer err-buffer (goto-char (point-min)))
                                                              )
                                                            (lambda (err-buffer str)
                                                              (with-current-buffer err-buffer (goto-char (point-max)))
                                                              (nrepl-emit-into-popup-buffer err-buffer str)
                                                              (with-current-buffer err-buffer (goto-char (point-min)))
                                                              )
                                                            '())
                               (nrepl-current-ns)
                               (nrepl-current-tooling-session)))
          (with-current-buffer nrepl-error-buffer
            (compilation-minor-mode 1))
          ))))

;;(setq nrepl-err-handler 'live-nrepl-err-handler)

;;; Region discovery fix
(defun nrepl-region-for-expression-at-point ()
  "Return the start and end position of defun at point."
  (when (and (live-paredit-top-level-p)
             (save-excursion
               (ignore-errors (forward-char))
               (live-paredit-top-level-p)))
    (error "Oops! You tried to evaluate whitespace. Move the point into in a form and try again."))

  (save-excursion
    (save-match-data
      (ignore-errors (live-paredit-forward-down))
      (paredit-forward-up)
      (while (ignore-errors (paredit-forward-up) t))
      (let ((end (point)))
        (backward-sexp)
        (list (point) end)))))

;;; Windows M-. navigation fix
(defun nrepl-jump-to-def (var)
  "Jump to the definition of the var at point."
  (let ((form (format "((clojure.core/juxt
                         (comp (fn [s] (if (clojure.core/re-find #\"[Ww]indows\" (System/getProperty \"os.name\"))
                                           (.replace s \"file:/\" \"file:\")
                                           s))
                               clojure.core/str
                               clojure.java.io/resource :file)
                         (comp clojure.core/str clojure.java.io/file :file) :line)
                        (clojure.core/meta (clojure.core/ns-resolve '%s '%s)))"
                      (nrepl-current-ns) var)))
    (nrepl-send-string form
                       (nrepl-jump-to-def-handler (current-buffer))
                       (nrepl-current-ns)
                       (nrepl-current-tooling-session))))

(setq nrepl-port "4555")
(defun nrepl-make-response-handler
 (buffer value-handler stdout-handler stderr-handler done-handler
         &optional eval-error-handler)
  "Make a response handler for BUFFER.
Uses the specified VALUE-HANDLER, STDOUT-HANDLER, STDERR-HANDLER,
DONE-HANDLER, and EVAL-ERROR-HANDLER as appropriate."
  (lexical-let ((buffer buffer)
                (value-handler value-handler)
                (stdout-handler stdout-handler)
                (stderr-handler stderr-handler)
                (done-handler done-handler)
                (eval-error-handler eval-error-handler))
    (lambda (response)
      (nrepl-dbind-response response (value ns out err status id ex root-ex
                                            session)
        (cond (value
               (with-current-buffer buffer
                 (if ns
                     (setq nrepl-buffer-ns ns)))
               (if value-handler
                   (funcall value-handler buffer value)))
              (out
               (if stdout-handler
                   (funcall stdout-handler buffer out)))
              (err
               (if stderr-handler
                   (funcall stderr-handler buffer err)))
              (status
               (if (member "interrupted" status)
                   (message "Evaluation interrupted."))
               (if (member "eval-error" status)
                   (funcall (or eval-error-handler nrepl-err-handler)
                            buffer ex root-ex session))
               (if (member "namespace-not-found" status)
                   (message "Oops! You tried to evaluate something in a namespace that doesn't yet exist. Try evaluating the ns form at the top of the buffer."))
               (if (member "need-input" status)
                   (nrepl-need-input buffer))
               (if (member "done" status)
                   (progn (remhash id nrepl-requests)
                          (if done-handler
                              (funcall done-handler buffer))))))))))
