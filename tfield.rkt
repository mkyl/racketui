#lang racket

(require racket/block
         racket/draw
         file/convertible
         net/base64
         xml
         (only-in srfi/13 string-trim-both)
         (for-syntax syntax/parse)
         (prefix-in 2htdp: 2htdp/image)
         )

#| 
  A "tfield" represents the specification and input data for a web field of
  some type of data (number, string, boolean, etc.). The types of data are
  intended to match those used in the HtDP student languages. Currently, the
  following types of fields are represented:

    constant (value of any type)
    boolean
    number
    string (empty/non-empty)
    symbol
    file   (intended to work with 2htdp/batch-io teachpack)
    image  (intended to work with 2htdp/image teachpack)
    structure (must be #:transparent, because of use of struct->vector)
    one-of (union of types)
    list-of
    function
|#


;; TODO: clean up tfield/struct case of value->tfield -- several weird things
;;       there to account for apparent BSL behavior with structs ???


#|
Implementation Notes and Subtleties:

 For tfield/file, the following procedures create a new temporary file
 upon successful execution:
   - value->tfield
   - parse (if given bytes? file content -- see LOOKUP-FUNC below)
 The following delete the temporary file upon execution:
   - clear
 The following attempt to create and delete files in the current directory:
   - materialize-input-files
   - purge-input-files
   These two are called from extract&apply-args.

 For tfield/file, if file-name is a string but temp-path is #f, it indicates
 that at upload is in progress, or at least was initiated at some point.

 For tfield/function, an attempt is made to apply the function in the
 following procedures/circumstances:
   - TODO.... (list out) .....
|#

;;=============================================================================
;;=============================================================================
;;=============================================================================

; STRUCTURE DEFINITIONS

; tfield : (U #f string) string (U #f xexpr)
(struct tfield (label name error) #:transparent)   
;; label is what is visible on the web form, 
;; name is used for form input elements

; TODO: add (listof procedure) <---- guard functions
; TODO: once guard predicates are added, possibly collapse
;       tfield/boolean, /number, /string, /symbol
;       into a single tfield/basic representation

(struct tfield/const tfield (value) #:transparent)
(struct tfield/boolean tfield (value) #:transparent)
(struct tfield/number tfield (value raw-value) #:transparent)
(struct tfield/string tfield (value non-empty?) #:transparent)
(struct tfield/symbol tfield (value) #:transparent)
(struct tfield/image tfield (mime-type data) #:transparent)
(struct tfield/struct tfield (constr args) #:transparent)
(struct tfield/oneof tfield (options chosen) #:transparent)
(struct tfield/listof tfield (base elts non-empty?) #:transparent)
(struct tfield/file tfield (file-name mime-type temp-path) #:transparent)
(struct tfield/function tfield (text func args result) #:transparent)
;; label of the function to be used as page title/header when rendered

;;=============================================================================
;;=============================================================================
;;=============================================================================

;; CONSTRUCTORS (and related defs)

; Two utility functions to manage the generation of unique names for 
; form input elements...
; 
; gen-new-name : -> string
; reset-name-counter : number -> void
(define-values (gen-new-name reset-name-counter)
  (let ([next-id 0])
    (values
     (λ() 
       (define new-name (format "tfield-~a" next-id))
       (set! next-id (add1 next-id))
       new-name)
     (λ(n)
       (set! next-id n)))))

; A macro to help generate derived constructors for sub-tfields
(define-syntax (derive-tfield-constructor stx)
  (define-syntax-class arg-spec
    (pattern id:identifier #:with decl #'id)
    (pattern (id:identifier defval) #:with decl #'[id defval]))
  
  (syntax-parse stx
                [(derive-tfield-constructor subtype a:arg-spec ...)
                 #`(λ(label a.decl ... 
                            #:name [name (gen-new-name)] 
                            #:error [error #f])
                     (subtype label name error a.id ...))]
                
                [(derive-tfield-constructor subtype a:arg-spec ... 
                                            (~datum #:check) guard-func)
                 #`(λ(label a.decl ... 
                            #:name [name (gen-new-name)] 
                            #:error [err #f])
                     (define t (subtype label name err a.id ...))
                     (if (guard-func t) t
                         (error "Check failed on constructor:" 
                                (object-name subtype))))]
                ))


; This is the base constructor
(define (new-tfield label                               ;;; (U #f string)
                    #:name [name (gen-new-name)]        ;;; string
                    #:error [error #f])                 ;;; (U #f xexpr)
  (tfield label name error))

; every constructor has signature :
;   (new-tfield/xyz label <additional-params ...>  #:name <...> #:error <...>)
; where label : #f or string, name : string, error : xexpr

(define new-tfield/const
  (derive-tfield-constructor tfield/const value))
(define new-tfield/number
  (derive-tfield-constructor tfield/number [value #f] [raw-value #f]))
(define new-tfield/string 
  (derive-tfield-constructor tfield/string [value #f] [non-empty? #f]))
(define new-tfield/symbol
  (derive-tfield-constructor tfield/symbol [value #f]))
(define new-tfield/image
  (derive-tfield-constructor tfield/image [mime-type #f] [data #f]))
(define new-tfield/boolean 
  (derive-tfield-constructor tfield/boolean [value #f]))
(define new-tfield/struct
  (let ([check (λ(tf)  ; hack to try to verify that structure is #:transparent
                 (define c (tfield/struct-constr tf))
                 (define a (tfield/struct-args tf))
                 (and (procedure? c) (list? a)
                      (= (procedure-arity c) (length a))
                      (struct? (apply c a))))])
    (derive-tfield-constructor tfield/struct constr args #:check check)))
(define new-tfield/oneof
  (derive-tfield-constructor tfield/oneof options [chosen #f]))
(define new-tfield/listof
  (derive-tfield-constructor tfield/listof base [elts empty] [non-empty? #f]))
(define new-tfield/file
  (derive-tfield-constructor tfield/file
                             [file-name #f] [mime-type #f] [temp-path #f]))
(define new-tfield/function  ; label is title
  (derive-tfield-constructor tfield/function text func args result))


;;=============================================================================
;;=============================================================================
;;=============================================================================

;; TEMPLATE FOR TFIELD FUNCS
#;
(define (tfield-func tf ...)
  (match tf
    [(tfield/const label name error value)
     #f]
    [(tfield/boolean label name error value)
     #f]
    [(tfield/number label name error value raw-value)
     #f]
    [(tfield/symbol label name error value)
     #f]
    [(tfield/string label name error value non-empty?)
     #f]
    [(tfield/image label name error mime-type data)
     #f]
    [(tfield/file label name error file-name mime-type temp-path)
     #f]
    [(tfield/struct label name error constr args)
     #f]
    [(tfield/oneof label name error options chosen)
     #f]
    [(tfield/listof label name error base elts non-empty?)
     #f]
    [(tfield/function title name error text func args result)
     #f]
    [_ (error (object-name tfield-func)
              (format "somehow got an unknown field type: ~a" tf))]))



;;=============================================================================
;;=============================================================================
;;=============================================================================

; true? : any -> boolean
; guarantees the result is a boolean #t or #f
(define (true? v) 
  (not (false? v)))

; any-error? : tfield -> boolean
; determine if the tfield or any of its subcomponent tfields contain an error

(define (any-error? tf)
  (match tf
    [(tfield/const label name error value)
     (true? error)]
    [(tfield/number label name error value raw-value)
     (true? error)]
    [(tfield/string label name error value non-empty?)
     (true? error)]
    [(tfield/symbol label name error value)
     (true? error)]
    [(tfield/boolean label name error value)
     (true? error)]
    [(tfield/image label name error mime-type data)
     (true? error)]
    [(tfield/file label name error file-name mime-type temp-path)
     (true? error)]
    [(tfield/struct label name error constr args)
     (or (true? error)
         (ormap any-error? args))]
    [(tfield/oneof label name error options chosen)
     (or (true? error)
         (and chosen
              (<= chosen (length options))
              (any-error? (list-ref options chosen))))]
    [(tfield/listof label name error base elts non-empty?)
     (or (true? error)
         (ormap any-error? elts))]
    [(tfield/function title name error text func args result)
     (or (true? error)
         (ormap any-error? args))]
    [_ (error (object-name any-error?)
              (format "somehow got an unknown field type: ~a" tf))]))


;;=============================================================================
;;=============================================================================
;;=============================================================================

; clear : tfield [boolean] -> tfield
; clears out any user-entered values (or function results) and error in the field
; if finalize? is #t:
;   * for tfield/file, if the temp-path file exists, it will be deleted

(define (clear tf [finalize? #t])
  (match tf
    [(tfield/const label name error value)
     tf]
    [(tfield/number label name error value raw-value)
     (tfield/number label name #f #f #f)]
    [(tfield/string label name error value non-empty?)
     (tfield/string label name #f #f non-empty?)]
    [(tfield/symbol label name error value)
     (tfield/symbol label name #f #f)]
    [(tfield/boolean label name error value)
     (tfield/boolean label name #f #f)]
    [(tfield/image label name error mime-type data)
     (tfield/image label name #f #f #f)]
    [(tfield/file label name error file-name mime-type temp-path)
     (when (and finalize? temp-path (file-exists? temp-path))
       ;;;(printf "deleting ~a\n" temp-path)   ;; <<----- should be logged!!!
       (delete-file temp-path))
     (tfield/file label name #f #f #f #f)]
    [(tfield/struct label name error constr args)
     (tfield/struct label name #f constr 
                    (map (λ(a) (clear a finalize?)) args))]
    [(tfield/oneof label name error options chosen)
     (tfield/oneof label name #f 
                   (map (λ(a) (clear a finalize?)) options) #f)]
    [(tfield/listof label name error base elts non-empty?)
     (when finalize? (map clear elts))  
     (tfield/listof label name #f (clear base finalize?) empty non-empty?)]
                    ;; should this really clear base???
                    ;; well base should really be cleared to begin with,
                    ;; maybe a TODO: ensure constructor for tfield/listof
                    ;;  clear's base upon initialization
                    ;;(map clear elts))]
    [(tfield/function title name error text func args result)
     (tfield/function title name #f text func
                      (map (λ(a) (clear a finalize?)) args)
                      (clear result finalize?))]
    [_ (error (object-name clear)
              (format "somehow got an unknown field type: ~a" tf))]))



;;=============================================================================
;;=============================================================================
;;=============================================================================

; tfield-filled? : tfield -> boolean
; determine if all data values are filled in and valid in the tfield

(define (filled? tf)
  (match tf
    [(or (tfield/const label name error value) 
         (tfield/boolean label name error value))  #t]    
    [(tfield/number label name error value raw-value) (number? value)]
    [(tfield/symbol label name error value) (symbol? value)]
    
    [(tfield/string label name error value non-empty?)
     (and (string? value)
          (not (and non-empty? (string=? value ""))))]
    
    [(tfield/image label name error mime-type data)
     (and (string? mime-type) (bytes? data))]
    
    [(tfield/file label name error file-name mime-type temp-path)
     (and (string? file-name) 
          (path-string? temp-path)
          (file-exists? temp-path))]
    
    [(tfield/struct label name error constr args) (andmap filled? args)]
    
    [(tfield/oneof label name error options chosen)
     (and (natural-number/c chosen)  ;; already enforced by exported contract?
          (<= chosen (length options))
          (filled? (list-ref options chosen)))]
    
    [(tfield/listof label name error base elts non-empty?)
     (and (andmap filled? elts) (or (not non-empty?) (not (empty? elts))))]
    
    ;; for function... just check the args and result are filled?
    ;; ... don't try to apply func here otherwise...(?)
    [(tfield/function title name error text func args result)
     (and (not (any-error? tf)) ;; catch any parse error on the function
          (andmap filled? args) (filled? result))]
    
    [_ (error (object-name filled?)
              (format "somehow got an unknown field type: ~a" tf))]))



;;=============================================================================
;;=============================================================================
;;=============================================================================


; tfield->value : tfield -> any
; extracts the data value from the tfield, stripping away the tfield wrappers
; *** raises an error if filled? is false
; for a file, simply returns the file-name of the field (not the temp-path)
; for a function, it extracts data value from the result tfield; but note, it
;   doesn't actually apply the function to the extracted args -- assumes that
;   has been previously done
(define (tfield->value tf)
  (if (filled? tf)
      (match tf
        [(tfield/const label name error value)
         value]
        [(tfield/number label name error value raw-value)
         value]
        [(tfield/symbol label name error value)
         value]
        [(tfield/string label name error value non-empty?)
         value]
        [(tfield/boolean label name error value)
         value]
        [(tfield/image label name error mime-type data)
         (define inp (open-input-bytes (base64-decode data)))
         (define bmp (make-object bitmap% inp 'unknown/alpha))
         (close-input-port inp)
         bmp]
        [(tfield/file label name error file-name mime-type temp-path)
         file-name]
        [(tfield/struct label name error constr args)
         ;; TODO: this assumes constructor application doesn't raise 
         ;;       contract/type error?
         (apply constr (map tfield->value args))]
        [(tfield/oneof label name error options chosen)
         (tfield->value (list-ref options chosen))]
        [(tfield/listof label name error base elts non-empty?)
         (map tfield->value elts)]
        [(tfield/function title name error text func args result)
         (tfield->value result)]
        [_ (error (object-name tfield->value)
                  (format "somehow got an unknown field type: ~a" tf))])
      (error (object-name tfield->value)
             "attempted to extract a value from a field not filled in")))



;;=============================================================================
;;=============================================================================
;;=============================================================================

; value->tfield : tfield any -> (#f or tfield)
; attempts to unify given value with the tfield, filling in value fields of 
; the tfield if possible. If succeeds, it produces a new tfield object with
; value fields overwritten with the given value
;
; for a file, expects a string, which should be the name of a file in
;   the current directory; it makes a temporary copy of the file for itself
; for a function tfield, unifies a list of arguments with the argument tfields
;   and clears out the result

(define (value->tfield tf v)
  (match tf
    [(tfield/const label name error value)
     (and (equal? v value) tf)]
    
    [(tfield/number label name error value raw-value)
     (and (number? v)
          (struct-copy tfield/number tf [value v] 
                       [raw-value 
                        (number->string 
                         ; try to avoid fractions printing when non-integral?
                         (if (integer? v) v (exact->inexact v)))]))]
    
    [(tfield/symbol label name error value)
     (and (symbol? v)
          (struct-copy tfield/symbol tf [value v]))]
    
    [(tfield/string label name error value non-empty?)
     (and (string? v)
          (or (> (string-length v) 0)
              (not non-empty?))
          (struct-copy tfield/string tf [value v]))]
    
    [(tfield/boolean label name error value)
     (and (boolean? v)
          (struct-copy tfield/boolean tf [value v]))]
    
    [(tfield/image label name error mime-type data)
     (and (2htdp:image? v)
          (let ([conv (convert v 'png-bytes)])
            (and conv
                 (struct-copy tfield/image tf
                         [mime-type "image/png"] [data (base64-encode conv)]))))]
    
    [(tfield/file label name error file-name mime-type temp-path)
     ;; note: we don't delete the previous file if there is one...
     (and (file-exists? v) (string? v)
          (tfield/file label name error 
                       v #f (make-temporary-file "mztmp~a" v)))] 
    ; copy v to a temp file (is this being too cautious?) <-- TODO: evaluate
    
    
    [(tfield/struct label name error constr args)
     (define struct-args (cdr (vector->list (struct->vector v))))   
     ;; QUESTION:  ??????
     ;; IS THIS THE BEST WAY TO CHECK TYPE OF STRUCTURE ********* <-----
     (and (symbol? (object-name v)) (symbol? (object-name constr))
          (or (equal? (object-name v) (object-name constr))
              (equal?
               (string-append "make-" (symbol->string (object-name v)))
               (symbol->string (object-name constr))))
          (or (= (length args) (length struct-args))
              (= (length args) (sub1 (length struct-args))))
          ; in BSL, struct->vector produces an extra field at the end?????
          (block
           ;(printf "here\n ~a ~a\n\n~a ~a\n" (length args) args
           ;            (length struct-args) struct-args)
           (define value/args
             (map (λ(a v/arg) (value->tfield a v/arg)) 
                  args (take struct-args (length args))))
           (and (andmap (λ(i)i) value/args)
                (struct-copy tfield/struct tf [args value/args]))))]
    
    [(tfield/oneof label name error options chosen)
     (define idxs (build-list (length options) values))
     (define unifieds (map (λ(i) (value->tfield (list-ref options i) v)) idxs))
     (define new-options (map (λ(u o) (or u o)) unifieds options))
     (define new-chosen (ormap (λ(o i) (and o i)) unifieds idxs))
     (and new-chosen
          (struct-copy tfield/oneof tf
                       [options new-options] [chosen new-chosen]))]
    
    [(tfield/listof label name error base elts non-empty?)
     (define elts/unify (and (list? v) (map (curry value->tfield base) v)))
     (and elts/unify 
          (andmap values elts/unify)
          (struct-copy tfield/listof tf
                       [elts (rename/deep* elts/unify name)]))]
    
    [(tfield/function title name error text func args result)
     (define args/unify (and (list? v) (map value->tfield args v)))
     (and args/unify
          (andmap values args/unify)
          (struct-copy tfield/function tf
                       [args (rename/deep* args/unify name)]
                       [result (clear result)]))]
    
    [_ (error (object-name value->tfield)
              (format "somehow got an unknown field type: ~a" tf))]))




;;=============================================================================
;;=============================================================================
;;=============================================================================


; rename/deep* : (listof tfield) string -> (listof tfield)
; produces a copy of all the tfields with name indexed and extended 
; from given name

(define (rename/deep* tfs new-name [start-i 0])
  (map (λ(tf i)
         (rename/deep tf (string-append new-name "-" (number->string i))))
       tfs (build-list (length tfs) (λ(x) (+ start-i x)))))


; rename/deep : tfield string -> tfield
; produces a renamed copy of this tfield, as well as renaming all sub-fields
; using indexes based on the given name

(define (rename/deep tf [new-name #f])
  (when (not new-name) (set! new-name (tfield-name tf)))
  (match tf
    [(tfield/const label name error value)
     (tfield/const label new-name error value)]
    
    [(tfield/number label name error value raw-value)
     (tfield/number label new-name error value raw-value)]
    
    [(tfield/string label name error value non-empty?)
     (tfield/string label new-name error value non-empty?)]
    
    [(tfield/symbol label name error value)
     (tfield/symbol label new-name error value)]
    
    [(tfield/boolean label name error value)
     (tfield/boolean label new-name error value)]
    
    [(tfield/image label name error mime-type data)
     (tfield/image label new-name error mime-type data)]
    
    [(tfield/file label name error file-name mime-type temp-path)
     (tfield/file label new-name error file-name mime-type temp-path)]

    [(tfield/struct label name error constr args)
     (tfield/struct label new-name error constr (rename/deep* args new-name))]
    
    [(tfield/oneof label name error options chosen)
     (tfield/oneof label new-name error 
                   (rename/deep* options new-name) chosen)]
    
    [(tfield/listof label name error base elts non-empty?)
     (tfield/listof label new-name
                    error (rename/deep base (string-append new-name "-base"))
                    (rename/deep* elts new-name) non-empty?)]
    
    [(tfield/function title name error text func args result)
     (tfield/function title new-name error text func
                      (rename/deep* args new-name) 
                      (rename/deep result (string-append new-name "-result")))]
    
    [_ (error (object-name rename/deep)
              (format "somehow got an unknown field type: ~a" tf))]))



;;=============================================================================
;;=============================================================================
;;=============================================================================


; validate : tfield -> tfield
; examines the entire tfield, filling in error as appropriate
; (somewhat inside out, but since the parse function below was already
;  written, and already fills in errors, to avoid duplication, this 
;  function builds a lookup-func based on the current data in the given
;  tfield and then tries to parse based on that -- i.e. it re-parses
;  itself, and fills in errors)

(define (validate tf [apply-func #f]) 
  (define (lookup-func name)  ; string -> #f or string
    (match (find-named tf name)
      [#f #f]
      [(tfield/const label name error value) (format "~a" value)]
      [(tfield/number label name error value raw-value) raw-value]
      [(tfield/string label name error value non-empty?) value]
      [(tfield/symbol label name error value)
       (and value (symbol->string value))]
      [(tfield/boolean label name error value) (and value "on")]
      [(tfield/image label name error mime-type data)
       (and mime-type data (list "" mime-type data))]
      [(and tf/f (tfield/file label name error file-name mime-type temp-path))
       (cond [(filled? tf/f) (list file-name mime-type temp-path)]
             [file-name (list file-name #f #f)]  ; in-progress upload ?
             [else #f])]
      [(tfield/struct label name error constr args)     #f]
      [(tfield/oneof label name error options chosen)   
       (and chosen (number->string chosen))]
      [(tfield/listof label name error base elts non-empty?)      
       (number->string (length elts))]
      [(tfield/function title name error text func args result) #f]
      [_ (error (object-name validate)
                (format "somehow got an unknown field type: ~a" tf))]
      ))
  (parse tf lookup-func #t apply-func))


;; This is the type of a "lookup-func" for parse purposes:
;;
;; LOOKUP-FUNC :  string -> 
;;                -> (or/c #f string? (list/c string? (or/c #f string?)
;;                                             (or/c #f path-string? bytes?)))
;;
;; Namely, it's a function that maps a string key value to a 
;; string data value, or a triple of <fileneame> <mimetype> <content/path> 
;; representing file upload data, or #f if no mapping exists for the key.
;; For files, if the third element of the triple is a bytes?, it represents
;; the actual content of the file; if it is a path-string? then it 
;; represents the path to an existing temporary file, to be reused (this is 
;; useful for validate)
;;
;; For images, if the key maps to a string, that is assumed to be a URL unless
;; it is the string "*IMAGE*; if it is a triple like a file, then the first element 
;; of the triple is to be ignored, and the second and third elements are the mime 
;; type and the actual bytes of the image. If the key maps to the string "*IMAGE*"
;; then any existing image data the tfield currently has is to be retained.




; parse : tfield LOOKUP-FUNC [boolean] [boolean] -> tfield
; given a lookup function from tfield names to raw string values, attempts to
; parse and validate values according to the tfield, filling in the error
; if necessary
;
; for a file tfield, if the lookup function produces bytes?, then a new
;  temporary file is created and the content written to it; otherwise 
;  the tfield/file just uses the provided path-string? of the lookup-func
;  as the temp-path
; for a function tfield, parses all the argument tfields, *that are not 
;  tfield/function's in themselves*, then it strips
;  the arguments for their values, attempts to apply the function (if
;  'apply-func' argument is #t and unify
;  (i.e. tfield->value) the result with the result tfield, filling in the 
;  error if that is not successful (i.e. if exception occurs either 
;  with tfield->value or when the function is actually applied)

(define ERRMSG/NO-IMAGE "Image not specified")
(define ERRMSG/NO-FILE "Must select an input file")
(define ERRMSG/UPLOAD "File upload is not yet complete")
(define ERRMSG/NOT-FILLED "Must be filled in")
(define ERRMSG/NOT-EMPTY "Cannot be empty")
(define ERRMSG/NOT-NUMBER "Should be a number")
(define ERRMSG/MISSING-INPUT "Not all required input has been entered")
(define ERRMSG/SELECT-OPTION "Must select an option")
(define ERRMSG/FUNC-APP "Something went wrong processing the input")
(define ERRMSG/MISMATCH "The result of the program was of an unexpected type")

(define (parse tf lookup-func [validate? #t] [apply-func? #t])
  ;(printf "Parsing tfield ~a (~a); Lookup: ~a\n"
  ;        (tfield-label tf) (tfield-name tf) (lookup-func (tfield-name tf)))
  
  (match tf
    ;; ---- TFIELD/CONST ----
    [(tfield/const label name error value)
     ;; actually ignore any bindings in the lookup-func,
     ;; but it should equal? value
     ;; TODO... add conflicting binding to error(?)
     tf]
    
    ;; ---- TFIELD/NUMBER ----
    [(tfield/number label name error value raw-value)
     (define v (lookup-func name))
     (define n (and (string? v) (string->number (string-trim-both v))))
     (cond
       [(and (not v) validate?)
        (tfield/number label name ERRMSG/NOT-FILLED #f #f)]
       [(and (not n) validate?)
        (tfield/number label name ERRMSG/NOT-NUMBER #f v)]
       [(or (not v) (not n))
        (tfield/number label name error n v)] ;; retain error
       [else  ;; probably won't ever get here?
        (tfield/number label name #f n v)])]
    
    ;; ---- TFIELD/STRING ----
    [(tfield/string label name error value non-empty?)     
     (define v (lookup-func name))
     (cond
       [(and (string? v)
             (not (and (string=? v "") non-empty?)))
        (tfield/string label name #f v non-empty?)]
       ; (struct-copy tfield/string tf [value v])]
       [validate?
        (tfield/string label name ERRMSG/NOT-FILLED v non-empty?)]
       [else
        (tfield/string label name error v non-empty?)])] ;; retain error
    
    ;; ---- TFIELD/SYMBOL ----
    [(tfield/symbol label name error value)
     (define v (lookup-func name))
     (cond
       [(and (string? v) (not (string=? v "")))
        (struct-copy tfield/symbol tf [value (string->symbol v)])]
       [validate?
        (tfield/symbol label name ERRMSG/NOT-FILLED #f)]
       [else
        (tfield/symbol label name error value)])]
    
    ;; ---- TFIELD/BOOLEAN ----
    [(tfield/boolean label name error value)
     (define v (lookup-func name))
     (define missing? (false? v))
     (tfield/boolean label name 
                     #f   ;; cannot distinguish missing from not selected 
                     ;; with HTMLform submission
                     (and (string? v) (string=? v "on")))]
    
    ;; ---- TFIELD/IMAGE ----
    [(tfield/image label name error mime-type data)
     (define v (lookup-func name))
     (cond
       [(equal? v "*IMAGE*") 
        (if (and mime-type data) tf
            (tfield/image label name (if validate? ERRMSG/NO-IMAGE error) #f #f))]
       [(string? v)   ; URL (note: bitmap/url never fails?)
        (with-handlers ([exn:fail? 
                         (λ(exn)
                           (tfield/image label name (if validate? ERRMSG/NO-IMAGE error)
                                         #f #f))])
          (define the-url 
            (if (regexp-match #rx"^http://" v) v (string-append "http://" v)))
          (define img-bytes 
            (base64-encode (convert (2htdp:bitmap/url the-url) 'png-bytes)))
          (tfield/image label name #f "image/png" img-bytes))]
       [(and (list? v) (string? (second v)) (bytes? (third v)))
        (tfield/image label name #f (second v) (third v))]
       [else
        (tfield/image label name (if validate? ERRMSG/NO-IMAGE error) #f #f)])]
    
    ;; ---- TFIELD/FILE ----
    [(tfield/file label name error file-name mime-type temp-path)
     (define v (lookup-func name))
     (cond
       [(and (string? v) file-name temp-path (string=? v file-name))
        tf]  ; if file already uploaded, then a hidden input element will be in 
             ; the form with same value as existing file-name
       [(not (list? v))
        (tfield/file label name (if validate? ERRMSG/NO-FILE error)
                     #f #f #f)]
       [(not (third v))
        (tfield/file label name (if validate? ERRMSG/UPLOAD error) (first v) #f #f)]
       [(path-string? (third v)) ; existing temp-path
        (tfield/file label name #f (first v) (second v) (third v))]
       [(bytes? (third v))  ; raw-content
        (define temp-file (make-temporary-file))
        (with-output-to-file temp-file
          (λ() (write-bytes (third v)))
          #:exists 'truncate/replace)
        (tfield/file label name #f (first v) (second v) temp-file)])]
     
    
    ;; ---- TFIELD/STRUCT ----
    [(tfield/struct label name error constr args)
     (define new-args (map (λ(a) (parse a lookup-func validate?)) args))
     (struct-copy tfield/struct tf [args new-args])]
    
    ;; ---- TFIELD/ONEOF ----
    [(tfield/oneof label name error options chosen)
     ; sel-chosen will be #f if none selected
     (define sel-chosen (string->number (or (lookup-func name) "")))
     ; options/parse : number -> listof tfield (new-options)
     ; produces an updated options list with the x'th option parsed
     (define (options/parse options x)
       (map (λ(o i) (if (= i x)
                        (parse o lookup-func validate?) 
                        o))
            options
            (build-list (length options) values)))
     
     (cond [(not sel-chosen)   ; no option was chosen
            (tfield/oneof label name
                          (if validate? ERRMSG/SELECT-OPTION error) 
                          options sel-chosen)]
           [(not chosen)       ; option was chosen where none was previously
            (struct-copy tfield/oneof tf
                         [options (options/parse options sel-chosen)]
                         [chosen sel-chosen]
                         [error #:parent tfield #f]
                         )]
           [(not (= chosen sel-chosen)) 
            ; option chosen different than previously selected
            ; note: updates both old and new chosen option tfields
            ;       (though really only one could happen at a time?)
            (struct-copy tfield/oneof tf 
                         [options (options/parse 
                                   (options/parse options chosen) 
                                   sel-chosen)]
                         [chosen sel-chosen]
                         [error #:parent tfield #f])]
           [else ; chosen=sel-chosen
            ; i.e. not changing the option -- just attempt to parse fields for 
            ;      the currently chosen one
            (struct-copy tfield/oneof tf
                         [options (options/parse options chosen)]
                         [error #:parent tfield #f])]
           )]
    
    ;; ---- TFIELD/LISTOF ----
    [(tfield/listof label name error base elts non-empty?)
     (define n (string->number (or (lookup-func name) "0")))
     (define elts-n (length elts))
     (define new-elts      ; extend or truncate elts if necessary
       (cond [(= n elts-n) elts]
             [(< n elts-n) (take elts n)]
             [(> n elts-n) (append elts 
                                   (rename/deep* (make-list (- n elts-n) base)
                                                 name elts-n))]))
     ;(define new-elts (rename/deep* (make-list n base) name))

     (define new-elts/parsed
       (map (λ(e) (parse e lookup-func validate?)) new-elts))
     
     (tfield/listof label name 
                    (if (and validate? non-empty? (empty? new-elts/parsed))
                        ERRMSG/NOT-EMPTY #f)
                       base new-elts/parsed non-empty?)]
    
    ;; ---- TFIELD/FUNCTION
    [(tfield/function title name error text func args result)
     ; note: does *not* parse inner tfield/function args
     (define new-args (map (λ(a) 
                             ; parse non-tfield/function args
                             (if (tfield/function? a)  
                                 a
                                 (parse a lookup-func validate?)))
                           args))
     
     ; cleared result
     (define result/cleared (clear result))
     (define return-result (if apply-func?
                               (extract&apply-args func new-args result)
                               '(failure #f)))
     
     ;;(printf "ret-res: ~s validate? ~s\n" return-result validate?)
     
     ; now check possible situations...
     (match return-result
       [(list 'failure msg)
        (tfield/function title name (if validate? msg #f)
                         text func new-args result/cleared)]
       [(list 'success new-result)
        (tfield/function title name #f
                         text func new-args new-result)]
       )
     ]
    
    [_ (error 'parse (format "somehow got an unknown field type: ~a" tf))]))


; apply-tfield/function : tfield/function -> tfield/function or #f
; takes a tfield/function object and attempts to actually apply the
;  embedded function to the arguments stored in the tfield, producing
;  #f if any error occurs

(define (apply-tfield/function tf)
  (match tf
    [(tfield/function title name error text func args result)
     (match (extract&apply-args func args result)
       [(list 'success new-result)
        (struct-copy tfield/function tf [result new-result])]
       [_ #f])]
    [_ (error (object-name apply-tfield/function)
              "Can only apply a tfield/function")]))


; apply-function/tfield : procedure (listof tfield) tfield 
;                         -> ['(failure <err-msg>) or '(success <ret-value>)]
; attempts to strip given args tfield, apply the procedure to it, and then
;  unify the return value with the result tfield -- either producing the
;  return tfield or a failure message

(define (extract&apply-args func args result)
  (define temp-current-directory (make-temporary-file "mztmp~a" 'directory))
  (define the-return
    (parameterize ([current-directory temp-current-directory])
      ;;(printf "extract&apply-args in directory: ~a\n" (current-directory))
      ;;(pretty-print args)
      
      ; check if all args were parsed & are filled
      (define all-filled? (andmap filled? args))
      
      ; attempt to apply if all-filled
      (define return-value
        (or (and (not all-filled?) '(failure)) 
            ;; if not all filled, apply-result = '(failure)
            (with-handlers ([exn? (λ(x) #;(pretty-print x)            
                                    ;; or if exn, apply-result = '(failure ...)
                                    `(failure ,(exn-message x)))])
              (if (andmap materialize-input-files args) ; attempt to setup files
                  (let ([ret-val (apply func (map tfield->value args))])
                    (andmap purge-input-files args)
                    (list 'success ret-val))
                  (list 'failure "A problem occurred with the input file(s)")))))
      
      (define result-good? (symbol=? (first return-value) 'success))
      
      ; attempt to unify apply-result with the tfield's result tfield
      (define new-result 
        (and result-good? (value->tfield result (second return-value))))
      
      ;;;(printf "applied: filled? ~s good? ~s new-result: ~s return-value: ~s\n" 
      ;;;        all-filled? result-good? new-result return-value)
      
      (cond [(not all-filled?) 
             `(failure ,ERRMSG/MISSING-INPUT)]
            [(not result-good?) 
             `(failure ,(format "~a: ~a" ERRMSG/FUNC-APP (second return-value)))]
            [(not new-result) 
             `(failure ,ERRMSG/MISMATCH)]
            [else `(success ,new-result)])
      
      ))
  
  ;; TODO: remove all files from temp-current-directory and delete it
  (with-handlers ([exn? (λ(x) (pretty-print x) the-return)])
    (for ([file (directory-list temp-current-directory)])
      (delete-file (build-path temp-current-directory file)))
    (delete-directory temp-current-directory)
    the-return))



;; materialize-input-files : tfield -> boolean
;; processes the tfield and all its subtfields, copying the temporary
;;  file from any tfield/file instances into a file in the current
;;  directory with file-name, unless file already exists (error), or
;;  file-name and temp-path are the same (ignore)
;; returns #t if successful, #f if error occurred (or raises
;;  an exception)
;;
;; NOTE: does not process *any* of the sub-fields of a tfield/function
;; TODO: handle this ^^^^ better
;;
(define (materialize-input-files tf)
  (match tf
    [(or (? tfield/const? _) (? tfield/number? _)
         (? tfield/string? _) (? tfield/boolean? _)
         (? tfield/symbol? _) (? tfield/image? _))
     #t]

    [(tfield/file label name error file-name mime-type temp-path)
     (if (and file-name temp-path)
         (cond
           [(equal? file-name (path->string temp-path))
            #t]    ; nothing to do -- file already in place
           [else (copy-file temp-path file-name)])
         #f)]   ; file missing

    [(tfield/struct label name error constr args)
     (andmap materialize-input-files args)]
    [(tfield/oneof label name error options chosen)
     (and chosen (materialize-input-files (list-ref options chosen)))]
    [(tfield/listof label name error base elts non-empty?)
     (andmap materialize-input-files elts)]
    [(tfield/function title name error text func args result)
     #t]     ;; handle this better
    [_ (error (object-name materialize-input-files)
              (format "somehow got an unknown field type: ~a" tf))]))



;; purge-input-files : tfield -> boolean
;; undoes the work of materialize-input-files, by deleting files in 
;; the current directory, leaving in place those where temp-path = file-name
;;
;; NOTE: does not process *any* of the sub-fields of a tfield/function
;; TODO: handle this ^^^^ better
;;
;; NOTE: this is a dangerous operation (because it deletes files)
;;
(define (purge-input-files tf)
  (match tf
    [(or (? tfield/const? _) (? tfield/number? _)
         (? tfield/string? _) (? tfield/boolean? _)
         (? tfield/symbol? _) (? tfield/image? _))
     #t]
    [(tfield/file label name error file-name mime-type temp-path)
     (if (and file-name temp-path)
         (cond
           [(equal? file-name (path->string temp-path))
            #t]    ; nothing to do -- file was already in place
           [else (delete-file file-name)])
         #f)]   ; file missing
    [(tfield/struct label name error constr args)
     (andmap purge-input-files args)]
    [(tfield/oneof label name error options chosen)
     (and chosen (purge-input-files (list-ref options chosen)))]
    [(tfield/listof label name error base elts non-empty?)
     (andmap purge-input-files elts)]
    [(tfield/function title name error text func args result)
     #t]     ;; handle this better
    [_ (error (object-name purge-input-files)
              (format "somehow got an unknown field type: ~a" tf))]))


;;=============================================================================
;;=============================================================================
;;=============================================================================

;; TRAVERSAL FUNCTIONS


; find-named : tfield string -> tfield or #f
; searches tf until it finds a sub-field of given name and returns it,
; or #f if none found

(define (find-named tf target-name)
  ;; 3 fun ways to accomplish this using the traversal procedures...
  #;(let/cc k (update-named tf target-name (λ(tf) (k tf))))
  
  (let/cc k (visit tf (λ(f) (if (string=? target-name (tfield-name f))
                                       (k f) #f))))
  
  #;(fold tf (λ(cur-tf found?)
               (or found? (and (string=? target-name
                                         (tfield-name cur-tf)) cur-tf)))
          #f))

; find-parent-of-named : tfield string -> tfield or #f

(define (find-parent-of-named tf target-name)
  (let/cc k
    (visit 
     tf (λ(f)
          (match f
            [(tfield/struct label name error constr args)
             (if (member target-name (map tfield-name args)) (k f) #f)]
            [(tfield/oneof label name error options chosen)
             (if (member target-name (map tfield-name options)) (k f) #f)]
            [(tfield/listof label name error base elts non-empty?)
             (if (member target-name (map tfield-name elts)) (k f) #f)]
            [(tfield/function title name error text func args result)
             (if (or (member target-name (map tfield-name args))
                     (equal? target-name (tfield-name result)))
                 (k f) #f)]
            [_ #f])))))


; update-named/tfield : tfield string (tfield->tfield) -> tfield or #f
; burrows through tf until finds a sub-tfield of given name and then updates
; that by applying the given procedure, returns the updated tfield or 
; #f if no changes made

(define (update-named tf target-name tf-func)
  (update tf (λ(f) (string=? target-name (tfield-name f))) tf-func))


; update : tfield (tfield -> boolean) (tfield -> tfield) -> tfield or #f
(define (update tf pred tf-func)
  (define (copy/non-false old new)
    (map (λ(o n) (if n n o)) old new))
  
  (match tf
    [(or (? tfield/const? _) (? tfield/number? _)
         (? tfield/string? _) (? tfield/boolean? _)
         (? tfield/symbol? _) (? tfield/file? _) (? tfield/image? _))
     (and (pred tf) (tf-func tf))]

    [(tfield/struct label name error constr args)
     (define upd-args (map (λ(a) (update a pred tf-func)) args))
     (define new-args (copy/non-false args upd-args))
     (define new-tf (struct-copy tfield/struct tf [args new-args]))
     (or (and (pred new-tf) (tf-func new-tf))
         (and (ormap values upd-args) new-tf))]
    
    [(tfield/oneof label name error options chosen)
     (define upd-options (map (λ(a) (update a pred tf-func)) options))
     (define new-options (copy/non-false options upd-options))
     (define new-tf (struct-copy tfield/oneof tf [options new-options]))
     (or (and (pred new-tf) (tf-func new-tf))
         (and (ormap values new-options) new-tf))]
    
    [(tfield/listof label name error base elts non-empty?)
     (define upd-base (update base pred tf-func))
     (define upd-elts (map (λ(a) (update a pred tf-func)) elts))
     (define new-elts (copy/non-false elts upd-elts))
     (define new-tf (struct-copy tfield/listof tf
                                 [base (or upd-base base)]
                                 [elts new-elts]))
     (or (and (pred new-tf) (tf-func new-tf))
         (and upd-base new-tf)
         (and (ormap values new-elts) new-tf))]
    
    [(tfield/function title name error text func args result)
     (define upd-result (update result pred tf-func))
     (define upd-args (map (λ(a) (update a pred tf-func)) args))
     (define new-args (copy/non-false args upd-args))
     (define new-tf (struct-copy tfield/function tf
                                 [result (or upd-result result)]
                                 [args new-args]))
     (or (and (pred new-tf) (tf-func new-tf))
         (and upd-result new-tf)
         (and (ormap values new-args) new-tf))]

#|
    (cond [(string=? target-name name) (tf-func tf)]
           [else
            (define new-args 
              (map (λ(a) (update a pred tf-func)) args))
            (and (ormap values new-args)
                 (struct-copy tfield/struct tf 
                              [args (copy/non-false (tfield/struct-args tf)
                                                    new-args)]))])]
    
    [(tfield/oneof label name error options chosen)
     (cond [(string=? target-name name)(tf-func tf)]
           [else
            (define new-options 
              (map (λ(a) (update-named a target-name tf-func)) options))
            (and (ormap values new-options)
                 (struct-copy tfield/oneof tf 
                              [options 
                               (copy/non-false (tfield/oneof-options tf)
                                               new-options)]))])]
    
     (cond [(string=? target-name name) (tf-func tf)]
           [(update-named base target-name tf-func)
            => (λ(new-base) (struct-copy tfield/listof tf [base new-base]))]
           [else
            (define new-elts
              (map (λ(a) (update-named a target-name tf-func)) elts))
            (and (ormap values new-elts)
                 (struct-copy tfield/listof tf 
                              [elts (copy/non-false (tfield/listof-elts tf)
                                                    new-elts)]))])]

    [(tfield/function title name error text func args result)
     (cond [(string=? target-name name) (tf-func tf)]
           [(update-named result target-name tf-func)
            => (λ(new-result) 
                 (struct-copy tfield/function tf [result new-result]))]
           [else
            (define new-args 
              (map (λ(a) (update-named a target-name tf-func)) args))
            (and (ormap values new-args)
                 (struct-copy tfield/function tf 
                              [args (copy/non-false (tfield/function-args tf)
                                                    new-args)]))])]
        |#

    [_ (error 'update
              (format "somehow got an unknown field type: ~a" tf))]))



; fold : tfield (tfield any -> any) any -> any

(define (fold tf proc init)
  (match tf
    [(tfield/const label name error value) (proc tf init)]
    [(tfield/boolean label name error value) (proc tf init)]
    [(tfield/number label name error value raw-value) (proc tf init)]
    [(tfield/symbol label name error value) (proc tf init)]
    [(tfield/string label name error value non-empty?) (proc tf init)]
    [(tfield/image label name error mime-type data) (proc tf init)]
    [(tfield/file label name error file-name mime-type temp-path) (proc tf init)]
    [(tfield/struct label name error constr args) 
     (proc tf (foldl (λ(f i) (fold f proc i)) init args))]
    [(tfield/oneof label name error options chosen)
     (proc tf (foldl (λ(f i) (fold f proc i)) init options))]   
     ;; ^^^ goes through all options
    [(tfield/listof label name error base elts non-empty?) 
     (proc tf (foldl (λ(f i) (fold f proc i)) init elts))]
    [(tfield/function title name error text func args result)
     (proc tf (fold result proc (foldl (λ(f i) (fold f proc i)) init args)))]
    [_ (error (object-name fold)
              (format "somehow got an unknown field type: ~a" tf))]))


; visit : tfield (tfield -> #) -> #
; imperative traversal

(define (visit tf func)
  (fold tf (λ(f i) (func f)) #f))



;;=============================================================================
;;=============================================================================
;;;============================================================================
;;; Utility Functions


; depth-of : (or tfield string) -> number
; produces numbers of nesting levels under which tfield of given name is
; (basically depends on # of "-" characters in the standard naming scheme)
(define (depth-of tf/name)
  (define name (if (tfield? tf/name) (tfield-name tf/name) tf/name))
  (length (filter (λ(c) (char=? #\- c)) (string->list name))))


; move-to : list number number -> list
; moves element at position n to position m in the list
;  (assumes the positions are valid)
(define (move-to lst n m)
  (cond [(= n m) lst]
        [(< n m) 
         (define-values (anb c) (split-at lst (add1 m)))
         (define-values (a nb) (split-at anb n))
         (define-values (nth b) (values (first nb) (rest nb)))
         (append a b (cons nth c))]
        [(> n m)
         (define-values (ab nc) (split-at lst n))
         (define-values (nth c) (values (first nc) (rest nc)))
         (define-values (a b) (split-at ab m))
         (append a (cons nth b) c)]))


; bump-up : any list -> list
; swaps e with the element before it in the list
; assumes e is in the list
(define (bump-up e lst)
  (let ([tl (member e lst)])
    (if (or (not tl) (= (length lst) (length tl))) lst
        (append
         (take lst (- (length lst) (length tl) 1))
         (list (car tl))
         (list (list-ref lst (- (length lst) (length tl) 1)))
         (cdr tl)))))

; bump-down : any list -> list
; swaps e with the element after it in the list
; assumes e is in the list
(define (bump-down e lst)
  (let ([tl (member e lst)])
    (if (or (not tl) (= (length tl) 1)) lst
        (append
         (drop-right lst (length tl))
         (list (cadr tl))
         (list (car tl))
         (cddr tl)))))



;;=============================================================================
;;=============================================================================
;;=============================================================================

;; Exports and Contracts


(provide ERRMSG/NOT-FILLED ERRMSG/NOT-NUMBER ERRMSG/MISSING-INPUT
         ERRMSG/SELECT-OPTION ERRMSG/FUNC-APP ERRMSG/MISMATCH
         ERRMSG/NO-FILE ERRMSG/UPLOAD ERRMSG/NO-IMAGE)

(provide/contract
 
 ; structures
 [struct tfield 
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c)))]
 [struct (tfield/const tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (value  any/c))]
 [struct (tfield/number tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (value  (or/c #f number?))
    (raw-value (or/c #f string?)))]
 [struct (tfield/string tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (value  (or/c #f string?))
    (non-empty? boolean?))]
 [struct (tfield/symbol tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (value  (or/c #f symbol?)))] 
 [struct (tfield/image tfield)
   ((label (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (mime-type (or/c #f string?))
    (data (or/c #f bytes?)))]
 [struct (tfield/boolean tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (value  boolean?))]
 [struct (tfield/struct tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (constr procedure?)
    (args (listof tfield?)))]
 [struct (tfield/oneof tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (options (listof tfield?))
    (chosen (or/c #f natural-number/c)))]
 [struct (tfield/listof tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (base   tfield?)
    (elts   (listof tfield?))
    (non-empty? boolean?))]
 [struct (tfield/file tfield)
   ((label (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (file-name (or/c #f string?))
    (mime-type (or/c #f string?))
    (temp-path (or/c #f path-string?)))]
 [struct (tfield/function tfield)
   ((label  (or/c #f string?))
    (name   string?)
    (error (or/c #f xexpr/c))
    (text (or/c string? (listof xexpr/c)))
    (func procedure?)
    (args (listof tfield?))
    (result tfield?))]
 
 
 ; constructors and utilities
 (gen-new-name (-> string?))
 (reset-name-counter (-> number? void))
 
 (new-tfield (->* ((or/c #f string?)) 
                  (#:name string? #:error (or/c #f xexpr/c)) 
                  tfield?))
 (new-tfield/const (->* ((or/c #f string?) any/c) 
                        (#:name string? #:error (or/c #f xexpr/c))
                        tfield/const?))
 (new-tfield/boolean (->* ((or/c #f string?)) 
                          (boolean? #:name string? #:error (or/c #f xexpr/c))
                          tfield/boolean?))
 (new-tfield/number (->* ((or/c #f string?)) 
                         ((or/c #f number?) (or/c #f string?) 
                                  #:name string? #:error (or/c #f xexpr/c))
                         tfield/number?))
 (new-tfield/string (->* ((or/c #f string?)) 
                         ((or/c #f string?) boolean? 
                                  #:name string? #:error (or/c #f xexpr/c)) 
                         tfield/string?))
 (new-tfield/symbol (->* ((or/c #f string?)) 
                         ((or/c #f symbol?) #:name string?
                                            #:error (or/c #f xexpr/c))
                         tfield/symbol?))
 (new-tfield/image (->* ((or/c #f string?))
                        ((or/c #f string?) (or/c #f bytes?) 
                                  #:name string? #:error (or/c #f xexpr/c)) 
                         tfield/image?))
 (new-tfield/struct (->* ((or/c #f string?) procedure? (listof tfield?))
                         (#:name string? #:error (or/c #f xexpr/c))
                         tfield/struct?))
 (new-tfield/oneof (->i ([label (or/c #f string?)] [options (listof tfield?)])
                        ([chosen (or/c #f natural-number/c)]
                         #:name [name string?] 
                         #:error [error (or/c #f xexpr/c)])
                        #:pre (options chosen) (or (not chosen) 
                                                   (unsupplied-arg? chosen)
                                                   (< chosen (length options)))
                        [_ tfield/oneof?]))
 (new-tfield/listof (->* ((or/c #f string?) tfield?)
                         ((listof tfield?) boolean? #:name string?
                         #:error (or/c #f xexpr/c))
                         tfield/listof?))
 (new-tfield/file (->* ((or/c #f string?))
                       ((or/c #f string?) (or/c #f string?) (or/c #f path-string?)
                        #:name string? #:error (or/c #f xexpr/c))
                         tfield/file?))
 (new-tfield/function (->* ((or/c #f string?) 
                            (or/c string? (listof xexpr/c)) procedure?
                            (listof tfield?) tfield?)
                           (#:name string? #:error (or/c #f xexpr/c))
                           tfield/function?))
 
 
 ; functions
 (any-error? (-> tfield? boolean?))
 (clear (->* (tfield?) (boolean?) tfield?))
 (filled? (-> tfield? boolean?))
 
 (tfield->value (-> tfield? any))
 (value->tfield (-> tfield? any/c (or/c #f tfield?)))
 
 (parse (->* (tfield? 
              (-> string?
                  (or/c #f string? (list/c string? (or/c #f string?)
                                           (or/c #f path-string? bytes?)))))
             (boolean? boolean?) tfield?))
 (validate (->* (tfield?) (boolean?) tfield?))
 
 (update (-> tfield? (-> tfield? boolean?) (-> tfield? tfield?) (or/c #f tfield?)))
 (update-named (-> tfield? string? (-> tfield? tfield?) (or/c #f tfield?)))
 (find-named (-> tfield? string? (or/c #f tfield?)))
 (find-parent-of-named (-> tfield? string? (or/c #f tfield?)))

 (extract&apply-args (-> procedure? (listof tfield?) tfield? list?))
 (apply-tfield/function (-> tfield/function? (or/c #f tfield/function?)))
 
 (rename/deep (->* (tfield?) ((or/c #f string?)) tfield?))
 (rename/deep* (->* ((listof tfield?) string?) (number?) (listof tfield?)))
 
 (depth-of (-> (or/c tfield? string?) number?))
 (move-to (-> list? number? number? list?))
 (bump-up (-> any/c list? list?))
 (bump-down (-> any/c list? list?))
 
 )
