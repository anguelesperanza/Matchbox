"""
Independent check of matchbox/retarget_windows.odin, numpy only.

Reads the same glTF files the game uses and works out what a ROTATION_ONLY retarget must give for the game's clips
(Idle_Subtle, Walk, Walk_Backwards, Run_Female), with rotation *matrices* (the Odin code uses quaternions), then
forward kinematics through the destination skeleton. Prints the world positions that matchbox/retarget_windows_test.odin
compares against, at the time of each clip's KEY_INDEX-th key on its densest track (no interpolation involved).

    python tools/verify_retarget.py <the-game assets/models/character folder>
"""
import json, struct, sys, os
import numpy as np

KEY_INDEX = 5
CLIPS = ["Idle_Subtle", "Walk", "Walk_Backwards", "Run_Female"]
REPORT = ["Hips", "Head", "LeftHand", "RightHand", "LeftFoot", "RightFoot"]

UNITY = {"HIPS": "Hips", "SPINE": "Spine", "CHEST": "Chest", "UPPER_CHEST": "UpperChest", "NECK": "Neck", "HEAD": "Head",
         "LUL": "LeftUpperLeg", "LLL": "LeftLowerLeg", "LF": "LeftFoot", "LT": "LeftToes",
         "RUL": "RightUpperLeg", "RLL": "RightLowerLeg", "RF": "RightFoot", "RT": "RightToes",
         "LS": "LeftShoulder", "LUA": "LeftUpperArm", "LLA": "LeftLowerArm", "LH": "LeftHand",
         "RS": "RightShoulder", "RUA": "RightUpperArm", "RLA": "RightLowerArm", "RH": "RightHand"}
UNREAL = {"HIPS": "pelvis", "SPINE": "spine_01", "CHEST": "spine_02", "UPPER_CHEST": "spine_03", "NECK": "neck_01", "HEAD": "head",
          "LUL": "thigh_l", "LLL": "calf_l", "LF": "foot_l", "LT": "ball_l", "RUL": "thigh_r", "RLL": "calf_r", "RF": "foot_r", "RT": "ball_r",
          "LS": "clavicle_l", "LUA": "upperarm_l", "LLA": "lowerarm_l", "LH": "hand_l",
          "RS": "clavicle_r", "RUA": "upperarm_r", "RLA": "lowerarm_r", "RH": "hand_r"}


def load_gltf(path):
    data = open(path, "rb").read()
    if path.lower().endswith(".glb"):
        jlen, _ = struct.unpack_from("<II", data, 12)
        doc = json.loads(data[20:20 + jlen])
        offset = 20 + jlen
        blen, _ = struct.unpack_from("<II", data, offset)
        blob = data[offset + 8: offset + 8 + blen]
    else:
        doc = json.loads(data)
        blob = b""
    return doc, blob


def accessor(doc, blob, index):
    acc = doc["accessors"][index]
    view = doc["bufferViews"][acc["bufferView"]]
    width = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[acc["type"]]
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = view.get("byteStride", 0) or width * 4
    out = np.zeros((acc["count"], width))
    for i in range(acc["count"]):
        out[i] = struct.unpack_from("<%df" % width, blob, start + i * stride)
    return out


def quat_matrix(q):
    x, y, z, w = np.asarray(q, np.float64) / np.linalg.norm(q)
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def slerp(a, b, t):
    a, b = a / np.linalg.norm(a), b / np.linalg.norm(b)
    d = np.dot(a, b)
    if d < 0:
        b, d = -b, -d
    if d > 0.9995:
        r = a + t * (b - a)
        return r / np.linalg.norm(r)
    th = np.arccos(d)
    return (np.sin((1 - t) * th) * a + np.sin(t * th) * b) / np.sin(th)


def matrix_quat(m):
    """Rotation matrix to x, y, z, w (only used for glTF nodes given as a matrix)."""
    tr = np.trace(m)
    if tr > 0:
        s = np.sqrt(tr + 1) * 2
        return np.array([(m[2, 1] - m[1, 2]) / s, (m[0, 2] - m[2, 0]) / s, (m[1, 0] - m[0, 1]) / s, s / 4])
    i = int(np.argmax(np.diag(m)))
    j, k = (i + 1) % 3, (i + 2) % 3
    s = np.sqrt(1 + m[i, i] - m[j, j] - m[k, k]) * 2
    v = np.zeros(4)
    v[i] = s / 4
    v[j] = (m[j, i] + m[i, j]) / s
    v[k] = (m[k, i] + m[i, k]) / s
    v[3] = (m[k, j] - m[j, k]) / s
    return v


class Rig:
    def __init__(self, path):
        self.doc, self.blob = load_gltf(path)
        nodes = self.doc["nodes"]
        self.names = [x.get("name", "") for x in nodes]
        self.parent = [-1] * len(nodes)
        for i, node in enumerate(nodes):
            for c in node.get("children", []):
                self.parent[c] = i
        self.t = np.array([x.get("translation", [0, 0, 0]) for x in nodes], np.float64)
        self.q = np.array([x.get("rotation", [0, 0, 0, 1]) for x in nodes], np.float64)
        self.s = np.array([x.get("scale", [1, 1, 1]) for x in nodes], np.float64)
        for i, node in enumerate(nodes):
            if "matrix" in node:
                m = np.array(node["matrix"]).reshape(4, 4).T
                self.t[i] = m[:3, 3]
                self.s[i] = np.linalg.norm(m[:3, :3], axis=0)
                self.q[i] = matrix_quat(m[:3, :3] / self.s[i])
        self.order, seen = [], set()
        while len(self.order) < len(nodes):
            for i, p in enumerate(self.parent):
                if i not in seen and (p < 0 or p in seen):
                    seen.add(i)
                    self.order.append(i)

    def node(self, name):
        return self.names.index(name)

    def local(self, i, rotation=None, translation=None):
        m = np.eye(4)
        m[:3, :3] = (quat_matrix(self.q[i]) if rotation is None else rotation) * self.s[i]
        m[:3, 3] = self.t[i] if translation is None else translation
        return m

    def globals(self, rotations=None, translations=None):
        rotations, translations = rotations or {}, translations or {}
        g = [None] * len(self.parent)
        for i in self.order:
            l = self.local(i, rotations.get(i), translations.get(i))
            g[i] = l if self.parent[i] < 0 else g[self.parent[i]] @ l
        return g

    def clip(self, name):
        for a in self.doc["animations"]:
            if a.get("name") == name:
                out = {}
                for ch in a["channels"]:
                    smp = a["samplers"][ch["sampler"]]
                    out[(ch["target"]["node"], ch["target"]["path"])] = (
                        accessor(self.doc, self.blob, smp["input"])[:, 0], accessor(self.doc, self.blob, smp["output"]),
                        smp.get("interpolation", "LINEAR"))
                return out
        raise KeyError(name)


def rot(m):
    return m[:3, :3] / np.linalg.norm(m[:3, :3], axis=0)


def value_at(track, time, quat):
    times, vals, interp = track
    if time >= times[-1]:
        return vals[-1]
    k = int(np.searchsorted(times, time, side="right") - 1)
    if time <= times[0] or interp == "STEP" or times[k] == time:
        return vals[max(k, 0)]
    f = (time - times[k]) / (times[k + 1] - times[k])
    return slerp(vals[k], vals[k + 1], f) if quat else vals[k] + (vals[k + 1] - vals[k]) * f


def main(folder):
    dst = Rig(os.path.join(folder, "psx_humanoid_male.glb"))
    src = Rig(os.path.join(folder, "retargeted_animations.glb"))
    ref = Rig(os.path.join(folder, "retargeted_animations_rest.gltf"))
    for i, name in enumerate(src.names):  # adopt the reference rest by name, as load_animation_source does
        if name and name in ref.names:
            j = ref.names.index(name)
            src.t[i], src.q[i], src.s[i] = ref.t[j], ref.q[j], ref.s[j]

    sg, dg = src.globals(), dst.globals()
    pairs = {r: (src.node(UNREAL[r]), dst.node(UNITY[r])) for r in UNITY if UNREAL[r] in src.names and UNITY[r] in dst.names}
    hips_s, hips_d = pairs["HIPS"]
    scale = dg[hips_d][1, 3] / sg[hips_s][1, 3]
    print("mapped roles", len(pairs), "hips_scale %.6f" % scale)

    for clip in CLIPS:
        tracks = src.clip(clip)
        longest = max((t[0] for t in tracks.values()), key=len)  # a clip's dense time line, whichever bone has it
        time = float(longest[KEY_INDEX])
        rotations, translations = {}, {}
        for s_node, d_node in pairs.values():
            track = tracks.get((s_node, "rotation"))
            if track is None:
                continue
            ps, pd = src.parent[s_node], dst.parent[d_node]
            rps = rot(sg[ps]) if ps >= 0 else np.eye(3)
            rpd = rot(dg[pd]) if pd >= 0 else np.eye(3)
            ls = quat_matrix(value_at(track, time, True))
            rotations[d_node] = np.linalg.inv(rpd) @ rps @ ls @ np.linalg.inv(rot(sg[s_node])) @ rot(dg[d_node])
        track = tracks.get((hips_s, "translation"))
        if track is not None:
            rps = rot(sg[src.parent[hips_s]]) if src.parent[hips_s] >= 0 else np.eye(3)
            rpd = rot(dg[dst.parent[hips_d]]) if dst.parent[hips_d] >= 0 else np.eye(3)
            delta = np.linalg.inv(rpd) @ rps @ (value_at(track, time, False) - src.t[hips_s])
            translations[hips_d] = dst.t[hips_d] + delta * scale
        g = dst.globals(rotations, translations)
        print(clip, "time %.6f" % time)
        for name in REPORT:
            print("    %-10s" % name, ", ".join("%.5f" % v for v in g[dst.node(name)][:3, 3]))


if __name__ == "__main__":
    main(sys.argv[1])
