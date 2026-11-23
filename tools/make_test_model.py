"""Writes tools/testdata/models/test_crate.gltf and .glb: the model Matchbox's glTF reader is tested with.
Copies them into assets/models too, where examples/model-check loads one. assets/ is the game's own
and git ignores it, so the tracked copies are the ones in tools/testdata.

    python tools/make_test_model.py

Two nodes, so the reader's node baking is tested, and both of glTF's ways of holding an image:
- node "crate": a 1-unit cube, 24 vertices, normals, uvs, a 4 x 4 orange/white checker texture,
  opaque material.
- node "flag", a child of "crate": moved up 1 and scaled 0.5, a 1-unit quad in the XY plane with
  red vertex colours, a double-sided MASK material (cutoff 0.3), base colour (0.5, 1, 1, 1).
The .gltf embeds its buffer and image as base64 data URIs; the .glb keeps both in its binary
chunk, the image as a buffer view. model_load_windows_test.odin checks the numbers below.
"""
import base64, json, os, struct, zlib

def png_rgba(width, height, pixel):
    raw = b"".join(b"\0" + b"".join(bytes(pixel(x, y)) for x in range(width)) for y in range(height))
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))

image = png_rgba(4, 4, lambda x, y: (255, 140, 0, 255) if (x + y) % 2 == 0 else (255, 255, 255, 255))

# The cube: per face its outward normal and two axes, u x v == normal, counter-clockwise from outside
faces = [((0, 0, 1), (1, 0, 0), (0, 1, 0)), ((0, 0, -1), (-1, 0, 0), (0, 1, 0)),
         ((1, 0, 0), (0, 0, -1), (0, 1, 0)), ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
         ((0, 1, 0), (1, 0, 0), (0, 0, -1)), ((0, -1, 0), (1, 0, 0), (0, 0, 1))]
cube_positions, cube_normals, cube_uvs, cube_indices = [], [], [], []
for n, u, v in faces:
    first = len(cube_positions)
    for su, sv, uv in ((-1, -1, (0, 1)), (1, -1, (1, 1)), (1, 1, (1, 0)), (-1, 1, (0, 0))):
        cube_positions.append(tuple(0.5 * (n[i] + su * u[i] + sv * v[i]) for i in range(3)))
        cube_normals.append(n)
        cube_uvs.append(uv)
    cube_indices += [first, first + 1, first + 2, first, first + 2, first + 3]

quad_positions = [(-0.5, -0.5, 0), (0.5, -0.5, 0), (0.5, 0.5, 0), (-0.5, 0.5, 0)]
quad_normals = [(0, 0, 1)] * 4
quad_uvs = [(0, 1), (1, 1), (1, 0), (0, 0)]
quad_colors = [(255, 0, 0, 255)] * 4  # normalised unsigned bytes: the reader divides by 255
quad_indices = [0, 1, 2, 0, 2, 3]

# One buffer, every view 4-byte aligned
blob, views, accessors = bytearray(), [], []
def add(data, target=None):
    while len(blob) % 4: blob.append(0)
    view = {"buffer": 0, "byteOffset": len(blob), "byteLength": len(data)}
    if target: view["target"] = target
    blob.extend(data)
    views.append(view)
    return len(views) - 1
def accessor(view, component, count, kind, normalized=False, **extra):
    a = {"bufferView": view, "componentType": component, "count": count, "type": kind}
    if normalized: a["normalized"] = True
    a.update(extra)
    accessors.append(a)
    return len(accessors) - 1
f3 = lambda rows: b"".join(struct.pack("<3f", *r) for r in rows)
f2 = lambda rows: b"".join(struct.pack("<2f", *r) for r in rows)

FLOAT, U8, U16 = 5126, 5121, 5123
cube = {"POSITION": accessor(add(f3(cube_positions), 34962), FLOAT, 24, "VEC3", min=[-0.5] * 3, max=[0.5] * 3),
        "NORMAL": accessor(add(f3(cube_normals), 34962), FLOAT, 24, "VEC3"),
        "TEXCOORD_0": accessor(add(f2(cube_uvs), 34962), FLOAT, 24, "VEC2")}
cube_index = accessor(add(struct.pack("<36H", *cube_indices), 34963), U16, 36, "SCALAR")
quad = {"POSITION": accessor(add(f3(quad_positions), 34962), FLOAT, 4, "VEC3", min=[-0.5, -0.5, 0], max=[0.5, 0.5, 0]),
        "NORMAL": accessor(add(f3(quad_normals), 34962), FLOAT, 4, "VEC3"),
        "TEXCOORD_0": accessor(add(f2(quad_uvs), 34962), FLOAT, 4, "VEC2"),
        "COLOR_0": accessor(add(b"".join(bytes(c) for c in quad_colors), 34962), U8, 4, "VEC4", normalized=True)}
quad_index = accessor(add(struct.pack("<6B", *quad_indices), 34963), U8, 6, "SCALAR")

def document(image_entry, buffer_entry):
    return {
        "asset": {"version": "2.0", "generator": "tools/make_test_model.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": "crate", "mesh": 0, "children": [1]},
                  {"name": "flag", "mesh": 1, "translation": [0, 1, 0], "scale": [0.5, 0.5, 0.5]}],
        "meshes": [{"primitives": [{"attributes": cube, "indices": cube_index, "material": 0}]},
                   {"primitives": [{"attributes": quad, "indices": quad_index, "material": 1}]}],
        "materials": [{"name": "crate", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}},
                      {"name": "flag", "alphaMode": "MASK", "alphaCutoff": 0.3, "doubleSided": True,
                       "pbrMetallicRoughness": {"baseColorFactor": [0.5, 1, 1, 1]}}],
        "textures": [{"source": 0}],
        "images": [image_entry],
        "buffers": [buffer_entry],
        "bufferViews": views,
        "accessors": accessors,
    }

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.join(here, "testdata", "models")
os.makedirs(root, exist_ok=True)

gltf = document({"uri": "data:image/png;base64," + base64.b64encode(image).decode()},
                {"byteLength": len(blob), "uri": "data:application/octet-stream;base64," + base64.b64encode(bytes(blob)).decode()})
with open(os.path.join(root, "test_crate.gltf"), "w") as f:
    json.dump(gltf, f, indent=1)

image_view = add(image)  # the .glb's image lives in the binary chunk; the .gltf above ignores this view
glb_json = json.dumps(document({"bufferView": image_view, "mimeType": "image/png"}, {"byteLength": len(blob)})).encode()
glb_json += b" " * (-len(glb_json) % 4)
binary = bytes(blob) + b"\0" * (-len(blob) % 4)
with open(os.path.join(root, "test_crate.glb"), "wb") as f:
    f.write(struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(glb_json) + 8 + len(binary)))
    f.write(struct.pack("<I4s", len(glb_json), b"JSON") + glb_json)
    f.write(struct.pack("<I4s", len(binary), b"BIN\0") + binary)
import shutil
assets = os.path.join(here, "..", "assets", "models")
os.makedirs(assets, exist_ok=True)
for name in ("test_crate.gltf", "test_crate.glb"):
    shutil.copy(os.path.join(root, name), os.path.join(assets, name))
print("wrote", root, "and copied them into", assets)
