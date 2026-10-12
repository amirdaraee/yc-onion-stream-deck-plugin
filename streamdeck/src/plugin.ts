import streamDeck, {
  action,
  type DidReceiveSettingsEvent,
  type KeyDownEvent,
  SingletonAction,
  type SendToPluginEvent,
  type WillAppearEvent
} from "@elgato/streamdeck";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { chmod, mkdir, open as openFile, readFile, rm, unlink, writeFile } from "node:fs/promises";
import { homedir, platform, tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

type Settings = {
  operation?: string;
  brightness?: number;
  kelvin?: number;
  hue?: number;
  cycleIndex?: number;
  saturation?: number;
  family?: string;
  effectId?: number;
  speed?: number;
  device?: string;
  deviceLabel?: string;
  serial?: string;
  service?: string;
  write?: string;
  packet?: string;
};

const pluginRoot = fileURLToPath(new URL("..", import.meta.url));
const controllerArchive = join(pluginRoot, "controllers", "mac", "YC Onion Controller.zip");
const controllerRuntime = join(homedir(), "Library", "Application Support", "YCOnion", "runtime");
const controllerApp = join(controllerRuntime, "YC Onion Controller.app");
const controllerBinary = join(controllerApp, "Contents", "MacOS", "yc-onion");
const controllerMarker = join(controllerRuntime, ".version");
const controllerVersion = "1.3.8";
const windowsController = join(pluginRoot, "controllers", "windows", "yc-onion.ps1");
const controllerTimeoutMs = 18_000;
const maxCapturedOutput = 64 * 1024;

let controllerPreparation: Promise<void> | undefined;
let controllerBusy = false;

type DeviceRecord = {
  name: string;
  id: string;
  rssi: number;
  serial: string;
  manufacturer: string;
};

function captureChunk(current: string, chunk: string): string {
  if (current.length >= maxCapturedOutput) return current;
  return current + chunk.slice(0, maxCapturedOutput - current.length);
}

async function readCapturedFile(path: string): Promise<string> {
  let handle: Awaited<ReturnType<typeof openFile>> | undefined;
  try {
    handle = await openFile(path, "r");
    const buffer = Buffer.alloc(maxCapturedOutput);
    const { bytesRead } = await handle.read(buffer, 0, buffer.length, 0);
    return buffer.toString("utf8", 0, bytesRead);
  } catch {
    return "";
  } finally {
    await handle?.close().catch(() => {});
  }
}

type ControllerResult = { code: number | null; signal: NodeJS.Signals | null; stdout: string; stderr: string };

function executeController(command: string, args: string[], options: { windowsHide?: boolean } = {}): Promise<ControllerResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { ...options, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let timedOut = false;
    let forceKill: NodeJS.Timeout | undefined;
    const timeout = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      forceKill = setTimeout(() => child.kill("SIGKILL"), 1_000);
    }, controllerTimeoutMs);
    const finish = (error?: Error, code: number | null = null, signal: NodeJS.Signals | null = null) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (forceKill) clearTimeout(forceKill);
      if (error) reject(error);
      else if (timedOut) reject(new Error(`YC Onion controller timed out after ${controllerTimeoutMs / 1000} seconds.`));
      else resolve({ code, signal, stdout, stderr });
    };
    child.stdout?.setEncoding("utf8").on("data", chunk => { stdout = captureChunk(stdout, chunk); });
    child.stderr?.setEncoding("utf8").on("data", chunk => { stderr = captureChunk(stderr, chunk); });
    child.once("error", error => finish(error));
    child.once("close", (code, signal) => finish(undefined, code, signal));
  });
}

async function runMacController(args: string[]): Promise<ControllerResult> {
  if (!controllerPreparation) {
    controllerPreparation = prepareMacController().catch(error => {
      controllerPreparation = undefined;
      throw error;
    });
  }
  await controllerPreparation;
  // Launch via LaunchServices to apply the helper's Bluetooth privacy text.
  const requestId = randomUUID();
  const stdoutPath = join(tmpdir(), `yc-onion-${requestId}.out`);
  const stderrPath = join(tmpdir(), `yc-onion-${requestId}.err`);
  try {
    const launcher = await executeController("/usr/bin/open", [
      "-n", "-W", "--stdout", stdoutPath, "--stderr", stderrPath,
      controllerApp, "--args", ...args
    ]);
    const [appStdout, appStderr] = await Promise.all([
      readCapturedFile(stdoutPath),
      readCapturedFile(stderrPath)
    ]);
    const result = {
      code: launcher.code,
      signal: launcher.signal,
      stdout: captureChunk(launcher.stdout, appStdout),
      stderr: captureChunk(launcher.stderr, appStderr)
    };
    if (result.stdout.trim()) streamDeck.logger.info(result.stdout.trim());
    return result;
  } finally {
    await Promise.all([unlink(stdoutPath).catch(() => {}), unlink(stderrPath).catch(() => {})]);
  }
}

async function prepareMacController(): Promise<void> {
  const installedVersion = await readFile(controllerMarker, "utf8").catch(() => "");
  if (installedVersion.trim() === controllerVersion) {
    await chmod(controllerBinary, 0o755);
    return;
  }

  // The plugin bundle is read-only; unpack the helper into Application Support.
  await rm(controllerRuntime, { recursive: true, force: true });
  await mkdir(controllerRuntime, { recursive: true });
  await new Promise<void>((resolve, reject) => {
    const child = spawn("/usr/bin/ditto", ["-x", "-k", controllerArchive, controllerRuntime], {
      stdio: "ignore"
    });
    child.once("error", reject);
    child.once("exit", code => code === 0 ? resolve() : reject(new Error(`Controller extraction exited with ${code}`)));
  });
  await chmod(controllerBinary, 0o755);
  await writeFile(controllerMarker, `${controllerVersion}\n`, "utf8");
}

function runController(args: string[]): Promise<ControllerResult> {
  if (platform() === "darwin") return runMacController(args);
  return new Promise((resolve, reject) => {
    if (platform() === "win32") {
      executeController("powershell.exe", [
        "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", windowsController, ...args
      ], { windowsHide: true }).then(resolve, reject);
      return;
    }
    reject(new Error(`Unsupported Stream Deck host: ${platform()}`));
  });
}

async function runExclusiveController(args: string[]): Promise<ControllerResult | undefined> {
  if (controllerBusy) return undefined;
  controllerBusy = true;
  try {
    const result = await runController(args);
    if ((result.code ?? 1) !== 0 || result.stderr.trim()) {
      const exit = result.code === null ? `signal ${result.signal ?? "unknown"}` : `code ${result.code}`;
      throw new Error(result.stderr.trim() || `Controller launcher exited with ${exit}`);
    }
    return result;
  } finally {
    controllerBusy = false;
  }
}

async function control(args: string[]): Promise<boolean> {
  return (await runExclusiveController(args)) !== undefined;
}

function parseDevices(stdout: string): DeviceRecord[] {
  return stdout
    .split(/\r?\n/)
    .map(line => line.trim())
    .filter(Boolean)
    .map(line => {
      const match = line.match(/^(.*?)\s+id=(.*?)\s+rssi=(-?\d+)\s+serial=([0-9a-fA-F]+|unknown)\s+manufacturer=([0-9a-fA-F]+|none)$/);
      if (!match) return null;
      return {
        name: match[1],
        id: match[2],
        rssi: Number(match[3]),
        serial: match[4] === "unknown" ? "" : match[4],
        manufacturer: match[5] === "none" ? "" : match[5]
      } satisfies DeviceRecord;
    })
    .filter((device): device is DeviceRecord => device !== null);
}

function targetArgs(settings: Settings): string[] {
  const args: string[] = [];
  if (settings.device) {
    args.push("--device", settings.device);
  }
  if (settings.serial) {
    args.push("--serial", settings.serial);
  }
  return args;
}

abstract class ControllerAction extends SingletonAction<Settings> {
  abstract arguments(settings: Settings): string[];
  abstract title(settings: Settings): string;

  override async onKeyDown(ev: KeyDownEvent<Settings>): Promise<void> {
    const settings = ev.payload.settings;
    await ev.action.setTitle("...");
    try {
      const started = await control(this.arguments(settings));
      if (!started) {
        await ev.action.setTitle(this.title(settings));
        return;
      }
      await ev.action.showOk();
      await ev.action.setTitle(this.title(settings));
    } catch (error) {
      streamDeck.logger.error(String(error));
      await ev.action.setTitle("ERROR");
      await ev.action.showAlert();
    }
  }

  override async onWillAppear(ev: WillAppearEvent<Settings>): Promise<void> {
    if (ev.action.isKey()) {
      await ev.action.setTitle(this.title(ev.payload.settings));
    }
  }

  override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>): Promise<void> {
    if (ev.action.isKey()) {
      await ev.action.setTitle(this.title(ev.payload.settings));
    }
  }

  override async onSendToPlugin(ev: SendToPluginEvent<{ type?: string }, Settings>): Promise<void> {
    const message = ev.payload;
    if (message.type !== "listDevices") return;
    try {
      const result = await runExclusiveController(["devices"]);
      if (!result) {
        await streamDeck.ui.sendToPropertyInspector({
          type: "devices",
          error: "A YC Onion command is in progress. Try again in a moment."
        });
        return;
      }
      const devices = parseDevices(result.stdout);
      await streamDeck.ui.sendToPropertyInspector({
        type: "devices",
        devices
      });
    } catch (error) {
      await streamDeck.ui.sendToPropertyInspector({
        type: "devices",
        error: String(error)
      });
    }
  }
}

@action({ UUID: "com.amirdaraee.yc-onion.power" })
class PowerAction extends ControllerAction {
  arguments(s: Settings): string[] { return [s.operation ?? "toggle", ...targetArgs(s)]; }
  title(s: Settings): string { return (s.operation ?? "toggle").toUpperCase(); }
}

@action({ UUID: "com.amirdaraee.yc-onion.brightness" })
class BrightnessAction extends ControllerAction {
  arguments(s: Settings): string[] { return ["brightness", String(s.brightness ?? 50), ...targetArgs(s)]; }
  title(s: Settings): string { return `${s.brightness ?? 50}%`; }
}

@action({ UUID: "com.amirdaraee.yc-onion.cct" })
class CCTAction extends ControllerAction {
  arguments(s: Settings): string[] { return ["cct", String(s.kelvin ?? 4500), String(s.brightness ?? 60), ...targetArgs(s)]; }
  title(s: Settings): string { return `${s.kelvin ?? 4500}K`; }
}

@action({ UUID: "com.amirdaraee.yc-onion.color" })
class ColorAction extends ControllerAction {
  arguments(s: Settings): string[] {
    return ["hsi", String(s.hue ?? 0), String(s.saturation ?? 100), String(s.brightness ?? 60), ...targetArgs(s)];
  }
  title(s: Settings): string { return `H ${s.hue ?? 0}°`; }
}

const cycleColors = [
  { name: "RED", hue: 0 },
  { name: "ORANGE", hue: 30 },
  { name: "YELLOW", hue: 60 },
  { name: "GREEN", hue: 120 },
  { name: "CYAN", hue: 180 },
  { name: "BLUE", hue: 240 },
  { name: "PURPLE", hue: 270 },
  { name: "MAGENTA", hue: 300 }
] as const;

function lastCycleIndex(value: number | undefined): number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value < cycleColors.length ? value : -1;
}

@action({ UUID: "com.amirdaraee.yc-onion.color-cycle" })
class ColorCycleAction extends ControllerAction {
  private readonly lastColors = new Map<string, number>();

  arguments(s: Settings): string[] {
    const next = (lastCycleIndex(s.cycleIndex) + 1) % cycleColors.length;
    return ["hsi", String(cycleColors[next].hue), String(s.saturation ?? 100), String(s.brightness ?? 100), ...targetArgs(s)];
  }

  title(s: Settings): string {
    const last = lastCycleIndex(s.cycleIndex);
    return last < 0 ? "CYCLE" : cycleColors[last].name;
  }

  override async onKeyDown(ev: KeyDownEvent<Settings>): Promise<void> {
    const id = ev.action.id;
    const settings = ev.payload.settings;
    const last = this.lastColors.get(id) ?? lastCycleIndex(settings.cycleIndex);
    const next = (last + 1) % cycleColors.length;
    await ev.action.setTitle("...");
    try {
      const started = await control(this.arguments({ ...settings, cycleIndex: last }));
      if (!started) {
        await ev.action.setTitle(this.title(settings));
        return;
      }
      this.lastColors.set(id, next);
      await ev.action.setSettings({ ...settings, cycleIndex: next });
      await ev.action.setTitle(cycleColors[next].name);
      await ev.action.showOk();
    } catch (error) {
      streamDeck.logger.error(String(error));
      await ev.action.setTitle("ERROR");
      await ev.action.showAlert();
    }
  }
}

@action({ UUID: "com.amirdaraee.yc-onion.effect" })
class EffectAction extends ControllerAction {
  arguments(s: Settings): string[] {
    return ["effect", s.family ?? "rgb", String(s.effectId ?? 1), String(s.speed ?? 50), String(s.brightness ?? 60), ...targetArgs(s)];
  }
  title(s: Settings): string { return `${(s.family ?? "rgb").toUpperCase()} FX`; }
}

@action({ UUID: "com.amirdaraee.yc-onion.raw" })
class RawBLEAction extends ControllerAction {
  arguments(s: Settings): string[] {
    return [
      "raw",
      s.packet ?? "00",
      "--service", s.service ?? "FFE0",
      "--write", s.write ?? "FFE1",
      ...targetArgs(s)
    ];
  }
  title(s: Settings): string { return s.device ? "BLE\nSEND" : "SET\nDEVICE"; }
}

// Preserve settings events for the supported Stream Deck 6.9 hosts.
streamDeck.settings.useLegacySettingsBehavior = true;

streamDeck.actions.registerAction(new PowerAction());
streamDeck.actions.registerAction(new BrightnessAction());
streamDeck.actions.registerAction(new CCTAction());
streamDeck.actions.registerAction(new ColorAction());
streamDeck.actions.registerAction(new ColorCycleAction());
streamDeck.actions.registerAction(new EffectAction());
streamDeck.actions.registerAction(new RawBLEAction());
streamDeck.connect();
