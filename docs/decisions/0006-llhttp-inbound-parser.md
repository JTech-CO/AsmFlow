# ADR 0006: Use llhttp for inbound HTTP/1.1 syntax parsing

- Status: Accepted
- Date: 2026-08-02

## Context

AsmFlow needs a bounded, incremental HTTP/1.1 listener for loopback OpenAI-compatible
requests. Hand-writing a complete HTTP parser in assembly would consume disproportionate
scope and create request-smuggling and framing risks unrelated to the product's routing
and supervision experiment. A full embedded web framework would instead own too much of
the event loop and response lifecycle.

## Decision

AsmFlow will own listener sockets, epoll integration, connection state, limits,
authentication, route dispatch, response writing, and backpressure in assembly. It will
use llhttp through a fixed-width C ABI shim only for incremental HTTP/1.1 syntax and body
framing callbacks.

Leniency modes remain disabled. AsmFlow performs additional policy checks after parsing,
including header-name validation, duplicate framing-header rejection, total-size limits,
method/path/content-type allowlists, and `Content-Length` versus `Transfer-Encoding`
conflict rejection.

## Consequences

- Chunked and fragmented requests can be parsed without implementing an independent HTTP
  grammar in assembly.
- The llhttp callback surface becomes a security-sensitive FFI boundary and requires
  corpus, fragmentation, smuggling, allocation-failure, and ABI tests.
- No routing, authentication, request-size, or response-commit policy may enter the C shim.
- Binary releases must include llhttp in the SBOM and third-party notices according to its
  license and distribution method.
