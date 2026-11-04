// ClingCling の LP のデモ。
// 判定は Sources/ClingClingCore の ContentClassifier・SecretDetector・ActionRanker の規則を
// 移したもの。コピーされた文字はこのページのメモリにだけ置き、保存も送信もしない。
(() => {
  "use strict";

  const ja = document.documentElement.lang === "ja";

  const T = ja
    ? {
        filter: "入力して絞り込み",
        hints: ["↩ 貼り付け", "→ アクション", "1–9 すぐ貼る"],
        clears: "5分で消去",
        paste: "貼り付け",
        save: "ダウンロードに保存",
        pin: "ピン留めする",
        rename: "別名を付ける",
        folder: "フォルダに入れる",
        del: "削除",
        notice: "アプリでは、直前のアプリにそのまま貼り付けます。",
        actions: {
          copy: "コピー", open: "ブラウザで開く", markdown: "Markdown リンクをコピー", explain: "説明する",
          search: "Web で検索", run: "Terminal で実行", polish: "文章を整える", shorten: "短くする",
          translate: "翻訳する", newMail: "メールを作成", openMaps: "マップで開く", format: "JSON を整形",
          inspect: "JSON の構造を見る",
        },
      }
    : {
        filter: "Type to filter",
        hints: ["↩ Paste", "→ Actions", "1–9 Quick Paste"],
        clears: "Clears in 5 min",
        paste: "Paste",
        save: "Save to Downloads",
        pin: "Pin",
        rename: "Rename",
        folder: "Add to Folder",
        del: "Delete",
        notice: "The app pastes straight into the app you were using.",
        actions: {
          copy: "Copy", open: "Open in Browser", markdown: "Copy Markdown Link", explain: "Explain",
          search: "Search the Web", run: "Run in Terminal", polish: "Polish", shorten: "Shorten",
          translate: "Translate", newMail: "New Email", openMaps: "Open in Maps", format: "Format JSON",
          inspect: "Inspect JSON",
        },
      };

  // SF Symbols の代わりの線画
  const stroke = (d) =>
    `<svg viewBox="0 0 16 14" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
  const ICONS = {
    search: stroke('<circle cx="7" cy="6" r="4"/><path d="m10 9 3.5 3.5"/>'),
    url: stroke('<path d="M7 4.5 8.6 3a2.6 2.6 0 0 1 3.7 3.7L10.6 8.4M9 9.5 7.4 11a2.6 2.6 0 0 1-3.7-3.7l1.7-1.7M6.2 8.2l3.6-3.4"/>'),
    error: stroke('<path d="M8 1.6 14.2 12.4H1.8L8 1.6Z"/><path d="M8 5.6v3M8 10.6v.1"/>'),
    lock: stroke('<rect x="3.2" y="6.2" width="9.6" height="6.4" rx="1.4"/><path d="M5.2 6.2V4.4a2.8 2.8 0 0 1 5.6 0v1.8"/>'),
    command: stroke('<rect x="1.8" y="1.8" width="12.4" height="10.4" rx="2"/><path d="m4.6 5 2 2-2 2M8.4 9.4h3"/>'),
    text: stroke('<path d="M2.4 3h11.2M2.4 7h11.2M2.4 11h7"/>'),
    code: stroke('<path d="M5 3.4 1.8 7 5 10.6M11 3.4 14.2 7 11 10.6M9.2 2.4 6.8 11.6"/>'),
    json: stroke('<path d="M6 2H5a1.6 1.6 0 0 0-1.6 1.6v1.8C3.4 6.4 2.4 7 2.4 7s1 .6 1 1.6v1.8A1.6 1.6 0 0 0 5 12h1M10 2h1a1.6 1.6 0 0 1 1.6 1.6v1.8c0 1 1 1.6 1 1.6s-1 .6-1 1.6v1.8A1.6 1.6 0 0 1 11 12h-1"/>'),
    email: stroke('<rect x="1.8" y="2.6" width="12.4" height="8.8" rx="1.6"/><path d="m2.4 3.6 5.6 4.2 5.6-4.2"/>'),
    address: stroke('<path d="M8 12.8S3.4 8.8 3.4 5.6a4.6 4.6 0 0 1 9.2 0c0 3.2-4.6 7.2-4.6 7.2Z"/><circle cx="8" cy="5.6" r="1.6"/>'),
    number: stroke('<path d="M6.2 1.8 4.8 12.2M11.2 1.8 9.8 12.2M2.6 5h11M2.2 9h11"/>'),
    paste: stroke('<rect x="3" y="2.4" width="10" height="10.4" rx="1.6"/><path d="M5.8 1.4h4.4v2.2H5.8z"/>'),
    copy: stroke('<rect x="5.4" y="1.6" width="8" height="8.6" rx="1.4"/><path d="M3.4 4.2h-.2A1.4 1.4 0 0 0 1.8 5.6v5.8a1.4 1.4 0 0 0 1.4 1.4h5.2a1.4 1.4 0 0 0 1.4-1.4v-.2"/>'),
    open: stroke('<rect x="2" y="2" width="12" height="10.4" rx="2"/><path d="M6 9 10.4 4.8M7 4.8h3.4v3.4"/>'),
    explain: stroke('<path d="M3.4 1.8h9.2a1.8 1.8 0 0 1 1.8 1.8v4.6A1.8 1.8 0 0 1 12.6 10H7.4L4.2 12.6V10h-.8a1.8 1.8 0 0 1-1.8-1.8V3.6a1.8 1.8 0 0 1 1.8-1.8Z"/><path d="M6.8 4.6a1.3 1.3 0 1 1 2 1.1c-.5.3-.8.6-.8 1.1M8 8.2v.1"/>'),
    sparkles: stroke('<path d="M6.6 2.6 7.8 6l3.4 1.2-3.4 1.2-1.2 3.4-1.2-3.4L2 7.2 5.4 6l1.2-3.4ZM12 1.8l.5 1.4 1.4.5-1.4.5-.5 1.4-.5-1.4-1.4-.5 1.4-.5.5-1.4Z"/>'),
    save: stroke('<path d="M8 1.8v7.4M5.2 6.6 8 9.4l2.8-2.8M2.6 9.6v2a1.4 1.4 0 0 0 1.4 1.4h8a1.4 1.4 0 0 0 1.4-1.4v-2"/>'),
    pin: stroke('<path d="M5.4 1.8h5.2M6.2 1.8v4.4L4.2 8.6h7.6L9.8 6.2V1.8M8 8.6v4"/>'),
    rename: stroke('<path d="M6.2 2h3.6M6.2 12h3.6M8 2v10M2 5h2.6M2 9h2.6M11.4 5H14M11.4 9H14"/>'),
    folder: stroke('<path d="M1.8 4V3.2A1.2 1.2 0 0 1 3 2h3l1.4 1.6H13a1.2 1.2 0 0 1 1.2 1.2v6.4A1.2 1.2 0 0 1 13 12.4H3a1.2 1.2 0 0 1-1.2-1.2V4Z"/><path d="M8 6v4M6 8h4"/>'),
    trash: stroke('<path d="M2.6 3.6h10.8M6 3.4V2h4v1.4M3.8 3.6l.6 9h7.2l.6-9"/>'),
  };

  const AI_ACTIONS = new Set(["explain", "polish", "shorten", "translate"]);
  const EXTERNAL = new Set([...AI_ACTIONS, "search"]);

  // ContentClassifier.swift
  const COMMANDS = new Set(("git gh npm npx yarn pnpm node bun deno python python3 pip pip3 uv brew docker kubectl helm aws gcloud az terraform cd ls cat curl wget ssh scp rsync make swift xcodebuild xcrun cargo go sudo chmod chown mkdir rm cp mv grep rg find echo export open defaults launchctl tail head ps kill killall ping java mvn gradle ruby gem bundle rails sed awk jq tar unzip zip xattr codesign security systemctl journalctl psql mysql redis-cli mongosh ffmpeg pod claude touch source env which man dig nslookup lsof").split(" "));
  const ERROR_PATTERNS = [
    /\b[A-Z][A-Za-z0-9]*[a-z](?:Exception|Error)\b/,
    /^Traceback \(most recent call last\)/m,
    /^\s*(?:error|fatal|panic|exception)(?:\[[\w-]+\])?\s*:/im,
    /^\s*at [\w.$<>]+\(.*:\d+(?::\d+)?\)/m,
    /^\s*File ".+", line \d+/m,
    /\b(?:command not found|no such file or directory|permission denied|segmentation fault|access denied|unauthorized|forbidden)\b/i,
    /\bnpm ERR!/,
    /\bexit(?:ed)? (?:code|status) [1-9]\d*/i,
    /\b(?:4\d{2}|5\d{2}) (?:Bad Request|Unauthorized|Forbidden|Not Found|Internal Server Error|Bad Gateway|Service Unavailable)\b/,
  ];
  const ADDRESS_PATTERNS = [
    /(?<![\d-])〒?\d{3}-\d{4}(?![\d-])/,
    /(?:東京都|北海道|(?:京都|大阪)府|[^\s]{2,3}県)[^\s]{1,8}?[市区町村郡].*\d/,
    /\b\d+\s+[\w .]+\b(?:St|Street|Ave|Avenue|Rd|Road|Blvd|Boulevard|Dr|Drive|Ln|Lane|Way)\b.*\b\d{5}\b/i,
  ];
  const CODE_KEYWORD = /^\s*(?:func|def|class|struct|enum|interface|import|from \S+ import|const|let|var|public|private|protected|return|fn|package|#include|using|namespace|async function|function|export)\b/m;
  const CODE_SYMBOLS = /(?:[;{]\s*$|^\s*\}|=>|\)\s*\{|->\s*\w+|::|\bnil\b|\bnull\b|\bself\.|\bthis\.)/gm;

  const isURL = (s) => {
    if (/\s/.test(s)) return false;
    const candidate = s.toLowerCase().startsWith("www.") ? "https://" + s : s;
    try {
      const url = new URL(candidate);
      const scheme = url.protocol.slice(0, -1);
      if (scheme === "http" || scheme === "https") return url.hostname.includes(".") || url.hostname === "localhost";
      return ["ftp", "file", "mailto", "slack", "vscode", "x-apple.systempreferences"].includes(scheme);
    } catch {
      return false;
    }
  };

  const isJSON = (s) => {
    if (!(s[0] === "{" || s[0] === "[") || s.length < 2) return false;
    try { JSON.parse(s); return true; } catch { return false; }
  };

  const isCommand = (lines) => {
    let line = lines[0].trim();
    for (const prompt of ["$ ", "% ", "# ", "> "]) if (line.startsWith(prompt)) line = line.slice(prompt.length);
    const words = line.split(" ").filter(Boolean);
    const first = words[0];
    if (!first) return false;
    if (first.startsWith("./") || first.startsWith("~/")) return true;
    if (first.includes("=") && words[1]) return COMMANDS.has(words[1]);
    return COMMANDS.has(first);
  };

  const isCode = (s, lineCount) => {
    const keyword = CODE_KEYWORD.test(s);
    const symbols = (s.match(CODE_SYMBOLS) || []).length;
    return (keyword && (symbols > 0 || lineCount > 1)) || symbols >= 3;
  };

  const classify = (raw) => {
    const text = raw.trim();
    if (!text) return "other";
    const lines = text.split(/\r?\n/).filter(Boolean);
    const single = lines.length === 1;
    if (/^(?:\d{4,8}|\d{3}[ -]\d{3}|[A-Z0-9]{3}-[A-Z0-9]{3})$/.test(text)) return "verificationCode";
    if (single && isURL(text)) return "url";
    if (single && /^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(text)) return "email";
    if (isJSON(text)) return "json";
    if (ERROR_PATTERNS.some((re) => re.test(text))) return "error";
    if (lines.length <= 5 && isCommand(lines)) return "command";
    if (isCode(text, lines.length)) return "code";
    if ([...text].length < 200 && ADDRESS_PATTERNS.some((re) => re.test(text))) return "address";
    return "text";
  };

  // SecretDetector.swift
  const SECRETS = [
    /\b(?:AKIA|ASIA|ABIA|ACCA)[0-9A-Z]{16}\b/,
    /aws_?secret_?access_?key\s*[=:]\s*\S+/i,
    /\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}\b/,
    /\bgithub_pat_[A-Za-z0-9_]{22,}\b/,
    /\bsk-ant-[A-Za-z0-9_-]{20,}/,
    /\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}/,
    /\bxox[abposr]-[A-Za-z0-9-]{10,}/,
    /\bAIza[0-9A-Za-z_-]{35}\b/,
    /\b(?:sk|rk|pk)_(?:live|test)_[0-9A-Za-z]{16,}/,
    /\bbearer\s+[A-Za-z0-9\-._~+/]{16,}=*/i,
    /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
    /-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----/,
    /-----BEGIN CERTIFICATE-----/,
    /\b[a-z][a-z0-9+.-]*:\/\/[^\s:/@]+:[^\s@/]+@/i,
    /(?:password|passwd|pwd|secret|api[_-]?key|private[_-]?key|[_-]token|accesstoken|authtoken)(?:\\?["'])?\s*[=:]\s*(?:\\?['"])?[^\s'"\\]{6,}/i,
    /(?:パスワード|パスコード|シークレット|秘密鍵|API ?キー|アクセスキー|アクセストークン)\s*(?:[:：=＝]|は)\s*[「『"']?[!-~]{4,}/,
    /暗証番号\s*(?:[:：=＝は]\s*)?[0-9０-９]{4,}/,
    /[?&#](?:token|access_token|id_token|refresh_token|api_?key|key|secret|password|sig|signature|code|auth)=[^&\s]{8,}/i,
  ];
  const PERSONAL = [
    /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/,
    /(?<![\d-])(?:\+81[- ]?|0)\d{1,4}[- ]\d{1,4}[- ]\d{3,4}(?![\d-])/,
    /(?<![\d-])(?:\+81|0)[789]0\d{8}(?![\d-])/,
  ];
  const CARD = /(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)/;
  const TOKEN = /[A-Za-z0-9+/=_\-.~]{20,}/;
  const CAMEL_WORDS = /^(?:[A-Z]?[a-z]{2,}|[A-Z]{2,}(?![a-z])|[0-9]+|[-_=.~+])+$/;
  const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  // 一致した範囲 [開始, 終了) の一覧
  const spans = (re, s) => [...s.matchAll(new RegExp(re.source, re.flags + "g"))].map((m) => [m.index, m.index + m[0].length]);

  const luhn = (digits) =>
    [...digits].reverse().reduce((sum, c, i) => {
      const d = i % 2 ? Number(c) * 2 : Number(c);
      return sum + (d > 9 ? d - 9 : d);
    }, 0) % 10 === 0;

  const entropy = (s) => {
    const chars = [...s];
    const freq = new Map();
    for (const c of chars) freq.set(c, (freq.get(c) || 0) + 1);
    return [...freq.values()].reduce((acc, n) => acc - (n / chars.length) * Math.log2(n / chars.length), 0);
  };

  // SecretDetector.looksRandom
  const looksRandom = (t) => {
    if (UUID.test(t)) return false;
    if (t.includes(".") && t.split(".").every((p) => /^[A-Za-z]*$/.test(p) || p.length < 12)) return false;
    const hasDigit = /\d/.test(t);
    const hasLower = /[a-z]/.test(t);
    const hasUpper = /[A-Z]/.test(t);
    if (/^[0-9A-Fa-f]+$/.test(t)) return t.length >= 32 && hasDigit;
    if (hasUpper && hasLower && CAMEL_WORDS.test(t)) return false;
    const classes = [hasDigit, hasLower, hasUpper].filter(Boolean).length;
    if (classes < 2 || !(hasDigit || t.length >= 32)) return false;
    return entropy(t) >= (t.length >= 40 ? 4.0 : 3.6);
  };

  // SecretDetector.classSwitchRatio
  const switchRatio = (s) => {
    const chars = s.replace(/[^A-Za-z0-9]/g, "");
    if (chars.length < 2) return 0;
    const kind = (c) => (/[A-Z]/.test(c) ? 0 : /[a-z]/.test(c) ? 1 : 2);
    let switches = 0;
    for (let i = 1; i < chars.length; i++) if (kind(chars[i]) !== kind(chars[i - 1])) switches++;
    return switches / (chars.length - 1);
  };

  // SecretDetector.randomRanges。`/` を含む Token は区切りごとに見る
  const randomRanges = (s, [from, to]) => {
    const token = s.slice(from, to);
    if (!token.includes("/")) return looksRandom(token) ? [[from, to]] : [];
    const segments = [];
    let start = from;
    for (let i = from; i < to; i++) {
      if (s[i] !== "/") continue;
      if (start < i) segments.push([start, i]);
      start = i + 1;
    }
    if (start < to) segments.push([start, to]);
    const random = segments.filter(([a, b]) => b - a >= 16 && looksRandom(s.slice(a, b)));
    if (random.length) return random;
    return switchRatio(token) >= 0.45 && looksRandom(token) ? [[from, to]] : [];
  };

  // SecretDetector.scan。kind は secret（既知の形式）、random（ランダムに見える）、personal
  const scan = (s) => {
    const found = [];
    for (const re of SECRETS) for (const r of spans(re, s)) found.push({ kind: "secret", r });
    for (const re of PERSONAL) for (const r of spans(re, s)) found.push({ kind: "personal", r });
    for (const r of spans(CARD, s)) {
      const digits = s.slice(...r).replace(/\D/g, "");
      if (digits.length >= 13 && digits.length <= 19 && luhn(digits)) found.push({ kind: "secret", r });
    }
    for (const t of spans(TOKEN, s)) {
      if (found.some((f) => f.r[0] < t[1] && t[0] < f.r[1])) continue;
      for (const r of randomRanges(s, t)) found.push({ kind: "random", r });
    }
    return found;
  };

  // PrivacyGate.isMostlySecret
  const mostlySecret = (s, found) => {
    const total = s.replace(/\s/g, "").length;
    const secretChars = found
      .filter((f) => f.kind !== "personal")
      .reduce((n, f) => n + s.slice(...f.r).replace(/\s/g, "").length, 0);
    return total > 0 && secretChars / total >= 0.6;
  };

  const mask = (s) => {
    const c = [...s.trim()];
    return c.length > 12 ? `${c.slice(0, 4).join("")}••••••••${c.slice(-4).join("")}` : "••••••••";
  };

  // SecretDetector.redact。ランダムに見える部分だけを伏せる
  const redact = (s) => {
    const merged = [];
    for (const [a, b] of scan(s).filter((f) => f.kind !== "personal").map((f) => f.r).sort((x, y) => x[0] - y[0])) {
      const last = merged[merged.length - 1];
      if (last && a <= last[1]) last[1] = Math.max(last[1], b);
      else merged.push([a, b]);
    }
    let out = "";
    let cursor = 0;
    for (const [a, b] of merged) {
      out += s.slice(cursor, a) + mask(s.slice(a, b));
      cursor = b;
    }
    return out + s.slice(cursor);
  };

  // ActionRanker.baseCandidates
  const CANDIDATES = {
    url: ["open", "markdown", "copy"],
    error: ["explain", "search", "copy"],
    command: ["copy", "run", "explain"],
    text: ["copy", "polish", "shorten", "translate"],
    email: ["copy", "newMail"],
    address: ["copy", "openMaps"],
    json: ["copy", "format", "inspect"],
    code: ["copy", "explain"],
    credential: ["copy"],
    verificationCode: ["copy"],
    other: ["copy"],
  };
  const ROW_ICON = {
    url: "url", error: "error", command: "command", text: "text", email: "email", address: "address",
    json: "json", code: "code", credential: "lock", verificationCode: "number", other: "text",
  };
  const MONO = new Set(["code", "command", "json", "error", "credential"]);
  // SF Symbols（SmartAction.systemImage）の代わりの線画
  const ACTION_ICON = {
    copy: "copy", open: "open", markdown: "url", explain: "explain", search: "search", run: "command",
    polish: "sparkles", shorten: "sparkles", translate: "sparkles", newMail: "email", openMaps: "address",
    format: "json", inspect: "json",
  };
  const EXTERNAL_TYPES = new Set(["text", "url", "code", "command", "error", "json"]);

  // PrivacyGate.evaluate の要約
  const evaluate = (content) => {
    const found = scan(content);
    const secret = found.some((f) => f.kind === "secret");
    const suspicious = found.some((f) => f.kind !== "personal");
    let type = classify(content);
    const code = type === "verificationCode";
    if (!code && suspicious && type !== "url" && mostlySecret(content, found)) type = "credential";
    const temporary = code || secret;
    const external = !found.length && EXTERNAL_TYPES.has(type) && [...content].length <= 20000;
    // ActionRanker.rank
    const actions = CANDIDATES[type].filter((a) => external || !EXTERNAL.has(a));
    if (!actions.includes("copy")) actions.push("copy");
    // Presentation.makePreview
    const collapsed = content.split(/\r?\n/).map((l) => l.trim()).filter(Boolean).slice(0, 3).join(" ⏎ ");
    const masked = !code && (secret || (suspicious && type === "credential"));
    return {
      type,
      temporary,
      actions: actions.slice(0, 3),
      preview: masked ? mask(collapsed) : suspicious && !code ? redact(collapsed) : collapsed,
      icon: masked ? "lock" : ROW_ICON[type],
    };
  };

  // 見出しと組になる履歴。API キーは形だけの見本で、どのサービスにも使えない
  const SAMPLES = ja
    ? [
        "https://example.com/report/2026-q3",
        "TypeError: Cannot read properties of undefined (reading 'map')",
        "sk-ant-api03-SAMPLEonlyNotArealKey0000",
        "brew install ffmpeg",
        "来週の打ち合わせは水曜 15 時からに変更します。",
      ]
    : [
        "https://example.com/report/2026-q3",
        "TypeError: Cannot read properties of undefined (reading 'map')",
        "sk-ant-api03-SAMPLEonlyNotArealKey0000",
        "brew install ffmpeg",
        "Moving next week's meeting to Wednesday at 3 pm.",
      ];

  const esc = (s) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

  // PopupViewModel.menuEntries。Copy は「貼り付け」と重なるので出さない。
  // 見本では先頭の提案を選んだ状態にする（提案がなければ貼り付け）
  const menuHTML = (item) => {
    const smart = item.actions
      .filter((a) => a !== "copy")
      .map((a, i) => ({ icon: ACTION_ICON[a], title: T.actions[a], key: `⌘${i + 1}`, ai: AI_ACTIONS.has(a) }));
    const active = smart.length ? 1 : 0;
    const row = (e, i) => `<button class="pop-item" type="button" data-entry="${i}" ${i === active ? 'aria-current="true"' : ""}>${ICONS[e.icon]}<span class="pop-text">${esc(e.title)}</span>${e.ai ? ICONS.sparkles : ""}<span class="pop-meta">${e.key}</span></button>`;
    const parts = [row({ icon: "paste", title: T.paste, key: "↩" }, 0), '<div class="pop-rule"></div>'];
    if (smart.length) {
      smart.forEach((e, i) => parts.push(row(e, i + 1)));
      parts.push('<div class="pop-rule"></div>');
    }
    let n = smart.length + 1;
    // PopupViewModel.menuEntries と同じく、ディスクに書かない一時 Item には保存・ピン留め・別名・フォルダを出さない
    if (!item.temporary) {
      parts.push(row({ icon: "save", title: T.save, key: "⌘S" }, n++));
      parts.push(row({ icon: "pin", title: T.pin, key: "⌘P" }, n++));
      parts.push(row({ icon: "rename", title: T.rename, key: "⌘R" }, n++));
      parts.push(row({ icon: "folder", title: T.folder, key: "" }, n++));
    }
    parts.push(row({ icon: "trash", title: T.del, key: "⌘⌫" }, n));
    return parts.join("");
  };

  const listHTML = (items, selected, notice) => {
    const rows = items
      .map((it, i) => `<button class="pop-row" type="button" data-row="${i}" ${i === selected ? 'aria-current="true"' : ""}>${ICONS[it.icon]}<span class="pop-text${MONO.has(it.type) ? " code" : ""}">${esc(it.preview)}</span>${it.temporary ? `<span class="pop-meta">${T.clears}</span>` : ""}<span class="pop-meta pop-num">${i === selected ? "›" : i < 9 ? i + 1 : ""}</span></button>`)
      .join("");
    return `<div class="pop-search">${ICONS.search}<span>${T.filter}</span></div><div class="pop-rule"></div><div class="pop-rows">${rows}</div>${notice ? `<p class="pop-notice">${T.notice}</p>` : ""}<div class="pop-rule"></div><div class="pop-hints">${T.hints.map((h) => `<span>${h}</span>`).join("")}</div>`;
  };

  // ── ヒーロー ──

  const stage = document.getElementById("stage");
  const lines = [...document.querySelectorAll(".say")];
  const heroItems = SAMPLES.map((s) => ({ ...evaluate(s), content: s }));
  // site.css で .pop-row-wrap を縦に積む幅
  const stacked = matchMedia("(max-width: 680px)");
  // メニューの先頭を選択中の行に揃える（PopupView.menuOffset）。縦に積む幅では揃えない
  const menuOffset = (index) => (stacked.matches ? "" : `${46 + index * 28}px`);
  let heroIndex = 0;

  const showHero = (index) => {
    heroIndex = index;
    stage.querySelector(".pop.list").innerHTML = listHTML(heroItems, index, false);
    const menu = stage.querySelector(".pop.menu");
    menu.innerHTML = menuHTML(heroItems[index]);
    menu.style.marginTop = menuOffset(index);
    lines.forEach((b, i) => b.setAttribute("aria-pressed", String(i === index)));
  };

  let timer = null;
  const stop = () => { clearInterval(timer); timer = null; };

  lines.forEach((b, i) => b.addEventListener("click", () => { stop(); showHero(i); }));
  stage.addEventListener("click", (e) => {
    const row = e.target.closest("[data-row]");
    if (!row) return;
    stop();
    showHero(Number(row.dataset.row));
  });

  showHero(0);
  stacked.addEventListener("change", () => {
    stage.querySelector(".pop.menu").style.marginTop = menuOffset(heroIndex);
    if (!floating.hidden) renderFloating();
  });

  // 3 行を一度だけ順に見せて、API キーの行で止まる
  if (!matchMedia("(prefers-reduced-motion: reduce)").matches) {
    let step = 0;
    timer = setInterval(() => {
      step += 1;
      showHero(step);
      if (step === lines.length - 1) stop();
    }, 2800);
  }

  // ── ページのどこでも: ⌘C のあとに ⌘⇧V ──

  // ⌘ のキーがない環境では、試し方の案内を出さない（site.css は .try.mac をポインターのある端末に出す）
  if (!/mac/i.test(navigator.userAgentData?.platform || navigator.platform || "")) {
    document.querySelectorAll(".try.mac").forEach((el) => el.classList.remove("mac"));
  }

  const copied = [];
  const floating = document.createElement("div");
  floating.className = "floating pop-row-wrap opens";
  floating.hidden = true;
  floating.innerHTML = '<div class="pop list"></div><div class="pop menu" hidden></div>';
  document.body.append(floating);
  const state = { selection: 0, open: false, notice: false };
  let anchor = { x: 24, y: 24 };

  document.addEventListener("copy", () => {
    const text = String(getSelection()).trim();
    if (!text) return;
    anchor = caret();
    const at = copied.findIndex((c) => c.content === text);
    if (at >= 0) copied.splice(at, 1);
    copied.unshift({ ...evaluate(text), content: text });
    copied.length = Math.min(copied.length, 9);
  });

  const caret = () => {
    const sel = getSelection();
    if (!sel.rangeCount) return anchor;
    const rects = sel.getRangeAt(0).getClientRects();
    const r = rects[rects.length - 1];
    return r ? { x: r.left, y: r.bottom + 8 } : anchor;
  };

  const items = () => [...copied, ...heroItems.filter((h) => !copied.some((c) => c.content === h.content))].slice(0, 9);

  const place = () => {
    const pad = 12;
    const w = floating.offsetWidth;
    const h = floating.offsetHeight;
    floating.style.left = `${Math.max(pad, Math.min(anchor.x, innerWidth - w - pad))}px`;
    floating.style.top = `${Math.max(pad, Math.min(anchor.y, innerHeight - h - pad))}px`;
  };

  const renderFloating = () => {
    const list = items();
    floating.querySelector(".list").innerHTML = listHTML(list, state.selection, state.notice);
    const menu = floating.querySelector(".menu");
    menu.hidden = !state.open;
    menu.innerHTML = state.open ? menuHTML(list[state.selection]) : "";
    menu.style.marginTop = state.open ? menuOffset(state.selection) : "";
    place();
  };

  const closeFloating = () => {
    floating.hidden = true;
    state.open = false;
    state.notice = false;
  };

  document.addEventListener("keydown", (e) => {
    if (e.metaKey && e.shiftKey && e.key.toLowerCase() === "v") {
      e.preventDefault();
      stop();
      anchor = caret();
      state.selection = 0;
      state.open = false;
      state.notice = false;
      floating.hidden = false;
      renderFloating();
      return;
    }
    if (floating.hidden) return;
    const count = items().length;
    if (e.key === "Escape") closeFloating();
    else if (e.key === "ArrowDown") state.selection = Math.min(count - 1, state.selection + 1);
    else if (e.key === "ArrowUp") state.selection = Math.max(0, state.selection - 1);
    else if (e.key === "ArrowRight") state.open = true;
    else if (e.key === "ArrowLeft") state.open = false;
    else if (e.key === "Enter" || (/^[1-9]$/.test(e.key) && !e.metaKey && Number(e.key) <= count)) state.notice = true;
    else return;
    e.preventDefault();
    if (!floating.hidden) renderFloating();
  });

  floating.addEventListener("click", (e) => {
    const row = e.target.closest("[data-row]");
    if (row) {
      state.selection = Number(row.dataset.row);
      state.open = true;
      renderFloating();
    } else if (e.target.closest("[data-entry]")) {
      state.notice = true;
      renderFloating();
    }
  });
  document.addEventListener("mousedown", (e) => {
    if (!floating.hidden && !floating.contains(e.target)) closeFloating();
  });
  addEventListener("scroll", () => { if (!floating.hidden) closeFloating(); }, { passive: true });
})();
