import { describe, expect, test } from "bun:test";
import {
  buildArgv,
  buildEnv,
  buildShellCommand,
  buildWorkdir,
  EXTENSIONS,
  expandTilde,
  PROMPT_FILES,
  SHIM_URL,
  shQuote,
  type PiSpawnConfig,
} from "../src/pi/argv";

const HOME = "/home/tester";

/** The only filesystem fact buildArgv needs, injected. */
function cfg(over: Partial<PiSpawnConfig> = {}): PiSpawnConfig {
  return {
    provider: "ollama",
    model: "glm-5.3-flash",
    home: HOME,
    exists: () => true,
    ...over,
  };
}

/** Value following `flag`, or undefined. */
function after(argv: string[], flag: string): string | undefined {
  const i = argv.indexOf(flag);
  return i === -1 ? undefined : argv[i + 1];
}

function allAfter(argv: string[], flag: string): string[] {
  const out: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === flag) {
      const v = argv[i + 1];
      if (v !== undefined) out.push(v);
    }
  }
  return out;
}

describe("buildArgv", () => {
  test("the flags ori-agent argued for are all present, in order", () => {
    const argv = buildArgv(cfg());
    expect(argv.slice(0, 9)).toEqual([
      "pi",
      "--mode",
      "rpc",
      "-ne",
      "-nc",
      "--provider",
      "ollama",
      "--model",
      "glm-5.3-flash",
    ]);
  });

  test("all four prompt files and all six extensions are passed", () => {
    const argv = buildArgv(cfg());
    expect(allAfter(argv, "--append-system-prompt")).toHaveLength(4);
    expect(allAfter(argv, "-e")).toHaveLength(6);
    expect(PROMPT_FILES).toHaveLength(4);
    expect(EXTENSIONS).toHaveLength(6);
  });

  test("~ is expanded in prompt files and extensions", () => {
    const argv = buildArgv(cfg());
    for (const p of allAfter(argv, "--append-system-prompt")) {
      expect(p.startsWith(HOME + "/")).toBe(true);
    }
    for (const e of allAfter(argv, "-e")) {
      expect(e.startsWith(HOME + "/")).toBe(true);
    }
    expect(allAfter(argv, "--append-system-prompt")).toContain(
      `${HOME}/.config/assistant/soul.md`,
    );
  });

  test("the existence check is asked about the EXPANDED path", () => {
    const asked: string[] = [];
    buildArgv(
      cfg({
        exists: (p) => {
          asked.push(p);
          return true;
        },
      }),
    );
    expect(asked).toHaveLength(4);
    for (const p of asked) expect(p).not.toContain("~");
  });

  test("a missing prompt file is SKIPPED, not passed", () => {
    // The trap: pi tells a path from literal prompt text with existsSync(), so a
    // path that does not resolve is prepended to the system prompt as text.
    const missing = `${HOME}/.config/assistant/memory.md`;
    const argv = buildArgv(cfg({ exists: (p) => p !== missing }));
    const prompts = allAfter(argv, "--append-system-prompt");
    expect(prompts).toHaveLength(3);
    expect(prompts).not.toContain(missing);
    expect(argv).not.toContain(missing);
  });

  test("no prompt file exists -> no --append-system-prompt at all", () => {
    const argv = buildArgv(cfg({ exists: () => false }));
    expect(argv).not.toContain("--append-system-prompt");
  });

  test("--thinking is omitted when effort is empty or absent", () => {
    expect(buildArgv(cfg())).not.toContain("--thinking");
    expect(buildArgv(cfg({ effort: "" }))).not.toContain("--thinking");
    expect(after(buildArgv(cfg({ effort: "medium" })), "--thinking")).toBe("medium");
  });

  test("--session-id is present only when a session id is given, and --session never is", () => {
    const none = buildArgv(cfg());
    expect(none).not.toContain("--session-id");
    expect(none).not.toContain("--session");

    const some = buildArgv(cfg({ sessionId: "2026-09-05T10:04:11" }));
    expect(after(some, "--session-id")).toBe("2026-09-05T10:04:11");
    expect(some).not.toContain("--session");
  });

  test("empty provider/model fall back rather than emitting a bare flag", () => {
    const argv = buildArgv(cfg({ provider: "", model: "" }));
    expect(after(argv, "--provider")).toBe("ollama");
    expect(after(argv, "--model")).toBe("glm-5.3-flash");
  });

  test("is pure: same config, same argv, and the input is not mutated", () => {
    const c = cfg({ effort: "high" });
    const frozen = JSON.stringify({ ...c, exists: undefined });
    const a = buildArgv(c);
    const b = buildArgv(c);
    expect(a).toEqual(b);
    expect(JSON.stringify({ ...c, exists: undefined })).toBe(frozen);
  });
});

describe("expandTilde", () => {
  test("handles ~, ~/x and leaves everything else alone", () => {
    expect(expandTilde("~", HOME)).toBe(HOME);
    expect(expandTilde("~/a/b", HOME)).toBe(`${HOME}/a/b`);
    expect(expandTilde("/abs", HOME)).toBe("/abs");
    expect(expandTilde("rel/x", HOME)).toBe("rel/x");
    // ~user is not a form this project uses; mangling it would be worse.
    expect(expandTilde("~root/x", HOME)).toBe("~root/x");
  });
});

describe("buildEnv", () => {
  test("SHIM_URL always; ORI_DETACH_PATH only when there is a detach file", () => {
    expect(buildEnv(cfg())).toEqual({ SHIM_URL });
    expect(buildEnv(cfg({ detachPath: "" }))).toEqual({ SHIM_URL });
    expect(buildEnv(cfg({ detachPath: "/run/user/1000/ori-detach-9-1" }))).toEqual({
      SHIM_URL,
      ORI_DETACH_PATH: "/run/user/1000/ori-detach-9-1",
    });
  });

  test("SHIM_URL is the VPS, not a local port that can fail closed", () => {
    expect(SHIM_URL).toBe("https://ollama.ncym.uk");
  });
});

describe("buildShellCommand", () => {
  test("sh -lc, cd into an expanded workdir, exec pi", () => {
    const c = cfg();
    const cmd = buildShellCommand(buildArgv(c), buildWorkdir(c));
    expect(cmd[0]).toBe("sh");
    expect(cmd[1]).toBe("-lc");
    expect(cmd[2]).toStartWith(`cd '${HOME}/.dotfiles' && exec 'pi'`);
  });

  test("session ids with colons survive quoting", () => {
    const c = cfg({ sessionId: "2026-09-05T10:04:11" });
    const line = buildShellCommand(buildArgv(c), buildWorkdir(c))[2] ?? "";
    expect(line).toContain("--session-id' '2026-09-05T10:04:11'");
  });

  test("shQuote closes a single quote safely", () => {
    expect(shQuote("it's")).toBe(`'it'\\''s'`);
  });
});
