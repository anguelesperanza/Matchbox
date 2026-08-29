import io, re, glob, os

DECL = re.compile(r"^([a-z_][a-zA-Z_0-9]*) :: proc")

GROUPS = [
    ("Getting started",  ["init.odin", "destroy.odin", "clock.odin", "display.odin", "files.odin"]),
    ("Input",            ["input.odin", "gamepad.odin", "touch.odin"]),
    ("2D drawing",       ["render.odin", "sprite.odin", "sprite_cache.odin", "shapes.odin",
                          "image.odin", "pixel_buffer.odin", "clip.odin"]),
    ("Text and fonts",   ["font.odin", "text.odin"]),
    ("2D cameras",       ["camera.odin"]),
    ("UI",               ["ui.odin", "layout.odin"]),
    ("3D cameras",       ["camera3d.odin", "look_at.odin", "math3d.odin"]),
    ("3D drawing",       ["render3d.odin", "shapes3d.odin", "light.odin", "skybox.odin"]),
    ("Models",           ["model.odin", "model_load.odin", "model_skin_load.odin", "upload.odin"]),
    ("Animation",        ["animation.odin", "animation3d.odin", "lerp.odin", "timer.odin"]),
    ("Render targets",   ["render_target.odin"]),
    ("Sound",            ["sound.odin"]),
    ("Tiled maps",       ["tiled.odin", "collisions.odin", "maps.odin", "procedural_generation.odin"]),
    ("Platform",         ["android.odin"]),
]


def strip_comment(block):
    text = []
    for l in block:
        l = l.strip()
        if l.startswith("/*"):
            l = l[2:]
        elif l.startswith("*/"):
            l = l[:-2]
        elif l.startswith("//"):
            l = l[2:]
        elif l.startswith("*"):
            l = l[1:]
        text.append(l.strip())
    s = " ".join(t for t in text if t)
    s = re.sub(r"\s+", " ", s).strip()
    if not s:
        return ""
    m = re.search(r"(?<!e\.g)(?<!i\.e)\.(?:\s|$)", s)
    if m:
        s = s[: m.start() + 1]
    return s.strip()


def signature(lines, i):
    out, depth = [], 0
    for j in range(i, min(i + 40, len(lines))):
        l = lines[j]
        out.append(l.strip())
        depth += l.count("(") - l.count(")")
        if depth <= 0 and "{" in l:
            break
    s = " ".join(out)
    if "{" in s:
        # the body brace is the last one that is not inside the parameter list
        depth = 0
        cut = None
        for idx, ch in enumerate(s):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "{" and depth == 0:
                cut = idx
                break
        if cut is not None:
            s = s[:cut]
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r",\s*\)", ")", s)
    s = s.replace("proc( ", "proc(")
    return s


def wrap(sig):
    """One line when it fits, otherwise a parameter per line."""
    if len(sig) <= 78:
        return sig

    open_i = sig.find("(")
    close_i = sig.rfind(")")
    if open_i < 0 or close_i < open_i:
        return sig

    head, params, tail = sig[: open_i + 1], sig[open_i + 1 : close_i], sig[close_i:]

    parts, depth, cur = [], 0, ""
    for ch in params:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        parts.append(cur.strip())

    if len(parts) < 2:
        return sig

    return head + "".join("\n\t" + p + "," for p in parts) + "\n" + tail


entries = {}
for f in sorted(glob.glob("matchbox/*.odin")):
    base = os.path.basename(f)
    if base == "touch_test.odin":
        continue
    lines = io.open(f, encoding="utf-8").read().split("\n")
    for i, l in enumerate(lines):
        m = DECL.match(l)
        if not m:
            continue

        attr, k = False, i - 1
        while k >= 0 and lines[k].strip().startswith("@("):
            if "private" in lines[k] or "test" in lines[k]:
                attr = True
            k -= 1
        if attr:
            continue

        block = []
        while k >= 0 and not lines[k].strip():
            k -= 1
        if k >= 0 and lines[k].strip().endswith("*/"):
            while k >= 0:
                block.insert(0, lines[k])
                if lines[k].strip().startswith("/*"):
                    break
                k -= 1
        else:
            while k >= 0 and lines[k].strip().startswith("//"):
                block.insert(0, lines[k])
                k -= 1

        entries.setdefault(base, []).append(
            (m.group(1), signature(lines, i), strip_comment(block))
        )

placed = {b for _, files in GROUPS for b in files}
leftover = sorted(set(entries) - placed)
if leftover:
    GROUPS.append(("Other", leftover))

total = sum(len(v) for v in entries.values())

out = [
    "# Matchbox cheatsheet\n",
    f"Every public procedure in the package -- {total} of them -- with its arguments",
    "and one line on what it does.\n",
    "**Generated from the source.** Regenerate rather than edit by hand: each",
    "description is the first sentence of that procedure's own doc comment, so the way",
    "to improve an entry here is to improve the comment it came from. Every public",
    "procedure has one; anything showing _(no doc comment)_ is a regression.\n",
    "Names are as exported. A game importing the package as `mb` writes `mb.init(...)`.",
    "Private procedures are left out -- there are 109 of them and a game cannot call",
    "any.\n",
    "## Contents\n",
]

for title, files in GROUPS:
    n = sum(len(entries.get(f, [])) for f in files)
    if n:
        out.append(f"- [{title}](#{title.lower().replace(' ', '-')}) -- {n}")
out.append("")

undocumented = 0
for title, files in GROUPS:
    rows = [(n, s, d, f) for f in files for n, s, d in entries.get(f, [])]
    if not rows:
        continue

    out.append(f"## {title}\n")
    current = None
    for name, sig, doc, f in rows:
        if f != current:
            out.append(f"### `{f}`\n")
            current = f
        out.append("```odin\n" + wrap(sig) + "\n```")
        if doc:
            out.append(doc + "\n")
        else:
            undocumented += 1
            out.append("_(no doc comment)_\n")

io.open("cheatsheet.md", "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
print(f"wrote cheatsheet.md: {total} procedures, {undocumented} with no doc comment")
