# Migrating Matchbox from no_gfx_api to SDL3_GPU

## Why

`matchbox/gpu` (no_gfx_api) requires `VK_EXT_shader_object` as a hard device
extension (`impl_vk.odin:510`). Intel's Windows Vulkan driver does not expose it,
including on current drivers — an Arc B580 reporting Vulkan 1.4.348 with driver
0.406.672 fails at device selection, as does the UHD 770 alongside it. The
extension is not the only requirement no_gfx leans on (`bufferDeviceAddress`,
update-after-bind descriptor indexing, Vulkan 1.3) but it is the one that bites.

SDL3_GPU's Vulkan backend builds ordinary `VkPipeline` objects and never touches
`VK_EXT_shader_object`. Both Intel devices will run it. Odin's `vendor:sdl3`
(3.4.2) ships complete GPU bindings, so this removes a vendored dependency
rather than swapping one for another.

## Goal

Replace `matchbox/gpu` with `vendor:sdl3`'s GPU API, targeting **both Vulkan and
D3D12**, with no change to the game-facing API (`draw_sprite`, `draw_rect`,
`draw_text`, `begin_drawing`, `clear_background`).

## Scope

`gpu.*` appears in 6 files and nowhere else:

| File | refs |
|---|---|
| `matchbox/init.odin` | 43 |
| `matchbox/sprite.odin` | 34 |
| `matchbox/render.odin` | 31 |
| `matchbox/font.odin` | 29 |
| `matchbox/animation.odin` | 6 |
| `matchbox/types.odin` | 3 |

The other 13 files — camera, input, ui, tiled, collisions, display, clock,
sound, timer, lerp, look_at, maps, procedural_generation — are untouched.
`ui.odin` in particular is 10KB with zero `gpu.` references; it rides entirely on
`draw_rect` / `draw_text`.

## Two simplifications found while reading

Both are free wins that fall out of the migration rather than extra work.

**1. `test.vert` and `font.vert` are the same shader.** Their bodies are
identical — scale the unit quad, rotate, translate to NDC, lerp uv between
`uv_min`/`uv_max`. Only the field *order* of the `Data` struct differs. Collapse
to one vertex shader. Six shaders become five: 1 vertex + 4 fragment.

**2. Every mesh allocates a duplicate quad.** `create_mesh` (`sprite.odin:47`),
`load_font` (`font.odin:65`) and `init` (`init.odin:158`) each upload the *same*
4 vertices and 6 indices. With a real vertex buffer there is one shared quad in
`Renderer`, and `Mesh` drops `verts_local` / `indices_local` entirely.

Also worth deleting on the way past: `VertData.flip_x` / `flip_y` are never read
by the vertex shader — flipping happens in `test.frag` off `FragData`.

---

## Stage 0 — Shader toolchain

Do this first; stages 2 onward depend on it.

### Decision: HLSL compiled offline to SPIR-V *and* DXIL

`SDL_CreateGPUDevice(format_flags, ...)` only considers backends that can consume
a format you declare. Passing `{.SPIRV}` alone gives Vulkan only and forfeits the
D3D12 fallback. So:

```odin
device := sdl.CreateGPUDevice({.SPIRV, .DXIL}, when ODIN_DEBUG do true else false, nil)
```

and both blobs must be embedded. Odin's `vendor:sdl3` has **no** SDL_shadercross
bindings (checked — nothing in the vendor tree), so runtime cross-compilation
would mean writing bindings *and* shipping an extra DLL. Compile offline instead.

**SDL_shadercross turns out not to be needed at all.** `dxc` from the Vulkan SDK
emits SPIR-V (`-spirv`) *and* DXIL from the same HLSL source, which is the same
DirectXShaderCompiler shadercross wraps. Verified on this machine
(Vulkan SDK 1.4.321.1, dxc 1.8.0.4973): both containers come out signed, and a
D3D12 device accepts the DXIL. So the build-time tool is `dxc`, already present
wherever the Vulkan SDK is, and nothing new has to be installed.

### Register conventions

shadercross requires SDL3's fixed HLSL register spaces:

| Stage | Textures/storage (`t`) | Samplers (`s`) | Uniforms (`b`) |
|---|---|---|---|
| Vertex | `space0` | `space0` | `space1` |
| Fragment | `space2` | `space2` | `space3` |

Vertex inputs use `TEXCOORD*n*` semantics, matched to pipeline attribute
locations in order.

### Work

- Write `matchbox/shaders/*.hlsl`: `quad.vert.hlsl`, `sprite.frag.hlsl`,
  `rect.frag.hlsl`, `outline.frag.hlsl`, `font.frag.hlsl`. The bodies port
  directly from the `.nosl` sources — they are 10–25 real lines each.
- Replace `build_shaders.bat` / `.sh` with a shadercross loop emitting `.spv` and
  `.dxil` per shader. Confirm exact CLI flags with `shadercross --help`; stage
  inference is from the `.vert.` / `.frag.` infix, same idea as the current
  script.
- Delete `tools/gpu_compiler`, `tools/gpu_compiler.exe`, and every `.nosl` /
  `.glsl` / `.spv` under `matchbox/shaders`.

### Uniform layout — the one silent-failure hazard

SDL3 push-uniforms follow std140 (SPIR-V) / cbuffer (DXIL) packing. A `vec2` may
not straddle a 16-byte boundary. Getting this wrong produces garbled output, not
a crash — and `types.odin:35-45` records that this has already bitten once. Lay
the structs out explicitly:

```odin
// 48 bytes: (position,size) (screen,uv_min) (uv_max,rotation,pad)
VertData :: struct #align(16) {
	position: [2]f32,
	size:     [2]f32,
	screen:   [2]f32,
	uv_min:   [2]f32,
	uv_max:   [2]f32,
	rotation: f32,
	_pad:     f32,
}

// 16 bytes. texture_a/sampler are gone — bound, not indexed.
FragData :: struct #align(16) {
	flip_x: b32,
	flip_y: b32,
	_pad:   [2]f32,
}

// 32 bytes. flip_x/flip_y were never read by outline.frag.
OutlineFragData :: struct #align(16) {
	color:  [4]f32,
	border: f32,
	_pad:   [3]f32,
}

FontFragData   :: struct #align(16) { color: [4]f32 }  // 16
Rect_Frag_Data :: struct #align(16) { color: [4]f32 }  // 16
```

**Verify:** `size_of` each struct matches the comment before wiring anything up.

---

## Stage 1 — Device, window, clearing swapchain

No shaders needed. Milestone: the window opens and `clear_background` fills it.

- `init.odin`: drop `.VULKAN` from `mbi.flags` (`init.odin:69`). Leaving it in
  forces a Vulkan surface and breaks the D3D12 path — easy to miss.
- Replace `gpu.init()` + `gpu.swapchain_init_from_sdl(window, 3)` with
  `sdl.CreateGPUDevice({.SPIRV, .DXIL}, ...)` + `sdl.ClaimWindowForGPUDevice`.
  Note the ordering flips: SDL3 wants the window created *first*.
- `Renderer` loses `desc_pool`, `frame_arenas`, `frame_arena`, `frame_sem`,
  `next_frame`, `swapchain`. It gains `device: ^sdl.GPUDevice`,
  `cmd: ^sdl.GPUCommandBuffer`, `pass: ^sdl.GPURenderPass`.
- `begin_drawing`: keep all the letterbox math (`render.odin:44-71`) verbatim.
  Replace the sync block (`render.odin:73-86`) with `AcquireGPUCommandBuffer` +
  `WaitAndAcquireGPUSwapchainTexture`. Drop the `swapchain_resize` call — SDL3
  handles resize itself.
- `clear_background`: `BeginGPURenderPass` with one `GPUColorTargetInfo`,
  `load_op = .CLEAR`, `clear_color` from the argument.
- `end_drawing`: `EndGPURenderPass` + `SubmitGPUCommandBuffer`. **Delete the
  `gpu.wait_idle()` at `render.odin:91`** — that is a full GPU stall every frame;
  `WaitAndAcquireGPUSwapchainTexture` does the pacing properly.
- Guard the minimized case: `WaitAndAcquireGPUSwapchainTexture` can hand back a
  nil texture, and every draw for that frame must be skipped rather than
  recording into a nil pass.

Stage 1 will not compile until stages 2–4 land, since `draw_*` still call `gpu.*`.
Either stub them out or work on a branch and accept a broken build until stage 4.

## Stage 2 — Pipelines + shared quad + `draw_rect`

`draw_rect` is the right second milestone: it exercises pipeline creation, the
vertex buffer and push-uniforms **without needing a texture or sampler**.

- Upload the shared quad once in `init`: `CreateGPUBuffer` (VERTEX and INDEX) +
  `CreateGPUTransferBuffer` → `MapGPUTransferBuffer` → memcpy →
  `BeginGPUCopyPass` → `UploadToGPUBuffer` ×2 → `EndGPUCopyPass` →
  `SubmitGPUCommandBuffer`. Store on `Renderer`.
- Vertex input state: `Vertex` is `{pos: [3]f32, uv: [2]f32}` → attribute 0
  `FLOAT3` at offset 0, attribute 1 `FLOAT2` at offset 12, pitch 20.
- Create the 4 pipelines in `init` via `CreateGPUGraphicsPipeline`, all sharing
  the one vertex shader and this alpha blend, which is what `set_alpha_blend`
  (`sprite.odin:167`) sets today:
  `src_color = SRC_ALPHA`, `dst_color = ONE_MINUS_SRC_ALPHA`, `src_alpha = ONE`,
  `dst_alpha = ZERO`, both ops `ADD`.
  Color target format comes from `GetGPUSwapchainTextureFormat`.
- `set_alpha_blend` deletes — blend state is baked into the pipeline.
- `draw_rect`: `BindGPUGraphicsPipeline(pass, pipelines.rect)`,
  `BindGPUVertexBuffers`, `BindGPUIndexBuffer`, `PushGPUVertexUniformData(cmd, 0,
  &vd, size_of(vd))`, `PushGPUFragmentUniformData(cmd, 0, &fd, size_of(fd))`,
  `DrawGPUIndexedPrimitives(pass, 6, 1, 0, 0, 0)`.

**Verify:** a rotated, coloured rect at the right position and size. If position
is right but size or rotation is wrong, suspect the uniform padding from stage 0.

## Stage 3 — Textures, samplers, `draw_sprite`

- `Mesh` becomes `{ texture: ^sdl.GPUTexture, sampler: ^sdl.GPUSampler, width,
  height: i32 }`. `tex_id` / `sampler_id` `u32`s are gone; so are `verts_local` /
  `indices_local`.
  - `create_sprite` (`sprite.odin:85`) and `sprite_set_frame`
    (`sprite.odin:268`) read `gpu_texture.dimensions[0/1]` — repoint at the new
    `width`/`height` fields, since SDL3 textures do not carry their size back.
- `create_mesh`: `CreateGPUTexture` (`R8G8B8A8_UNORM`, `SAMPLER` usage) then the
  same transfer-buffer → `UploadToGPUTexture` dance as stage 2. The stb decode
  path (`sprite.odin:29`) is unchanged. Barriers and `queue_wait_idle` vanish —
  SDL3 tracks resource state itself.
- Two samplers created once in `init`: nearest for sprites, linear for the font
  (matching `init.odin:143` and `font.odin:87`). Store on `Renderer`.
- `draw_sprite`: as `draw_rect`, plus `BindGPUFragmentSamplers(pass, 0,
  &{texture, sampler}, 1)`.
- `destroy_mesh`: `ReleaseGPUTexture`. The whole descriptor-pool lifecycle
  (`desc_pool_alloc_texture` / `desc_pool_free_textures`) disappears — **and with
  it the 32-sampler ceiling documented at `render.odin:31-34`.**

**Verify:** a textured sprite, then a spritesheet frame via `sprite_set_frame`,
then several sprites at once — the old ceiling is the thing being disproved.

## Stage 4 — Text, animation, outline

Mechanical once stage 3 works; these three share the sprite path.

- `font.odin`: `load_font` follows stage 3's upload path for the RGBA atlas
  (`font.odin:44-51` unchanged). `draw_text_string` binds the font pipeline and
  the atlas once, then pushes uniforms per glyph.
- `animation.odin:97-122`: identical shape to `draw_sprite`.
- `draw_outline` (`sprite.odin:180`): the outline pipeline, no texture bind.
  - Port `outline.frag` as-is. It has a known defect — `border` is in UV space so
    the edge comes out thicker on the long side (see commit `7aa5a4f`). **Do not
    fix it here**; port it faithfully so any visual diff during migration is a
    migration bug, not a mixed signal.

**Verify:** run `examples/pong`, `examples/camera-2d`, `examples/TankMovement` —
between them they cover text, camera transform, spritesheets and rotation.

## Stage 5 — Removal and diagnostics

- Delete `matchbox/gpu/` entirely: `impl_vk.odin` (142KB), `gpu.odin`,
  `impl_common.odin`, `impl_vk_type_conversion.odin`, `interop.odin`,
  `report_vk.odin`, and the vendored `vma/` including the checked-in
  `vma_windows_x86_64.lib`.
- `load_shader` (`init.odin:235`) takes `gpu.Shader_Type_Graphics` — the only
  `gpu` type in the public API. Retype to `sdl.GPUShaderStage`. It must now load
  the right blob for the active backend; consider taking both paths, or a base
  path plus an extension chosen from `GetGPUShaderFormats`.
- Rewrite `write_gpu_report` (`init.odin:30`). Keep the mechanism — a file next
  to the executable is still the only thing a tester can send back — but the body
  becomes `GPUSupportsShaderFormats({.SPIRV}, "vulkan")`,
  `({.DXIL}, "direct3d12")`, `GetGPUDriver` enumeration and `SDL_GetError()`.
  Much less code than `report_vk.odin`.
  - **The current report's advice is wrong and should not be carried over.** It
    tells the user "a current driver usually does [provide it]" — but the Arc
    B580 failure came from a current driver. That paragraph sends people to a
    driver reinstall that cannot work.
- `README.md:5,15,19` describe Matchbox as built on no_gfx_api and note the
  vendored copy. Rewrite.
- Check the `SDL3.dll` / `libSDL3.so` checked into each example directory. GPU
  needs SDL ≥ 3.1.3; the bindings here are 3.4.2. If those DLLs predate GPU
  support the examples will fail to start with a confusing symbol error.

---

## Dependency ledger

| | Before | After |
|---|---|---|
| Runtime | SDL3.dll + Vulkan loader + VMA | SDL3.dll |
| Build-time | `gpu_compiler.exe` (NoSL) | `dxc` (Vulkan SDK) |
| Vendored source | ~200KB `matchbox/gpu/` + VMA | none |
| Graphics APIs | Vulkan only | Vulkan + D3D12 |

## Risk register

| Risk | Mitigation |
|---|---|
| Uniform padding wrong → silent visual corruption | Assert `size_of` in stage 0; stage 2 verifies before anything complex is built on it |
| `.VULKAN` window flag left in → D3D12 silently unavailable | Explicit step in stage 1; confirm with `GetGPUDeviceDriver` |
| DXIL path untested until someone runs D3D12 | Force it during stage 2 via `CreateGPUDevice({.DXIL}, ...)` and run the examples |
| Per-glyph draws in `draw_text_string` | Carried over as-is. Works, but batching is the obvious follow-up once correctness is proven — not during migration |
| Broken build across stages 1–4 | Work on a branch; migrate `draw_rect` (stage 2) before deleting the no_gfx paths for sprite/text |

---

# What actually happened

The migration is done and on `sdl3-gpu-switch`. Deviations from the plan above,
and what was verified rather than assumed.

## Deviations

**SDL_shadercross was not needed.** `dxc` from the Vulkan SDK does both formats.
One fewer tool to install; see Stage 0.

**The clip-space y term had to be negated.** Not in the plan, and it would have
turned the whole picture upside down. Matchbox works in screen coordinates with
y growing downward, and the old GLSL wrote NDC straight out because raw Vulkan's
clip space already points y down. SDL3 normalises to the D3D convention on every
backend, so `quad.vert.hlsl` negates. Confirmed by screenshot on both backends.

**Drawing without clearing first now works.** `clear_background` is what opened
the render pass, so a frame that skipped it recorded into a null pass. Draws go
through `ensure_pass`, which opens a LOAD pass if there is not one already.

**`draw_outline` gained a sibling rather than changing behaviour outright.** See
the outline section below.

## Verified

- **Vulkan and D3D12 both render the pong example identically**, geometry and
  text in the same places and the right way up.
- **`SDL_GPU_DRIVER=direct3d12` genuinely selects D3D12** — checked with a probe
  that prints `GetGPUDeviceDriver` and then creates all five shaders from the
  shipped blobs. Both backends accept theirs; the DXIL is signed.
- **Every example builds** except `random-walk`, which was already broken on
  `main`: a four-value `Rectangle` literal against a five-field type, from when
  `pivot` was added. Left alone as unrelated to this work.

## The outline fix

`border` was a fraction the shader compared against uv on both axes, so the
thickness was `border * size` per axis. The shader now takes a per-axis
half-extent, and the choice of what that means moved to the call site:

- `draw_outline(center, size, color, thickness, rotation)` — **thickness in
  pixels**, even the whole way round
- `draw_outline_proportional(...)` — the old behaviour, kept for outlines that
  should scale with their shape

**This changes units on existing calls silently.** A call passing `0.04` still
compiles and now draws four hundredths of a pixel, which is nothing. Every
`draw_rect_outline` and `draw_bounding_box_outline` call needs looking at —
scaled up to pixels, or switched to `draw_outline_proportional`. Nothing in this
repository called them; the calls are in the games.

`examples/outline` draws both on the 460x52 box the difference shows up on.

## Not done

- **Text still issues one draw per glyph**, now with a uniform push each.
  Correct, and the obvious thing to batch next.
- **`sprite.frag` still flips uv after the atlas sub-rect is applied**, so
  flipping a spritesheet frame samples outside its tile. Pre-existing; ported
  faithfully so migration diffs stayed readable.
