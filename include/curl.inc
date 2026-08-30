; AsmFlow — policy-neutral libcurl/epoll ABI constants.

%ifndef ASMFLOW_CURL_INC
%define ASMFLOW_CURL_INC

%define AF_CURL_POLL_NONE   0
%define AF_CURL_POLL_IN     1
%define AF_CURL_POLL_OUT    2
%define AF_CURL_POLL_INOUT  3
%define AF_CURL_POLL_REMOVE 4
%define AF_CURL_SOCKET_TIMEOUT -1
%define AF_CURL_CSELECT_IN  0x01
%define AF_CURL_CSELECT_OUT 0x02
%define AF_CURL_CSELECT_ERR 0x04
%define AF_CURLM_OK 0
%define AF_CURL_TAKE_PAUSE -1
%define AF_CURL_TAKE_ABORT -2

%define ITS_INTERVAL_SEC  0
%define ITS_INTERVAL_NSEC 8
%define ITS_VALUE_SEC     16
%define ITS_VALUE_NSEC    24
%define ITS_SIZE          32

%endif ; ASMFLOW_CURL_INC
