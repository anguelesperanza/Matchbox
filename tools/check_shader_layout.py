"""
Check every shader's resource layout against what the Odin side claims.

Run from the repository root:

    python tools/check_shader_layout.py

Exits non-zero if anything disagrees, so it can go in front of a commit that
touches a shader.

## Why this exists

P7c found that `shaders/shadow/cascaded.hlsli` had declared `camera_forward`
in its cbuffer since **P3** with no field on the Odin side backing it. The
shader was reading sixteen bytes past the end of what `push_lighting` actually
pushed, so CASCADED had been selecting its cascade from undefined memory for
four phases -- which looks like cascades chosen at random distances, not like a
crash, and so had never been noticed.

Nothing in the package could have caught it. `init` asserts
`size_of(Cascade_Frag_Data) == 544` against a literal, and a literal cannot
notice a field the *shader* has and the struct does not. The two declarations
were only ever compared by eye.

The same phase found the other half of the same gap from the other side: P7c
put a fifth uniform buffer at b4, and SDL_GPU allows four per stage, so every
shader including `lighting_core.hlsli` failed to create and `init` panicked.
Also invisible until it ran.

Both are layout claims that only a program comparing the two sides can check.
This is that program.

## What it checks

  1. **Uniform buffers per stage stay within SDL_GPU's four.** The limit that
     produced a startup crash the moment it was crossed.
  2. **Each cbuffer's HLSL size matches an `#assert` in `init.odin`.** Sizes
     are computed from the preprocessed declaration with HLSL's own packing
     rules, so a member added on one side and not the other moves the number
     and is reported. This is the `camera_forward` check.
  3. **Sampled textures stay under Vulkan's guaranteed per-stage floor of 16**,
     which `lighting_rework.md` section 7.7 makes a stop-and-ask.
  4. **Storage buffers continue the `t` register sequence with no gap after
     the last sampled texture**, which is the numbering rule
     `lighting_core.hlsli` documents and which every added sampler quietly
     renumbers.

## What it does not check

That a field *means* the same thing on both sides. A struct whose members are
the right sizes in the wrong order passes this and renders nonsense. Sizes are
what a program can compare; order is still read by eye.
"""

import os
import re
import subprocess
import sys
import tempfile

SHADER_DIR = os.path.join("matchbox", "shaders")
INIT_FILE  = os.path.join("matchbox", "init.odin")

# SDL_GPU's own per-stage limit. Crossing it does not warn -- CreateGPUShader
# fails, and matchbox panics on that.
MAX_UNIFORM_BUFFERS_PER_STAGE = 4

# Vulkan's spec-guaranteed minimum for maxPerStageDescriptorSampledImages and
# maxPerStageDescriptorSamplers. Desktop drivers report far more; Android is
# where the floor is an ordinary number.
VULKAN_SAMPLER_FLOOR = 16


def preprocess(path, stage):
    """The shader with every #include and macro expanded, which is the only
    form in which a register number written as CONCAT(t, SSAO_T) is readable."""
    with tempfile.NamedTemporaryFile(suffix=".pp", delete=False) as tmp:
        out = tmp.name

    profile = "ps_6_0" if stage == "frag" else "vs_6_0"

    result = subprocess.run(
        ["dxc", "-T", profile, "-E", "main", "-I", SHADER_DIR, "-P", "-Fi", out, path],
        capture_output=True, text=True,
    )

    if result.returncode != 0:
        os.unlink(out)
        return None, result.stderr.strip()

    with open(out, encoding="utf-8", errors="replace") as f:
        text = f.read()

    os.unlink(out)
    return text, None


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    text = re.sub(r"//[^\n]*", " ", text)

    # dxc -P leaves `#line N "file"` markers behind, including *inside* a
    # cbuffer body wherever an include boundary fell -- which is every one of
    # the shared blocks, since they are declared in .hlsli files. They are not
    # members and would otherwise be parsed as one.
    text = re.sub(r"^[ \t]*#[^\n]*$", " ", text, flags=re.M)

    return text


# HLSL scalar and vector sizes in bytes. Matrices are float4-per-row and so
# occupy 16 bytes a row whatever their column count.
SCALAR = {"float": 4, "int": 4, "uint": 4, "bool": 4}


def member_size_and_alignment(decl):
    """One cbuffer member's (size, alignment) under HLSL's packing rules.

    The rule that matters and is easy to get wrong: a member never straddles a
    16-byte boundary, and an array element always occupies a whole multiple of
    16 however small its type is. Everything in this package's uniform blocks
    is a float4 or a float4x4 precisely to keep those rules from mattering --
    see any of the *_Frag_Data doc comments -- so anything reaching the scalar
    branches below is worth a second look on its own.
    """
    decl = decl.strip()

    array = re.search(r"\[\s*(\d+)\s*\]\s*$", decl)
    count = int(array.group(1)) if array else 1
    if array:
        decl = decl[: array.start()].strip()

    type_name = decl.split()[0]

    matrix = re.match(r"(float|int|uint)(\d)x(\d)$", type_name)
    if matrix:
        rows = int(matrix.group(2))
        return 16 * rows * count, 16

    vector = re.match(r"(float|int|uint|bool)(\d)$", type_name)
    if vector:
        size = SCALAR[vector.group(1)] * int(vector.group(2))
        if count > 1:
            return 16 * count, 16
        return size, 16 if size > 8 else size

    if type_name in SCALAR:
        size = SCALAR[type_name]
        if count > 1:
            return 16 * count, 16
        return size, size

    return None, None  # a struct or something unhandled -- reported, not guessed


def cbuffer_size(body):
    """The byte size of a cbuffer from its member declarations."""
    offset = 0

    for raw in body.split(";"):
        decl = raw.strip()
        if not decl:
            continue

        size, alignment = member_size_and_alignment(decl)
        if size is None:
            return None, decl

        if alignment == 16:
            offset = (offset + 15) & ~15
        elif (offset % 16) + size > 16:
            # Would straddle a 16-byte row, so it starts the next one.
            offset = (offset + 15) & ~15

        offset += size

    return (offset + 15) & ~15, None


def parse_cbuffers(text):
    out = []
    for match in re.finditer(
        r"cbuffer\s+(\w+)\s*:\s*register\s*\(\s*b(\d+)\s*,\s*space(\d+)\s*\)\s*\{(.*?)\}",
        text, flags=re.S,
    ):
        name, slot, space, body = match.group(1), int(match.group(2)), int(match.group(3)), match.group(4)
        size, bad = cbuffer_size(body)
        out.append({"name": name, "slot": slot, "space": space, "size": size, "bad": bad})
    return out


def odin_asserts():
    """Every `#assert(size_of(X) == N)` init.odin makes, as {name: size}."""
    with open(INIT_FILE, encoding="utf-8") as f:
        text = f.read()

    return {
        m.group(1): int(m.group(2))
        for m in re.finditer(r"#assert\s*\(\s*size_of\(\s*(\w+)\s*\)\s*==\s*(\d+)\s*\)", text)
    }


def main():
    if not os.path.isdir(SHADER_DIR):
        print("run this from the repository root", file=sys.stderr)
        return 2

    asserts = odin_asserts()
    problems = []

    shaders = sorted(
        f for f in os.listdir(SHADER_DIR) if f.endswith(".frag.hlsl") or f.endswith(".vert.hlsl")
    )

    for name in shaders:
        stage = "frag" if ".frag." in name else "vert"
        path  = os.path.join(SHADER_DIR, name)

        text, error = preprocess(path, stage)
        if text is None:
            problems.append(f"{name}: could not preprocess -- {error}")
            continue

        text = strip_comments(text)

        samplers = re.findall(r"register\s*\(\s*s(\d+)\s*,\s*space2\s*\)", text)
        textures = re.findall(r"register\s*\(\s*t(\d+)\s*,\s*space2\s*\)", text)
        cbuffers = parse_cbuffers(text)

        sampler_count = len(samplers)
        t_registers   = sorted(int(t) for t in textures)
        storage       = t_registers[sampler_count:]

        slots = sorted(c["slot"] for c in cbuffers if c["space"] == 3)

        print(f"{name}")
        print(f"    sampled textures {sampler_count}, storage buffers {len(storage)}"
              f"{' at t' + ',t'.join(str(s) for s in storage) if storage else ''}")
        for c in sorted(cbuffers, key=lambda c: (c["space"], c["slot"])):
            size = "unparsed" if c["size"] is None else f"{c['size']} bytes"
            print(f"    b{c['slot']} space{c['space']}  {c['name']:<32} {size}")

        # 1. SDL_GPU's four-per-stage uniform buffer limit.
        if slots and max(slots) >= MAX_UNIFORM_BUFFERS_PER_STAGE:
            problems.append(
                f"{name}: uniform buffer at b{max(slots)}, but SDL_GPU allows "
                f"{MAX_UNIFORM_BUFFERS_PER_STAGE} per stage (b0..b{MAX_UNIFORM_BUFFERS_PER_STAGE - 1}) "
                f"-- CreateGPUShader will fail and init will panic"
            )

        # 2. Sampled textures against Vulkan's floor.
        if sampler_count >= VULKAN_SAMPLER_FLOOR:
            problems.append(
                f"{name}: {sampler_count} sampled textures, at or past Vulkan's guaranteed "
                f"floor of {VULKAN_SAMPLER_FLOOR} -- lighting_rework.md 7.7 makes this a stop-and-ask"
            )

        # 3. Storage buffers continue the t sequence with no gap.
        expected = list(range(sampler_count, sampler_count + len(storage)))
        if storage != expected:
            problems.append(
                f"{name}: storage buffers at t{storage} but the {sampler_count} sampled textures "
                f"ahead of them put the sequence at t{expected} -- see lighting_core.hlsli on "
                f"why a new sampler renumbers every buffer behind it"
            )

        # 4. Each cbuffer's size against an Odin #assert.
        for c in cbuffers:
            if c["size"] is None:
                problems.append(f"{name}: could not size cbuffer {c['name']} at member '{c['bad']}'")
                continue

            if c["size"] not in asserts.values():
                problems.append(
                    f"{name}: cbuffer {c['name']} (b{c['slot']}) computes to {c['size']} bytes, "
                    f"which no #assert in init.odin claims -- either the Odin struct is missing a "
                    f"member the shader declares, or a new block needs its own assert"
                )

        print()

    if problems:
        print("PROBLEMS")
        for p in problems:
            print(f"  - {p}")
        return 1

    print("every shader's layout agrees with the Odin side")
    return 0


if __name__ == "__main__":
    sys.exit(main())
