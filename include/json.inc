; AsmFlow — JSON value types and parse limits.
;
; The type ordinals mirror Jansson's enumerators. They are not taken on faith:
; af_jsonc_type_ordinals writes the compiler's values into an array and
; tests/asm/test_json.asm asserts they match these constants, so a Jansson
; upgrade that renumbered the enum would fail the test rather than silently
; reinterpret every parsed document.

%ifndef ASMFLOW_JSON_INC
%define ASMFLOW_JSON_INC

%define AF_JSON_INVALID -1
%define AF_JSON_OBJECT   0
%define AF_JSON_ARRAY    1
%define AF_JSON_STRING   2
%define AF_JSON_INTEGER  3
%define AF_JSON_REAL     4
%define AF_JSON_TRUE     5
%define AF_JSON_FALSE    6
%define AF_JSON_NULL     7

; af_json_limits — the bounds every untrusted document is parsed under
; (AGENTS.md invariant 8). Supplied by the caller because the configured limits
; differ between the config file, the data plane, and MCP frames.
;
;   +0   max_bytes        whole document
;   +8   max_depth        nesting of arrays and objects
;   +16  max_string_bytes any single string value
;   +24  max_elements     any single array or object
%define AF_JSONLIM_MAX_BYTES   0
%define AF_JSONLIM_MAX_DEPTH   8
%define AF_JSONLIM_MAX_STRING  16
%define AF_JSONLIM_MAX_ELEMS   24
%define AF_JSONLIM_SIZE        32

; af_json_doc — an owned parsed document.
;
;   +0   root            json_t * (owned; released by af_json_doc_free)
;   +8   error_line      1-based line of a parse failure, else 0
;   +16  error_column
;   +24  error_position  byte offset
%define AF_JSONDOC_ROOT     0
%define AF_JSONDOC_LINE     8
%define AF_JSONDOC_COLUMN   16
%define AF_JSONDOC_POSITION 24
%define AF_JSONDOC_SIZE     32

%endif ; ASMFLOW_JSON_INC
