# Lighting Engine Architecture Guidelines

## Core Principle

This lighting system must be built as a **modular, pluggable architecture** — not a system with hardcoded choices baked in. The end goal is a lighting engine where the *user of the framework* can choose which shading model, shadow technique, and render pipeline fits their needs, rather than being locked into whatever was implemented first.

**Nothing in this document should be interpreted as "pick one." Every section below describes a set of interchangeable modules, not competing final decisions.**

When implementing any piece of this system, default to a strategy-pattern / interface-based approach:
- Define an interface/abstract contract for the category (e.g. `Shading_Model`, `Shadow_Technique`, `Render_Pipeline`)
- Implement each variant as a separate module conforming to that contract
- Let the consumer of the engine select and swap between them at the material, light, or renderer level
- Avoid hardcoding assumptions from one variant into shared/core code — shared code should only assume the interface, not a specific implementation

---

## 1. Shading Models (BRDFs)

A BRDF (bidirectional reflectance distribution function) is the general math describing how light reflects off a surface. "Diffuse shading" is not an alternative to a BRDF — it's a component *within* one. This means multiple shading models can and should coexist in the same engine, selected per-material.

**Modules to support:**
- Blinn-Phong (simple, cheap, non-physically-based)
- PBR metallic-roughness (Cook-Torrance/GGX — industry standard)
- PBR specular-glossiness (alternate PBR parameterization)
- Toon/cel-shading
- Subsurface scattering (for skin, wax, foliage)

**Architecture requirement:** Each material should reference which shading model it uses. The renderer calls "shade this fragment using whatever BRDF this material specifies" — it should not assume a single global shading model.

---

## 2. Shadows

Multiple shadow techniques should be implemented as selectable modules, not a single fixed method.

**Modules to support:**
- Standard shadow mapping (depth-from-light-view)
- Cascaded shadow maps (CSM) — for large directional-light scenes
- Cube shadow maps — for point lights
- Soft shadow filtering: PCF (Percentage Closer Filtering), PCSS (Percentage Closer Soft Shadows)

**Important distinction:** Shadow acne and peter-panning are **not features to implement** — they are rendering artifacts caused by incorrect shadow bias tuning (too little bias → acne/self-shadowing stripes; too much bias → shadow detaches from the caster, "peter-panning"). Every shadow technique above needs its own bias-tuning logic and should be validated against both artifacts, not built to include them.

---

## 3. Render Pipelines

Forward, deferred, and clustered/forward+ pipelines should all be implementable as swappable pipeline modules (this mirrors how engines like Unity ship Built-in / URP / HDRP as parallel options).

**Modules to support:**
- **Forward** — simplest, good baseline, straightforward transparency handling
- **Deferred** — decouples geometry from lighting, scales better with many lights, weaker transparency/MSAA support
- **Forward+ / Clustered forward** — tiles/clusters the view frustum to cull lights per-fragment; modern hybrid approach

**Architecture requirement:** Shading model code must be written pipeline-agnostically — a shading function should be callable from a forward fragment shader *or* a deferred lighting pass without being rewritten per pipeline. Expect transparency to require a forward-style fallback even inside a deferred pipeline; this is normal, not a design flaw.

**Suggested build order (for implementation sequencing only — not a restriction on final capability):**
1. Build and validate one pipeline fully (forward is the simplest starting point)
2. Port the validated shading/shadow modules outward to the other pipelines
3. Avoid building all three in parallel from scratch — bugs multiply across codepaths simultaneously

---

## 4. Supporting Systems (also modular)

These should follow the same pluggable pattern:

- **Light types:** directional, point, spot, area, ambient/environment — all should be able to coexist in a scene simultaneously
- **Global illumination:** baked lightmaps, light probes, SSAO, reflection probes, real-time GI — treat as optional layered modules, not mutually exclusive choices
- **Light culling:** frustum culling, tiled/clustered light lists — needed regardless of pipeline once light counts scale up
- **Post-processing:** tone mapping/exposure (HDR pipeline should be established early), bloom, color grading, volumetric lighting — these consume lighting output and should not assume a specific shading model or pipeline upstream

---

## Summary Directive for Implementation

> Build every category above (shading models, shadow techniques, render pipelines, GI methods) as an interchangeable module behind a shared interface. The lighting engine's job is to offer these as configurable choices to whoever uses the framework — not to make the choice for them. Time is not a constraint; architectural flexibility and avoiding hard lock-in are the priority.
