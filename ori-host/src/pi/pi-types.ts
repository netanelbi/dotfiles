/**
 * pi's own protocol types, re-exported. NOTHING here is transcribed -- these are
 * the declarations pi ships and validates its own RPC mode against
 * (`dist/modes/rpc/rpc-types.d.ts`, `dist/modes/json-event.d.ts`, both
 * re-exported from `dist/index.d.ts`).
 *
 * WHY THE IMPORT IS AN ABSOLUTE PATH
 * ----------------------------------
 * pi is installed globally (`~/.bun/install/global/node_modules/`), which is not
 * an ancestor of this project, so node-style resolution never reaches it. Its
 * package.json `exports` map also publishes only ".", "./rpc-entry" and
 * "./client", so even a deep specifier would be blocked. Both were checked:
 * `@earendil-works/pi-coding-agent` and
 * `@earendil-works/pi-coding-agent/dist/modes/rpc/rpc-types.d.ts` each fail with
 * TS2307 from here.
 *
 * The alternative was copying ~400 lines of union out by hand, and
 * ARCHITECTURE.md rule 3 is explicit that a pi frame shape is never re-declared
 * -- the whole point of this rewrite is that the wire format is parsed once, by
 * pi's own definitions. So the path is hardcoded, ONCE, in this file, and every
 * other module imports from here.
 *
 * This costs nothing at runtime: every import below is `import type`, which Bun
 * erases before the file is ever executed. Only `tsc --noEmit` reads the path.
 * The tidy fix is a `paths` entry in tsconfig.json (or linking the package into
 * node_modules); this file is then a one-line change.
 */

import type {
  JsonAgentSessionEvent,
  RpcCommand,
  RpcResponse,
  RpcSessionState,
} from "/home/netanel/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/dist/index.d.ts";

export type { JsonAgentSessionEvent, RpcCommand, RpcResponse, RpcSessionState };

/**
 * One record on pi's stdout. pi emits exactly two kinds: correlated replies to
 * a command (`type: "response"`) and session events. `agent_settled` is the idle
 * signal, not `agent_end` -- see ARCHITECTURE.md.
 */
export type PiFrame = RpcResponse | JsonAgentSessionEvent;

/** Narrow a frame to a correlated command reply. */
export function isRpcResponse(frame: PiFrame): frame is RpcResponse {
  return (frame as { type?: unknown }).type === "response";
}
