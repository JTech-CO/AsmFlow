; AsmFlow — JSON writer state.
;
; The writer tracks container nesting so that separators and the object/array
; grammar are produced by construction rather than by each call site
; remembering whether a comma is due. A call that does not fit the grammar —
; a key in an array, a value where a key belongs, an end that does not match
; the open — is a sticky error rather than malformed output.

%ifndef ASMFLOW_JSONW_INC
%define ASMFLOW_JSONW_INC

%define AF_JW_MAX_DEPTH 32

; Per-level state byte.
%define AF_JW_ARRAY     1   ; container is an array (clear = object)
%define AF_JW_HAS_ITEM  2   ; at least one member has been written
%define AF_JW_WANT_VALUE 4  ; an object key was written; a value must follow

;   +0   out         af_buffer * (BORROWED; the writer never owns it)
;   +8   depth       number of open containers
;   +16  status      sticky af_status; the first failure is kept
;   +24  root_done   this writer has emitted its one root value
;   +32  stack       AF_JW_MAX_DEPTH state bytes
;
; `root_done` belongs to the writer rather than being inferred from the output
; buffer being non-empty. A control connection's outbox accumulates several
; complete frames before it is flushed, so "the buffer already has bytes" is not
; the same question as "this document already has a root value".
%define JW_OUT       0
%define JW_DEPTH     8
%define JW_STATUS    16
%define JW_ROOT_DONE 24
%define JW_STACK     32
%define JW_SIZE      (JW_STACK + AF_JW_MAX_DEPTH)

%endif ; ASMFLOW_JSONW_INC
