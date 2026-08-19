import { readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const packageJson = JSON.parse(await readFile(new URL("streamdeck/package.json", root), "utf8"));
const manifest = JSON.parse(await readFile(
  new URL("streamdeck/com.amirdaraee.yc-onion.sdPlugin/manifest.json", root),
  "utf8"
));
const pluginSource = await readFile(new URL("streamdeck/src/plugin.ts", root), "utf8");

const packageVersion = packageJson.version;
const expectedManifest = `${packageVersion}.0`;
const controllerMatch = pluginSource.match(/const controllerVersion = "([^"]+)";/);

if (manifest.Version !== expectedManifest) {
  throw new Error(`Manifest version ${manifest.Version} does not match package version ${packageVersion}.`);
}
if (controllerMatch?.[1] !== packageVersion) {
  throw new Error(`Controller version ${controllerMatch?.[1] ?? "missing"} does not match package version ${packageVersion}.`);
}

const tag = process.env.GITHUB_REF_TYPE === "tag" ? process.env.GITHUB_REF_NAME : undefined;
if (tag && tag !== `v${packageVersion}`) {
  throw new Error(`Release tag ${tag} must match v${packageVersion}.`);
}

console.log(`Release versions agree: ${packageVersion}`);
