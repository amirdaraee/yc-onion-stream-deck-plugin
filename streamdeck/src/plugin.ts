import streamDeck, {
  action,
  type DidReceiveSettingsEvent,
  type KeyDownEvent,
  SingletonAction,
  type SendToPluginEvent,
  type WillAppearEvent
} from "@elgato/streamdeck";
import { spawn } from "node:child_process";
import { chmod, mkdir, readFile, rm, unlink, writeFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { homedir, platform, tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

type Settings = {
  operation?: string;
  brightness?: number;
  kelvin?: number;
  hue?: number;
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
const controllerVersion = "1.3.0";
const windowsController = join(pluginRoot, "controllers", "windows", "yc-onion.ps1");

let controllerPreparation: Promise<void> | undefined;

type DeviceRecord = {
  name: string;
  id: string;
  rssi: number;
  serial: string;
  manufacturer: string;
};

async function runMacController(args: string[]): Promise<{ code: number | null; stdout: string; stderr: string }> {
  if (!controllerPreparation) {
    controllerPreparation = prepareMacController().catch(error => {
      controllerPreparation = undefined;
      throw error;
    });
  }
  await controllerPreparation;
  return new Promise((resolve, reject) => {
    const request = randomUUID();
    const stdoutPath = join(tmpdir(), `yc-onion-${request}.out`);
    const stderrPath = join(tmpdir(), `yc-onion-${request}.err`);
    const child = spawn("/usr/bin/open", [
      "-n", "-W", "--stdout", stdoutPath, "--stderr", stderrPath,
      controllerApp, "--args", ...args
    ], {
      stdio: "ignore"
    });
    child.once("error", reject);
    child.once("exit", async code => {
      const [stdout, stderr] = await Promise.all([
        readFile(stdoutPath, "utf8").catch(() => ""),
        readFile(stderrPath, "utf8").catch(() => "")
      ]);
      await Promise.all([unlink(stdoutPath).catch(() => {}), unlink(stderrPath).catch(() => {})]);
      if (stdout.trim()) streamDeck.logger.info(stdout.trim());
      resolve({ code, stdout, stderr });
    });
  });
}

async function prepareMacController(): Promise<void> {
  const installedVersion = await readFile(controllerMarker, "utf8").catch(() => "");
  if (installedVersion.trim() === controllerVersion) {
    await chmod(controllerBinary, 0o755);
    return;
  }

  // Marketplace-protected plugin files are immutable. The signed helper is
  // therefore shipped as an archive and expanded into writable application
  // support rather than modified inside the installed plugin bundle.
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

function runController(args: string[]): Promise<{ code: number | null; stdout: string; stderr: string }> {
  if (platform() === "darwin") return runMacController(args);
  return new Promise((resolve, reject) => {
    if (platform() === "win32") {
      const child = spawn("powershell.exe", [
        "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
        "-File", windowsController, ...args
      ], { windowsHide: true });
      let stdout = "";
      let stderr = "";
      child.stdout?.setEncoding("utf8").on("data", chunk => { stdout += chunk; });
      child.stderr?.setEncoding("utf8").on("data", chunk => { stderr += chunk; });
      child.once("error", reject);
      child.once("exit", code => resolve({ code, stdout, stderr }));
      return;
    }
    reject(new Error(`Unsupported Stream Deck host: ${platform()}`));
  });
}

async function control(args: string[]): Promise<void> {
  const result = await runController(args);
  if ((result.code ?? 1) !== 0 || result.stderr.trim()) {
    throw new Error(result.stderr.trim() || `Controller launcher exited with ${result.code}`);
  }
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
    try {
      await control(this.arguments(ev.payload.settings));
      await ev.action.showOk();
    } catch (error) {
      streamDeck.logger.error(String(error));
      await ev.action.setTitle("ERROR");
      await ev.action.showAlert();
    }
  }

  override async onWillAppear(ev: WillAppearEvent<Settings>): Promise<void> {
    await ev.action.setTitle(this.title(ev.payload.settings));
  }

  override async onDidReceiveSettings(ev: DidReceiveSettingsEvent<Settings>): Promise<void> {
    await ev.action.setTitle(this.title(ev.payload.settings));
  }

  override async onSendToPlugin(ev: SendToPluginEvent<{ type?: string }, Settings>): Promise<void> {
    const message = ev.payload;
    if (message.type !== "listDevices") return;
    try {
      const result = await runController(["devices"]);
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

streamDeck.actions.registerAction(new PowerAction());
streamDeck.actions.registerAction(new BrightnessAction());
streamDeck.actions.registerAction(new CCTAction());
streamDeck.actions.registerAction(new ColorAction());
streamDeck.actions.registerAction(new EffectAction());
streamDeck.actions.registerAction(new RawBLEAction());
streamDeck.connect();
