#!/usr/bin/env node
// AgentStatusBar の hook を Codex / Claude Code に登録する。
//
// ユーザーが既に登録している hook は一切変更せず、
// 各イベントに独立したグループとして追加する。
//
//   node Scripts/setup-hooks.js            登録
//   node Scripts/setup-hooks.js --uninstall 解除
//   node Scripts/setup-hooks.js --status    状態確認
//
// 将来はアプリ自身がこれを行えるようにしたい。

const fs = require('fs');
const os = require('os');
const path = require('path');

const SUPPORT_DIR = path.join(os.homedir(), 'Library/Application Support/AgentStatusBar');
const HOOK_PATH = path.join(SUPPORT_DIR, 'asb-hook');
const SOURCE_HOOK = path.join(__dirname, 'asb-hook');

// 登録するイベント。実際に発火することを確認したものに限る。
const EVENTS = {
  claude: [
    'SessionStart',
    'UserPromptSubmit',
    'PreToolUse',
    'PostToolUse',
    'PostToolUseFailure',
    'PermissionRequest',
    'Stop',
    'StopFailure',
    'SessionEnd',
  ],
  codex: [
    'SessionStart',
    'UserPromptSubmit',
    'PreToolUse',
    'PostToolUse',
    'PermissionRequest',
    'Stop',
    'SessionEnd',
  ],
};

const TARGETS = {
  claude: path.join(os.homedir(), '.claude/settings.json'),
  codex: path.join(os.homedir(), '.codex/hooks.json'),
};

const command = (provider) => `"${HOOK_PATH}" ${provider}`;
// Codex の SessionEnd は 3 秒を超える timeout を受け付けない
const timeout = (provider, event) => (provider === 'codex' && event === 'SessionEnd' ? 3 : 5);
const isOurs = (hook) => typeof hook.command === 'string' && hook.command.includes('asb-hook');

function readConfig(file) {
  if (!fs.existsSync(file)) return { hooks: {} };
  const config = JSON.parse(fs.readFileSync(file, 'utf8'));
  config.hooks = config.hooks || {};
  return config;
}

function writeConfig(file, config) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(config, null, 2) + '\n');
}

function installShim() {
  fs.mkdirSync(SUPPORT_DIR, { recursive: true, mode: 0o700 });
  fs.copyFileSync(SOURCE_HOOK, HOOK_PATH);
  fs.chmodSync(HOOK_PATH, 0o755);
  console.log(`shim を配置: ${HOOK_PATH}`);
}

function register() {
  installShim();
  for (const [provider, file] of Object.entries(TARGETS)) {
    const config = readConfig(file);
    let added = 0;
    for (const event of EVENTS[provider]) {
      config.hooks[event] = config.hooks[event] || [];
      // 既に入っていれば足さず、timeout だけ現在の値に揃える（冪等）
      const existing = config.hooks[event].flatMap((g) => g.hooks || []).find(isOurs);
      if (existing) {
        existing.timeout = timeout(provider, event);
        continue;
      }
      config.hooks[event].push({
        hooks: [{ type: 'command', command: command(provider), timeout: timeout(provider, event) }],
      });
      added++;
    }
    writeConfig(file, config);
    console.log(`${provider}: ${added} イベントを追加 (${file})`);
  }
}

function uninstall() {
  for (const [provider, file] of Object.entries(TARGETS)) {
    const config = readConfig(file);
    let removed = 0;
    for (const event of Object.keys(config.hooks)) {
      const before = config.hooks[event].length;
      config.hooks[event] = config.hooks[event]
        .map((g) => ({ ...g, hooks: (g.hooks || []).filter((h) => !isOurs(h)) }))
        .filter((g) => g.hooks.length > 0);
      removed += before - config.hooks[event].length;
      if (config.hooks[event].length === 0) delete config.hooks[event];
    }
    writeConfig(file, config);
    console.log(`${provider}: ${removed} エントリを削除`);
  }
  fs.rmSync(HOOK_PATH, { force: true });
  console.log('shim を削除');
}

function status() {
  console.log(`shim: ${fs.existsSync(HOOK_PATH) ? HOOK_PATH : '未配置'}`);
  for (const [provider, file] of Object.entries(TARGETS)) {
    const hooks = readConfig(file).hooks;
    const registered = Object.entries(hooks)
      .filter(([, groups]) => groups.some((g) => (g.hooks || []).some(isOurs)))
      .map(([event]) => event);
    console.log(`${provider}: ${registered.length ? registered.join(', ') : '未登録'}`);
  }
}

// Codex の hook 承認状態について
//
// Codex は `hooks.json` の各エントリを個別に信頼する必要があり、未承認なら hook は
// 黙って実行されない。承認状態は `~/.codex/config.toml` の `[hooks.state]` に
// `trusted_hash` として記録される。
//
// この状態を**スクリプトから判定することはできない**。
// キーは `<file>:<event>:<group>:<index>` だが、`trusted_hash` はコマンド内容の
// ハッシュであり、その元データ（正規化方法）を再現できないため。
// キーの存在だけを見ると、別のコマンドが同じ index に登録されていた履歴と
// 区別できず誤検出する。
//
// したがって承認の確認は経験的に行う:
//   ターミナルで codex を動かし、AgentStatusBar にそのセッションが現れるかを見る。

const arg = process.argv[2];
if (arg === '--uninstall') {
  uninstall();
} else if (arg === '--status') {
  status();
} else {
  register();
  console.log('');
  status();
  console.log('');
  console.log('次の手順:');
  console.log('  1. AgentStatusBar.app を起動する');
  console.log('  2. ターミナルで codex を起動し、hook の信頼を求められたら承認する');
  console.log('     書き込むだけでは Codex は hook を実行しない。');
  console.log('     承認できたかどうかは、codex のセッションが');
  console.log('     AgentStatusBar に現れるかで確認する（config.toml からは判定できない）。');
  console.log('  3. Claude Code は settings.json を動的に読み直すため再起動は不要');
}
