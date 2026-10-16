extends RefCounted
## CircuitForge 3D - component definition database (public API).
##
## Thin façade over ComponentCatalog so the UI, connectivity layer, persistence
## layer and MCP server all read the same normalised definitions. Callers keep
## using get_def()/all_defs()/pin_count()/... exactly as before; the catalog is now
## data-driven (data/components/*.json) instead of hardcoded.

const Catalog = preload("res://scripts/components/component_catalog.gd")
const Schema = preload("res://scripts/components/component_schema.gd")


static func all_defs() -> Dictionary:
	return Catalog.defs()


static func get_def(type: String) -> Dictionary:
	return Catalog.get_def(type)


static func exists(type: String) -> bool:
	return Catalog.has(type)


static func count() -> int:
	return Catalog.count()


static func pin_count(type: String) -> int:
	var d = get_def(type)
	if d.is_empty():
		return 0
	return (d.pins as Array).size()


static func default_params(type: String) -> Dictionary:
	var d = get_def(type)
	var out := {}
	if d.is_empty():
		return out
	for k in d.params:
		out[k] = d.params[k].default
	return out


static func categories() -> Array:
	var cats := []
	for t in all_defs():
		var c = String(all_defs()[t].category)
		if not cats.has(c):
			cats.append(c)
	cats.sort()
	return cats


static func types_in_category(cat: String) -> Array:
	var out := []
	for t in all_defs():
		if String(all_defs()[t].category) == cat:
			out.append(t)
	out.sort()
	return out


# --- extended catalog API -------------------------------------------------

static func subcategories() -> Array:
	return Catalog.facets().subcategories


static func status_of(type: String) -> String:
	var d = get_def(type)
	if d.is_empty():
		return ""
	return String(d.get("simulation_status", "full"))


static func status_label(type: String) -> String:
	return Schema.status_label(status_of(type))


static func status_labels() -> Dictionary:
	return Schema.STATUS_LABELS.duplicate()


static func is_simulatable(type: String) -> bool:
	return Schema.is_simulatable(status_of(type))


static func search(query: String = "", filters: Dictionary = {}) -> Dictionary:
	return Catalog.search(query, filters)


static func facets() -> Dictionary:
	return Catalog.facets()


static func catalog_errors() -> Array:
	return Catalog.errors()


static func reload() -> void:
	Catalog.load_all(true)
