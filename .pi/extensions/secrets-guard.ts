/**
 * Secrets Guard (home-ops)
 *
 * Fail-closed guard against writing plaintext secrets into this repository.
 *
 * Checks `write`, `edit`, and `bash` tool calls for:
 *   - sensitive filenames (.env, *.pem, id_*, credentials, secrets, age keys)
 *   - obvious secret content (private keys, age secret keys, AWS/GitHub/OpenAI/Slack tokens, JWTs)
 *
 * A target that Git ignores is allowed, because the concern is secrets reaching
 * version control. Anything else is confirmed interactively, and blocked when
 * there is no UI (print/JSON/RPC) so unattended runs cannot leak secrets.
 *
 * Toggle at runtime with /secrets-guard off | on.
 *
 * NOTE: heuristics, not a guarantee. SOPS-encrypted files and `*.sops.*` are allowed.
 */

import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const SENSITIVE_NAME: RegExp[] = [
  /(^|\/)\.env(\.[^/]+)?$/i,
  /(^|\/)id_(rsa|dsa|ecdsa|ed25519)$/i,
  /\.(pem|key|p12|pfx|jks|ppk)$/i,
  /(^|\/)credentials(\.(json|ya?ml|toml))?$/i,
  /(^|\/)secrets?(\.(json|ya?ml|toml|txt))?$/i,
  /age-key(\.txt)?$/i,
  /(^|\/)\.netrc$/i,
  /(^|\/)\.npmrc$/i,
];

const ALLOWED_NAME: RegExp[] = [
  /\.env\.(example|sample|template|dist)$/i,
  /\.sops\./i,
  /(^|\/)\.sops\.yaml$/,
  /(^|\/)fnox\.toml$/,
  /\.pub$/i,
];

const SECRET_CONTENT: RegExp[] = [
  /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/,
  /AGE-SECRET-KEY-1[0-9A-Z]{20,}/,
  /\bAKIA[0-9A-Z]{16}\b/,
  /\bASIA[0-9A-Z]{16}\b/,
  /\bgh[pousr]_[A-Za-z0-9]{30,}\b/,
  /\bsk-(?:proj-)?[A-Za-z0-9_-]{20,}\b/,
  /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
  /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
];

function collectStrings(value: unknown, out: string[]): void {
  if (typeof value === "string") {
    out.push(value);
  } else if (Array.isArray(value)) {
    for (const item of value) collectStrings(item, out);
  } else if (value && typeof value === "object") {
    for (const item of Object.values(value as Record<string, unknown>)) collectStrings(item, out);
  }
}

// Well-known documented placeholder values (AWS docs examples, obvious dummies).
const PLACEHOLDER =
  /^(AKIAIOSFODNN7EXAMPLE|ASIAIOSFODNN7EXAMPLE|EXAMPLE|PLACEHOLDER|CHANGEME|changeme|xxx+|your[-_]?key.*)$/i;

function matchSecretContent(text: string): string | undefined {
  for (const re of SECRET_CONTENT) {
    const m = re.exec(text);
    if (m && !PLACEHOLDER.test(m[0])) return m[0].slice(0, 40);
  }
  return undefined;
}

function sensitiveName(path: string): boolean {
  if (ALLOWED_NAME.some((re) => re.test(path))) return false;
  return SENSITIVE_NAME.some((re) => re.test(path));
}

export default function (pi: ExtensionAPI) {
  let enabled = true;

  pi.registerCommand("secrets-guard", {
    description: "Show or toggle the home-ops plaintext-secrets guard",
    handler: async (arg, ctx) => {
      const value = (arg || "").trim().toLowerCase();
      if (value === "on") enabled = true;
      else if (value === "off") enabled = false;
      else if (value !== "") {
        ctx.ui.notify("Usage: /secrets-guard on|off", "warning");
        return;
      }
      ctx.ui.notify(`secrets-guard: ${enabled ? "on" : "off"}`, "info");
    },
  });

  async function isGitIgnored(path: string, cwd: string): Promise<boolean> {
    if (!path) return false;
    try {
      const result = await pi.exec("git", ["check-ignore", "-q", "--", path], { cwd });
      return result.code === 0;
    } catch {
      return false;
    }
  }

  async function confirmOrBlock(reason: string, ctx: ExtensionContext) {
    if (ctx.hasUI) {
      const ok = await ctx.ui.confirm("Secrets guard: possible plaintext secret", reason);
      if (ok) return undefined;
      return { block: true, reason: `Blocked by secrets guard: ${reason}` };
    }
    return { block: true, reason: `Blocked by secrets guard (no UI to confirm): ${reason}` };
  }

  pi.on("tool_call", async (event, ctx) => {
    if (!enabled) return undefined;

    // write / edit: inspect path and content
    if (event.toolName === "write" || event.toolName === "edit") {
      const path = String((event.input as { path?: unknown }).path ?? "");
      const strings: string[] = [];
      collectStrings(event.input, strings);
      const contentHit = matchSecretContent(strings.join("\n"));

      const nameHit = sensitiveName(path);
      if (nameHit) {
        if (await isGitIgnored(path, ctx.cwd)) return undefined;
        return confirmOrBlock(`writing "${path}" matches a sensitive filename pattern`, ctx);
      }
      if (contentHit) {
        if (path && (await isGitIgnored(path, ctx.cwd))) return undefined;
        return confirmOrBlock(
          `content for "${path || "file"}" looks like a secret (${contentHit}…)`,
          ctx,
        );
      }
      return undefined;
    }

    // bash: catch redirects / git add / cp / mv targeting sensitive names,
    // and here-docs / printf / echo containing secret content.
    if (event.toolName === "bash") {
      const command = String((event.input as { command?: unknown }).command ?? "");
      if (!command) return undefined;

      const referenced: string[] = [];
      // redirects: > path, >> path, tee path, cp/mv ... path
      const redirectRe =
        /(?:>>?\s*|tee\s+(?:-a\s+)?|(?:cp|mv|install)\s+(?:-\S+\s+)*\S+\s+)(["']?)([^\s"'|;&>)]+)\1/g;
      let m: RegExpExecArray | null;
      while ((m = redirectRe.exec(command)) !== null) referenced.push(m[2]);

      for (const path of referenced) {
        if (!sensitiveName(path)) continue;
        if (await isGitIgnored(path, ctx.cwd)) continue;
        return confirmOrBlock(`bash writes to sensitive path "${path}"`, ctx);
      }

      // git add/commit on sensitive paths
      if (/\bgit\s+(?:add|commit)\b/.test(command)) {
        for (const path of referenced) {
          if (sensitiveName(path) && !(await isGitIgnored(path, ctx.cwd))) {
            return confirmOrBlock(`git staging of sensitive path "${path}"`, ctx);
          }
        }
        const bare = command.match(/\b(\.env(\.[\w-]+)?|id_(?:rsa|ed25519)|[^\s]*\.(?:pem|key))\b/);
        if (bare && !(await isGitIgnored(bare[1], ctx.cwd))) {
          return confirmOrBlock(`git command references sensitive path "${bare[1]}"`, ctx);
        }
      }

      const contentHit = matchSecretContent(command);
      if (contentHit) {
        return confirmOrBlock(
          `bash command contains what looks like a secret (${contentHit}…)`,
          ctx,
        );
      }
      return undefined;
    }

    return undefined;
  });
}
