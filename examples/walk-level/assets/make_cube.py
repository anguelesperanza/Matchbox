"""
Writes cube.gltf beside this script: a unit cube centred on the origin, white,
with normals and texture coordinates, and its buffer embedded in the file.

Matchbox commits no model files, and examples/walk-level needs something to
place. A cube generated here is small enough to read, carries nobody else's
licence, and a cube scaled and tinted per entity is enough to build a floor,
crates and a lamp post from.

Run from this folder:  python make_cube.py
"""

import base64
import json
import os
import struct

# One entry per face: its outward normal, and the two axes its texture runs
# along. right x up == normal, which is what makes (0, 1, 2), (0, 2, 3)
# counter-clockwise seen from outside -- glTF's front face.
FACES = [
    ((1, 0, 0), (0, 0, -1), (0, 1, 0)),
    ((-1, 0, 0), (0, 0, 1), (0, 1, 0)),
    ((0, 1, 0), (1, 0, 0), (0, 0, -1)),
    ((0, -1, 0), (1, 0, 0), (0, 0, 1)),
    ((0, 0, 1), (1, 0, 0), (0, 1, 0)),
    ((0, 0, -1), (-1, 0, 0), (0, 1, 0)),
]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


positions, normals, uvs, indices = [], [], [], []

for normal, right, up in FACES:
    assert cross(right, up) == normal, f"face {normal} winds the wrong way"

    base = len(positions)
    centre = [0.5 * n for n in normal]
    for (su, sv), uv in (((-1, -1), (0, 1)), ((1, -1), (1, 1)), ((1, 1), (1, 0)), ((-1, 1), (0, 0))):
        positions.append(tuple(centre[i] + 0.5 * su * right[i] + 0.5 * sv * up[i] for i in range(3)))
        normals.append(normal)
        uvs.append(uv)
    indices += [base, base + 1, base + 2, base, base + 2, base + 3]

blob = b"".join(struct.pack("<3f", *p) for p in positions)
normal_offset = len(blob)
blob += b"".join(struct.pack("<3f", *n) for n in normals)
uv_offset = len(blob)
blob += b"".join(struct.pack("<2f", *uv) for uv in uvs)
index_offset = len(blob)
blob += b"".join(struct.pack("<H", i) for i in indices)
assert len(blob) % 4 == 0

gltf = {
    "asset": {"version": "2.0", "generator": "examples/walk-level/assets/make_cube.py"},
    "scene": 0,
    "scenes": [{"nodes": [0]}],
    "nodes": [{"mesh": 0, "name": "cube"}],
    "meshes": [{
        "name": "cube",
        "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2},
            "indices": 3,
            "material": 0,
        }],
    }],
    "materials": [{
        "name": "white",
        "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 0.8},
    }],
    "buffers": [{
        "byteLength": len(blob),
        "uri": "data:application/octet-stream;base64," + base64.b64encode(blob).decode("ascii"),
    }],
    "bufferViews": [
        {"buffer": 0, "byteOffset": 0, "byteLength": normal_offset, "target": 34962},
        {"buffer": 0, "byteOffset": normal_offset, "byteLength": uv_offset - normal_offset, "target": 34962},
        {"buffer": 0, "byteOffset": uv_offset, "byteLength": index_offset - uv_offset, "target": 34962},
        {"buffer": 0, "byteOffset": index_offset, "byteLength": len(blob) - index_offset, "target": 34963},
    ],
    "accessors": [
        {"bufferView": 0, "componentType": 5126, "count": len(positions), "type": "VEC3",
         "min": [-0.5, -0.5, -0.5], "max": [0.5, 0.5, 0.5]},
        {"bufferView": 1, "componentType": 5126, "count": len(normals), "type": "VEC3"},
        {"bufferView": 2, "componentType": 5126, "count": len(uvs), "type": "VEC2"},
        {"bufferView": 3, "componentType": 5123, "count": len(indices), "type": "SCALAR"},
    ],
}

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cube.gltf")
with open(out, "w", newline="\n") as f:
    json.dump(gltf, f, indent=2)
    f.write("\n")

print(f"wrote {out}: {len(positions)} vertices, {len(indices) // 3} triangles, {len(blob)} buffer bytes")
