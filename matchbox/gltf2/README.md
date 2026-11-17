# About this copy (Matchbox)
This package is based on the work of Pawel82S: **[Pawel82S/glTF2](https://github.com/Pawel82S/glTF2)** (MIT license, see `LICENSE`). It is vendored into Matchbox, and the original library's README follows below.

Changes made for Matchbox:
- The package is named `gltf` (the original is `gltf2`). Import the folder and call it as `gltf.`, for example `import "./gltf2"` from the `matchbox` package.
- Fixes needed to load files from tools like VRoid and Blender. Each is marked `MATCHBOX PATCH` in the source:
  - Embedded base64 buffers and textures came back as zero bytes because of a shadowed variable (`gltf.odin`).
  - Sparse accessors: `indices` and `values` are now a single struct, as in the glTF 2.0 schema, instead of arrays (`types.odin`).
  - Mesh primitive `targets` (morph targets / blend shapes) are skipped instead of crashing. The base mesh loads in its neutral pose (`gltf.odin`).

Everything below is the original README, apart from the usage examples, which use the `gltf` name.

---

# Why another glTF2 library?
1. I want to learn [Odin](https://odin-lang.org/) because I like philosophy behind it and syntax. I also tried [Zig](https://ziglang.org/) for few weeks, but it's syntax is not compelling to me.
2. I don't like [cgltf](https://github.com/jkuhlmann/cgltf) implementation in [vendor:cgltf](https://pkg.odin-lang.org/vendor/cgltf/) and it doesn't work on *Nix based systems (for now), only on Windows.
3. Odin has built-in many great native packages like [core/encoding/json](https://pkg.odin-lang.org/core/encoding/json/) so why not write glTF file format package that uses Odin types and remove C hint fields from cgltf wrapper?
4. Learning how to implement specification document into working code. In this case it's [glTF2](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html)
5. Because it's fun.

# Progress
:heavy_check_mark: - fully implemented
:heavy_plus_sign: - partially implemented
:x: - not implemented

| Type | Status | Details | Specification URL |
|---|---|---|---|
| Accessors | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-accessor |
| Animations | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-animation |
| Asset | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-asset |
| Buffers | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-buffer |
| Buffer Views | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-bufferview |
| Cameras | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-camera |
| Images | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-image |
| Materials | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-material |
| Meshes | :heavy_plus_sign: | Missing mesh primitive targets | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-mesh |
| Nodes | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-node |
| Samplers | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-sampler |
| Scene | :heavy_check_mark: | It's just an integer | |
| Scenes | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-scene |
| Skins | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-skin |
| Textures | :heavy_check_mark: | | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-texture |
| Extensions | :heavy_check_mark: | Represented as JSON.Value | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-extension |
| Extensions Used | :heavy_check_mark: | Array of strings | |
| Extensions Required | :heavy_check_mark: | Array of strings | |
| Extras | :heavy_check_mark: | Represented as JSON.Value | https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html#reference-extras |

# How to use it
1. Download [glTF2](https://github.com/Pawel82S/glTF2) package from github and put in your source folder.
2. Load entire glTF2 file into memory (simplest way).
3. You can change floating point precision (by default it's 32bit) to 64bit, by setting flag to Odin compiler like this:
        -define:GLTF_DOUBLE_PRECISION=true

```odin
import "./gltf2"

main :: proc() {
    // This procedure sets file format from file extension [gltf/glb]
    data, error := gltf.load_from_file("file_name.[gltf/glb]")
    switch err in error {
    case gltf.JSON_Error: // handle json parsing errors
    case gltf.GLTF_Error: // handle gltf2 parsing errors
    }
    // if there are no errors we want to free memory when we are done with processing gltf/glb file.
    defer gltf.unload(data)

    // do stuff with 'data'
    // ...

    // Iterate over buffer elements using accessor:
    buf := gltf.buffer_slice(data, 0).([][3]f32)
    for val, i in buf {
        fmt.printf("Index: %v = %v\n", i, val)
    }
}
```
3. Load parts of file into memory and parse itself. It can be handy if you can't load entire file into memory.
```odin
import "./gltf2"

main :: proc () {
    // Set options for gltf2 parser.
    // is_glb must be set to true if file is in binary format. Most likely it will have "*.glb" suffix. By default it's gltf or JSON file format.
    // delete_content set to true will delete bytes provided in procedure call. This is what 'load_from_file' does.
    options := gltf.Options{ is_glb = [true/false(default)], delete_content = [true/false(default)] }

    // Load some part of file that is valid JSON object
    data, error := gltf.parse(bytes, options)
    switch err in error {
    case gltf.JSON_Error: // Handle JSON parsing errors
    case gltf.GLTF_Error: // Handle GLTF2 parsing errors
    }
    // If there are no errors we want to free memory when we are done with processing gltf/glb file.
    defer gltf.unload(data)
}
```
# How You can help.
1. Implement missing functionality (package is still missing some stuff).
2. Remove bugs (they are for sure).
3. Optimize code.
