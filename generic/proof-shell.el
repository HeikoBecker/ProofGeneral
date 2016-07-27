;;; proof-shell.el --- Proof General shell mode.
;;
;; Copyright (C) 1994-2011 LFCS Edinburgh.
;; Authors:   David Aspinall, Yves Bertot, Healfdene Goguen,
;;            Thomas Kleymann and Dilip Sequeira
;; License:   GPL (GNU GENERAL PUBLIC LICENSE)
;;
;; $Id$
;;
;;; Commentary:
;;
;; Mode for buffer which interacts with proof assistant.
;; Includes management of a queue of commands waiting to be sent.
;;

;;; Code:

(require 'cl)				; set-difference, every

(eval-when-compile
  (require 'span)
  (require 'proof-utils))

(require 'pg-response)
(require 'pg-goals)
(require 'pg-user)			; proof-script, new-command-advance
(require 'proof-tree)
(require 'proof-queue)
(require 'proof-proverargs)
(require 'proof-buffers)

;;
;; Internal variables used by proof shell
;;

(defvar proof-marker nil
  "Marker in proof shell buffer pointing to previous command input.")

;; We record the last output from the prover and a flag indicating its
;; type, as well as a previous ("delayed") version for when the end
;; of the queue is reached or an error or interrupt occurs.
;; 
;; See `proof-prover-last-output', `proof-shell-last-prompt' in
;; pg-vars.el

(defvar proof-shell-last-goals-output ""
  "The last displayed goals string.")

(defvar proof-shell-last-response-output ""
  "The last displayed response message.")

(defvar proof-shell-delayed-output-start nil
  "A record of the start of the previous output in the shell buffer.
The previous output is held back for processing at end of queue.")

(defvar proof-shell-delayed-output-end nil
  "A record of the start of the previous output in the shell buffer.
The previous output is held back for processing at end of queue.")

(defvar proof-shell-delayed-output-flags nil
  "A copy of the `proof-action-list' flags for `proof-shell-delayed-output'.")

(defvar proof-shell-interrupt-pending nil
  "A flag indicating an interrupt is pending.
This ensures that the proof queue will be interrupted even if no
interrupt message is printed from the prover after the last output.")

(defvar proof-shell-exit-in-progress nil
  "A flag indicating that the current proof process is about to exit.
This flag is set for the duration of `proof-shell-kill-function'
to tell hooks in `proof-deactivate-scripting-hook' to refrain
from calling `proof-shell-exit'.")



;;
;; Indicator and fake minor mode for active scripting buffer
;;

(defcustom proof-shell-active-scripting-indicator
  '(:eval (propertize 
	   " Scripting " 'face 
	   (cond
	    (proof-shell-busy			       'proof-queue-face)
	    ((eq proof-prover-last-output-kind 'error)  'proof-script-sticky-error-face)
	    ((proof-with-current-buffer-if-exists proof-script-buffer
						  (proof-locked-region-full-p))
	     'font-lock-type-face)
	    (t 'proof-locked-face))))
  "Modeline indicator for active scripting buffer.
Changes colour to indicate whether the shell is busy, etc."
  :type 'sexp
  :group 'proof-general-internals)

(unless
    (assq 'proof-active-buffer-fake-minor-mode minor-mode-alist)
  (setq minor-mode-alist
	(append minor-mode-alist
		(list
		 (list
		  'proof-active-buffer-fake-minor-mode
		  proof-shell-active-scripting-indicator)))))




;;
;; Implementing the process lock
;;
;; Note that because Emacs Lisp code is single-threaded, there are no
;; concurrency issues here (a loop parsing process output cannot get
;; pre-empted by the user trying to send more input to the process, or
;; by the process filter trying to deal with more output).  But the
;; lock allows for clear management of the queue.
;;
;; Three relevant functions:
;;
;;  proof-shell-ready-prover
;;    starts proof shell, gives error if it's busy.
;;
;;  proof-activate-scripting  (in proof-script.el)
;;    calls proof-shell-ready-prover, and turns on scripting minor
;;    mode for current (scripting) buffer.
;;
;; Also, an enabler predicate:
;;
;;  proof-shell-available-p
;;    returns non-nil if a proof shell is active and not locked.
;;

;;;###autoload
(defun proof-shell-ready-prover (&optional queuemode)
  "Make sure the proof assistant is ready for a command.
If QUEUEMODE is set, succeed if the proof shell is busy but
has mode QUEUEMODE, which is a symbol or list of symbols.
Otherwise, if the shell is busy, give an error.
No change to current buffer or point."
  (proof-shell-start)
  (unless (or (not proof-shell-busy)
	      (eq queuemode proof-shell-busy)
	      (and (listp queuemode)
		   (member proof-shell-busy queuemode)))
    (error "Proof process busy!")))

;;;###autoload
(defsubst proof-shell-live-buffer ()
  "Return non-nil if proof-shell-buffer is live."
  (and proof-shell-buffer
       (buffer-live-p proof-shell-buffer)))

;;;###autoload
(defun proof-shell-available-p ()
  "Return non-nil if there is a proof shell active and available.
No error messages.  Useful as menu or toolbar enabler."
  (and (proof-shell-live-buffer)
       (not proof-shell-busy)))

(defun proof-grab-lock (&optional queuemode)
  "Grab the proof shell lock, starting the proof assistant if need be.
Runs `proof-state-change-hook' to notify state change.
If QUEUEMODE is supplied, set the lock to that value."
  (proof-shell-ready-prover queuemode)
  (setq proof-shell-interrupt-pending nil
	proof-shell-busy (or queuemode t)
	proof-shell-last-queuemode proof-shell-busy)
  (run-hooks 'proof-state-change-hook))

(defun proof-release-lock ()
  "Release the proof shell lock.  Clear `proof-shell-busy'."
  (setq proof-shell-busy nil))



;;
;;  Starting and stopping the proof shell
;;

(defcustom proof-shell-fiddle-frames t
  "Non-nil if proof-shell functions should fire-up/delete frames like crazy."
  :type 'boolean
  :group 'proof-shell)

(defvar proof-shell-filter-active nil
  "t when `proof-shell-filter' is running.")

(defvar proof-shell-filter-was-blocked nil
  "t when a recursive call of `proof-shell-filter' was blocked.
In this case `proof-shell-filter' must be called again after it finished.")

(defun proof-shell-start ()
  "Initialise a shell-like buffer for a proof assistant.
Does nothing if proof assistant is already running.

Also generates goal and response buffers.

If `proof-prog-name-ask' is set, query the user for the
process command."
  (interactive)
  (unless (proof-shell-live-buffer)

    (setq proof-shell-filter-active nil)
    (setq proof-included-files-list nil) ; clear some state

    (let ((name (buffer-file-name (current-buffer))))
      (if (and name proof-prog-name-guess proof-guess-command-line)
	  (setq proof-prog-name
		(apply proof-guess-command-line (list name)))))

    (if proof-prog-name-ask
	(setq proof-prog-name (read-shell-command "Run process: "
						  proof-prog-name)))
    (let
	((proc (downcase proof-assistant)))

      ;; Starting the inferior process (asynchronous)
      (let* ((command-line-and-names (prover-command-line-and-names))

	     (prog-command-line (cdr command-line-and-names))
	     (prog-name-list (car command-line-and-names))

	     (process-connection-type
	      proof-shell-process-connection-type)

	     ;; Trac #324, Trac #284: default with Emacs 23 variants
	     ;; is t.  nil gives marginally better results with "make
	     ;; profile.isar" on homogenous test input.  Top-level
	     ;; Emacs loop causes slow down on Mac and Windows ports.
	     (process-adaptive-read-buffering nil)
	     
	     
	     ;; The next few settings control the proof assistant encoding.
	     ;; See Elisp manual for recommendations for coding systems.  
	     
	     ;; Modern versions of proof systems should be Unicode
	     ;; clean, i.e., outputing only ASCII characters or using a
	     ;; representation such as UTF-8.  Old versions of PG
	     ;; relied on control sequences using 8-bit characters with
	     ;; codes between 127 and 255, this is now deprecated.

	     ;; Backward compatibility: remove UTF-8 encoding if not
	     ;; wanted; it conflicts with using chars 128-255 for
	     ;; markup and results in blocking in C libraries.
	     (process-environment
	      (append (proof-ass prog-env)    ; custom environment
		      (if proof-prover-unicode ; if specials not used,
			  process-environment ; leave it alone
			(cons
			 (if (getenv "LANG")
			     (format "LANG=%s"
				     (replace-regexp-in-string 
				      "\\.UTF-8" ""
				      (getenv "LANG")))
			   "LANG=C")
			 (delete
			  (concat "LANG=" (getenv "LANG"))
			  process-environment)))))

	     (normal-coding-system-for-read coding-system-for-read)
	     (coding-system-for-read
	      (if proof-prover-unicode
		  (or (condition-case nil
			  (check-coding-system 'utf-8)
			(error nil))
		      normal-coding-system-for-read)

		(if (string-match "Linux"
				  (shell-command-to-string "uname"))
		    'raw-text
		  normal-coding-system-for-read)))

	     (coding-system-for-write coding-system-for-read))

	(message "Starting: %s" prog-command-line)

	(setq proof-shell-buffer (get-buffer (concat "*" proc "*")))

	(unless (proof-shell-live-buffer)
	  ;; Give error now if shell buffer isn't live (process exited)
	  (setq proof-shell-buffer nil)
	  (error "Starting process: %s..failed" prog-command-line)))
      
      (proof-prover-make-associated-buffers)

      (with-current-buffer proof-shell-buffer
	;; Clear and set text representation (see CVS history for comments)
	(erase-buffer)
	(proof-prover-set-text-representation)

	;; Initialise shell mode (calls hook function, after process started)
	(funcall proof-mode-for-shell)

	;; Check to see that the process is still going.  If not,
	;; switch buffer to display the error messages to the user.
	(unless (proof-shell-live-buffer)
	  (switch-to-buffer proof-shell-buffer)
	  (error "%s process exited!" proc))

	;; Setting modes initialises local variables which
	;; may affect frame/buffer appearance: so we fire up frames
	;; once this has been done.
	(if proof-shell-fiddle-frames
	    ;; Call multiple-frames-enable in case we need to fire up
	    ;; new frames (NB: sets specifiers to remove modeline)
	    (save-selected-window
	      (save-selected-frame
	       (proof-multiple-frames-enable)))))

      (message "Starting %s process... done." proc))))


;;
;;  Shutting down proof shell and associated buffers
;;

;; Hooks here are handy for liaising with prover config stuff.

(defvar proof-shell-kill-function-hooks nil
  "Functions run from `proof-shell-kill-function'.")

(defun proof-shell-clear-state ()
  "Clear internal state of proof shell."
  (setq proof-action-list nil
	proof-included-files-list nil
	proof-shell-busy nil
	proof-shell-last-queuemode nil
	proof-prover-proof-completed nil
	proof-nesting-depth 0
	proof-prover-silent nil
	proof-prover-last-output ""
	proof-shell-last-prompt ""
	proof-prover-last-output-kind nil
	proof-shell-delayed-output-start nil
	proof-shell-delayed-output-end nil
	proof-shell-delayed-output-flags nil))

(defun proof-shell-exit (&optional dont-ask)
  "Query the user and exit the proof process.

This simply kills the `proof-shell-buffer' relying on the hook function

`proof-shell-kill-function' to do the hard work. If optional
argument DONT-ASK is non-nil, the proof process is terminated
without confirmation.

The kill function uses `<PA>-quit-timeout' as a timeout to wait
after sending `proof-shell-quit-cmd' before rudely killing the process.

This function should not be called if
`proof-shell-exit-in-progress' is t, because a recursive call of
`proof-shell-kill-function' will give strange errors."
  (interactive "P")
  (if (buffer-live-p proof-shell-buffer)
      (when (or dont-ask
		(yes-or-no-p (format "Exit %s process? " proof-assistant)))
	(let ((kill-buffer-query-functions nil)) ; avoid extra dialog
	  (kill-buffer proof-shell-buffer))
	(setq proof-shell-buffer nil))
    (error "No proof shell buffer to kill!")))

(defun proof-shell-bail-out (process event)
  "Value for the process sentinel for the proof assistant PROCESS.
If the proof assistant dies, run `proof-shell-kill-function' to
cleanup and remove the associated buffers.  The shell buffer is
left around so the user may discover what killed the process.
EVENT is the string describing the change."
  (message "Process %s %s, shutting down scripting..." process event)
  (proof-shell-kill-function)
  (message "Process %s %s, shutting down scripting...done." process event))

(defun proof-shell-restart ()
  "Clear script buffers and send `proof-shell-restart-cmd'.
All locked regions are cleared and the active scripting buffer
deactivated.

If the proof shell is busy, an interrupt is sent with
`proof-interrupt-process' and we wait until the process is ready.

The restart command should re-synchronize Proof General with the proof
assistant, without actually exiting and restarting the proof assistant
process.

It is up to the proof assistant how much context is cleared: for
example, theories already loaded may be \"cached\" in some way,
so that loading them the next time round only performs a re-linking
operation, not full re-processing.  (One way of caching is via
object files, used by Lego and Coq)."
  (interactive)
  (when proof-shell-busy
    (proof-interrupt-process)
    (proof-shell-wait))
  (if (not (proof-shell-live-buffer))
      (proof-shell-start) ;; start if not running
    ;; otherwise clear context
    (proof-script-remove-all-spans-and-deactivate)
    (proof-shell-clear-state)
    (with-current-buffer proof-shell-buffer
      (delete-region (point-min) (point-max)))
    (if (and (buffer-live-p proof-shell-buffer)
	     proof-shell-restart-cmd)
	(proof-shell-invisible-command
	 proof-shell-restart-cmd))))




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Response buffer processing
;;

(defvar proof-shell-urgent-message-marker nil
  "Marker in proof shell buffer pointing to end of last urgent message.")

(defvar proof-shell-urgent-message-scanner nil
  "Marker in proof shell buffer pointing to scan start for urgent messages.
This is only used in `proof-shell-process-urgent-message'.")

'(defun proof-shell-handle-error-output (start-regexp append-face)
  "Displays output from process in `proof-response-buffer'.
The output is taken from `proof-prover-last-output' and begins
the first match for START-REGEXP.

If START-REGEXP is nil or no match can be found (which can happen
if output has been garbled somehow), begin from the start of
the output for this command.

This is a subroutine of `proof-shell-handle-error'."
  (let ((string proof-prover-last-output) pos)
      (if (and start-regexp
	       (setq pos (string-match start-regexp string)))
	  (setq string (substring string pos)))

      ;; Erase if need be, and erase next time round too.
      (pg-response-maybe-erase t nil)
      ;; Coloring the whole message may be ugly ad hide better
      ;; coloring mechanism.
      (if proof-script-color-error-messages
	  (pg-response-display-with-face string append-face)
	(pg-response-display-with-face string))))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Processing error output
;;

'(defun proof-shell-handle-error-or-interrupt (err-or-int flags)
  "React on an error or interrupt message triggered by the prover.

The argument ERR-OR-INT should be set to 'error or 'interrupt
which affects the action taken.

For errors, we first flush unprocessed output (usually goals).
The error message is the (usually) displayed in the response buffer.

For interrupts, a warning message is displayed.

In both cases we then sound a beep, clear the queue and spans and
finally we call `proof-shell-handle-error-or-interrupt-hook'.

Commands which are not part of regular script management (with
non-empty flags='no-error-display) will not cause any display action.

This is called in two places: (1) from the output processing
functions, in case we find an error or interrupt message output,
and (2) from the exec loop, in case of a pending interrupt which
didn't cause prover output."
  (unless (memq 'no-error-display flags)
    (cond
     ((eq err-or-int 'interrupt)
      (pg-response-maybe-erase t t t) ; force cleaned now & next
      (proof-shell-handle-error-output
       (if proof-shell-truncate-before-error proof-shell-interrupt-regexp)
       'proof-error-face)
      (pg-response-warning
       "Interrupt: script management may be in an inconsistent state
	   (but it's probably okay)"))
     (t ; error
      (if proof-shell-delayed-output-start 
	  (save-excursion
	    (proof-shell-handle-delayed-output)))
      (proof-shell-handle-error-output
       (if proof-shell-truncate-before-error proof-shell-error-regexp)
       'proof-error-face)
      (proof-display-and-keep-buffer proof-response-buffer))))
  
  (proof-with-current-buffer-if-exists proof-shell-buffer
    (proof-shell-error-or-interrupt-action err-or-int)))

(defun proof-shell-error-or-interrupt-action (err-or-int)
  "Take action on errors or interrupts.
ERR-OR-INT is a flag, 'error or 'interrupt.
This is a subroutine of `proof-shell-handle-error-or-interrupt'.
Must be called with proof shell buffer current.

This function invokes `proof-shell-handle-error-or-interrupt-hook'
unless the FLAGS for the command are non-nil (see `proof-action-list')."
  (unless proof-shell-quiet-errors
    (beep))
  (let* ((fatalitem  (car-safe proof-action-list))
	 (badspan    (car-safe fatalitem))
	 (flags      (if fatalitem (nth 3 fatalitem))))

    (proof-with-current-buffer-if-exists proof-script-buffer
      (save-excursion
	(proof-script-clear-queue-spans-on-error badspan 
						 (eq err-or-int 'interrupt))))
    ;; Note: coq-par-emergency-cleanup, which might be called via
    ;; proof-shell-handle-error-or-interrupt-hook below, assumes that
    ;; proof-action-list is empty on error. 
    (setq proof-action-list nil)
    (proof-release-lock)
    (unless flags
      ;; Give a hint about C-c C-`.  (NB: approximate test)
      (if (pg-response-has-error-location)
	  (pg-next-error-hint))
      ;; Run hooks for additional effects, e.g. highlight or moving pointer
      (run-hooks 'proof-shell-handle-error-or-interrupt-hook))))

(defun proof-goals-pos (span maparg)
  "Given a span, return the start of it if corresponds to a goal, nil otherwise."
  (and (eq 'goal (car (span-property span 'proof-top-element)))
       (span-start span)))

(defun proof-pbp-focus-on-first-goal ()
  "If the `proof-goals-buffer' contains goals, bring the first one into view.
This is a hook function for proof-shell-handle-delayed-output-hook."
  )
;; PG 4.0 FIXME
;       (let
;	   ((pos (map-extents 'proof-goals-pos proof-goals-buffer
;			      nil nil nil nil 'proof-top-element)))
;	 (and pos (set-window-point
;		   (get-buffer-window proof-goals-buffer t) pos)))))


(defsubst proof-shell-string-match-safe (regexp string)
  "Like string-match except returns nil if REGEXP is nil."
  (and regexp (string-match regexp string)))

(defun proof-shell-handle-immediate-output (cmd start end flags)
  "See if the output between START and END must be dealt with immediately.
To speed up processing, PG tries to avoid displaying output that
the user will not have a chance to see.  Some output must be
handled immediately, however: these are errors, interrupts,
goals and loopbacks (proof step hints/proof by pointing results).

In this function we check, in turn:

  `proof-shell-interrupt-regexp'
  `proof-shell-error-regexp'
  `proof-shell-proof-completed-regexp'
  `proof-shell-result-start'

Other kinds of output are essentially display only, so only
dealt with if necessary.

To extend this, set `proof-shell-handle-output-system-specific',
which is a hook to take particular additional actions.

This function sets variables: `proof-prover-last-output-kind',
and the counter `proof-prover-proof-completed' which counts commands
after a completed proof."
  (setq proof-prover-last-output-kind nil) ; unclassified
  (goto-char start)
  (cond
   ;; TODO: Isabelle has changed (since 2009) and is now amalgamating
   ;; output between prompts, and does e.g.,
   ;;   GOALS 
   ;;   ERROR
   ;; we need to override delayed output from the previous
   ;; command with delayed output from this command to handle that!
   ((proof-re-search-forward-safe proof-shell-interrupt-regexp end t)
    (setq proof-prover-last-output-kind 'interrupt)
    (proof-shell-handle-error-or-interrupt 'interrupt flags))
   
   ((proof-re-search-forward-safe proof-shell-error-regexp end t)
    (setq proof-prover-last-output-kind 'error)
    (proof-shell-handle-error-or-interrupt 'error flags))

   ((proof-re-search-forward-safe proof-shell-result-start end t)
    ;; NB: usually the action list is empty, strange results likely if
    ;; more commands follow. Therefore, this case might be delayed.
    (let (pstart pend)
      (setq pstart (+ 1 (match-end 0)))
      (re-search-forward proof-shell-result-end end t)
      (setq pend (- (match-beginning 0) 1))
      (proof-shell-insert-loopback-cmd
       (buffer-substring-no-properties pstart pend)))
    (setq proof-prover-last-output-kind 'loopback)
    (proof-shell-exec-loop))
   
   ((proof-re-search-forward-safe proof-shell-proof-completed-regexp end t)
    (setq proof-prover-proof-completed 0))) ; commands since complete

  ;; PG4.0 change: simplify and run earlier
  (if proof-shell-handle-output-system-specific
      (funcall proof-shell-handle-output-system-specific
	       cmd proof-prover-last-output)))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Interrupts
;;

(defun proof-interrupt-process ()
  "Interrupt the proof assistant.  Warning! This may confuse Proof General.

This sends an interrupt signal to the proof assistant, if Proof General
thinks it is busy.

This command is risky because we don't know whether the last command
succeeded or not.  The assumption is that it didn't, which should be true
most of the time, and all of the time if the proof assistant has a careful
handling of interrupt signals.

Some provers may ignore (and lose) interrupt signals, or fail to indicate
that they have been acted upon yet stop in the middle of output.
In the first case, PG will terminate the queue of commands at the first
available point.  In the second case, you may need to press enter inside
the prover command buffer (e.g., with Isabelle2009 press RET inside *isabelle*)."
  (interactive)
  (unless (proof-shell-live-buffer)
      (error "Proof process not started!"))
  (unless proof-shell-busy
    (error "Proof process not active!"))
  (setq proof-shell-interrupt-pending t)
  (with-current-buffer proof-shell-buffer
    (interrupt-process))
  (run-hooks 'proof-shell-signal-interrupt-hook))




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;;   Low-level commands for shell communication
;;

;;;###autoload

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Code for manipulating proof queue
;;

(defun proof-shell-action-list-item (cmd callback &optional flags)
  "Return action list entry run CMD with callback CALLBACK and FLAGS.
The queue entry does not refer to a span in the script buffer."
  (list nil (list cmd) callback flags))

(defun proof-shell-set-silent (span)
  "Callback for `proof-shell-start-silent'.
Very simple function but it's important to give it a name to help
track what happens in the proof queue."
  (setq proof-prover-silent t))

(defun proof-shell-start-silent-item ()
  "Return proof queue entry for starting silent mode."
  (proof-shell-action-list-item
   proof-shell-start-silent-cmd
   'proof-shell-set-silent))

(defun proof-shell-clear-silent (span)
  "Callback for `proof-shell-stop-silent'.
Very simple function but it's important to give it a name to help
track what happens in the proof queue."
  (setq proof-prover-silent nil))

(defun proof-shell-stop-silent-item ()
  "Return proof queue entry for stopping silent mode."
  (proof-shell-action-list-item
   proof-shell-stop-silent-cmd
   'proof-shell-clear-silent))

(defsubst proof-shell-should-be-silent ()
  "Non-nil if we should switch to silent mode based on size of queue."
  (if (and proof-shell-start-silent-cmd ; configured
	   (not proof-full-annotation)  ; always noisy
	   (not proof-tree-external-display) ; no proof-tree display 
	   (not proof-prover-silent))	; already silent
	  ;; NB: to be more accurate we should only count number
	  ;; of scripting items in the list (not e.g. invisibles).
	  ;; More efficient: keep track of size of queue as modified.
	  (>= (length proof-action-list) proof-shell-silent-threshold)))

(defsubst proof-shell-should-not-be-silent ()
  "Non-nil if we should switch to non silent mode based on size of queue."
  (if (and proof-shell-stop-silent-cmd ; configured
	   proof-prover-silent)	; already non silent
	  ;; NB: to be more accurate we should only count number
	  ;; of scripting items in the list (not e.g. invisibles).
	  ;; More efficient: keep track of size of queue as modified.
	  (< (length proof-action-list) proof-shell-silent-threshold)))

(defsubst proof-shell-insert-action-item (item)
  "Insert ITEM from `proof-action-list' into the proof shell."
  (proof-shell-insert (nth 1 item) (nth 2 item) (nth 0 item)))

(defun proof-shell-add-to-queue (queueitems &optional queuemode)
  "Chop off the vacuous prefix of the QUEUEITEMS and queue them.
For each item with a nil command at the head of the list, invoke its
callback and remove it from the list.

Append the result onto `proof-action-list', and if the proof
shell isn't already busy, grab the lock with QUEUEMODE and
start processing the queue.


If the proof shell is busy when this function is called,
then QUEUEMODE must match the mode of the queue currently
being processed."

  (when (and queueitems proof-action-list)
    ;; internal check: correct queuemode in force if busy
    ;; (should have proof-action-list<>nil -> busy)
    (and proof-shell-busy queuemode                            ;;; PROOF-SHELL
	 (unless (eq proof-shell-busy queuemode)
	   (proof-debug
	    "proof-append-alist: wrong queuemode detected for busy shell")
	   (assert (eq proof-shell-busy queuemode)))))

  (let ((nothingthere (null proof-action-list)))
    ;; Now extend or start the queue.
    (setq proof-action-list
	  (nconc proof-action-list queueitems))
    
    (when nothingthere ; process comments immediately
      (let ((cbitems  (proof-prover-slurp-comments))) 
	(mapc 'proof-prover-invoke-callback cbitems))) 
  
    (if proof-action-list ;; something to do
	(progn
	  (when (proof-shell-should-be-silent)                 ;;; PROOF-SHELL
	      ;; do this ASAP, either first or just after current command
	      (setq proof-action-list
		    (if nothingthere ; the first thing
			(cons (proof-shell-start-silent-item)  ;;; PROOF-SHELL
			      proof-action-list)
		      (cons (car proof-action-list) ; after current
			    (cons (proof-shell-start-silent-item) ;;; PROOF-SHELL
				  (cdr proof-action-list))))))
	  ;; Sometimes the non silent mode needs to be set because a
	  ;; previous error prevented to go back to non silent mode
	  (when (proof-shell-should-not-be-silent)        ;;; PROOF-SHELL
	      ;; do this ASAP, either first or just after current command
	      (setq proof-action-list
		    (if nothingthere ; the first thing
			(cons (proof-shell-stop-silent-item)  ;;; PROOF-SHELL
			      proof-action-list)
		      (cons (car proof-action-list) ; after current
			    (cons (proof-shell-stop-silent-item)
				  (cdr proof-action-list))))))	  
	  (when nothingthere  ; start sending commands
	    (proof-grab-lock queuemode)
	    (setq proof-prover-last-output-kind nil)            ;;; PROOF-SHELL
	    (proof-shell-insert-action-item (car proof-action-list))))
      (if proof-second-action-list-active
	  ;; primary action list is empty, but there are items waiting
	  ;; somewhere else
	  (proof-grab-lock queuemode)
      ;; nothing to do: maybe we completed a list of comments without sending them
	(proof-detach-queue)))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MAIN LOOP
;;

(defun proof-shell-exec-loop ()
  "Main loop processing the `proof-action-list', called from shell filter.

`proof-action-list' contains a list of (SPAN COMMAND ACTION [FLAGS]) lists.

If this function is called with a non-empty `proof-action-list', the
head of the list is the previously executed command which succeeded.
We execute the callback (ACTION SPAN) on the first item,
then (ACTION SPAN) on any following items which have null as
their cmd components.

If a there is a next command after that, send it to the process.

If the action list becomes empty, unlock the process and remove
the queue region.

The return value is non-nil if the action list is now empty or
contains only invisible elements for Prooftree synchronization."
  (unless (null proof-action-list)
    (save-excursion
      (if proof-script-buffer		      ; switch to active script
	  (set-buffer proof-script-buffer))

      (let* ((item    (car proof-action-list))
	     (flags   (nth 3 item))
	     cbitems)

	;; now we should invoke callback on just processed command,
	;; but we delay this until sending the next command, attempting
	;; to parallelize prover and Emacs somewhat.  (PG 4.0 change)

	(message (format "proof-action-list 1: %s" proof-action-list))

	(setq proof-action-list (cdr proof-action-list))

	(setq cbitems (cons item
			    (proof-prover-slurp-comments)))

	;; This is the point where old items have been removed from
	;; proof-action-list and where the next item has not yet been
	;; sent to the proof assistant. This is therefore one of the
	;; few points where it is safe to manipulate
	;; proof-action-list. The urgent proof-tree display actions
	;; must therefore be called here, because they might add some
	;; Show actions at the front of proof-action-list.
	(if proof-tree-external-display
	    (proof-tree-urgent-action flags))

	;; if action list is (nearly) empty, ensure prover is noisy.
	(if (and proof-prover-silent
		 (not (eq (nth 2 item) 'proof-shell-clear-silent))
		 (or (null proof-action-list)
		     (null (cdr proof-action-list))))
	    ;; Insert the quieten command on head of queue
	    (setq proof-action-list
		  (cons (proof-shell-stop-silent-item)
			proof-action-list)))

	;; pending interrupts: we want to stop the queue here
	(when proof-shell-interrupt-pending
	  (mapc 'proof-prover-invoke-callback cbitems)
	  (setq cbitems nil)
	  (proof-shell-handle-error-or-interrupt 'interrupt flags))

	(message (format "proof-action-list 2: %s" proof-action-list))

	(if proof-action-list
	    ;; send the next command to the process.
	    (proof-shell-insert-action-item (car proof-action-list)))

	;; process the delayed callbacks now
	(mapc 'proof-prover-invoke-callback cbitems)	

	(unless (or proof-action-list proof-second-action-list-active)
          ; release lock, cleanup
	  (proof-release-lock)
	  (proof-detach-queue)
	  (unless flags ; hint after a batch of scripting
	    (pg-processing-complete-hint))
	  (pg-finish-tracing-display))

	(and (not proof-second-action-list-active)
	     (or (null proof-action-list)
		 (every
		  (lambda (item) (memq 'proof-tree-show-subgoal (nth 3 item)))
		  proof-action-list)))))))

(defun proof-shell-insert-loopback-cmd  (cmd)
  "Insert command string CMD sent from prover into script buffer.
String is inserted at the end of locked region, after a newline
and indentation.  Assumes `proof-script-buffer' is active."
  (unless (string-match "^\\s-*$" cmd)	; FIXME: assumes cmd is single line
    (with-current-buffer proof-script-buffer
      (let (span)
	(proof-goto-end-of-locked)
	(let ((proof-one-command-per-line t)) ; because pbp several commands
	  (proof-script-new-command-advance))
	(insert cmd)
	;; NB: difference between ordinary commands and pbp is that
	;; pbp can return *several* commands, that are treated as
	;; a unit, i.e. sent to the proof assistant together.
	;; FIXME da: this seems very similar to proof-insert-pbp-command
	;; in proof-script.el.  Should be unified, I suspect.
	(setq span (span-make (proof-unprocessed-begin) (point)))
	(span-set-property span 'type 'pbp)
	(span-set-property span 'cmd cmd)
	(proof-set-queue-endpoints (proof-unprocessed-begin) (point))
	(setq proof-action-list
	      (cons (car proof-action-list)
		    (cons (list span cmd 'proof-done-advancing)
			  (cdr proof-action-list))))))))

;;
;; urgent message subroutines
;;

'(defun proof-shell-process-urgent-message-default (start end)
  "A subroutine of `proof-shell-process-urgent-message'."
  ;; Clear the response buffer this time, but not next, leave window.
  (pg-response-maybe-erase nil nil)
  (proof-minibuffer-message
   (buffer-substring-no-properties
    (save-excursion
      (re-search-forward proof-shell-eager-annotation-start end nil)
      (point))
    (min end
	 (save-excursion (end-of-line) (point))
	 (+ start 75))))
  (pg-response-display-with-face
   (proof-shell-strip-eager-annotations start end)
   'proof-eager-annotation-face))

(defun proof-shell-process-urgent-message-trace (start end)
  "Display a message in the tracing buffer.
A subroutine of `proof-shell-process-urgent-message'."
  (proof-trace-buffer-display start end)
  (unless (and proof-trace-output-slow-catchup
	       (pg-tracing-tight-loop))
    (proof-display-and-keep-buffer proof-trace-buffer))
  ;; If user quits during tracing output, send an interrupt
  ;; to the prover.  Helps when Emacs is "choking".
  (if (and quit-flag proof-action-list)
      (proof-interrupt-process)))

(defun proof-shell-process-urgent-message-retract (start end)
  "A subroutine of `proof-shell-process-urgent-message'.
Takes files off `proof-included-files-list' and calls
`proof-restart-buffers' to do the necessary clean-up on those
buffers visting a file that disappears from
`proof-included-files-list'. So in some respect this function is
inverse to `proof-register-possibly-new-processed-file'."
  (let ((current-included proof-included-files-list))
    (setq proof-included-files-list
	  (funcall proof-shell-compute-new-files-list))
    (let ((scrbuf proof-script-buffer))
      ;; NB: we assume that no new buffers are *added* by
      ;; the proof-shell-compute-new-files-list
      (proof-restart-buffers
       (proof-files-to-buffers
	(set-difference current-included
			proof-included-files-list)))
      (cond
       ;; Do nothing if there was no active scripting buffer
       ((not scrbuf))
       ;; Do nothing if active buffer hasn't changed (may be nuked)
       ((eq scrbuf proof-script-buffer))
       ;; Otherwise, active scripting buffer has been retracted.
       (t
	(setq proof-script-buffer nil))))))

(defun proof-shell-process-urgent-message-elisp ()
  "A subroutine of `proof-shell-process-urgent-message'."
  (let
      ((variable   (match-string 1))
       (expr       (match-string 2)))
    (condition-case nil
	(with-temp-buffer
	  (insert expr) ; massive risk from malicious provers!!
	  (set (intern variable) (eval-last-sexp t)))
      (t (proof-debug
	  (concat
	   "lisp error when obeying proof-shell-set-elisp-variable: \n"
	   "setting `" variable "'\n to: \n"
	   expr "\n"))))))

(defun proof-shell-process-urgent-message-thmdeps ()
  "A subroutine of `proof-shell-process-urgent-message'."
  (let ((names   (match-string 1))
	(deps    (match-string 2))
	(sep     proof-shell-theorem-dependency-list-split))
    (setq
     proof-last-theorem-dependencies
     (cons (split-string names sep)
	   (split-string deps sep)))))

(defun proof-shell-process-interactive-prompt-regexp ()
  "Action taken when `proof-shell-interactive-prompt-regexp' is observed."
  (when (and (proof-shell-live-buffer)
	     ; not already visible
	     t)
    (switch-to-buffer proof-shell-buffer)
    (message "Prover expects input in %s buffer" proof-shell-buffer)))

;;
;; urgent message utilities
;;

(defun proof-shell-strip-eager-annotations (start end)
  "Strip `proof-shell-eager-annotation-{start,end}' from region."
  (goto-char start)
  (if (re-search-forward proof-shell-eager-annotation-start end nil)
      (setq start (point)))
  (if (re-search-forward proof-shell-eager-annotation-end end nil)
      (setq end (match-beginning 0)))
  (buffer-substring-no-properties start end))



;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; The proof shell process filter
;;

(defun proof-shell-filter-wrapper (str-do-not-use)
  "Wrapper for `proof-shell-filter', protecting against parallel calls.
In Emacs a process filter function can be called while the same
filter is currently running for the same process, for instance,
when the filter bocks on I/O. This wrapper protects the main
entry point, `proof-shell-filter' against such parallel,
overlapping calls.

The argument STR-DO-NOT-USE contains the most recent output, but
is discarded. `proof-shell-filter' collects the output from
`proof-shell-buffer' (where it is inserted by
`scomint-output-filter'), relieving this function from the task
to buffer the output that arrives during parallel, overlapping
calls."
  (if proof-shell-filter-active
      (progn
	(setq proof-shell-filter-was-blocked t))
    (let ((call-proof-shell-filter t))
      (while call-proof-shell-filter
	(setq proof-shell-filter-active t
	      proof-shell-filter-was-blocked nil)
	(condition-case err
	    (progn
	      (proof-shell-filter)
	      (setq proof-shell-filter-active nil))
	  ((error quit)
	   (setq proof-shell-filter-active nil
		 proof-shell-filter-was-blocked nil)
	   (signal (car err) (cdr err))))
	(setq call-proof-shell-filter proof-shell-filter-was-blocked)))))  


(defun proof-shell-filter-first-command ()
  "Deal with initial output.  A subroutine of `proof-shell-filter'.

This initialises `proof-marker': we set marker to after the first
prompt in the output buffer if one can be found now.

The first time a prompt is seen we ignore any output that occurred
before it, assuming that corresponds to uninteresting startup
messages."
  (goto-char (point-min))
  (if (re-search-forward proof-shell-annotated-prompt-regexp nil t)
      (progn
	(set-marker proof-marker (point))
	(proof-shell-exec-loop))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Despatching output
;;


(defun proof-shell-filter-manage-output (start end)
  "Subroutine of `proof-shell-filter' for output between START and END.

First, we invoke `proof-shell-handle-immediate-output' which classifies
and handles output that must be dealt with immediately.

Other output (user display) is only displayed when the proof
action list becomes empty, to avoid a confusing rapidly changing
output that slows down processing.

After processing the current output, the last step undertaken
by the filter is to send the next command from the queue."
  ;; NOTE: this routine display stuff already in proof action list
  ;; SO for server mode, must have a way to put items in that list
  ;; call a similar routine after processing prover response
  (let ((span  (caar proof-action-list))
	(cmd   (nth 1 (car proof-action-list)))
	(flags (nth 3 (car proof-action-list)))
	(old-proof-marker (marker-position proof-marker)))

    ;; A copy of the last message, verbatim, never modified.
    (setq proof-prover-last-output
	  (buffer-substring-no-properties start end))

    ;; sets proof-prover-last-output-kind
    (proof-shell-handle-immediate-output cmd start end flags)

    (unless proof-prover-last-output-kind ; dealt with already
      (setq proof-shell-delayed-output-start start)
      (setq proof-shell-delayed-output-end end)
      (setq proof-shell-delayed-output-flags flags)
      (if (proof-shell-exec-loop)
	  (setq proof-prover-last-output-kind
		;; only display result for last output
		(proof-shell-handle-delayed-output)))
      ;; send output to the proof tree visualizer
      (if proof-tree-external-display
	  (proof-tree-handle-delayed-output old-proof-marker cmd flags span)))))


(defsubst proof-shell-display-output-as-response (flags str)
  "If FLAGS permit, display response STR; set `proof-shell-last-response-output'."
  (setq proof-shell-last-response-output str) ; set even if not displayed
  (unless (memq 'no-response-display flags)
    (pg-response-display str)))

(defun proof-shell-handle-delayed-output ()
  "Display delayed goals/responses, when queue is stopped or completed.
This function handles the cases of `proof-shell-output-kind' which
are not dealt with eagerly during script processing, namely
'response and 'goals types.

This is useful even with empty delayed output as it will empty
the buffers.

The delayed output is in the region
\[proof-shell-delayed-output-start,proof-shell-delayed-output-end].

If no goals classified output is found, the whole output is
displayed in the response buffer.

If goals output is found, the last matching instance, possibly
bounded by `proof-shell-end-goals-regexp', will be displayed
in the goals buffer (and may be further analysed by Proof General).

Any output that appears *before* the last goals output (but
after messages classified as urgent, see `proof-shell-filter')
will also be displayed in the response buffer.

For example, if OUTPUT has this form:

  MESSSAGE-1
  GOALS-1
  MESSAGE-2
  GOALS-2
  JUNK

then GOALS-2 will be displayed in the goals buffer, and MESSAGE-2
in the response buffer.  JUNK will be ignored.

Notice that the above alternation (and separation of JUNK) can
only be distinguished if both `proof-shell-start-goals-regexp'
and `proof-shell-end-goals-regexp' are set.  With just the start
goals regexp set, GOALS-2 JUNK will appear in the goals buffer
and no response output would occur.
   
The goals and response outputs are copied into
`proof-shell-last-goals-output' and
`proof-shell-last-response-output' respectively.

The value returned is the value for `proof-prover-last-output-kind',
i.e., 'goals or 'response."
  (let ((start proof-shell-delayed-output-start)
	(end   proof-shell-delayed-output-end)
	(flags proof-shell-delayed-output-flags))
  (goto-char start)
  (cond
   ((and proof-shell-start-goals-regexp
	 (proof-re-search-forward proof-shell-start-goals-regexp end t))
     (let* ((gmark  (match-beginning 0)) ; start of goals message
	    (gstart (or (match-end 1)    ; start of actual display
			gmark))
	    (rstart start)		 ; possible response before goals
	    (gend   end)
	    both)			 ; flag for response+goals

       (goto-char gstart)
       (while (re-search-forward proof-shell-start-goals-regexp end t)
	 (setq gmark (match-beginning 0))
	 (setq gstart (or (match-end 1) gmark))
	 (setq gend
	       (if (and proof-shell-end-goals-regexp
			(re-search-forward proof-shell-end-goals-regexp end t))
		   (progn
		     (setq rstart (match-end 0))
		     (match-beginning 0))
		 end)))
       (setq proof-shell-last-goals-output
	     (buffer-substring-no-properties gstart gend))

       ;; FIXME heuristic: 4 allows for annotation in end-goals-regexp [is it needed?]
       (setq both
	     (> (- gmark rstart) 4))
       (if both
	   (proof-shell-display-output-as-response 
	    flags
	    (buffer-substring-no-properties rstart gmark)))
       ;; display goals output second so it persists in 2-pane mode
       (unless (memq 'no-goals-display flags)
	 (pg-goals-display proof-shell-last-goals-output both))
       ;; indicate a goals output has been given
       'goals))

   (t
    (proof-shell-display-output-as-response flags proof-prover-last-output)
    ;; indicate that (only) a response output has been given
    'response))
  
  ;; FIXME (CPC 2015-12-31): The documentation of this hook suggests that it
  ;; only gets run after new output has been displayed, but this isn't true at
  ;; the moment: indeed, it gets run even for invisible commands.
  ;;
  ;; This causes issues in company-coq, where completion uses invisible
  ;; commands to display the types of completion candidates; this causes the
  ;; goals and response buffers to scroll. I fixed it by adding checks to
  ;; coq-mode's hooks, but maybe we should do more.
  (run-hooks 'proof-shell-handle-delayed-output-hook)))




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Tracing slow down: prevent Emacs-consumes-all-CPU-displaying phenomenon
;;

;; Possible improvement: add user-controlled flag to turn on/off display

(defvar pg-last-tracing-output-time (float-time)
  "Time of last tracing output, as recorded by (float-time).")

(defvar pg-last-trace-output-count 0
  "Count up to `pg-slow-mode-trigger-count'.")

(defconst pg-slow-mode-trigger-count 20
  "Number of fast trace messages before turning on slow mode.")

(defconst pg-slow-mode-duration 3
  "Maximum duration of slow mode in seconds.")

(defconst pg-fast-tracing-mode-threshold 500000
  "Minimum microsecond delay between tracing outputs that triggers slow mode.")

(defun pg-tracing-tight-loop ()
  "Return non-nil in case it seems like prover is dumping a lot of output.
This is a performance hack to avoid Emacs consuming CPU when prover is output
tracing information.
Only works when system timer has microsecond count available."
  (let ((tm        (float-time))
	(dontprint pg-tracing-slow-mode))
    (if pg-tracing-slow-mode
	(when ;; seconds differs by more than slow mode max duration
	    (> (- tm pg-last-tracing-output-time) pg-slow-mode-duration)
	  (setq dontprint nil))
      (when ;; time since last tracing output less than threshold
	  (and 
	   (< (- tm pg-last-tracing-output-time) 
	      (/ pg-fast-tracing-mode-threshold 1000000.0))
	   (>= (incf pg-last-trace-output-count) 
	       pg-slow-mode-trigger-count))
	;; quickly consecutive tracing outputs: go into slow mode
	(setq dontprint t)
	(pg-slow-fontify-tracing-hint)))
    ;; return flag for non-printing is new value of slow mode
    (setq pg-last-tracing-output-time tm)
    (setq pg-tracing-slow-mode dontprint)))

(defun pg-finish-tracing-display ()
  "Handle the end of possibly voluminous tracing-style output.
If the output update was slowed down, show it now."
  (proof-trace-buffer-finish)
  (when pg-tracing-slow-mode 
    (proof-display-and-keep-buffer proof-trace-buffer)
    (setq pg-tracing-slow-mode nil))
  (setq pg-last-trace-output-count 0))






;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; proof-shell-invisible-command: for user-level commands.
;;

;;;###autoload
(defun proof-shell-wait (&optional interrupt-on-input timeoutsecs)
  "Busy wait for `proof-shell-busy' to become nil, reading from prover.

Needed between sequences of commands to maintain synchronization,
because Proof General does not allow for the action list to be extended
in some cases.   Also is considerably faster than leaving the Emacs 
top-level command loop to read from the prover.

Called by `proof-shell-invisible-command' and `proof-process-buffer'
when setting `proof-fast-process-buffer' is enabled.

If INTERRUPT-ON-INPUT is non-nil, return if input is received.

If TIMEOUTSECS is a number, time out after that many seconds."
  (let* ((proverproc  (get-buffer-process proof-shell-buffer))
	 (accepttime  0.01)
	 (timecount   (if (numberp timeoutsecs)
			  (/ timeoutsecs accepttime))))
    (when proverproc
      (while (and proof-shell-busy (not quit-flag)
		  (if timecount 
		      (> (setq timecount (1- timecount)) 0)
		    t)
		  (not (and interrupt-on-input (input-pending-p))))
	;; TODO: check below OK on GE 22/23.1.  See Trac #324
	(accept-process-output proverproc accepttime nil 1))
      (redisplay)
      (if quit-flag
	  (error "Proof General: quit in proof-shell-wait")))))

(defun proof-done-invisible (span)
  "Callback for proof-shell-invisible-command.
Calls proof-state-change-hook."
  (run-hooks 'proof-state-change-hook))

;;;###autoload
(defun proof-shell-invisible-command (cmd &optional wait invisiblecallback
					  &rest flags)
  "Send CMD to the proof process.
The CMD is `invisible' in the sense that it is not recorded in buffer.
CMD may be a string or a string-yielding expression.

Automatically add `proof-terminal-string' if necessary, examining
`proof-shell-no-auto-terminate-commands'.

By default, let the command be processed asynchronously.
But if optional WAIT command is non-nil, wait for processing to finish
before and after sending the command.

In case CMD is (or yields) nil, do nothing.

INVISIBLECALLBACK will be invoked after the command has finished,
if it is set.  It should probably run the hook variables
`proof-state-change-hook'.

FLAGS are additional flags to put onto the `proof-action-list'.
The flag 'invisible is always added to FLAGS."
  (unless (stringp cmd)
    (setq cmd (eval cmd)))
  (if cmd
      (progn
	(unless (or (null proof-terminal-string)
		    (not proof-shell-auto-terminate-commands)
		    (string-match (concat
				   (regexp-quote proof-terminal-string)
				   "[ \t]*$") cmd))
	  (setq cmd (concat cmd proof-terminal-string)))
	(if wait (proof-shell-wait))
	(proof-shell-ready-prover)  ; start proof assistant; set vars.
	(let* ((callback
		(if invisiblecallback
		    (lexical-let ((icb invisiblecallback))
		      (lambda (span)
			(funcall icb span)))
		  'proof-done-invisible)))
	  (proof-start-queue nil nil
			     (list (proof-shell-action-list-item
				    cmd
				    callback
				    (cons 'invisible flags)))))
	(if wait (proof-shell-wait)))))

;;;###autoload
(defun proof-shell-invisible-cmd-get-result (cmd)
  "Execute CMD and return result as a string.
This expects CMD to result in some theorem prover output.
Ordinary output (and error handling) is disabled, and the result
\(contents of `proof-prover-last-output') is returned as a string."
  (proof-shell-invisible-command cmd 'waitforit
				 nil
				 'no-response-display
				 'no-error-display)
  proof-prover-last-output)

;;;###autoload
(defun proof-shell-invisible-command-invisible-result (cmd)
  "Execute CMD for side effect in the theorem prover, waiting before and after.
Error messages are displayed as usual."
  (proof-shell-invisible-command cmd 'waitforit
				 nil
				 'no-response-display))




;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; User-level functions depending on shell commands
;;

;;
;; Function to insert last prover output in comment.
;; Requested/suggested by Christophe Raffalli
;;

(defun pg-insert-last-output-as-comment ()
  "Insert the last output from the proof system as a comment in the proof script."
  (interactive)
  (if proof-prover-last-output
      (let  ((beg (point)))
	(insert (proof-shell-strip-output-markup proof-prover-last-output))
	(comment-region beg (point)))))





;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; Proof General shell mode definition
;;

;(eval-and-compile			; to define vars
;;;###autoload
;;
;; Sanity checks on important settings
;;

(defconst proof-shell-important-settings
  '(proof-shell-annotated-prompt-regexp ; crucial
    ))


;;;###autoload
(defun proof-shell-config-done ()
  "Initialise the specific prover after the child has been configured.
Every derived shell mode should call this function at the end of
processing."
  (with-current-buffer proof-shell-buffer

    ;; Give warnings if some crucial settings haven't been made
    (dolist (sym proof-shell-important-settings)
      (proof-warn-if-unset "proof-shell-config-done" sym))

    ;; Set font lock keywords, but turn off by default to save cycles.
    (setq font-lock-defaults '(proof-shell-font-lock-keywords))
    (set (make-local-variable 'font-lock-global-modes)
	 (list 'not proof-mode-for-shell))

    (let ((proc (get-buffer-process proof-shell-buffer)))
      ;; Add the kill buffer function and process sentinel
      (add-hook 'kill-buffer-hook 'proof-shell-kill-function t t)
      (set-process-sentinel proc 'proof-shell-bail-out)

      ;; Pre-sync initialization command.  Necessary for provers which
      ;; change output modes only after some initializations.
      (if proof-shell-pre-sync-init-cmd
	  (proof-shell-insert proof-shell-pre-sync-init-cmd 'init-cmd))

      ;; Flush pending output from startup (it gets hidden from the user)
      ;; while waiting for the prompt to appear
      (while (and (memq (process-status proc) '(open run))
		  (null (marker-position proof-marker)))
	(accept-process-output proc 1))

      (if (memq (process-status proc) '(open run))
	  (progn
	    ;; Also ensure that proof-action-list is initialised.
	    (setq proof-action-list nil)
	    ;; Send main intitialization command and wait for it to be
	    ;; processed.

	    ;; Now send the initialisation commands.
	    (unwind-protect
		(progn
		  (run-hooks 'proof-shell-init-hook)
		  (when proof-shell-init-cmd
		    (if (listp proof-shell-init-cmd)
			(mapc 'proof-shell-invisible-command-invisible-result
				proof-shell-init-cmd)
		      (proof-shell-invisible-command-invisible-result 
		       proof-shell-init-cmd)))
		  (proof-shell-wait)
		  (if proof-assistant-settings
		      (mapcar (lambda (c)
				(proof-shell-invisible-command c t))
			      (proof-assistant-settings-cmds))))))))))


(provide 'proof-shell)

;;; proof-shell.el ends here
