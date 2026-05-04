#!/usr/bin/env node
// Purpose: Create a GitHub App in an org via the manifest flow, no Backstage CLI.
// Usage:   node scripts/create-gh-app.mjs <org> <app-name-slug> <role>
//          role = "backstage" | "argocd"
// Output:  prints credentials to stdout as YAML; also writes private/<role>-github.yaml
import http from "node:http";
import { writeFileSync, mkdirSync } from "node:fs";
import { exec } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "..");

const [, , ORG, APP_SLUG, ROLE] = process.argv;
if (!ORG || !APP_SLUG || !ROLE) {
  console.error("Usage: node create-gh-app.mjs <org> <app-name-slug> <backstage|argocd>");
  process.exit(2);
}
if (!["backstage", "argocd"].includes(ROLE)) {
  console.error("role must be 'backstage' or 'argocd'");
  process.exit(2);
}

const PORT = 39876;
const CALLBACK = `http://127.0.0.1:${PORT}/callback`;

const manifestByRole = {
  backstage: {
    name: APP_SLUG,
    url: "https://backstage.local",
    hook_attributes: { url: "https://backstage.local/api/github/webhook", active: false },
    redirect_url: CALLBACK,
    public: false,
    default_permissions: {
      administration: "write",
      contents: "write",
      metadata: "read",
      members: "read",
      organization_administration: "read",
    },
    default_events: [],
  },
  argocd: {
    name: APP_SLUG,
    url: "https://argocd.local",
    hook_attributes: { url: "https://argocd.local/webhook", active: false },
    redirect_url: CALLBACK,
    public: false,
    default_permissions: {
      contents: "read",
      metadata: "read",
      checks: "read",
      members: "read",
    },
    default_events: [],
  },
};
const manifest = manifestByRole[ROLE];

const STATE = Math.random().toString(36).slice(2);
const postUrl = `https://github.com/organizations/${ORG}/settings/apps/new?state=${STATE}`;

// Minimal HTML form that auto-submits the manifest via POST to GitHub.
const formHtml = `<!doctype html><html><body onload="document.forms[0].submit()">
<form action="${postUrl}" method="post">
<input type="hidden" name="manifest" value='${JSON.stringify(manifest).replace(/'/g, "&apos;")}'/>
<noscript><button type="submit">Create app</button></noscript>
</form></body></html>`;

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`);
  if (url.pathname === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(formHtml);
    return;
  }
  if (url.pathname === "/callback") {
    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    if (!code || state !== STATE) {
      res.writeHead(400); res.end("bad state/code"); return;
    }
    res.writeHead(200, { "content-type": "text/html" });
    res.end(`<h2>App "${APP_SLUG}" created. You can close this tab.</h2>`);
    try {
      const r = await fetch(`https://api.github.com/app-manifests/${code}/conversions`, {
        method: "POST", headers: { accept: "application/vnd.github+json" },
      });
      if (!r.ok) throw new Error(`conversion failed: ${r.status} ${await r.text()}`);
      const data = await r.json();
      // data has: id, slug, name, owner, html_url, pem, webhook_secret, client_id, client_secret, ...
      mkdirSync(path.join(REPO_ROOT, "private"), { recursive: true });
      let out;
      if (ROLE === "backstage") {
        out =
`appId: ${data.id}
webhookUrl: ${data.html_url}
clientId: ${data.client_id}
clientSecret: ${data.client_secret}
webhookSecret: ${data.webhook_secret}
privateKey: |
${data.pem.split("\n").map(l => "  " + l).join("\n")}
`;
      } else {
        // For argocd we need installationId. We will fetch after you install the app.
        // Write placeholder for now; wrapper script will patch later.
        out =
`url: https://github.com/${ORG}
appId: "${data.id}"
installationId: "PENDING_INSTALL"
privateKey: |
${data.pem.split("\n").map(l => "  " + l).join("\n")}
`;
      }
      const outfile = path.join(REPO_ROOT, "private", `${ROLE}-github.yaml`);
      writeFileSync(outfile, out);
      console.error(`\n✓ wrote ${outfile}`);
      console.error(`App URL: ${data.html_url}`);
      console.error(`Next: install this app on your fork at:\n  https://github.com/organizations/${ORG}/settings/installations`);
      // Print the installation URL GitHub already provides
      console.error(`  (direct install link: ${data.html_url}/installations/new)`);
      setTimeout(() => process.exit(0), 250);
    } catch (e) {
      console.error("ERROR:", e);
      process.exit(1);
    }
    return;
  }
  res.writeHead(404); res.end();
});

server.listen(PORT, "127.0.0.1", () => {
  const openUrl = `http://127.0.0.1:${PORT}/`;
  console.error(`Open in browser:  ${openUrl}`);
  console.error(`(auto-submits manifest to GitHub; you will be asked to confirm and create the app)`);
  // Try to open default browser on macOS
  exec(`open ${openUrl}`);
});
