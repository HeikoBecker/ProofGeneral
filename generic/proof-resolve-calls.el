;;; proof-resolve-calls.el --- resolve function calls for proof shell or server
;;
;;; Code:

(require 'proof-config)
(require 'proof-shell)
(require 'proof-server)

;;;###autoload
(defun proof-ready-prover (&optional queuemode)
  "Call procedure according to proof-interaction-mode"
  (funcall proof-ready-prover-fun queuemode))

;;;###autoload
(defun proof-invisible-command (cmd &optional wait invisiblecallback
				    &rest flags)
  "Call procedure according to proof-interaction-mode"
  (funcall proof-invisible-command-fun cmd wait invisiblecallback flags))

;;;###autoload
(defun proof-invisible-cmd-get-result (cmd)
  "Call procedure according to proof-interaction-mode"
  (funcall proof-invisible-cmd-get-result-fun cmd))

;;;###autoload
(defun proof-invisible-command-invisible-result (cmd)
  "Call procedure according to proof-interaction-mode"
  (funcall proof-invisible-command-invisible-result-fun cmd))

(provide 'proof-resolve-calls)
;;; proof-resolve-calls.el ends here
