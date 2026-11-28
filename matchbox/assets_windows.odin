#+build windows

package matchbox

/*
	Listing assets
	==============
	What the asset folders hold, for a tool that offers the files in a picker. find_asset answers "is this name there"; this
	answers "which names are there".
*/

import "core:os"
import "core:slice"
import "core:strings"

/*
	The names of every asset of `asset_type`, in `assets/pc/<kind>/` and in `assets/<kind>/` together (a name in both is listed
	once, the way find_asset would pick the PC one), sorted, with forward slashes, relative to the kind's folder: a model at
	assets/models/props/crate.glb is "props/crate.glb", which is exactly what load_model and find_asset take. Folders below
	the kind's are searched. `extensions` limits it to files ending in one of them (".glb"), compared without regard to case;
	empty lists everything.

	The names are in `allocator`, which is the temp allocator unless another is given: use them this frame or copy them
*/
get_asset_names :: proc(asset_type:Asset_Type, extensions:[]string = {}, allocator := context.temp_allocator) -> []string {
	folder := get_asset_folder_name(asset_type)

	names := make([dynamic]string, allocator)
	for root in ([2]string{mbi.target_asset_path, mbi.asset_path}) {
		directory, _ := strings.concatenate({root, folder}, context.temp_allocator)
		collect_asset_names(directory, "", extensions, &names, allocator)
	}

	slice.sort(names[:])
	// The same name from both folders is one asset
	unique := make([dynamic]string, allocator)
	for name in names {
		if len(unique) > 0 && unique[len(unique) - 1] == name {
			delete(name, allocator)
			continue
		}
		append(&unique, name)
	}
	delete(names)
	return unique[:]
}

/*Adds the files under `directory` to `names`, each named relative to where the search began (`prefix` is the path so far)*/
@(private = "file")
collect_asset_names :: proc(directory, prefix:string, extensions:[]string, names:^[dynamic]string, allocator:=context.allocator) {
	entries, err := os.read_all_directory_by_path(directory, context.temp_allocator)
	if err != nil do return // a folder that is not there has no assets

	for entry in entries {
		name := entry.name if prefix == "" else strings.concatenate({prefix, "/", entry.name}, context.temp_allocator)
		if entry.type == .Directory {
			below, _ := strings.concatenate({directory, "/", entry.name}, context.temp_allocator)
			collect_asset_names(below, name, extensions, names, allocator)
			continue
		}
		if has_asset_extension(entry.name, extensions) do append(names, strings.clone(name, allocator))
	}
}

@(private = "file")
has_asset_extension :: proc(name:string, extensions:[]string) -> bool {
	if len(extensions) == 0 do return true
	for extension in extensions {
		if len(name) >= len(extension) && strings.equal_fold(name[len(name) - len(extension):], extension) do return true
	}
	return false
}
