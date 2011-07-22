#lang scribble/doc
@(require planet/scribble
          ;scribble/eval
          scribble/manual
          (for-label racket
                     "../main.rkt"
                     "../web-launch.rkt"))

@title[#:tag "top"]{RacketUI: Automated Web UI Generator}
@author{@(author+email "Nadeem Abdul Hamid" "nadeem@acm.org")}

This teachpack provides facilities for the
quick and easy generation of web interfaces for programs written in 
the @hyperlink["http://docs.racket-lang.org/htdp-langs/index.html"]{HtDP (@italic{How to Design Programs})}
estudent languages of Racket.

@section{Quick Start}

Consider the following program, which builds an acronym from the
capitalized words in a list of strings:

@racketblock[
(code:comment @{acronym : listof string -> string})
(define (acronym a-los)
  (cond [(empty? a-los) ""]
        [(cons? a-los)
          (if (string-upper-case? (string-ith (first a-los) 0))
              (string-append (string-ith (first a-los) 0)
                             (acronym (rest a-los)))
              (acronym (rest a-los)))]))
]

A web application for this can be automatically generated by including
the following at the top of the program:

@defmodule/this-package[main]

and then putting the following code beneath the definition of @racket[acronym]:

@racketblock[
(web-launch
 "Acronym Builder"
 (function 
  "Produces an acronym of the capitalized words in the given list of words."
  (acronym ["Words" (listof+ ["Word" string+])]
           ->["The acronym" string])))
]

Running this program should launch a web browser with a user
interface that allows input of a list of words (strings) and controls
to apply the function to that input and view the result.


@section{Web Field Specifications}

RacketUI generates a user interface based on an annotated specification 
of the types of data that the underlying function consumes and produces. 
The types of data that RacketUI supports are given by the @tech{web specs}
below. These are intended to correspond to the types of data 
used in @italic{How to Design Programs}.

For the purposes of generating a user-friendly interface, specifications
are annotated with text informally describing their purpose or 
interpretation in the context of the program. 

An annotated web
field specification, which we call a @deftech{labeled spec}, is a pair

@itemlist[
 @item{ @defform/none[[label spec]] 
       where @racket[label] is a @racket[string] and @racket[spec] is a @tech{web spec}. }
 ]


A @deftech{web spec} (web field specification) is one of
@itemlist[
 @item{ @defform/none[#:literals (constant) (constant x)] where @racket[x] is any value }
 @item{ @defform/none[#:literals (boolean) boolean] }
 @item{ @defform/none[#:literals (number) number] }
 @item{ @defform/none[#:literals (symbol) symbol] }
 @item{ @defform/none[#:literals (string) string] }
 @item{ @defform/none[#:literals (string+) string+] for non-empty strings }
 @item{ @defform/none[#:literals (filename) filename] for
        functions that expect the name of an input file, or that produce
        the name of a generated output file }
 @item{ @defform/none[#:literals (structure) (structure constr lab-spec ...+)] 
        where @racket[constr] is a structure constructor and 
        @racket[lab-spec] are one or more @tech{labeled specs}
        corresponding to the types expected for the fields of the
        structure
        }
 @item{ @defform/none[#:literals (oneof) (oneof lab-spec ...+)] 
        where @racket[lab-spec] are one or more @tech{labeled specs}
        corresponding to an itemization (union) of specifications
        }
 @item{ @defform/none[#:literals (listof) (listof lab-spec)] or,
        for non-empty lists,
        @defform/none[#:literals (listof+) (listof+ lab-spec)] 
        where @racket[lab-spec] is a @tech{labeled spec} describing
        the type of elements in the list
        }
 @item{ @defform/none[#:literals (function ->) (function purpose (proc lab-spec ...+ -> lab-spec))]
        where @racket[purpose] is a @racket[string], @racket[proc] is the name of a procedure,
        and @racket[lab-spec] is a @tech{labeled spec}. This form
        represents a specification for the given function (@racket[proc]), consuming
        one or more parameters whose specifications precede @racket[->], and 
        producing data that meets the right-most specification.
        }
]

It is possible to define a name for specifications that occur
repeatedly:

@defform/none[#:literals (define/web) (define/web id spec)]

After this, @racket[id] can be used in any context where
a @tech{web spec} is expected.


@section{Starting a Web Application}

To start a web application, use the following form:

@defform/none[#:literals (web-launch) (web-launch title web-spec)]

where @racket[title] is a @racket[string] and @racket[web-spec] is a @racket[function]
@tech{web spec}.

@section{Examples}





