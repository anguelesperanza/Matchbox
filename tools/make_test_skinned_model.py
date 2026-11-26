"""Writes tools/testdata/models/test_arm.glb and test_rope.glb: the skinned models Matchbox's animation is tested with,
and prints the joint palettes an independent implementation (numpy, no Matchbox code) works out for them.

    python tools/make_test_skinned_model.py

test_arm.glb -- three joints in a chain along +X, under a plain "armature" node that is NOT a joint and sits at (0, 1, 0)
(VRoid hangs its skeleton under a node like that, and dropping it loses the transform that stands the character up).
  nodes: 0 "arm" (mesh + skin), 1 "armature" (0,1,0), 2 "J0", 3 "J1" (1,0,0 from J0), 4 "J2" (1,0,0 from J1)
  mesh: a strip of six vertices at x = 0, 1, 2 (y = 1, z = +-0.1), four triangles. Weights: x=0 all J0;
        x=1 half J0 half J1; x=2 a quarter J1 and three quarters J2
  clip "Wave", 2 s:  J1 rotation LINEAR  0 -> 90 degrees about Z -> 0 at t = 0, 1, 2
                     J0 translation STEP (0,0,0) at t=0, (0,0.5,0) at t=1
                     J2 scale CUBICSPLINE (1,1,1) -> (2,1,1) -> (1,1,1), tangents (2,0,0) out of key 0, zero elsewhere
  clip "Bend", 1 s:  J1 rotation STEP, 45 degrees about Z at t = 0
test_rope.glb -- 40 joints in a chain, each 1 up from the last, 41 rows of two vertices, each weighted whole to one joint.
  More joints than the 3DS's 22 allow in a draw, so the loader's split is tested on a real file. No clips.
"""
import json, math, os, struct
import numpy as np

FLOAT, U8, U16 = 5126, 5121, 5123

def quat_z(degrees):
    h = math.radians(degrees) / 2
    return (0.0, 0.0, math.sin(h), math.cos(h))

def quat_matrix(q):
    x, y, z, w = q
    return np.array([[1 - 2*(y*y + z*z), 2*(x*y - z*w), 2*(x*z + y*w), 0],
                     [2*(x*y + z*w), 1 - 2*(x*x + z*z), 2*(y*z - x*w), 0],
                     [2*(x*z - y*w), 2*(y*z + x*w), 1 - 2*(x*x + y*y), 0],
                     [0, 0, 0, 1]])

def trs(t, q, s):
    m = np.eye(4)
    m[:3, :3] = quat_matrix(q)[:3, :3] * np.array(s)  # scale each column
    m[:3, 3] = t
    return m

class Builder:
    def __init__(self):
        self.blob, self.views, self.accessors = bytearray(), [], []
    def view(self, data, target=None):
        while len(self.blob) % 4: self.blob.append(0)
        v = {"buffer": 0, "byteOffset": len(self.blob), "byteLength": len(data)}
        if target: v["target"] = target
        self.blob.extend(data)
        self.views.append(v)
        return len(self.views) - 1
    def accessor(self, data, component, count, kind, target=None, normalized=False, **extra):
        a = {"bufferView": self.view(data, target), "componentType": component, "count": count, "type": kind}
        if normalized: a["normalized"] = True
        a.update(extra)
        self.accessors.append(a)
        return len(self.accessors) - 1

def write_glb(path, document, blob):
    document["buffers"] = [{"byteLength": len(blob)}]
    text = json.dumps(document).encode()
    text += b" " * (-len(text) % 4)
    binary = bytes(blob) + b"\0" * (-len(blob) % 4)
    with open(path, "wb") as f:
        f.write(struct.pack("<4sII", b"glTF", 2, 12 + 8 + len(text) + 8 + len(binary)))
        f.write(struct.pack("<I4s", len(text), b"JSON") + text)
        f.write(struct.pack("<I4s", len(binary), b"BIN\0") + binary)

def pack(fmt, rows): return b"".join(struct.pack(fmt, *r) for r in rows)

def skinned_mesh(b, positions, joints, weights, indices, joint_count, inverse_binds):
    n = len(positions)
    attributes = {
        "POSITION": b.accessor(pack("<3f", positions), FLOAT, n, "VEC3", 34962,
                               min=[min(p[i] for p in positions) for i in range(3)], max=[max(p[i] for p in positions) for i in range(3)]),
        "NORMAL": b.accessor(pack("<3f", [(0, 1, 0)] * n), FLOAT, n, "VEC3", 34962),
        "JOINTS_0": b.accessor(pack("<4B", joints), U8, n, "VEC4", 34962),
        "WEIGHTS_0": b.accessor(pack("<4f", weights), FLOAT, n, "VEC4", 34962),
    }
    index = b.accessor(struct.pack(f"<{len(indices)}H", *indices), U16, len(indices), "SCALAR", 34963)
    ibm = b.accessor(b"".join(np.asarray(m, dtype="<f4").T.tobytes() for m in inverse_binds), FLOAT, joint_count, "MAT4")  # column-major
    return {"attributes": attributes, "indices": index}, ibm

# ---- the arm ---------------------------------------------------------------------------------------------------------
def make_arm(path):
    b = Builder()
    positions = [(0, 1, -.1), (0, 1, .1), (1, 1, -.1), (1, 1, .1), (2, 1, -.1), (2, 1, .1)]
    joints = [(0, 0, 0, 0), (0, 0, 0, 0), (0, 1, 0, 0), (0, 1, 0, 0), (1, 2, 0, 0), (1, 2, 0, 0)]
    weights = [(1, 0, 0, 0), (1, 0, 0, 0), (.5, .5, 0, 0), (.5, .5, 0, 0), (.25, .75, 0, 0), (.25, .75, 0, 0)]
    indices = [0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4]
    # Rest world matrices: armature (0,1,0), J0 there, J1 at +1, J2 at +2
    rest_local = {1: trs((0, 1, 0), (0, 0, 0, 1), (1, 1, 1)), 2: trs((0, 0, 0), (0, 0, 0, 1), (1, 1, 1)),
                  3: trs((1, 0, 0), (0, 0, 0, 1), (1, 1, 1)), 4: trs((1, 0, 0), (0, 0, 0, 1), (1, 1, 1))}
    j0 = rest_local[1] @ rest_local[2]; j1 = j0 @ rest_local[3]; j2 = j1 @ rest_local[4]
    inverse_binds = [np.linalg.inv(m) for m in (j0, j1, j2)]
    primitive, ibm = skinned_mesh(b, positions, joints, weights, indices, 3, inverse_binds)

    def times(values): return b.accessor(struct.pack(f"<{len(values)}f", *values), FLOAT, len(values), "SCALAR", min=[min(values)], max=[max(values)])
    def vec3s(rows): return b.accessor(pack("<3f", rows), FLOAT, len(rows), "VEC3")
    def quats(rows): return b.accessor(pack("<4f", rows), FLOAT, len(rows), "VEC4")

    samplers_wave, channels_wave = [], []
    def track(samplers, channels, node, path, input_, output, interpolation):
        samplers.append({"input": input_, "output": output, "interpolation": interpolation})
        channels.append({"sampler": len(samplers) - 1, "target": {"node": node, "path": path}})
    track(samplers_wave, channels_wave, 3, "rotation", times([0, 1, 2]), quats([quat_z(0), quat_z(90), quat_z(0)]), "LINEAR")
    track(samplers_wave, channels_wave, 2, "translation", times([0, 1]), vec3s([(0, 0, 0), (0, .5, 0)]), "STEP")
    # Cubic spline: per key in-tangent, value, out-tangent
    track(samplers_wave, channels_wave, 4, "scale", times([0, 1, 2]),
          vec3s([(0, 0, 0), (1, 1, 1), (2, 0, 0),   (0, 0, 0), (2, 1, 1), (0, 0, 0),   (0, 0, 0), (1, 1, 1), (0, 0, 0)]), "CUBICSPLINE")
    samplers_bend, channels_bend = [], []
    track(samplers_bend, channels_bend, 3, "rotation", times([0, 1]), quats([quat_z(45), quat_z(45)]), "STEP")

    document = {
        "asset": {"version": "2.0", "generator": "tools/make_test_skinned_model.py"},
        "scene": 0, "scenes": [{"nodes": [0, 1]}],
        "nodes": [{"name": "arm", "mesh": 0, "skin": 0}, {"name": "armature", "translation": [0, 1, 0], "children": [2]},
                  {"name": "J0", "children": [3]}, {"name": "J1", "translation": [1, 0, 0], "children": [4]},
                  {"name": "J2", "translation": [1, 0, 0]}],
        "meshes": [{"primitives": [primitive]}],
        "skins": [{"joints": [2, 3, 4], "inverseBindMatrices": ibm, "skeleton": 1}],
        "animations": [{"name": "Wave", "samplers": samplers_wave, "channels": channels_wave},
                       {"name": "Bend", "samplers": samplers_bend, "channels": channels_bend}],
        "bufferViews": b.views, "accessors": b.accessors,
    }
    write_glb(path, document, b.blob)
    return inverse_binds

def sample_linear(keys, values, t):
    if t <= keys[0]: return values[0]
    for i in range(len(keys) - 1):
        if t < keys[i + 1]:
            f = (t - keys[i]) / (keys[i + 1] - keys[i])
            return values[i] + (values[i + 1] - values[i]) * f
    return values[-1]

def slerp(a, b, f):
    a, b = np.array(a), np.array(b)
    d = np.dot(a, b)
    if d < 0: b, d = -b, -d
    if d > 0.9995:
        r = a + (b - a) * f
        return r / np.linalg.norm(r)
    theta = math.acos(d)
    return (math.sin((1 - f) * theta) * a + math.sin(f * theta) * b) / math.sin(theta)

def arm_palettes(t, inverse_binds):
    """Wave at time t (seconds, 0..2), by the glTF spec's own formulas."""
    q = slerp(quat_z(0), quat_z(90), t) if t <= 1 else slerp(quat_z(90), quat_z(0), t - 1)
    j0_t = (0, 0.5, 0) if t >= 1 else (0, 0, 0)  # STEP
    # Cubic Hermite scale.x between keys: p0, m0 = out-tangent * dt, p1, m1 = in-tangent * dt
    if t <= 1:
        s, p0, m0, p1, m1 = t, 1.0, 2.0, 2.0, 0.0
    else:
        s, p0, m0, p1, m1 = t - 1, 2.0, 0.0, 1.0, 0.0
    scale_x = (2*s**3 - 3*s**2 + 1) * p0 + (s**3 - 2*s**2 + s) * m0 + (-2*s**3 + 3*s**2) * p1 + (s**3 - s**2) * m1
    armature = trs((0, 1, 0), (0, 0, 0, 1), (1, 1, 1))
    g0 = armature @ trs(j0_t, (0, 0, 0, 1), (1, 1, 1))
    g1 = g0 @ trs((1, 0, 0), tuple(q), (1, 1, 1))
    g2 = g1 @ trs((1, 0, 0), (0, 0, 0, 1), (scale_x, 1, 1))
    return [g @ ibm for g, ibm in zip((g0, g1, g2), inverse_binds)]

# ---- the rope --------------------------------------------------------------------------------------------------------
def make_rope(path, joint_count=40):
    b = Builder()
    rows = joint_count + 1
    positions, joints, weights = [], [], []
    for row in range(rows):
        for z in (-.1, .1):
            positions.append((0, row, z))
            joints.append((min(row, joint_count - 1), 0, 0, 0))
            weights.append((1, 0, 0, 0))
    indices = []
    for row in range(rows - 1):
        a, c = row * 2, (row + 1) * 2
        indices += [a, a + 1, c, a + 1, c + 1, c]
    inverse_binds = []
    for i in range(joint_count):
        m = np.eye(4); m[1, 3] = -i  # joint i sits at (0, i, 0) in bind pose
        inverse_binds.append(m)
    primitive, ibm = skinned_mesh(b, positions, joints, weights, indices, joint_count, inverse_binds)
    nodes = [{"name": "rope", "mesh": 0, "skin": 0}]
    for i in range(joint_count):
        node = {"name": f"R{i}"}
        if i > 0: node["translation"] = [0, 1, 0]
        if i < joint_count - 1: node["children"] = [len(nodes) + 1]
        nodes.append(node)
    document = {"asset": {"version": "2.0", "generator": "tools/make_test_skinned_model.py"},
                "scene": 0, "scenes": [{"nodes": [0, 1]}], "nodes": nodes, "meshes": [{"primitives": [primitive]}],
                "skins": [{"joints": list(range(1, joint_count + 1)), "inverseBindMatrices": ibm}],
                "bufferViews": b.views, "accessors": b.accessors}
    write_glb(path, document, b.blob)

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.join(here, "testdata", "models")
    os.makedirs(root, exist_ok=True)
    binds = make_arm(os.path.join(root, "test_arm.glb"))
    make_rope(os.path.join(root, "test_rope.glb"))
    print("wrote test_arm.glb and test_rope.glb in", root)
    np.set_printoptions(precision=6, suppress=True, linewidth=200)
    for t in (0.0, 0.5, 1.0, 1.5):
        print(f"Wave at t = {t}: palettes (rows 0..2 of each joint's matrix)")
        for j, m in enumerate(arm_palettes(t, binds)):
            print(f"  J{j}", [round(float(v), 6) for v in m[:3].flatten()])
