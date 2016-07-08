;; coq-response.el

(require 'proof-buffers)
(require 'proof-server)
(require 'coq-indent)

(defvar coq-time-commands nil)        ; defpacustom
(defconst coq--time-prefix "Time "
  "Coq command prefix for displaying timing information.")

(defcustom coq-optimise-resp-windows-enable t
  "If non-nil (default) resize vertically response windw after each command."
  :type 'boolean
  :group 'coq)

(defun is-not-split-vertic (selected-window)
  (<= (- (frame-height) (window-height)) 2))

(defun coq-find-threeb-frames ()
  "Return a list of frames displaying both response and goals buffers."
  (let* ((wins-resp (get-buffer-window-list proof-response-buffer nil t))
         (wins-gls (get-buffer-window-list proof-goals-buffer nil t))
         (frame-resp (cl-mapcar 'window-frame wins-resp))
         (frame-gls (cl-mapcar 'window-frame wins-gls)))
    (filtered-frame-list (lambda (x) (and (member x frame-resp) (member x frame-gls))))))

;; TODO: remove/add hook instead? 
(defun coq-optimise-resp-windows-if-option ()
  (when coq-optimise-resp-windows-enable (coq-optimise-resp-windows)))

(defun coq-optimise-resp-windows ()
  "Resize response buffer to optimal size.
Only when three-buffer-mode is enabled."
  ;; CPC 2015-12-31: Added the check below: if the command that caused this
  ;; call was silent, we shouldn't touch the response buffer.  See GitHub
  ;; issues https://github.com/cpitclaudel/company-coq/issues/32 and
  ;; https://github.com/cpitclaudel/company-coq/issues/8.
  (unless (memq 'no-response-display proof-server-delayed-output-flags)
    ;; If there is no frame with goql+response then do nothing
    (when (and proof-three-window-enable (coq-find-threeb-frames))
      (let ((pg-frame (car (coq-find-threeb-frames)))) ; selecting one adequat frame
        (with-selected-frame pg-frame
          (when (and (> (frame-height) 10)
                     (get-buffer-window proof-response-buffer))
            (let ((maxhgth
                   (- (+ (with-selected-window (get-buffer-window proof-goals-buffer t) (window-text-height))
                         (with-selected-window (get-buffer-window proof-response-buffer t) (window-text-height)))
                      window-min-height))
                  hgt-resp nline-resp)
              (with-selected-window (get-buffer-window proof-response-buffer)
                (setq hgt-resp (window-text-height))
                (with-current-buffer proof-response-buffer
                  (setq nline-resp ; number of lines we want for response buffer
                        (min maxhgth (max window-min-height ; + 1 for comfort
                                          (+ 1 (count-lines (point-max) (point-min)))))))
                (unless (is-not-split-vertic (selected-window))
                  (shrink-window (- hgt-resp nline-resp)))
                (with-current-buffer proof-response-buffer
                  (goto-char (point-min))
                  (recenter))))))))))

;; display something in response buffer
(defun coq--display-response (msg)
  (pg-response-message msg))

;; temporarily highlight error location
(defun coq--highlight-error (span start stop)
  (proof-with-current-buffer-if-exists 
   proof-script-buffer
   (let* ((len0 (- stop start))
	  (time-offset (if coq-time-commands (length coq--time-prefix) 0))
	  (len1 (- len0 time-offset)))
     ;; beginning of line
     (goto-char (span-start span))
     ;; skip whitespace
     (coq-find-real-start)
     ;; go to error start
     (goto-char (+ (point) start))
     (let ((err-start (point)))
       (span-make-self-removing-span err-start (+ err-start len1)
				     'face 'proof-warning-face)))))

;; indelibly mark span containing an error
(defun coq--mark-error (span msg)
  (proof-with-current-buffer-if-exists 
   proof-script-buffer
   (span-set-property span 'face proof-error-face)
   (span-set-property span 'help-echo msg)))

(provide 'coq-response)
