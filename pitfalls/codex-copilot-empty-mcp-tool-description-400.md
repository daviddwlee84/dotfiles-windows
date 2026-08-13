# codex-copilot fails with empty MCP tool description HTTP 400

**Symptoms**: `Invalid 'input[0].tools[0].description': empty string. Expected a string with minimum length 1`; `invalid_request_body`; `POST /responses 400`
**First seen**: 2026-08
**Affects**: Codex CLI through `@jeffreycao/copilot-api@2.1.0` and GitHub Copilot Responses
**Status**: fixed in the managed compatibility shim

## Symptom

```text
Invalid 'input[0].tools[0].description': empty string. Expected a string with minimum length 1, but got an empty string instead.
```

The model is served and the request reaches GitHub, but inference never starts.

## Root cause

Codex records MCP discovery as Responses `mcp_list_tools` input items. An MCP
tool may omit its description, but GitHub Copilot's Responses validator requires
at least one character. This is a payload-schema mismatch, not entitlement or
network failure.
Codex 0.147 also zstd-compresses this request, so the shim must decode it before
the tool definitions are visible.

## Workaround

Apply the managed module and use `codex-copilot`. It always starts and targets
the shim on port 4142; the shim fills only blank tool-definition descriptions.

## Prevention

- Keep both repositories' `copilot-throttle-shim.js` byte-identical.
- Never let `codex-copilot` fall back directly to port 4141.
- The shim logs repaired JSON paths without request content.
