import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { execSync } from "node:child_process";
import * as fs from "node:fs";
import * as http from "node:http";
import * as os from "node:os";
import * as path from "node:path";
import * as core from "./pi-extension-core.js";

const CLAWD_SERVER_ID = "hey-clawd";
const CLAWD_SERVER_HEADER = "x-clawd-server";
const DEFAULT_SERVER_PORT = 23333;
const SERVER_PORT_COUNT = 5;
const SERVER_PORTS = Array.from({ length: SERVER_PORT_COUNT }, (_, i) => DEFAULT_SERVER_PORT + i);
const RUNTIME_CONFIG_PATH = path.join(os.homedir(), ".clawd", "runtime.json");
const STATE_PATH = "/state";

type ClawdState = "idle" | "thinking" | "working" | "attention" | "sweeping" | "sleeping";
type ClawdEvent =
	| "SessionStart"
	| "UserPromptSubmit"
	| "PreToolUse"
	| "PostToolUse"
	| "PostToolUseFailure"
	| "Stop"
	| "PreCompact"
	| "PostCompact"
	| "SessionEnd";

type StatePayload = {
	state: ClawdState;
	session_id: string;
	event: ClawdEvent;
	cwd?: string;
	agent_id: "pi";
	agent_pid: number;
	source_pid?: number;
	editor?: "code" | "cursor";
};

type ProcessMetadata = {
	sourcePid?: number;
	editor?: "code" | "cursor";
};

type ExtensionContextLike = {
	cwd?: string;
	sessionManager?: { getSessionId?: () => string | undefined };
};

type ExtensionContextWithUI = ExtensionContextLike & { hasUI?: boolean };

const TERMINAL_NAMES_WIN = new Set([
	"windowsterminal.exe", "cmd.exe", "powershell.exe", "pwsh.exe",
	"code.exe", "cursor.exe", "alacritty.exe", "wezterm-gui.exe", "mintty.exe",
	"conemu64.exe", "conemu.exe", "hyper.exe", "tabby.exe",
	"antigravity.exe", "warp.exe", "iterm.exe", "ghostty.exe",
]);
const TERMINAL_NAMES_MAC = new Set([
	"terminal", "iterm2", "alacritty", "wezterm-gui", "kitty",
	"hyper", "tabby", "warp", "ghostty",
]);
const TERMINAL_NAMES_LINUX = new Set([
	"gnome-terminal", "kgx", "konsole", "xfce4-terminal", "tilix",
	"alacritty", "wezterm", "wezterm-gui", "kitty", "ghostty",
	"xterm", "lxterminal", "terminator", "tabby", "hyper", "warp",
]);

const SYSTEM_BOUNDARY_WIN = new Set(["explorer.exe", "services.exe", "winlogon.exe", "svchost.exe"]);
const SYSTEM_BOUNDARY_MAC = new Set(["launchd", "init", "systemd"]);
const SYSTEM_BOUNDARY_LINUX = new Set(["systemd", "init"]);

const EDITOR_MAP_WIN: Record<string, "code" | "cursor"> = { "code.exe": "code", "cursor.exe": "cursor" };
const EDITOR_MAP_MAC: Record<string, "code" | "cursor"> = { "code": "code", "cursor": "cursor" };
const EDITOR_MAP_LINUX: Record<string, "code" | "cursor"> = { "code": "code", "cursor": "cursor", "code-insiders": "code" };

const { shouldReport: shouldReportCore, buildPayload: buildPayloadCore, attach: attachCore } = core as {
	shouldReport: (
		ctx: { hasUI?: boolean } | undefined,
		runtime?: { argv?: string[]; stdinIsTTY?: boolean; stdoutIsTTY?: boolean }
	) => boolean;
	buildPayload: (input: {
		state: ClawdState;
		event: ClawdEvent;
		ctx?: ExtensionContextLike;
		metadata?: ProcessMetadata;
		agentPid?: number;
	}) => StatePayload;
	attach: (
		pi: ExtensionAPI,
		deps: {
			shouldReport: (ctx: unknown) => boolean;
			buildPayload: (state: ClawdState, event: ClawdEvent, ctx: unknown) => StatePayload;
			postState: (payload: StatePayload) => Promise<boolean>;
		}
	) => void;
};

let cachedProcessMetadata: ProcessMetadata | null = null;

function normalizePort(value: unknown): number | null {
	const port = Number(value);
	return Number.isInteger(port) && SERVER_PORTS.includes(port) ? port : null;
}

function readRuntimePort(): number | null {
	try {
		const raw = JSON.parse(fs.readFileSync(RUNTIME_CONFIG_PATH, "utf8"));
		if (!raw || typeof raw !== "object") return null;
		return normalizePort((raw as { port?: unknown }).port);
	} catch {
		return null;
	}
}

function getPortCandidates(): number[] {
	const runtimePort = readRuntimePort();
	const seen = new Set<number>();
	const ports: number[] = [];
	const add = (value: number | null) => {
		if (!value || seen.has(value)) return;
		seen.add(value);
		ports.push(value);
	};
	add(runtimePort);
	for (const port of SERVER_PORTS) add(port);
	return ports;
}

function isClawdResponse(res: http.IncomingMessage, body: string): boolean {
	const headerValue = res.headers[CLAWD_SERVER_HEADER];
	const header = Array.isArray(headerValue) ? headerValue[0] : headerValue;
	if (header === CLAWD_SERVER_ID) return true;
	if (!body) return false;
	try {
		const data = JSON.parse(body) as { app?: string };
		return data.app === CLAWD_SERVER_ID;
	} catch {
		return false;
	}
}

function postState(payload: StatePayload, timeoutMs = 120): Promise<boolean> {
	const body = JSON.stringify(payload);
	const ports = getPortCandidates();
	let index = 0;

	return new Promise((resolve) => {
		const tryNext = () => {
			if (index >= ports.length) {
				resolve(false);
				return;
			}

			const port = ports[index++];
			let settled = false;
			const finish = (ok: boolean) => {
				if (settled) return;
				settled = true;
				if (ok) {
					resolve(true);
					return;
				}
				tryNext();
			};

			const req = http.request(
				{
					hostname: "127.0.0.1",
					port,
					path: STATE_PATH,
					method: "POST",
					headers: {
						"Content-Type": "application/json",
						"Content-Length": Buffer.byteLength(body),
					},
					timeout: timeoutMs,
				},
				(res) => {
					let responseBody = "";
					res.setEncoding("utf8");
					res.on("data", (chunk) => {
						if (responseBody.length < 256) responseBody += chunk;
					});
					res.on("end", () => {
						finish(isClawdResponse(res, responseBody));
					});
				}
			);

			req.on("error", () => finish(false));
			req.on("timeout", () => {
				req.destroy();
				finish(false);
			});
			req.end(body);
		};

		tryNext();
	});
}

function getProcessInfo(pid: number): { parentPid: number | null; name: string; fullCommand: string } | null {
	const isWin = process.platform === "win32";
	try {
		if (isWin) {
			const out = execSync(
				`wmic process where "ProcessId=${pid}" get Name,ParentProcessId,ExecutablePath /format:csv`,
				{ encoding: "utf8", timeout: 1500, windowsHide: true }
			);
			const lines = out.trim().split("\n").filter((line) => line.includes(","));
			if (!lines.length) return null;
			const parts = lines[lines.length - 1].split(",");
			const name = (parts[1] || "").trim().toLowerCase();
			const parentPid = Number.parseInt(parts[2], 10);
			const fullCommand = (parts[3] || "").trim();
			return {
				parentPid: Number.isInteger(parentPid) ? parentPid : null,
				name,
				fullCommand,
			};
		}

		const parentPidOut = execSync(`ps -o ppid= -p ${pid}`, { encoding: "utf8", timeout: 1000 }).trim();
		const commandOut = execSync(`ps -o comm= -p ${pid}`, { encoding: "utf8", timeout: 1000 }).trim();
		const parentPid = Number.parseInt(parentPidOut, 10);
		return {
			parentPid: Number.isInteger(parentPid) ? parentPid : null,
			name: path.basename(commandOut).toLowerCase(),
			fullCommand: commandOut,
		};
	} catch {
		return null;
	}
}

function getProcessMetadata(): ProcessMetadata {
	if (cachedProcessMetadata) return cachedProcessMetadata;

	const isWin = process.platform === "win32";
	const terminalNames = isWin ? TERMINAL_NAMES_WIN : (process.platform === "linux" ? TERMINAL_NAMES_LINUX : TERMINAL_NAMES_MAC);
	const systemBoundary = isWin ? SYSTEM_BOUNDARY_WIN : (process.platform === "linux" ? SYSTEM_BOUNDARY_LINUX : SYSTEM_BOUNDARY_MAC);
	const editorMap = isWin ? EDITOR_MAP_WIN : (process.platform === "linux" ? EDITOR_MAP_LINUX : EDITOR_MAP_MAC);
	let pid: number | null = process.pid;
	let sourcePid: number | undefined;
	let editor: "code" | "cursor" | undefined;

	for (let i = 0; i < 8 && pid && pid > 1; i++) {
		const info = getProcessInfo(pid);
		if (!info) break;

		if (!editor) {
			const fullLower = info.fullCommand.toLowerCase();
			if (fullLower.includes("visual studio code")) editor = "code";
			else if (fullLower.includes("cursor.app")) editor = "cursor";
			else if (editorMap[info.name]) editor = editorMap[info.name];
		}

		if (terminalNames.has(info.name)) sourcePid = pid;
		if (systemBoundary.has(info.name)) break;
		if (!info.parentPid || info.parentPid === pid || info.parentPid <= 1) break;
		pid = info.parentPid;
	}

	cachedProcessMetadata = { sourcePid, editor };
	return cachedProcessMetadata;
}

export default function (pi: ExtensionAPI) {
	attachCore(pi, {
		shouldReport: (ctx: unknown) => shouldReportCore(ctx as ExtensionContextWithUI | undefined),
		buildPayload: (state: ClawdState, event: ClawdEvent, ctx: unknown) =>
			buildPayloadCore({
				state,
				event,
				ctx: ctx as ExtensionContextLike,
				metadata: getProcessMetadata(),
				agentPid: process.pid,
			}),
		postState,
	});
}
