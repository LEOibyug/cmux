// Run with: node --test scripts/lib/mobile-attach.test.mjs
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import { fileURLToPath } from "node:url";
import path from "node:path";
import test from "node:test";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const validator = path.join(repoRoot, "scripts/lib/mobile-attach.sh");
const reservedMessage = "reserved for the stable app instance";

function run(command, args, extraEnv = {}) {
  return spawnSync(command, args, {
    cwd: repoRoot,
    encoding: "utf8",
    env: { ...process.env, ...extraEnv },
  });
}

function validate(tag) {
  return run("bash", [
    "-c",
    'source "$1"; cmux_attach_validate_dev_tag "$2"',
    "mobile-attach-test",
    validator,
    tag,
  ]);
}

function resolveDevAPIBaseURL(fallback, override = "") {
  return run("bash", [
    "-c",
    'source "$1"; CMUX_DEV_API_BASE_URL="$3" cmux_attach_resolve_dev_api_base_url "$2"',
    "mobile-attach-test",
    validator,
    fallback,
    override,
  ]);
}

function removeStaleSocket(socketPath) {
  return run(
    "bash",
    [
      "-c",
      [
        'source "$1"',
        'cmux_attach_socket_path() { printf "%s" "$CMUX_TEST_SOCKET"; }',
        'cmux_attach_remove_stale_socket "release-gate"',
      ].join("; "),
      "mobile-attach-test",
      validator,
    ],
    { CMUX_TEST_SOCKET: socketPath },
  );
}

function waitForUsableSession(
  status = 0,
  baseline = "100",
  timeout = "15",
  event = '{"seq":101,"name":"mobile.rpc.ready","payload":{"connection_id":"connection-a","client_id":"phone-a","transport":"iroh","stream_id":"events"}}',
  expectedClientID = "phone-a",
  graceSeconds = "0",
) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-admission-test-"));
  const argsPath = path.join(tempRoot, "args");

  try {
    const result = run(
      "bash",
      [
        "-c",
        [
          'source "$1"',
          'cmux_attach_events() {',
          '  shift 2',
          '  printf "%s\\n" "$*" > "$CMUX_TEST_ARGS"',
          '  [[ "$CMUX_TEST_STATUS" == "0" ]] && printf "%s\\n" "$CMUX_TEST_EVENT"',
          '  return "$CMUX_TEST_STATUS"',
          '}',
          'cmux_attach_wait_for_usable_session "ready" "$2" "$3" "$4" "$5"',
        ].join("\n"),
        "mobile-admission-test",
        validator,
        repoRoot,
        baseline,
        timeout,
        expectedClientID,
      ],
      {
        CMUX_TEST_ARGS: argsPath,
        CMUX_TEST_EVENT: event,
        CMUX_TEST_STATUS: String(status),
        CMUX_ATTACH_READY_GRACE_SECONDS: graceSeconds,
      },
    );
    result.eventArgs = fs.existsSync(argsPath) ? fs.readFileSync(argsPath, "utf8").trim() : "";
    return result;
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function writeReadinessReceipt(eventJSON) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-receipt-test-"));
  const receiptPath = path.join(tempRoot, "receipt.json");
  const result = run(
    "bash",
    [
      "-c",
      [
        'source "$1"',
        'cmux_attach_write_readiness_receipt "$2" "$3" iosrdy dev.cmux.ios.iosrdy physical_device phone-a iosrdy /tmp/cmux-debug-iosrdy.sock 8421 1 "$4"',
      ].join("\n"),
      "mobile-readiness-receipt-test",
      validator,
      receiptPath,
      "0123456789abcdef0123456789abcdef01234567",
      eventJSON,
    ],
  );
  result.receipt = fs.existsSync(receiptPath)
    ? JSON.parse(fs.readFileSync(receiptPath, "utf8"))
    : null;
  result.directoryMode = fs.statSync(tempRoot).mode & 0o777;
  result.receiptMode = fs.existsSync(receiptPath)
    ? fs.statSync(receiptPath).mode & 0o777
    : null;
  fs.rmSync(tempRoot, { recursive: true, force: true });
  return result;
}

function readinessCursor(snapshot) {
  return run(
    "bash",
    [
      "-c",
      [
        'source "$1"',
        'cmux_attach_events() { printf "%s\\n" "$CMUX_TEST_SNAPSHOT"; }',
        'cmux_attach_readiness_cursor "ready" "$2"',
      ].join("\n"),
      "mobile-admission-cursor-test",
      validator,
      repoRoot,
    ],
    { CMUX_TEST_SNAPSHOT: snapshot },
  );
}

function monotonicMilliseconds() {
  return run("bash", [
    "-c",
    'source "$1"; cmux_attach_monotonic_milliseconds',
    "mobile-monotonic-clock-test",
    validator,
  ]);
}


async function mintAttachURL(target, payload, maxAttempts = 1) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-attach-test-"));
  const scriptsDir = path.join(tempRoot, "scripts");
  const socketPath = path.join(tempRoot, "mobile.sock");
  const payloadDirectory = path.join(tempRoot, "payloads");
  const callCounterPath = path.join(tempRoot, "call-count");
  fs.mkdirSync(scriptsDir);
  fs.mkdirSync(payloadDirectory);
  const payloads = Array.isArray(payload) ? payload : [payload];
  payloads.forEach((value, index) => {
    const response = value?.cliResponse;
    fs.writeFileSync(
      path.join(payloadDirectory, `${index + 1}.stdout`),
      response ? (response.stdout ?? "") : (value == null ? "" : JSON.stringify(value)),
    );
    fs.writeFileSync(
      path.join(payloadDirectory, `${index + 1}.stderr`),
      response?.stderr ?? "",
    );
    fs.writeFileSync(
      path.join(payloadDirectory, `${index + 1}.status`),
      String(response?.status ?? 0),
    );
  });
  const fakeCLI = path.join(scriptsDir, "cmux-debug-cli.sh");
  fs.writeFileSync(
    fakeCLI,
    [
      "#!/usr/bin/env bash",
      'count="$(cat "$CMUX_TEST_CALL_COUNTER" 2>/dev/null || printf 0)"',
      'count="$((count + 1))"',
      'printf "%s" "$count" > "$CMUX_TEST_CALL_COUNTER"',
      'payload="$CMUX_TEST_PAYLOAD_DIRECTORY/$count"',
      '[[ -f "$payload.stdout" ]] && cat "$payload.stdout"',
      '[[ -f "$payload.stderr" ]] && cat "$payload.stderr" >&2',
      'status="$(cat "$payload.status" 2>/dev/null || printf 0)"',
      'exit "$status"',
      "",
    ].join("\n"),
  );
  fs.chmodSync(fakeCLI, 0o755);

  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });

  try {
    const result = spawnSync(
      "bash",
      [
        "-c",
        [
          'source "$1"',
          'cmux_attach_socket_path() { printf "%s" "$CMUX_TEST_SOCKET"; }',
          'cmux_attach_mint_url "test" 60 "$2" "$3" "$4"',
        ].join("; "),
        "mobile-attach-test",
        validator,
        tempRoot,
        target,
        String(maxAttempts),
      ],
      {
        cwd: repoRoot,
        encoding: "utf8",
        env: {
          ...process.env,
          CMUX_TEST_CALL_COUNTER: callCounterPath,
          CMUX_TEST_PAYLOAD_DIRECTORY: payloadDirectory,
          CMUX_TEST_SOCKET: socketPath,
        },
      },
    );
    result.callCount = fs.existsSync(callCounterPath)
      ? Number.parseInt(fs.readFileSync(callCounterPath, "utf8"), 10)
      : 0;
    return result;
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

async function ensureMacAfterRelaunch({ forceRelaunch = false, readyAtCall = 2 } = {}) {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-mobile-ready-test-"));
  const socketPath = path.join(tempRoot, "mobile.sock");
  const appPath = path.join(tempRoot, "cmux DEV ready.app");
  const callCounterPath = path.join(tempRoot, "call-count");
  const pkillArgsPath = path.join(tempRoot, "pkill-args");
  fs.mkdirSync(appPath);

  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });

  try {
    const result = spawnSync(
      "bash",
      [
        "-c",
        [
          'source "$1"',
          'cmux_attach_enable_pairing_host() { :; }',
          'cmux_attach_socket_path() { printf "%s" "$CMUX_TEST_SOCKET"; }',
          'cmux_attach_mac_app_path() { printf "%s" "$CMUX_TEST_APP"; }',
          'cmux_attach__slug() { printf "ready"; }',
          'cmux_attach_mint_url() {',
          '  count="$(cat "$CMUX_TEST_CALL_COUNTER" 2>/dev/null || printf 0)"',
          '  count="$((count + 1))"',
          '  printf "%s" "$count" > "$CMUX_TEST_CALL_COUNTER"',
          '  if [[ "$count" -ge "$CMUX_TEST_READY_AT_CALL" ]]; then printf "cmux-ios-dev://attach?v=2&kind=iroh"; return 0; fi',
          '  return 1',
          '}',
          'cmux_attach_terminate_bundle_app() { printf "%s\\n" "$*" > "$CMUX_TEST_PKILL_ARGS"; return 0; }',
          'cmux_attach_launch_bundle_app() { return 0; }',
          'sleep() { return 0; }',
          'cmux_attach_ensure_mac "ready" "$2" physical_device "$CMUX_TEST_FORCE_RELAUNCH"',
        ].join("\n"),
        "mobile-attach-test",
        validator,
        tempRoot,
      ],
      {
        cwd: repoRoot,
        encoding: "utf8",
        env: {
          ...process.env,
          CMUX_TEST_APP: appPath,
          CMUX_TEST_CALL_COUNTER: callCounterPath,
          CMUX_TEST_FORCE_RELAUNCH: forceRelaunch ? "1" : "0",
          CMUX_TEST_PKILL_ARGS: pkillArgsPath,
          CMUX_TEST_READY_AT_CALL: String(readyAtCall),
          CMUX_TEST_SOCKET: socketPath,
        },
      },
    );
    result.callCount = fs.existsSync(callCounterPath)
      ? Number.parseInt(fs.readFileSync(callCounterPath, "utf8"), 10)
      : 0;
    result.pkillArgs = fs.existsSync(pkillArgsPath)
      ? fs.readFileSync(pkillArgsPath, "utf8").trim()
      : "";
    return result;
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
}

function attachPayload(kind) {
  return {
    attach_url: `cmux-ios-dev://attach?v=2&kind=${kind}`,
    routes: [{ id: kind, kind }],
    ticket: {
      routes: [{ id: kind, kind }],
    },
  };
}


test("shared dev-tag validator rejects every spelling that sanitizes to default", () => {
  for (const tag of ["default", "DEFAULT", "...Default..."]) {
    const result = validate(tag);
    assert.notEqual(result.status, 0, `${tag} unexpectedly passed`);
    assert.match(result.stderr, new RegExp(reservedMessage));
  }
});

test("shared dev-tag validator permits non-sentinel tags", () => {
  for (const tag of ["future-one", "default-2", "de fault"]) {
    const result = validate(tag);
    assert.equal(result.status, 0, `${tag}: ${result.stderr}`);
  }
});

test("shared dev API origin defaults to the tagged local server", () => {
  const result = resolveDevAPIBaseURL("http://localhost:4123");
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "http://localhost:4123");
});

test("shared dev API origin accepts an explicit trusted backend", () => {
  const result = resolveDevAPIBaseURL(
    "http://localhost:4123",
    "https://cmux-staging.vercel.app",
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "https://cmux-staging.vercel.app");
});

test("tagged stale-socket cleanup removes only the exact Unix socket", async () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-stale-socket-test-"));
  const socketPath = path.join(tempRoot, "release-gate.sock");
  const neighborPath = path.join(tempRoot, "neighbor.sock");
  fs.writeFileSync(neighborPath, "keep");
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });

  try {
    const result = removeStaleSocket(socketPath);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(socketPath), false);
    assert.equal(fs.readFileSync(neighborPath, "utf8"), "keep");
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("tagged stale-socket cleanup refuses a non-socket path", () => {
  const tempRoot = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-stale-socket-test-"));
  const socketPath = path.join(tempRoot, "release-gate.sock");
  fs.writeFileSync(socketPath, "keep");

  try {
    const result = removeStaleSocket(socketPath);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /refusing to remove non-socket/);
    assert.equal(fs.readFileSync(socketPath, "utf8"), "keep");
  } finally {
    fs.rmSync(tempRoot, { recursive: true, force: true });
  }
});

test("dogfood readiness captures the Mac event sequence before launch", () => {
  const result = readinessCursor(
    '{"type":"ack","resume":{"latest_seq":842,"next_seq":843}}',
  );

  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, "842");
});

test("dogfood readiness clock is stable across helper processes", () => {
  const first = monotonicMilliseconds();
  const second = monotonicMilliseconds();

  assert.equal(first.status, 0, first.stderr);
  assert.equal(second.status, 0, second.stderr);
  const firstMilliseconds = Number.parseInt(first.stdout.trim(), 10);
  const secondMilliseconds = Number.parseInt(second.stdout.trim(), 10);
  assert.ok(Number.isSafeInteger(firstMilliseconds));
  assert.ok(Number.isSafeInteger(secondMilliseconds));
  assert.ok(
    secondMilliseconds >= firstMilliseconds,
    `expected monotonic clock, got ${firstMilliseconds} -> ${secondMilliseconds}`,
  );
});

test("dogfood readiness blocks on the post-launch usable RPC event", () => {
  const result = waitForUsableSession(0, "842", "15");

  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    result.eventArgs,
    "--after 842 --name mobile.rpc.ready --limit 1 --timeout 15 --no-ack --no-heartbeat",
  );
  assert.match(result.stdout, /"name":"mobile\.rpc\.ready"/);
});

test("dogfood readiness rejects an event from another client", () => {
  const result = waitForUsableSession(
    0,
    "842",
    "1",
    '{"seq":843,"name":"mobile.rpc.ready","payload":{"client_id":"other-phone"}}',
    "phone-a",
  );

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /did not establish a usable RPC session/i);
});

test("dogfood readiness fails when a usable RPC session misses its deadline", () => {
  const result = waitForUsableSession(1, "100", "1");

  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /did not establish a usable RPC session.*readiness deadline/i);
});

test("dogfood readiness writes a secret-free identity and latency receipt", () => {
  const result = writeReadinessReceipt(
    '{"name":"mobile.rpc.ready","payload":{"connection_id":"connection-a","client_id":"phone-a","workspace_count":2,"stream_id":"events","transport":"iroh","access_token":"must-not-appear"}}',
  );

  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.receipt, {
    schema: "cmux-ios-dogfood-readiness-v1",
    git_sha: "0123456789abcdef0123456789abcdef01234567",
    tooling_checkout_sha: "0123456789abcdef0123456789abcdef01234567",
    installed_bundle: {
      bundle_id: "dev.cmux.ios.iosrdy",
      executable_sha256: null,
      source: "legacy_receipt_writer",
      target: "physical_device",
      target_id: "phone-a",
    },
    tag: "iosrdy",
    bundle_id: "dev.cmux.ios.iosrdy",
    target: "physical_device",
    target_id: "phone-a",
    mac_tag: "iosrdy",
    socket_path: "/tmp/cmux-debug-iosrdy.sock",
    readiness_latency_ms: 8421,
    attempt_count: 1,
    connection_id: "connection-a",
    client_id: "phone-a",
    workspace_count: 2,
    stream_id: "events",
    transport: "iroh",
    tooling_checkout_sha: "0123456789abcdef0123456789abcdef01234567",
    installed_bundle: {
      bundle_id: "dev.cmux.ios.iosrdy",
      target: "physical_device",
      target_id: "phone-a",
      source: "legacy_receipt_writer",
      executable_sha256: null,
    },
  });
  assert.equal(result.directoryMode, 0o700);
  assert.equal(result.receiptMode, 0o600);
  assert.doesNotMatch(JSON.stringify(result.receipt), /must-not-appear|access_token/);
});

test("macOS reload honors the dev API backend override", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");

  assert.match(macReload, /CMUX_DEV_API_BASE_URL_VALUE=.*cmux_attach_resolve_dev_api_base_url/);
  assert.match(macReload, /CMUX_API_BASE_URL="\$CMUX_DEV_API_BASE_URL_VALUE"/);
});

test("tagged macOS launches require a personal credential file by default", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");

  assert.match(macReload, /tagged launches require authenticated dev credentials/u);
  assert.match(macReload, /cmuxterm-dev\.env.*cmux\.env/su);
  assert.match(macReload, /AUTH_PROFILE="personal"/u);
});

test("bundle launches clear inherited tagged runtime state", () => {
  const launcher = fs.readFileSync(path.join(repoRoot, "scripts/launch-bundle-app.swift"), "utf8");

  assert.match(launcher, /runtimeEnvironmentPrefixes = \["CMUX_", "GHOSTTY_"\]/u);
  assert.match(launcher, /removeValue\(forKey: "CMUXD_UNIX_PATH"\)/u);
});


test("tagged macOS reload uses its dedicated Iroh broker", () => {
  const macReload = fs.readFileSync(path.join(repoRoot, "scripts/reload.sh"), "utf8");

  assert.match(macReload, /CMUX_IROH_BROKER_BASE_URL_VALUE=.*cmux-staging\.vercel\.app/);
  assert.match(macReload, /CMUX_IROH_BROKER_BASE_URL="\$CMUX_IROH_BROKER_BASE_URL_VALUE"/);
});


test("physical-device mint accepts the authenticated Tailscale fallback", async () => {
  const result = await mintAttachURL(
    "physical_device",
    [attachPayload("tailscale"), attachPayload("tailscale")],
    2,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, attachPayload("tailscale").attach_url);
  assert.equal(result.callCount, 1);
});

test("physical-device mint waits when no route is published yet", async () => {
  const payload = attachPayload("iroh");
  const result = await mintAttachURL(
    "physical_device",
    [attachPayload("none"), payload],
    2,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
  assert.equal(result.callCount, 2);
});

test("physical-device mint reports a redacted route-readiness timeout", async () => {
  const result = await mintAttachURL(
    "physical_device",
    {
      cliResponse: {
        status: 1,
        stderr: "unavailable: Mobile host routes are not available yet secret-token-value",
      },
    },
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /attach readiness exhausted: host_routes_unavailable/);
  assert.doesNotMatch(result.stderr, /secret-token-value/);
});

test("physical-device mint distinguishes malformed successful output", async () => {
  const result = await mintAttachURL(
    "physical_device",
    { cliResponse: { status: 0, stdout: "not-json secret-payload-value" } },
  );
  assert.equal(result.status, 1);
  assert.match(result.stderr, /attach readiness exhausted: malformed_response/);
  assert.doesNotMatch(result.stderr, /secret-payload-value/);
});

test("physical-device mint ignores successful CLI diagnostics on stderr", async () => {
  const payload = attachPayload("iroh");
  const result = await mintAttachURL(
    "physical_device",
    {
      cliResponse: {
        status: 0,
        stdout: JSON.stringify(payload),
        stderr: "warning: cached auth metadata was refreshed",
      },
    },
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
});

test("physical-device mint accepts an encrypted Iroh route", async () => {
  const payload = attachPayload("iroh");
  const result = await mintAttachURL("physical_device", payload);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
});


test("simulator mint retains its loopback ticket behavior", async () => {
  const payload = attachPayload("debug_loopback");
  const result = await mintAttachURL("simulator_injection", payload);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
});

test("physical-device mint retries transient empty responses", async () => {
  const payload = attachPayload("iroh");
  const result = await mintAttachURL(
    "physical_device",
    [null, payload],
    20,
  );
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, payload.attach_url);
  assert.equal(result.callCount, 2);
});

test("ensure-mac self-heals an unarmed running exact-tag app", async () => {
  const result = await ensureMacAfterRelaunch();
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.callCount, 2);
  assert.match(
    result.pkillArgs,
    /^com\.cmuxterm\.app\.debug\.ready .* 5$/,
  );
});

test("ensure-mac rotates an armed exact-tag app before using explicit credentials", async () => {
  const result = await ensureMacAfterRelaunch({ forceRelaunch: true, readyAtCall: 1 });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.callCount, 1);
  assert.match(
    result.pkillArgs,
    /^com\.cmuxterm\.app\.debug\.ready .* 5$/,
  );
});


for (const entrypoint of [
  { script: "scripts/reload.sh", args: ["--tag", "...DEFAULT..."] },
]) {
  test(`${entrypoint.script} rejects the reserved tag before doing work`, () => {
    const result = run("bash", [entrypoint.script, ...entrypoint.args]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, new RegExp(reservedMessage));
    assert.doesNotMatch(`${result.stdout}\n${result.stderr}`, /xcodebuild|launching|building/i);
  });
}
