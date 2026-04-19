#!/usr/bin/env python3
"""
MQTT Zig チュートリアル — PDF 電子本生成スクリプト

使い方:
    /tmp/pdfgen/bin/python generate-book.py

出力:
    mqtt-zig-tutorial.pdf
"""

import html
import os
import re
import subprocess
import tempfile

import markdown
import weasyprint
from pygments import highlight as pygments_highlight
from pygments.lexers import get_lexer_by_name, guess_lexer
from pygments.formatters import HtmlFormatter

BASE = os.path.dirname(os.path.abspath(__file__))

# ── 本の構造定義 ──────────────────────────────────────────

PARTS = [
    {
        "title": "第I部 MQTTプロトコルの基礎",
        "subtitle": "MQTTの概念とバイナリプロトコルを学びます",
        "chapters": [
            ("01-mqtt-overview", "MQTTの概要", "Pub/Subモデルと3つの役割"),
            ("02-binary-protocol", "バイナリプロトコルの基礎", "固定ヘッダとRemaining Length"),
            ("03-tcp-basics", "ZigでTCP通信", "std.Io.netによるソケットプログラミング"),
        ],
    },
    {
        "title": "第II部 MQTTパケット",
        "subtitle": "各パケットの構造と実装を学びます",
        "chapters": [
            ("04-connect-connack", "CONNECT / CONNACK", "接続パケットの構造と実装"),
            ("05-publish-flow", "PUBLISHフロー", "メッセージ送受信とQoS"),
            ("06-subscribe-unsubscribe", "SUBSCRIBE / UNSUBSCRIBE", "トピック購読の仕組み"),
        ],
    },
    {
        "title": "第III部 ブローカーロジック",
        "subtitle": "ブローカーの中核機能を実装します",
        "chapters": [
            ("07-topic-wildcards", "トピックワイルドカード", "+と#のマッチングアルゴリズム"),
            ("08-qos-levels", "QoS配信保証", "パケットID管理と再送"),
            ("09-keep-alive", "キープアライブ", "PINGREQ/PINGRESPとタイムアウト"),
        ],
    },
    {
        "title": "第IV部 統合",
        "subtitle": "コンポーネントを組み合わせて完成させます",
        "chapters": [
            ("10-broker-architecture", "ブローカーの全体設計", "コンポーネントとスレッドモデル"),
            ("11-session-management", "セッション管理", "Clean SessionとクライアントID"),
            ("12-retained-will-messages", "Retained/Willメッセージ", "保持メッセージと遺言"),
        ],
    },
    {
        "title": "第V部 デモとテスト",
        "subtitle": "統合デモとテスト手法を学びます",
        "chapters": [
            ("13-multi-client", "複数クライアントの統合", "1プロセスデモとメッセージルーティング"),
            ("14-integration-testing", "統合テスト", "TCPを使ったテストパターン"),
        ],
    },
    {
        "title": "第VI部 発展編",
        "subtitle": "Zig 0.16の新機能を活用してブローカーを改善します",
        "chapters": [
            ("15-event-driven-broker", "イベント駆動ブローカー", "io.async()とIo.Groupによる非同期化"),
            ("16-io-queue-messaging", "Io.Queueによるメッセージング", "ロックフリーなメッセージルーティング"),
            ("17-graceful-shutdown", "Graceful Shutdown", "安全な停止パターンとWillメッセージ"),
            ("18-ziglike-patterns", "Zigらしい設計パターン", "Juicy Main・RwLock・comptime活用"),
            ("19-benchmark-report", "ベンチマークレポート", "Debug vs ReleaseFast vs mosquitto 性能比較"),
        ],
    },
]

APPENDICES = [
    ("glossary.md", "用語集"),
    ("mqtt-v311-summary.md", "MQTT v3.1.1 仕様サマリ"),
    ("prerequisites.md", "前提知識"),
    ("debugging-network.md", "ネットワークデバッグ手法"),
]

# ── CSS スタイル ──────────────────────────────────────────

CSS = r"""
@page {
    size: A4;
    margin: 25mm 20mm 25mm 20mm;
    @bottom-center {
        content: counter(page);
        font-size: 9pt;
        color: #666;
    }
}

@page :first {
    @bottom-center { content: none; }
}

body {
    font-family: "Hiragino Kaku Gothic ProN", "Hiragino Sans", "Noto Sans JP",
                 "Yu Gothic", "Meiryo", sans-serif;
    font-size: 10pt;
    line-height: 1.7;
    color: #1a1a1a;
}

/* 表紙 */
.cover {
    page-break-after: always;
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    min-height: 85vh;
    text-align: center;
}
.cover h1 {
    font-size: 28pt;
    margin-bottom: 8pt;
    color: #1a73e8;
    letter-spacing: 2pt;
}
.cover .subtitle {
    font-size: 14pt;
    color: #555;
    margin-bottom: 30pt;
}
.cover .meta {
    font-size: 10pt;
    color: #888;
    margin-top: 20pt;
}
.cover .mqtt-logo {
    font-size: 48pt;
    margin-bottom: 20pt;
}

/* 目次 */
.toc {
    page-break-after: always;
}
.toc h2 {
    font-size: 18pt;
    border-bottom: 2px solid #1a73e8;
    padding-bottom: 6pt;
    margin-bottom: 16pt;
}
.toc ul {
    list-style: none;
    padding: 0;
}
.toc > ul > li {
    margin-top: 14pt;
    font-weight: bold;
    font-size: 11pt;
    color: #333;
}
.toc > ul > li > ul {
    margin-top: 4pt;
}
.toc > ul > li > ul > li {
    font-weight: normal;
    font-size: 10pt;
    color: #555;
    margin: 2pt 0;
    padding-left: 16pt;
}
.toc a {
    color: inherit;
    text-decoration: none;
}

/* 部の扉ページ */
.part-title {
    page-break-before: always;
    page-break-after: always;
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    min-height: 60vh;
    text-align: center;
}
.part-title h2 {
    font-size: 24pt;
    color: #1a73e8;
    margin-bottom: 8pt;
    border: none;
}
.part-title .part-subtitle {
    font-size: 12pt;
    color: #666;
}

/* 章 */
.chapter {
    page-break-before: always;
}
.chapter h2 {
    font-size: 18pt;
    color: #1a73e8;
    border-bottom: 2px solid #1a73e8;
    padding-bottom: 6pt;
    margin-top: 0;
}
.chapter h3 {
    font-size: 13pt;
    color: #333;
    margin-top: 18pt;
    border-left: 4px solid #1a73e8;
    padding-left: 10pt;
}
.chapter h4 {
    font-size: 11pt;
    color: #444;
    margin-top: 14pt;
}

/* コードブロック */
pre {
    background: #f8f8f5;
    border: 1px solid #ddd;
    border-left: 4px solid #1a73e8;
    padding: 10pt 12pt;
    font-size: 8.5pt;
    line-height: 1.5;
    overflow-wrap: break-word;
    white-space: pre-wrap;
    font-family: "SF Mono", "Menlo", "Monaco", "Consolas", monospace;
}
code {
    background: #e8f0fe;
    padding: 1pt 4pt;
    border-radius: 2pt;
    font-size: 9pt;
    font-family: "SF Mono", "Menlo", "Monaco", "Consolas", monospace;
}
pre code {
    background: none;
    padding: 0;
    border-radius: 0;
    font-size: inherit;
}

/* Pygments syntax highlighting */
.highlight { background: #f8f8f5; }
.highlight pre { background: #f8f8f5; border: 1px solid #ddd; border-left: 4px solid #1a73e8; padding: 10pt 12pt; font-size: 8.5pt; line-height: 1.5; overflow-wrap: break-word; white-space: pre-wrap; font-family: "SF Mono", "Menlo", "Monaco", "Consolas", monospace; }
.highlight .c { color: #6a9955; font-style: italic }    /* Comment */
.highlight .ch { color: #6a9955; font-style: italic }   /* Comment.Hashbang */
.highlight .cm { color: #6a9955; font-style: italic }   /* Comment.Multiline */
.highlight .c1 { color: #6a9955; font-style: italic }   /* Comment.Single */
.highlight .cs { color: #6a9955; font-style: italic }   /* Comment.Special */
.highlight .cp { color: #6a9955 }                        /* Comment.Preproc */
.highlight .cpf { color: #6a9955; font-style: italic }  /* Comment.PreprocFile */
.highlight .k { color: #cf8e6d; font-weight: bold }      /* Keyword */
.highlight .kc { color: #cf8e6d; font-weight: bold }     /* Keyword.Constant */
.highlight .kd { color: #cf8e6d; font-weight: bold }     /* Keyword.Declaration */
.highlight .kn { color: #cf8e6d; font-weight: bold }     /* Keyword.Namespace */
.highlight .kp { color: #cf8e6d }                        /* Keyword.Pseudo */
.highlight .kr { color: #cf8e6d; font-weight: bold }     /* Keyword.Reserved */
.highlight .kt { color: #2b91af }                        /* Keyword.Type */
.highlight .m { color: #2aacb8 }                         /* Number */
.highlight .mi { color: #2aacb8 }                        /* Number.Integer */
.highlight .mh { color: #2aacb8 }                        /* Number.Hex */
.highlight .mb { color: #2aacb8 }                        /* Number.Bin */
.highlight .mo { color: #2aacb8 }                        /* Number.Oct */
.highlight .mf { color: #2aacb8 }                        /* Number.Float */
.highlight .s { color: #6aab73 }                         /* String */
.highlight .s1 { color: #6aab73 }                        /* String.Single */
.highlight .s2 { color: #6aab73 }                        /* String.Double */
.highlight .sa { color: #6aab73 }                        /* String.Affix */
.highlight .sb { color: #6aab73 }                        /* String.Backtick */
.highlight .sc { color: #6aab73 }                        /* String.Char */
.highlight .se { color: #d7ba7d; font-weight: bold }     /* String.Escape */
.highlight .nb { color: #56b6c2 }                        /* Name.Builtin (e.g. @import) */
.highlight .nf { color: #61afef }                        /* Name.Function */
.highlight .fm { color: #61afef }                        /* Name.Function.Magic */
.highlight .n { color: #1a1a1a }                         /* Name */
.highlight .o { color: #888 }                            /* Operator */
.highlight .p { color: #888 }                            /* Punctuation */
.highlight .w { color: #bbb }                            /* Whitespace */
.highlight .err { color: #e06c75; border: none }         /* Error */

/* テーブル */
table {
    border-collapse: collapse;
    width: 100%;
    margin: 10pt 0;
    font-size: 9pt;
}
th, td {
    border: 1px solid #ccc;
    padding: 6pt 8pt;
    text-align: left;
}
th {
    background: #1a73e8;
    color: white;
    font-weight: bold;
}
tr:nth-child(even) {
    background: #f0f6ff;
}

/* 付録 */
.appendix {
    page-break-before: always;
}
.appendix h2 {
    font-size: 16pt;
    color: #555;
    border-bottom: 2px solid #888;
    padding-bottom: 6pt;
}

/* 図（zigraph Unicode レンダリング） */
.diagram {
    margin-top: 16pt;
}
.diagram h3 {
    font-size: 12pt;
    color: #1a73e8;
    border-left: 4px solid #1a73e8;
    padding-left: 10pt;
}
.diagram-pre {
    background: #f8f9fa;
    border: 1px solid #ddd;
    border-left: 4px solid #1a73e8;
    padding: 12pt 16pt;
    font-size: 7.5pt;
    line-height: 1.3;
    font-family: "SF Mono", "Menlo", "Monaco", "Consolas", monospace;
    white-space: pre;
    overflow-wrap: normal;
}

/* blockquote */
blockquote {
    border-left: 4px solid #1a73e8;
    margin: 10pt 0;
    padding: 6pt 12pt;
    background: #f0f6ff;
    color: #555;
    font-style: italic;
}

/* リスト */
ul, ol {
    margin: 6pt 0;
    padding-left: 20pt;
}
li {
    margin: 3pt 0;
}

/* 強調 */
strong {
    color: #1558b0;
}

/* はじめに */
.intro {
    page-break-after: always;
}
.intro h2 {
    font-size: 18pt;
    color: #1a73e8;
    border-bottom: 2px solid #1a73e8;
    padding-bottom: 6pt;
}
"""


# ── ヘルパー関数 ─────────────────────────────────────────

def read_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def render_mermaid_file(mermaid_src):
    """Mermaid ソースを zigraph --unicode でレンダリングする。"""
    try:
        result = subprocess.run(
            ["zigraph", "--unicode"],
            input=mermaid_src,
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode == 0 and result.stdout.strip():
            # zigraph 出力の <br/> タグをスペースに置換
            output = result.stdout.rstrip()
            output = output.replace("<br/>", " ")
            output = output.replace("<br>", " ")
            return output
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def render_mermaid_blocks(text):
    """Markdown 中の ```mermaid ブロックを zigraph --unicode でレンダリングし、
    通常のテキストコードブロックに置換する。"""
    def replace_mermaid(match):
        mermaid_src = match.group(1)
        try:
            result = subprocess.run(
                ["zigraph", "--unicode"],
                input=mermaid_src,
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0 and result.stdout.strip():
                # レンダリング成功: 通常のコードブロックとして埋め込む
                output = result.stdout.rstrip().replace("<br/>", " ").replace("<br>", " ")
                return "```\n" + output + "\n```"
            else:
                # 失敗時: 元の Mermaid ソースをそのまま返す
                return match.group(0)
        except (subprocess.TimeoutExpired, FileNotFoundError):
            return match.group(0)

    return re.sub(
        r'```mermaid\n(.*?)```',
        replace_mermaid,
        text,
        flags=re.DOTALL,
    )


def md_to_html(text):
    """Markdown テキストを HTML に変換する。fenced code は Pygments でハイライトする。"""
    # Mermaid ブロックを zigraph でレンダリングしてから Markdown 変換
    text = render_mermaid_blocks(text)
    result = markdown.markdown(
        text,
        extensions=["tables", "fenced_code", "codehilite", "toc"],
        extension_configs={
            "codehilite": {"guess_lang": False, "css_class": "highlight"},
            "fenced_code": {
                "lang_prefix": "language-",
            },
        },
    )
    # fenced_code が生成する <code class="language-zig"> ブロックを
    # Pygments でハイライトし直す
    def highlight_block(match):
        lang = match.group(1) or ""
        code_html = match.group(2)
        # HTML エンティティをデコードしてから Pygments に渡す
        import html as html_mod
        code_text = html_mod.unescape(code_html)
        if lang in ("zig", ""):
            try:
                lexer = get_lexer_by_name("zig")
            except Exception:
                return match.group(0)
        else:
            try:
                lexer = get_lexer_by_name(lang)
            except Exception:
                return match.group(0)
        fmt = HtmlFormatter(nowrap=False, cssclass="highlight", style="friendly")
        return pygments_highlight(code_text, lexer, fmt)

    result = re.sub(
        r'<pre><code class="language-(\w*)">(.*?)</code></pre>',
        highlight_block,
        result,
        flags=re.DOTALL,
    )
    return result


def strip_run_instructions(md_text):
    """README から実行方法セクションと図セクションを除去する（本には不要）。"""
    lines = md_text.split("\n")
    result = []
    skip = False
    for line in lines:
        if re.match(r"^## 完成版を動かす", line):
            skip = True
            continue
        if re.match(r"^## 図$", line):
            skip = True
            continue
        if re.match(r"^## ファイル$", line):
            skip = True
            continue
        if skip and re.match(r"^## ", line):
            skip = False
        if not skip:
            result.append(line)
    return "\n".join(result)


def strip_first_heading(md_text):
    """先頭の # 見出しを除去する（章タイトルは別途付けるため）。"""
    lines = md_text.split("\n")
    if lines and lines[0].startswith("# "):
        lines = lines[1:]
    return "\n".join(lines).strip()


def make_anchor(text):
    """目次用のアンカー ID を生成する。"""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


# ── HTML 構築 ────────────────────────────────────────────

def build_cover():
    total_chapters = sum(len(p["chapters"]) for p in PARTS)
    return f"""
    <div class="cover">
        <div class="mqtt-logo">&#x1F4E1;</div>
        <h1>MQTT Zig チュートリアル</h1>
        <div class="subtitle">Zigで学ぶMQTTプロトコル</div>
        <div class="meta">
            <p>対象: Zig 0.16 / MQTT v3.1.1</p>
            <p>全{total_chapters}章 + 付録{len(APPENDICES)}本</p>
        </div>
    </div>
    """


def build_toc():
    items = []
    ch_num = 1
    for part in PARTS:
        part_anchor = make_anchor(part["title"])
        items.append(f'<li><a href="#{part_anchor}">{part["title"]}</a><ul>')
        for dir_name, title, desc in part["chapters"]:
            label = f"第{ch_num}章 {title}"
            anchor = make_anchor(f"ch{ch_num:02d}-{title}")
            ch_num += 1
            items.append(
                f'<li><a href="#{anchor}">{label}</a> — {desc}</li>'
            )
        items.append("</ul></li>")

    # 付録
    items.append('<li><a href="#appendices">付録</a><ul>')
    for i, (fname, label) in enumerate(APPENDICES):
        letter = chr(ord("A") + i)
        anchor = make_anchor(f"appendix-{letter}")
        items.append(f'<li><a href="#{anchor}">付録{letter}. {label}</a></li>')
    items.append("</ul></li>")

    inner = "\n".join(items)
    return f"""
    <div class="toc">
        <h2>目次</h2>
        <ul>{inner}</ul>
    </div>
    """


def build_intro():
    readme_path = os.path.join(BASE, "README.md")
    if not os.path.exists(readme_path):
        return """
        <div class="intro">
            <h2>はじめに</h2>
            <p>本書は Zig プログラミング言語を使って MQTT v3.1.1 プロトコルを
            ゼロから実装するチュートリアルです。</p>
        </div>
        """

    md = read_file(readme_path)

    # README から主要セクションを抽出（プロジェクト固有のセクション名に対応）
    sections_to_keep = []
    current = []
    keep = False
    for line in md.split("\n"):
        if re.match(r"^## (前提知識|学習パス|本書の構成|概要|はじめに|このチュートリアルについて)", line):
            if current and keep:
                sections_to_keep.append("\n".join(current))
            current = [line]
            keep = True
        elif re.match(r"^## ", line):
            if current and keep:
                sections_to_keep.append("\n".join(current))
            current = [line]
            keep = False
        else:
            current.append(line)
    if current and keep:
        sections_to_keep.append("\n".join(current))

    if sections_to_keep:
        intro_md = "\n\n".join(sections_to_keep)
    else:
        # セクションが見つからない場合は README 全体を使う（先頭見出しは除去）
        intro_md = strip_first_heading(md)

    return f"""
    <div class="intro">
        <h2>はじめに</h2>
        {md_to_html(intro_md)}
    </div>
    """


def build_chapters():
    parts_html = []
    ch_num = 1

    for part in PARTS:
        part_anchor = make_anchor(part["title"])
        parts_html.append(f"""
        <div class="part-title" id="{part_anchor}">
            <h2>{part["title"]}</h2>
            <div class="part-subtitle">{part["subtitle"]}</div>
        </div>
        """)

        for dir_name, title, desc in part["chapters"]:
            label = f"第{ch_num}章 {title}"
            anchor = make_anchor(f"ch{ch_num:02d}-{title}")
            ch_num += 1

            ch_dir = os.path.join(BASE, "chapters", dir_name)

            # README
            readme_path = os.path.join(ch_dir, "README.md")
            readme_md = read_file(readme_path)
            readme_md = strip_first_heading(readme_md)
            readme_md = strip_run_instructions(readme_md)
            readme_html = md_to_html(readme_md)

            # diagram.mmd があれば zigraph でレンダリングして追加
            diagram_html = ""
            diagram_path = os.path.join(ch_dir, "diagram.mmd")
            if os.path.exists(diagram_path):
                mmd_src = read_file(diagram_path)
                diagram_rendered = render_mermaid_file(mmd_src)
                if diagram_rendered:
                    diagram_html = f"""
                    <div class="diagram">
                        <h3>図</h3>
                        <pre class="diagram-pre">{html.escape(diagram_rendered)}</pre>
                    </div>
                    """

            parts_html.append(f"""
            <div class="chapter" id="{anchor}">
                <h2>{label}</h2>
                <p style="color:#666; font-style:italic; margin-top:-6pt;">{desc}</p>
                {readme_html}
                {diagram_html}
            </div>
            """)

    return "\n".join(parts_html)


def build_appendices():
    parts = []
    parts.append("""
    <div class="part-title" id="appendices">
        <h2>付録</h2>
        <div class="part-subtitle">補足資料</div>
    </div>
    """)

    for i, (fname, label) in enumerate(APPENDICES):
        letter = chr(ord("A") + i)
        anchor = make_anchor(f"appendix-{letter}")
        fpath = os.path.join(BASE, "notes", fname)
        md = read_file(fpath)
        md = strip_first_heading(md)
        content = md_to_html(md)
        parts.append(f"""
        <div class="appendix" id="{anchor}">
            <h2>付録{letter}. {label}</h2>
            {content}
        </div>
        """)

    return "\n".join(parts)


def build_full_html():
    return f"""<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="utf-8">
<style>{CSS}</style>
</head>
<body>
{build_cover()}
{build_toc()}
{build_intro()}
{build_chapters()}
{build_appendices()}
</body>
</html>
"""


# ── メイン ───────────────────────────────────────────────

def main():
    print("Generating HTML...")
    full_html = build_full_html()

    html_path = os.path.join(BASE, "mqtt-zig-tutorial.html")
    with open(html_path, "w", encoding="utf-8") as f:
        f.write(full_html)
    print(f"  HTML written to {html_path}")

    print("Converting to PDF (this may take a minute)...")
    pdf_path = os.path.join(BASE, "mqtt-zig-tutorial.pdf")
    weasyprint.HTML(filename=html_path).write_pdf(pdf_path)
    print(f"  PDF written to {pdf_path}")

    os.remove(html_path)
    print("Done!")


if __name__ == "__main__":
    main()
