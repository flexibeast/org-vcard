;;; org-vcard.el --- org-mode support for vCard export and import.

;; Copyright (C) 2014  Free Software Foundation, Inc.

;; Author: Alexis <flexibeast@gmail.com>
;; Maintainer: Alexis <flexibeast@gmail.com>
;; Created: 2014-07-31
;; Keywords: outlines, org, vcard
     
;;
;; This file is NOT part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;

;;; Commentary:

;; `org-vcard` is a package for exporting and importing vCards from
;; within Emacs' Org mode.

;; The main user commands are `org-vcard-export` and
;; `org-vcard-import`, which are intended to be called
;; interactively; you can press TAB at many of the minibuffer
;; prompts to get a list of the available options for a prompt.

;; Both `org-vcard-export` and `org-vcard-import `are wrappers
;; around the `org-vcard-transfer-helper` function.
;; `org-vcard-transfer-helper` can be used to export and import
;; programatically (i.e. via Emacs Lisp).

;; Enabling `org-vcard-mode` will add an 'Org-vCard' menu to the menu
;; bar, from which one can access the various export, import and
;; customisation options.

;; This package is working towards full compliance with the
;; vCard specifications:

;; vCard 4.0: https://tools.ietf.org/html/rfc6350
;; vCard 3.0: https://tools.ietf.org/html/rfc2426
;; vCard 2.1: http://www.imc.org/pdi/vcard-21.txt

;; If you find any apparent instances of non-compliance that aren't
;; already noted in the TODO section of the org-vcard README.md
;; document, please let the maintainers know.

;; Differences between 4.0 and 3.0 can be found in Appendix A of
;; RFC6350: https://tools.ietf.org/html/rfc6350#page-73
;; Note that vCard 3.0 'types' became vCard 4.0 'properties'.

;; Differences between 3.0 and 2.1 can be found in Section 5 of
;; RFC2426: https://tools.ietf.org/html/rfc2426#page-37

;; Point of amusement:
;; In section 7 of RFC2426, the authors of the standard don't
;; include the 'N' type in their supposed-version-3.0 vCards.

;; Please refer to the TODO section of the org-vcard README.md
;; document for known limitations and/or issues.
;; 

;;; Code:

(require 'org)

;;
;; Setup.
;;

(defgroup org-vcard nil
  "vCard support for Org mode."
  :group 'org
  :prefix "org-vcard-")

(defconst org-vcard-elisp-dir (file-name-directory load-file-name)
  "Absolute path of the directory containing org-vcard.el.")

(defcustom org-vcard-custom-styles-dir "~/.emacs.d/org-vcard-styles/"
  "The default file to export to."
  :type 'directory
  :group 'org-vcard)

(defvar org-vcard-styles-dirs
  `(,(file-name-as-directory (concat org-vcard-elisp-dir "styles"))
    ,org-vcard-custom-styles-dir)
  "Internal variable; list of directories containing org-vcard styles.")

(defvar org-vcard-active-style ""
  "The currently-active contacts style.")

(defvar org-vcard-active-language ""
  "The currently-active language.")

(defvar org-vcard-active-version ""
  "The currently-active version of vCard.")

(defvar org-vcard-compound-properties '("ADR" "N")
  "List of vCard properties which can have a compound value, i.e.
a value containing multiple components, with each component
separated by a semicolon.")

(defun org-vcard-create-styles-functions ()
  "Function to create a data structure from the contents of
the org-vcard 'styles' directory, suitable for use by
the org-vcard-styles-functions defvar."
  (let ((the-list) '())
    (dolist (style-dir org-vcard-styles-dirs)
      (if (not (file-exists-p style-dir))
          (make-directory style-dir))
      (dolist (style (directory-files style-dir))
        (if (and (not (string= "." (file-name-nondirectory style)))
                 (not (string= ".." (file-name-nondirectory style))))
            (progn
              (load (concat
                     (file-name-as-directory (concat style-dir style))
                     "functions.el"))
              (add-to-list 'the-list
                           `(,(file-name-nondirectory style)
                             ,(list
                               (intern (concat "org-vcard-export-from-" (file-name-nondirectory style)))
                               (intern (concat "org-vcard-import-to-" (file-name-nondirectory style))))))))))
    (sort the-list #'(lambda (a b)
                       (if (string< (car a) (car b))
                           t
                         nil)))))

(defvar org-vcard-styles-functions (org-vcard-create-styles-functions)
    "org-vcard internal variable, containing available styles and
their associated export and import functions.")

(defun org-vcard-create-styles-languages-mappings ()
  "Function to create a data structure from the contents of
the org-vcard 'styles' directory, suitable for use by
the org-vcard-styles-languages-mappings defcustom."
  (let ((style-mappings '()))
    (dolist (style-dir org-vcard-styles-dirs)
      (if (not (file-exists-p style-dir))
          (make-directory style-dir))
      (dolist (style
               ;; Reverse the list so that the repeated calls to
               ;; add-to-list will produce a lexicographically-sorted
               ;; list.
               (sort (directory-files style-dir) #'(lambda (a b)
                                                     (if (not (string< a b))
                                                         t
                                                       nil))))
        (if (and (not (string= "." style))
                 (not (string= ".." style)))
            (progn
              (let ((language-mapping '()))
                (dolist (mapping
                         ;; Reverse the list so that the repeated calls to
                         ;; add-to-list will produce a lexicographically-sorted
                         ;; list.
                         (sort (directory-files
                                (file-name-as-directory
                                 (concat
                                  (file-name-as-directory
                                   (concat style-dir style))
                                  "mappings"))
                                t) #'(lambda (a b)
                                       (if (not (string< a b))
                                           t
                                         nil))))
                  (if (and (not (string= "." (file-name-nondirectory mapping)))
                           (not (string= ".." (file-name-nondirectory mapping))))
                      (progn
                        (add-to-list 'language-mapping
                                     `(,(file-name-nondirectory mapping)
                                       ,@(list (car
                                                (read-from-string
                                                 (with-temp-buffer
                                                   (insert-file-contents-literally mapping)
                                                   (buffer-string))))))))))
                (setq language-mapping (list language-mapping))
                (add-to-list 'style-mappings
                             `(,style
                               ,@language-mapping)))))))
    style-mappings))

(defcustom org-vcard-styles-languages-mappings (org-vcard-create-styles-languages-mappings)
  "Details of the available styles and their associated mappings."
  :type '(repeat (list string (repeat (list string (repeat (list string (repeat (cons string string))))))))
  :group 'org-vcard)

(defcustom org-vcard-default-export-file "~/org-vcard-export.vcf"
  "The default file to export to."
  :type 'file
  :group 'org-vcard)

(defcustom org-vcard-default-import-file "~/org-vcard-import.vcf"
  "The default file to import from."
  :type 'file
  :group 'org-vcard)

(defcustom org-vcard-include-import-unknowns nil
  "Whether the import process should include vCard properties not
listed in the mapping being used."
  :type 'boolean
  :group 'org-vcard)

(defcustom org-vcard-append-to-existing-import-buffer t
  "Whether the import process should append to any existing import
buffer. If not, create a new import buffer per import."
  :type 'boolean
  :group 'org-vcard)

(defcustom org-vcard-remove-external-semicolons nil
  "Whether the import process should remove any leading and/or
trailing semicolons from properties with compound values.

NB! Since the components of compound values are positional,
removing such semicolons will change the meaning of the value
if/when it is subsequently exported to vCard. If in doubt, leave
this set to nil."
  :type 'boolean
  :group 'org-vcard)

(defcustom org-vcard-character-set-mapping '(("Big5" . big5)
                                             ("EUC-JP" . euc-jp)
                                             ("EUC-KR" . euc-kr)
                                             ("GB2312" . gb2312)
                                             ("ISO-2022-JP" . iso-2022-jp)
                                             ("ISO-2022-JP-2" . iso-2022-jp-2)
                                             ("ISO-2022-KR" . iso-2022-kr)
                                             ("ISO-8859-1" . iso-8859-1)
                                             ("ISO-8859-2" . iso-8859-2)
                                             ("ISO-8859-3" . iso-8859-3)
                                             ("ISO-8859-4" . iso-8859-4)
                                             ("ISO-8859-5" . iso-8859-5)
                                             ("ISO-8859-6" . iso-8859-6)
                                             ("ISO-8859-6-E" . iso-8859-6-e)
                                             ("ISO-8859-6-I" . iso-8859-6-i)
                                             ("ISO-8859-7" . iso-8859-7)
                                             ("ISO-8859-8" . iso-8859-8)
                                             ("ISO-8859-8-E" . iso-8859-8-e)
                                             ("ISO-8859-8-I" . iso-8859-8-i)
                                             ("ISO-8859-9" . iso-8859-9)
                                             ("ISO-8859-10" . iso-8859-10)
                                             ("KOI8-R" . koi8-r)
                                             ("Shift_JIS" . shift_jis)
                                             ("US-ASCII" . us-ascii)
                                             ("UTF-8" . utf-8)
                                             ("UTF-16" . utf-16))
  "Association list, mapping IANA MIME names for character sets to
Emacs coding systems.

Derived from:
http://www.iana.org/assignments/character-sets/character-sets.xhtml"
  :type '(repeat (cons string symbol))
  :group 'org-vcard)

(defcustom org-vcard-default-vcard-21-character-set 'us-ascii
  "Value of the vCard 2.1 CHARSET modifier which will be applied to
all vCard properties when exporting to vCard 2.1."
  :type `(radio ,@(mapcar #'(lambda (entry)
                               `(const :tag ,(car entry) ,(cdr entry)))
                           org-vcard-character-set-mapping))
  :group 'org-vcard)

;; The in-buffer setting #+CONTACT_STYLE.

(defcustom org-vcard-default-style "flat"
  "Default contact style to use.
Initially set to \"flat\"."
  :type 'string
  :group 'org-vcard)

;; The in-buffer setting #+CONTACT_LANGUAGE.

(defcustom org-vcard-default-language "en"
  "Default language to use.
Initially set to \"en\"."
  :type 'string
  :group 'org-vcard)

;; The in-buffer setting #+VCARD_VERSION;
;; can be "4.0", "3.0" or "2.1".

(defcustom org-vcard-default-version "4.0"
  "Default version of the vCard standard to use.
Initially set to 4.0."
  :type '(radio (const "4.0") (const "3.0") (const "2.1"))
  :group 'org-vcard)


;;
;; org-vcard-mode setup
;;


(defconst org-vcard-mode-keymap (make-sparse-keymap))

(define-minor-mode org-vcard-mode
  "Toggle org-vcard mode.

Interactively with no argument, this command toggles the mode.
A positive prefix argument enables the mode, any other prefix
argument disables it.  From Lisp, argument omitted or nil enables
the mode, `toggle' toggles the state.

When org-vcard mode is enabled, an Org-vCard entry is added
to Emacs' menu bar."
      nil                     ; The initial value.
      nil                     ; The indicator for the mode line.
      org-vcard-mode-keymap ; The minor mode bindings.
      :group 'org-vcard)


;;
;; Utility functions.
;;


(defun org-vcard-check-contacts-styles ()
  "Utility function to check integrity of org-vcard-contacts-styles
variable."
  (let ((styles '()))
    (dolist (style org-vcard-styles-functions)
      (if (not (member (car style) styles))
          (setq styles (append styles `(,(car style))))
        (error (concat "Style '" (cadr style) "' appears more than once in org-vcards-contacts-styles")))
      (if (not (functionp (nth 0 (cadr style))))
          (error (concat "Style '" (car style) "' has an invalid export function")))
      (if (not (functionp (nth 1 (cadr style))))
          (error (concat "Style '" (car style) "' has an invalid import function"))))))


(defun org-vcard-escape-value-string (characters value)
  "Utility function to escape each instance of each character
specified in CHARACTERS.

CHARACTERS must be a list of strings. VALUE is the string to be
escaped."
  (if (member "\134" characters)
      ;; Process backslashes first.
      (setq value (replace-regexp-in-string "\134\134" "\134\134" value nil t)))
  (dolist (char characters)
    (if (not (string= "\134" char))
        ;; We're escaping a non-backslash character.
        (setq value (replace-regexp-in-string char (concat "\134" char) value nil t))))
  value)


(defun org-vcard-export-line (property value &optional noseparator)
  "Utility function to ensure each line is exported as appropriate
for each vCard version.

PROPERTY is the vCard property/type to output, VALUE its value.
If NOSEPARATOR is non-nil, don't output colon to separate PROPERTY
from VALUE."
  (let ((separator ":")
        (property-name (progn
                         (string-match "^[^;:]+" property)
                         (match-string 0 property))))
    (if noseparator
        (setq separator ""))
    (cond
     ((string= org-vcard-active-version "4.0")
      ;; In values, escape commas, semicolons and backslashes.
      ;; End line with U+000D U+000A.
      ;; Output must be UTF-8.
      (encode-coding-string (concat
                             property
                             separator
                             (if (not (member property-name org-vcard-compound-properties))
                                 (org-vcard-escape-value-string '("," ";" "\134") value)
                               (org-vcard-escape-value-string '("," "\134") value))
                             "\u000D\u000A")
                            'utf-8))
     ((string= org-vcard-active-version "3.0")
      ;; In values, escape commas and semicolons.
      ;; End line with CRLF.
      ;; RFC2426 doesn't seem to mandate an encoding, so output UTF-8.
      (encode-coding-string (concat
                             property
                             separator
                             (if (not (member property-name org-vcard-compound-properties))
                                 (org-vcard-escape-value-string '("," ";") value)
                               (org-vcard-escape-value-string '(",") value))
                             "\015\012")
                            'utf-8))
     ((string= org-vcard-active-version "2.1")
      ;; In values, escape semicolons.
      ;; End line with CRLF.
      ;; Output ASCII.
      (concat
       (encode-coding-string property 'us-ascii)
       (unless (or (string= "BEGIN" property)
                   (string= "VERSION" property)
                   (string= "END" property))
         (encode-coding-string (concat ";CHARSET=" (car (rassoc org-vcard-default-vcard-21-character-set org-vcard-character-set-mapping))) 'us-ascii))
       (encode-coding-string separator 'us-ascii)
       (if (not (member property-name org-vcard-compound-properties))
           (encode-coding-string (org-vcard-escape-value-string '(";") value) org-vcard-default-vcard-21-character-set)
         (encode-coding-string value org-vcard-default-vcard-21-character-set))
       (encode-coding-string "\015\012" 'us-ascii))))))


(defun org-vcard-set-active-settings ()
  "Utility function to set active settings based on value of last
instance of in-buffer setting; fall back to value of custom
variables."
  (save-excursion
    (goto-char (point-min))
    (let* ((valid-styles (mapcar 'car org-vcard-styles-functions))
           (valid-languages '("en" "en_AU" "en_US"))
           (valid-versions '("4.0" "3.0" "2.1"))
           (found-keywords '()))
      (while (not (eobp))
        (if (looking-at "^#+")
            (let ((this-line (org-element-keyword-parser nil nil)))
              (when (eq 'keyword (car this-line))
                (cond
                 ((string= "CONTACTS_STYLE" (plist-get (cadr this-line) :key))
                  (if (member (plist-get (cadr this-line) :value) valid-styles)
                      (progn
                        (setq org-vcard-active-style (plist-get (cadr this-line) :value))
                        (setq found-keywords (append found-keywords '("CONTACTS_STYLE"))))
                    (error "Invalid in-buffer setting for CONTACTS_STYLE")))
                 ((string= "CONTACTS_LANGUAGE" (plist-get (cadr this-line) :key))
                  (if (member (plist-get (cadr this-line) :value) valid-languages)
                      (progn
                        (setq org-vcard-active-language (plist-get (cadr this-line) :value))
                        (setq found-keywords (append found-keywords '("CONTACTS_LANGUAGE"))))
                    (error "Invalid in-buffer setting for CONTACTS_LANGUAGE")))
                 ((string= "VCARD_VERSION" (plist-get (cadr this-line) :key))
                  (if (member (plist-get (cadr this-line) :value) valid-versions)
                      (progn
                        (setq org-vcard-active-version (plist-get (cadr this-line) :value))
                        (setq found-keywords (append found-keywords '("VCARD_VERSION"))))
                    (error "Invalid in-buffer setting for VCARD_VERSION")))))))
        (forward-line))
      (cond
       ((not (member "CONTACTS_STYLE" found-keywords))
        (setq org-vcard-active-style org-vcard-default-style))
       ((not (member "CONTACTS_LANGUAGE" found-keywords))
        (setq org-vcard-active-language org-vcard-default-language))
       ((not (member "VCARD_VERSION" found-keywords))
        (setq org-vcard-active-version org-vcard-default-version))))))


(defun org-vcard-canonicalise-email-property (property-name)
  "Internal function to canonicalise a vCard EMAIL property, intended
to be called by the org-vcard-canonicalise-property-name function.

PROPERTY-NAME must be a string containing a vCard property name."
  (let ((property-canonicalised "EMAIL")
        (property-type-data '())
        (case-fold-search t))
    (if (string-match "HOME" property-name)
        (cond
         ((string= "4.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("home"))))
         ((string= "3.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("home"))))
         ((string= "2.1" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '(";HOME"))))))
    (if (string-match "WORK" property-name)
        (cond
         ((string= "4.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("work"))))
         ((string= "3.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("work"))))
         ((string= "2.1" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '(";WORK"))))))
    `(,property-canonicalised ,property-type-data)))


(defun org-vcard-canonicalise-tel-property (property-name)
  "Internal function to canonicalise a vCard TEL property, intended
to be called by the org-vcard-canonicalise-property-name functionon.

PROPERTY-NAME must be a string containing a vCard property name."
  (let ((property-canonicalised "TEL")
        (property-type-data '())
        (case-fold-search t))
    (if (string-match "CELL" property-name)
        (cond
         ((string= "4.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("cell"))))
         ((string= "3.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("cell"))))
         ((string= "2.1" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '(";CELL"))))))
    (if (string-match "FAX" property-name)
        (cond
         ((string= "4.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("fax"))))
         ((string= "3.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("fax"))))
         ((string= "2.1" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '(";FAX"))))))
    ;; Assume the TEL is for VOICE if other qualifiers
    ;; don't specify otherwise.
    (if (and (not (string-match "CELL" property-name))
             (not (string-match "FAX" property-name))
             (not (string-match "MSG" property-name)))
        (cond
         ((string= "4.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("voice"))))
         ((string= "3.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("voice"))))
         ((string= "2.1" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '(";VOICE"))))))
    (if (string-match "HOME" property-name)
        (cond
         ((string= "4.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("home"))))
         ((string= "3.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("home"))))
         ((string= "2.1" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '(";HOME"))))))
    (if (string-match "WORK" property-name)
        (cond
         ((string= "4.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("work"))))
         ((string= "3.0" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '("work"))))
         ((string= "2.1" org-vcard-active-version)
          (setq property-type-data (append property-type-data
                                           '(";WORK"))))))
      `(,property-canonicalised ,property-type-data)))


(defun org-vcard-canonicalise-property-name (property-name)
  "Canonicalise a vCard property name to enable it to be looked up in
an org-vcard mapping.

PROPERTY-NAME must be a string containing the vCard property name."
  (if (not (string-match ";" property-name))
      ;; No need to do anything, return property-name unchanged.
      property-name
    ;; Property has qualifiers.
    (if (or (and (not (string-match "^EMAIL" property-name))
                 (not (string-match "^TEL" property-name)))
            (and (string-match "^TEL" property-name)
                 (string-match "PAGER" property-name)))
        ;; We currently only canonicalise the EMAIL and TEL properties,
        ;; and don't handle the PAGER type within the latter, so
        ;; return property-name unchanged when not dealing with
        ;; EMAIL or TEL, or when dealing with PAGER.
        property-name
      ;; Canonicalise.
      (let* ((property-canonicalised "")
             (property-type-data '())
             (retval '())
             (case-fold-search t)
             (preferred (if (string-match "PREF" property-name)
                            t
                          nil)))
        (cond
         ((string-match "^EMAIL" property-name)
          (progn 
            (setq retval (org-vcard-canonicalise-email-property property-name))
            (setq property-canonicalised (car retval))
            (setq property-type-data (cadr retval))))
         ((string-match "^TEL" property-name)
          (progn 
            (setq retval (org-vcard-canonicalise-tel-property property-name))
            (setq property-canonicalised (car retval))
            (setq property-type-data (cadr retval)))))
        (cond
         ((string= "4.0" org-vcard-active-version)
          (progn
            (if property-type-data
                (progn
                  (setq property-canonicalised (concat property-canonicalised
                                                       ";TYPE=\""))
                  (let ((processed-one nil))
                    (dolist (type property-type-data)
                      (if processed-one
                          (setq property-canonicalised (concat property-canonicalised "," type))
                        (progn
                          (setq property-canonicalised (concat property-canonicalised type))
                          (setq processed-one t)))))
                  (setq property-canonicalised (concat property-canonicalised
                                                       "\""))))
            (if preferred
                (setq property-canonicalised (concat property-canonicalised
                                                     ";PREF=1")))))
         ((string= "3.0" org-vcard-active-version)
          (progn
            (if property-type-data
                (progn
                  (setq property-canonicalised (concat property-canonicalised
                                                 ";TYPE="))
                  (let ((processed-one nil))
                    (dolist (type property-type-data)
                      (if processed-one
                          (setq property-canonicalised (concat property-canonicalised "," type))
                        (progn
                          (setq property-canonicalised (concat property-canonicalised type))
                          (setq processed-one t)))))))
            (if preferred
                (if property-type-data
                    (setq property-canonicalised (concat property-canonicalised
                                                         ",pref"))
                  (setq property-canonicalised (concat property-canonicalised
                                                       ";TYPE=pref"))))))
         ((string= "2.1" org-vcard-active-version)
          (progn
            (dolist (type property-type-data)
              (setq property-canonicalised (concat property-canonicalised type)))
            (if preferred
                (setq property-canonicalised (concat property-canonicalised ";PREF"))))))
        property-canonicalised))))


(defun org-vcard-import-parser (source)
  "Utility function to read from SOURCE and return a list of
vCards, each in the form of a list of cons cells, with each
cell containing the vCard property in the car, and the value
of that property in the cdr.

SOURCE must be one of \"file\", \"buffer\" or \"region\"."
  (let ((current-line nil)
        (property "")
        (value "")
        (cards '())
        (current-card '()))
    (cond
     ((string= "file" source)
      (find-file (read-from-minibuffer "Filename? " org-vcard-default-import-file)))
     ((string= "region" source)
      (narrow-to-region (region-beginning) (region-end)))
     ((string= "buffer" source)
      t)
     (t
      (error "Invalid source type")))
    (goto-char (point-min))
    (setq case-fold-search t)
    (while (re-search-forward "BEGIN:VCARD" (point-max) t)
      (setq current-card '())
      (forward-line)
      (while (not (looking-at "END:VCARD"))
        (setq current-line
              (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
        (string-match "\\([^:]+\\): *\\(.*?\\)\\(?:\u000D\\|\015\\)?$" current-line)
        (setq property (match-string 1 current-line))
        (setq value (match-string 2 current-line))
        (if (string-match ";CHARSET=\\([^;:]+\\)" property)
            (let ((encoding (match-string 1 property)))
              (setq property (replace-regexp-in-string ";CHARSET=[^;:]+" "" property))
              (cond
               ((or (string= "4.0" org-vcard-active-version)
                    (string= "3.0" org-vcard-active-version))
                ;; vCard 4.0 mandates UTF-8 as the only possible encoding,
                ;; and 3.0 mandates encoding not per-property, but via the
                ;; CHARSET parameter on the containing MIME object. So we
                ;; just ignore the presence and/or value of the CHARSET
                ;; modifier in 4.0 and 3.0 contexts.
                t)
               ((string= "2.1" org-vcard-active-version)
                (setq value (string-as-multibyte
                             (encode-coding-string
                              value
                              (cdr (assoc encoding org-vcard-character-set-mapping)))))))))
        (setq property (org-vcard-canonicalise-property-name property))
        (setq current-card (append current-card (list (cons property value))))
        (forward-line))
      (setq cards (append cards (list current-card))))
   cards))


(defun org-vcard-write-to-destination (content destination)
  "Utility function to write CONTENT to DESTINATION.

CONTENT must be a string. DESTINATION must be either \"buffer\" or \"file\"."
  (if (not (stringp content))
      (error "Received non-string as CONTENT"))
  (cond
   ((string= "buffer" destination)
    (progn
      (generate-new-buffer "*org-vcard-export*")
      (set-buffer "*org-vcard-export*")
      (insert (string-as-multibyte content))))
   ((string= "file" destination)
    (let ((filename (read-from-minibuffer "Filename? " org-vcard-default-export-file)))
        (with-temp-buffer
          (insert (string-as-multibyte content))
          (when (file-writable-p filename)
            (write-region (point-min)
                          (point-max)
                          filename)))))
   (t
    (error "Invalid destination type"))))


(defun org-vcard-transfer-helper (source destination style language version direction)
  "Utility function via which other functions can dispatch export
and import requests to the appropriate functions.

Appropriate values for SOURCE and DESTINATION are determined by
the functions called. Appropriate values for STYLE and VERSION are
determined by the contents of the org-vcard-contacts-styles-mappings
variable. DIRECTION must be either the symbol 'export or the symbol
'import."
  (let ((position nil))
    (org-vcard-check-contacts-styles)
    (setq org-vcard-active-style style)
    (setq org-vcard-active-language language)
    (setq org-vcard-active-version version)
    (cond
     ((eq 'export direction)
      (setq position 0))
     ((eq 'import direction)
      (setq position 1))
     (t
      (error "Invalid direction type")))
    (dolist (style org-vcard-styles-functions)
      (if (string= (car style) org-vcard-active-style)
          (funcall (nth position (cadr style)) source destination)))))


;;
;; User-facing commands for export and import.
;;


;;;###autoload
(defun org-vcard-export (source destination)
  "User command to export to vCard.

Only intended for interactive use."
  (interactive (list
                (completing-read "Source: " '("buffer" "region" "subtree"))
                (completing-read "Destination: " '("file" "buffer"))))
  (let ((style "")
        (language "")
        (version ""))
    (setq style (completing-read "Style: " (mapcar 'car org-vcard-styles-functions)))
    (setq language (completing-read "Language: " (mapcar 'car (cadr (assoc style org-vcard-styles-languages-mappings)))))
    (setq version (completing-read "Version: " (mapcar 'car (cadr (assoc language (cadr (assoc style org-vcard-styles-languages-mappings)))))))
    (org-vcard-transfer-helper source destination style language version 'export)))


;;;###autoload
(defun org-vcard-import (source destination)
  "User command to import from vCard.

Only intended for interactive use."
  (interactive (list
                (completing-read "Source: " '("file" "buffer" "region"))
                (completing-read "Destination: " '("file" "buffer"))))
  (let ((style "")
        (language "")
        (version ""))
    (setq style (completing-read "Style: " (mapcar 'car org-vcard-styles-functions)))
    (setq language (completing-read "Language: " (mapcar 'car (cadr (assoc style org-vcard-styles-languages-mappings)))))
    (setq version (completing-read "Version: " (mapcar 'car (cadr (assoc language (cadr (assoc style org-vcard-styles-languages-mappings)))))))
    (org-vcard-transfer-helper source destination style language version 'import)))


;;;###autoload
(defun org-vcard-export-via-menu (style language version)
  "User command for exporting to vCard via Emacs' menu bar."
  (let ((source nil)
        (destination nil))
    (setq source (completing-read "Source: " '("buffer" "region" "subtree")))
    (setq destination (completing-read "Destination: " '("file" "buffer")))
    (org-vcard-transfer-helper source destination style language version 'export)))


;;;###autoload
(defun org-vcard-import-via-menu (style language version)
  "User command for importing from vCard via Emacs' menu bar."
  (let ((source nil)
        (destination nil))
    (setq source (completing-read "Source: " '("file" "buffer" "region")))
    (setq destination (completing-read "Destination: " '("file" "buffer")))
    (org-vcard-transfer-helper source destination style language version 'import)))


(defun org-vcard-create-org-vcard-mode-menu ()
  "Internal function to create or recreate the org-vcard-mode menu."
  (easy-menu-define org-vcard-menu org-vcard-mode-keymap "Menu bar entry for org-vcard"
    `("Org-vCard"
      ,(let ((export '("Export")))
         (let ((style-list '()))
           (dolist (style (sort (mapcar 'car org-vcard-styles-languages-mappings) 'string<))
             (setq style-list (list (concat "from " style)))
             (let ((language-list '()))
               (dolist (language (sort (mapcar 'car (cadr (assoc style org-vcard-styles-languages-mappings))) 'string<))
                 (setq language-list (list language))
                 (let ((version-list '()))
                   (dolist (version (sort (mapcar 'car (cadr (assoc language (cadr (assoc style org-vcard-styles-languages-mappings))))) 'string<))
                     (setq version-list (append version-list
                                                (list (vector
                                                       (concat "to vCard " version)
                                                       `(org-vcard-export-via-menu ,style ,language ,version) t)))))
                   (setq language-list (append language-list version-list)))
                 (setq style-list (append style-list `(,language-list)))))
             (setq export (append export `(,style-list)))))
         export)
      ,(let ((import '("Import")))
         (let ((style-list '()))
           (dolist (style (sort (mapcar 'car org-vcard-styles-languages-mappings) 'string<))
             (setq style-list (list (concat "to " style)))
             (let ((language-list '()))
               (dolist (language (sort (mapcar 'car (cadr (assoc style org-vcard-styles-languages-mappings))) 'string<))
                 (setq language-list (list language))
                 (let ((version-list '()))
                   (dolist (version (sort (mapcar 'car (cadr (assoc language (cadr (assoc style org-vcard-styles-languages-mappings))))) 'string<))
                     (setq version-list (append version-list
                                                (list (vector
                                                       (concat "from vCard " version)
                                                       `(org-vcard-import-via-menu ,style ,language ,version) t)))))
                   (setq language-list (append language-list version-list)))
                 (setq style-list (append style-list `(,language-list)))))
             (setq import (append import `(,style-list)))))
         import)
      ["Customize" (customize-group 'org-vcard) t])))

(org-vcard-create-org-vcard-mode-menu)


;;
;; User-facing general commands.
;;


(defun org-vcard-reload-styles ()
  "Reload the styles listed in the org-vcard 'styles' directory."
  (interactive)
  (setq org-vcard-styles-functions (org-vcard-create-styles-functions))
  (setq org-vcard-styles-languages-mappings (org-vcard-create-styles-languages-mappings))
  (org-vcard-create-org-vcard-mode-menu))


;; --

(provide 'org-vcard)

;;; org-vcard.el ends here
