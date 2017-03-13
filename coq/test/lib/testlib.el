;;; library of helper code for PG+coq tests

(defun process-file (file)
  (switch-to-buffer (find-file file))
  (proof-process-buffer))

(defun debug-msg (msg &rest args)
  (let ((str (format msg args)))
    (princ str 'external-debugging-output)
    (princ "\n" 'external-debugging-output)))

(defun verify-response (expected)
  (with-current-buffer proof-response-buffer
    (let ((got (buffer-substring-no-properties (point-min) (point-max))))
      (unless (equal expected got)
	(debug-msg "*** Contents of response buffer are NOT correct ***")
	(debug-msg "EXPECTED: %s" expected)
	(debug-msg "GOT:      %s" got)))))


