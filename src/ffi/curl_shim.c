/* AsmFlow — libcurl ABI adapter.
 *
 * The upstream side of the gateway is libcurl's multi interface driven from
 * AsmFlow's own epoll loop (ADR 0002: one loop, no second reactor). This file
 * is the whole of the boundary.
 *
 * It exists for the same reason the llhttp and Jansson shims do. `CURLcode`,
 * `CURLMcode`, `CURLoption`, `CURL_POLL_*` and `CURL_CSELECT_*` are C
 * enumerators whose numeric values are a property of the installed header, not
 * of libcurl's compatibility promise for every one of them; `curl_easy_setopt`
 * is variadic, which assembly cannot call portably; and `CURLMsg` has a layout
 * that should be described once, in the language that owns it.
 *
 * AGENTS.md invariant 2 still applies in full. Nothing here decides anything.
 * Every callback is an unconditional forward to an assembly function. Every
 * setter is one `curl_easy_setopt`. There is no default URL, no default
 * timeout, no retry, no allowlist, and no interpretation of a failure on this
 * side: `af_curl_error_ordinals` reports what the library's codes ARE, and
 * `src/providers/provider_error.asm` decides what they MEAN. Nothing about
 * TLS verification, redirect following, or permitted schemes is chosen here —
 * each is a setter the assembly must call, so a security property is never a
 * libcurl default that a version bump could change underneath us.
 *
 * The one allocation on this side is `curl_slist_append`, which is libcurl's
 * own structure and has no assembly-side equivalent; the handle it returns is
 * owned by the caller and freed through `af_curl_slist_free`.
 */

#include <curl/curl.h>
#include <stddef.h>
#include <stdint.h>

/* --- what the assembly provides -------------------------------------------
 *
 * Implemented in assembly. Each returns a signed count or a sentinel; mapping
 * a sentinel onto libcurl's magic return value is this file's job, because the
 * magic value is a property of the header. Provider and MCP HTTP callbacks are
 * deliberately separate so neither protocol's state can be passed to the
 * other's assembly entry points.
 */

/* The multi handle wants `fd` watched for `what` (CURL_POLL_*). Returns 0 on
 * success; anything else aborts the transfer set. */
int64_t af_prov_on_socket(void *user, int64_t fd, int64_t what);

/* The multi handle wants `timeout_ms` to elapse before the next call to
 * af_curl_multi_socket_timeout. -1 means disarm. Returns 0 on success. */
int64_t af_prov_on_timer(void *user, int64_t timeout_ms);

/* Response body bytes. Returns the number consumed, or one of: */
#define AF_CURL_TAKE_PAUSE (-1)   /* stop delivering until resumed */
#define AF_CURL_TAKE_ABORT (-2)   /* fail the transfer now */
int64_t af_prov_on_write(void *user, const char *at, size_t length);

/* One response header line, or the status line, including its CRLF. Same
 * return convention, except that a pause is not offered: libcurl's support for
 * pausing from a header callback has varied across releases, and a property
 * this code depends on should not be one that varies. */
int64_t af_prov_on_header(void *user, const char *at, size_t length);

/* The MCP Streamable HTTP adapter has the same ABI shape and separate assembly
 * entry points. The C side still performs no dispatch or protocol decisions. */
int64_t af_mcp_http_on_socket(void *user, int64_t fd, int64_t what);
int64_t af_mcp_http_on_timer(void *user, int64_t timeout_ms);
int64_t af_mcp_http_on_write(void *user, const char *at, size_t length);
int64_t af_mcp_http_on_header(void *user, const char *at, size_t length);

/* --- multi-handle callbacks ----------------------------------------------- */

static int af_tramp_socket(CURL *easy, curl_socket_t s, int what, void *userp,
                           void *socketp)
{
    (void)easy;
    (void)socketp;
    return (int)af_prov_on_socket(userp, (int64_t)s, (int64_t)what);
}

static int af_tramp_timer(CURLM *multi, long timeout_ms, void *userp)
{
    (void)multi;
    return (int)af_prov_on_timer(userp, (int64_t)timeout_ms);
}

static int af_mcp_http_tramp_socket(CURL *easy, curl_socket_t s, int what,
                                    void *userp, void *socketp)
{
    (void)easy;
    (void)socketp;
    return (int)af_mcp_http_on_socket(userp, (int64_t)s, (int64_t)what);
}

static int af_mcp_http_tramp_timer(CURLM *multi, long timeout_ms, void *userp)
{
    (void)multi;
    return (int)af_mcp_http_on_timer(userp, (int64_t)timeout_ms);
}

/* --- easy-handle callbacks ------------------------------------------------ */

static size_t af_tramp_write(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    if (nmemb != 0 && size > SIZE_MAX / nmemb) {
        return 0;
    }
    size_t length = size * nmemb;
    int64_t taken = af_prov_on_write(userdata, ptr, length);

    if (taken == AF_CURL_TAKE_PAUSE) {
        return CURL_WRITEFUNC_PAUSE;
    }
    if (taken < 0) {
        /* Any short return aborts the transfer; returning 0 for a non-empty
         * body is libcurl's documented way to say so. */
        return 0;
    }
    return (size_t)taken;
}

static size_t af_tramp_header(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    if (nmemb != 0 && size > SIZE_MAX / nmemb) {
        return 0;
    }
    size_t length = size * nmemb;
    int64_t taken = af_prov_on_header(userdata, ptr, length);

    if (taken < 0) {
        return 0;
    }
    return (size_t)taken;
}

static size_t af_mcp_http_tramp_write(char *ptr, size_t size, size_t nmemb,
                                      void *userdata)
{
    if (nmemb != 0 && size > SIZE_MAX / nmemb) {
        return 0;
    }
    size_t length = size * nmemb;
    int64_t taken = af_mcp_http_on_write(userdata, ptr, length);

    if (taken == AF_CURL_TAKE_PAUSE) {
        return CURL_WRITEFUNC_PAUSE;
    }
    if (taken < 0) {
        return 0;
    }
    return (size_t)taken;
}

static size_t af_mcp_http_tramp_header(char *ptr, size_t size, size_t nmemb,
                                       void *userdata)
{
    if (nmemb != 0 && size > SIZE_MAX / nmemb) {
        return 0;
    }
    size_t length = size * nmemb;
    int64_t taken = af_mcp_http_on_header(userdata, ptr, length);

    if (taken < 0) {
        return 0;
    }
    return (size_t)taken;
}

/* --- process-wide setup ---------------------------------------------------
 *
 * curl_global_init is not thread-safe and must run before any handle exists.
 * The daemon is single-threaded (ADR 0002) and calls this once at startup.
 */

int af_curl_global_init(void)
{
    return (int)curl_global_init(CURL_GLOBAL_DEFAULT);
}

void af_curl_global_cleanup(void)
{
    curl_global_cleanup();
}

const char *af_curl_version(void)
{
    return curl_version();
}

/* --- the multi handle ----------------------------------------------------- */

/* A multi handle whose socket and timer callbacks carry `user`. Returns NULL
 * if libcurl could not create it or could not accept a callback, so a partial
 * handle never escapes this function. */
void *af_curl_multi_new(void *user)
{
    CURLM *multi = curl_multi_init();

    if (multi == NULL) {
        return NULL;
    }
    if (curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION, af_tramp_socket) != CURLM_OK
        || curl_multi_setopt(multi, CURLMOPT_SOCKETDATA, user) != CURLM_OK
        || curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION, af_tramp_timer) != CURLM_OK
        || curl_multi_setopt(multi, CURLMOPT_TIMERDATA, user) != CURLM_OK) {
        curl_multi_cleanup(multi);
        return NULL;
    }
    return multi;
}

/* A distinct multi handle for MCP HTTP. It is driven by the same AsmFlow
 * epoll loop, but its callback state and completion policy stay in src/mcp/. */
void *af_curl_mcp_multi_new(void *user)
{
    CURLM *multi = curl_multi_init();

    if (multi == NULL) {
        return NULL;
    }
    if (curl_multi_setopt(multi, CURLMOPT_SOCKETFUNCTION,
                          af_mcp_http_tramp_socket) != CURLM_OK
        || curl_multi_setopt(multi, CURLMOPT_SOCKETDATA, user) != CURLM_OK
        || curl_multi_setopt(multi, CURLMOPT_TIMERFUNCTION,
                             af_mcp_http_tramp_timer) != CURLM_OK
        || curl_multi_setopt(multi, CURLMOPT_TIMERDATA, user) != CURLM_OK) {
        curl_multi_cleanup(multi);
        return NULL;
    }
    return multi;
}

void af_curl_multi_free(void *multi)
{
    if (multi != NULL) {
        curl_multi_cleanup((CURLM *)multi);
    }
}

int af_curl_multi_add(void *multi, void *easy)
{
    return (int)curl_multi_add_handle((CURLM *)multi, (CURL *)easy);
}

int af_curl_multi_remove(void *multi, void *easy)
{
    return (int)curl_multi_remove_handle((CURLM *)multi, (CURL *)easy);
}

/* Drive the transfer set because `fd` became readable, writable, or failed.
 * `out_running` receives the number of transfers still in flight. */
int af_curl_multi_socket_action(void *multi, int64_t fd, int64_t ev_bitmask,
                                int64_t *out_running)
{
    int running = 0;
    CURLMcode code = curl_multi_socket_action((CURLM *)multi, (curl_socket_t)fd,
                                              (int)ev_bitmask, &running);

    if (out_running != NULL) {
        *out_running = (int64_t)running;
    }
    return (int)code;
}

/* Drive the transfer set because the timer libcurl asked for has expired. */
int af_curl_multi_socket_timeout(void *multi, int64_t *out_running)
{
    int running = 0;
    CURLMcode code = curl_multi_socket_action((CURLM *)multi, CURL_SOCKET_TIMEOUT,
                                              0, &running);

    if (out_running != NULL) {
        *out_running = (int64_t)running;
    }
    return (int)code;
}

/* Reap one finished transfer.
 *
 * Returns 1 and fills the out-params when a transfer completed, 0 when none
 * has. `out_private` is the CURLOPT_PRIVATE pointer the caller attached, which
 * is how assembly finds the exchange a finished handle belongs to; reading it
 * here rather than making the caller call back in keeps CURLMsg's layout on
 * this side of the boundary.
 */
int af_curl_multi_next_done(void *multi, void **out_easy, int *out_result,
                            void **out_private)
{
    int queued = 0;
    CURLMsg *message = curl_multi_info_read((CURLM *)multi, &queued);

    while (message != NULL && message->msg != CURLMSG_DONE) {
        message = curl_multi_info_read((CURLM *)multi, &queued);
    }
    if (message == NULL) {
        return 0;
    }
    if (out_easy != NULL) {
        *out_easy = message->easy_handle;
    }
    if (out_result != NULL) {
        *out_result = (int)message->data.result;
    }
    if (out_private != NULL) {
        char *private_pointer = NULL;

        curl_easy_getinfo(message->easy_handle, CURLINFO_PRIVATE, &private_pointer);
        *out_private = private_pointer;
    }
    return 1;
}

/* --- easy handles ---------------------------------------------------------- */

/* A handle whose write and header callbacks carry `user`, and whose private
 * pointer is `user` as well. Nothing else is configured: every property that
 * matters to security or behaviour is a setter the caller must call. */
void *af_curl_easy_new(void *user)
{
    CURL *easy = curl_easy_init();

    if (easy == NULL) {
        return NULL;
    }
    if (curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, af_tramp_write) != CURLE_OK
        || curl_easy_setopt(easy, CURLOPT_WRITEDATA, user) != CURLE_OK
        || curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION, af_tramp_header) != CURLE_OK
        || curl_easy_setopt(easy, CURLOPT_HEADERDATA, user) != CURLE_OK
        || curl_easy_setopt(easy, CURLOPT_PRIVATE, user) != CURLE_OK) {
        curl_easy_cleanup(easy);
        return NULL;
    }
    return easy;
}

/* As above, but response bytes can only enter the MCP HTTP adapter. */
void *af_curl_mcp_easy_new(void *user)
{
    CURL *easy = curl_easy_init();

    if (easy == NULL) {
        return NULL;
    }
    if (curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION,
                         af_mcp_http_tramp_write) != CURLE_OK
        || curl_easy_setopt(easy, CURLOPT_WRITEDATA, user) != CURLE_OK
        || curl_easy_setopt(easy, CURLOPT_HEADERFUNCTION,
                            af_mcp_http_tramp_header) != CURLE_OK
        || curl_easy_setopt(easy, CURLOPT_HEADERDATA, user) != CURLE_OK
        || curl_easy_setopt(easy, CURLOPT_PRIVATE, user) != CURLE_OK) {
        curl_easy_cleanup(easy);
        return NULL;
    }
    return easy;
}

void af_curl_easy_free(void *easy)
{
    if (easy != NULL) {
        curl_easy_cleanup((CURL *)easy);
    }
}

int af_curl_set_url(void *easy, const char *url)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_URL, url);
}

/* The schemes this handle may reach, as libcurl's comma-separated list. The
 * caller states it; there is no default here, because "a gateway cannot be
 * talked into opening a file:// URL" is a property AsmFlow asserts rather than
 * one it inherits. */
int af_curl_set_protocols(void *easy, const char *csv)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_PROTOCOLS_STR, csv);
}

int af_curl_set_follow_location(void *easy, int64_t on)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_FOLLOWLOCATION, (long)on);
}

int af_curl_set_http_get(void *easy)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_HTTPGET, 1L);
}

/* An empty proxy string overrides libcurl's proxy environment discovery. The
 * assembly caller chooses this policy explicitly for configured origins. */
int af_curl_disable_proxy(void *easy)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_PROXY, "");
}

int af_curl_set_tls_verify(void *easy, int64_t peer, int64_t host)
{
    CURLcode code = curl_easy_setopt((CURL *)easy, CURLOPT_SSL_VERIFYPEER, (long)peer);

    if (code != CURLE_OK) {
        return (int)code;
    }
    /* 2 is "verify the name", not a boolean. libcurl treats 1 as an error. */
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_SSL_VERIFYHOST,
                                 host != 0 ? 2L : 0L);
}

/* libcurl must not install signal handlers or use alarm(): the daemon owns its
 * signal disposition through signalfd (ADR 0009). */
int af_curl_set_nosignal(void *easy, int64_t on)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_NOSIGNAL, (long)on);
}

int af_curl_set_post(void *easy, const char *body, int64_t length)
{
    CURLcode code = curl_easy_setopt((CURL *)easy, CURLOPT_POST, 1L);

    if (code != CURLE_OK) {
        return (int)code;
    }
    /* POSTFIELDS does not copy: the caller owns `body` until the transfer
     * finishes. Ownership stays in assembly on purpose (invariant 2). */
    code = curl_easy_setopt((CURL *)easy, CURLOPT_POSTFIELDSIZE_LARGE,
                            (curl_off_t)length);
    if (code != CURLE_OK) {
        return (int)code;
    }
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_POSTFIELDS, body);
}

int af_curl_set_headers(void *easy, void *slist)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_HTTPHEADER, (struct curl_slist *)slist);
}

int af_curl_set_connect_timeout_ms(void *easy, int64_t ms)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_CONNECTTIMEOUT_MS, (long)ms);
}

int af_curl_set_timeout_ms(void *easy, int64_t ms)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_TIMEOUT_MS, (long)ms);
}

/* The stall detector: fewer than `bytes_per_second` bytes for `seconds` fails
 * the transfer. It is what makes `timeouts.idle_stream_ms` mean something for
 * a stream that is open but producing nothing. */
int af_curl_set_low_speed(void *easy, int64_t bytes_per_second, int64_t seconds)
{
    CURLcode code = curl_easy_setopt((CURL *)easy, CURLOPT_LOW_SPEED_LIMIT,
                                     (long)bytes_per_second);

    if (code != CURLE_OK) {
        return (int)code;
    }
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_LOW_SPEED_TIME, (long)seconds);
}

/* An empty string asks for every encoding libcurl can decode; NULL sends no
 * Accept-Encoding at all. AsmFlow forwards upstream bytes unchanged, so the
 * caller passes NULL — but it passes it, rather than relying on the default. */
int af_curl_set_accept_encoding(void *easy, const char *value)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_ACCEPT_ENCODING, value);
}

int af_curl_set_verbose(void *easy, int64_t on)
{
    return (int)curl_easy_setopt((CURL *)easy, CURLOPT_VERBOSE, (long)on);
}

/* Suspend or resume delivery of the response body. `paused` non-zero stops the
 * write callback being called; zero resumes it, which can deliver buffered
 * bytes re-entrantly before this call returns. */
int af_curl_pause(void *easy, int64_t paused)
{
    return (int)curl_easy_pause((CURL *)easy, paused != 0 ? CURLPAUSE_RECV : CURLPAUSE_CONT);
}

int64_t af_curl_response_code(void *easy)
{
    long status = 0;

    if (curl_easy_getinfo((CURL *)easy, CURLINFO_RESPONSE_CODE, &status) != CURLE_OK) {
        return 0;
    }
    return (int64_t)status;
}

/* Microseconds spent establishing the connection, or 0 if it never connected.
 * That is what separates "the connection timed out" from "the response did". */
int64_t af_curl_connect_time_us(void *easy)
{
    curl_off_t microseconds = 0;

    if (curl_easy_getinfo((CURL *)easy, CURLINFO_CONNECT_TIME_T, &microseconds) != CURLE_OK) {
        return 0;
    }
    return (int64_t)microseconds;
}

const char *af_curl_strerror(int code)
{
    return curl_easy_strerror((CURLcode)code);
}

const char *af_curl_multi_strerror(int code)
{
    return curl_multi_strerror((CURLMcode)code);
}

/* --- header lists ---------------------------------------------------------- */

void *af_curl_slist_append(void *slist, const char *line)
{
    return curl_slist_append((struct curl_slist *)slist, line);
}

void af_curl_slist_free(void *slist)
{
    curl_slist_free_all((struct curl_slist *)slist);
}

/* --- enumerator ordinals ---------------------------------------------------
 *
 * The ADR 0007 pattern: the C side reports what the library's constants are,
 * and assembly asserts its own copies against them at startup rather than
 * hard-coding numbers that a header could change. include/provider.inc lists
 * these in the same order.
 */

/* CURL_POLL_NONE, IN, OUT, INOUT, REMOVE, then CURL_SOCKET_TIMEOUT and the
 * three CURL_CSELECT_* bits. */
void af_curl_poll_ordinals(int64_t *out9)
{
    out9[0] = CURL_POLL_NONE;
    out9[1] = CURL_POLL_IN;
    out9[2] = CURL_POLL_OUT;
    out9[3] = CURL_POLL_INOUT;
    out9[4] = CURL_POLL_REMOVE;
    out9[5] = (int64_t)CURL_SOCKET_TIMEOUT;
    out9[6] = CURL_CSELECT_IN;
    out9[7] = CURL_CSELECT_OUT;
    out9[8] = CURL_CSELECT_ERR;
}

/* The CURLE_* codes provider_error.asm classifies, in include/provider.inc
 * order. A code absent from this list is classified as "some other upstream
 * failure", which is a safe default because it is not retryable. */
void af_curl_error_ordinals(int64_t *out16)
{
    out16[0] = CURLE_OK;
    out16[1] = CURLE_COULDNT_RESOLVE_PROXY;
    out16[2] = CURLE_COULDNT_RESOLVE_HOST;
    out16[3] = CURLE_COULDNT_CONNECT;
    out16[4] = CURLE_OPERATION_TIMEDOUT;
    out16[5] = CURLE_SSL_CONNECT_ERROR;
    out16[6] = CURLE_PEER_FAILED_VERIFICATION;
    out16[7] = CURLE_SSL_CACERT_BADFILE;
    out16[8] = CURLE_SSL_ISSUER_ERROR;
    out16[9] = CURLE_GOT_NOTHING;
    out16[10] = CURLE_PARTIAL_FILE;
    out16[11] = CURLE_RECV_ERROR;
    out16[12] = CURLE_SEND_ERROR;
    out16[13] = CURLE_WRITE_ERROR;
    out16[14] = CURLE_ABORTED_BY_CALLBACK;
    out16[15] = CURLE_UNSUPPORTED_PROTOCOL;
}

/* CURLM_OK, and the size of the write-callback pause sentinel, so a test can
 * confirm the trampoline above is returning the value this libcurl expects. */
void af_curl_multi_ordinals(int64_t *out3)
{
    out3[0] = CURLM_OK;
    out3[1] = (int64_t)CURL_WRITEFUNC_PAUSE;
    out3[2] = CURLPAUSE_RECV;
}
