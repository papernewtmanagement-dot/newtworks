// Bundles the Earning Potential chart with the browser-only imports stubbed,
// then runs the render checks under Node. The theme and the money formatter
// are the REAL modules, so colour and format changes are exercised for real.
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdirSync, rmSync } from "node:fs";

const here = dirname(fileURLToPath(import.meta.url));
const stub = (f) => join(here, "stubs", f);
const STUBBED = {
  "../lib/supabase.js": stub("supabase.js"),
  "../lib/routing.jsx": stub("routing.jsx"),
  "../lib/hooks.js":    stub("hooks.js"),
};

const scratch = join(here, ".build");
mkdirSync(scratch, { recursive: true });
const outfile = join(scratch, "bundle.mjs");
await build({
  entryPoints: [join(here, "render-checks.jsx")],
  bundle: true, platform: "node", format: "esm", jsx: "automatic",
  // react-dom/server pulls Node built-ins through require(); leave them external
  // so the ESM bundle does not try to inline them.
  packages: "external",
  outfile, logLevel: "error",
  plugins: [{
    name: "stub-browser-only-libs",
    setup(b) {
      b.onResolve({ filter: /^\.\.\/lib\// }, (a) =>
        STUBBED[a.path] ? { path: STUBBED[a.path] } : undefined);
    },
  }],
});

const { run } = await import(outfile);
const ok = run();
rmSync(scratch, { recursive: true, force: true });
process.exit(ok ? 0 : 1);
