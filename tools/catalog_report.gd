extends SceneTree
## Catalog integrity / status report tool.
## Usage:
##   godot --headless --path <project> --script res://tools/catalog_report.gd
## Prints counts, the implementation-status breakdown and any validation errors.

const ComponentCatalog = preload("res://scripts/components/component_catalog.gd")


func _init() -> void:
	ComponentCatalog.load_all(true)
	var errs := ComponentCatalog.errors()
	var defs := ComponentCatalog.defs()
	var by_status := {}
	var by_category := {}
	var sim := 0
	for id in defs.keys():
		var d: Dictionary = defs[id]
		var st := String(d.get("simulation_status", "?"))
		by_status[st] = int(by_status.get(st, 0)) + 1
		var cat := String(d.get("category", "?"))
		by_category[cat] = int(by_category.get(cat, 0)) + 1
		if st == "full" or st == "partial":
			sim += 1
	print(JSON.stringify({
		"total": defs.size(),
		"simulatable": sim,
		"categories": by_category.size(),
		"by_status": by_status,
		"by_category": by_category,
		"errors": errs,
	}, "  ", false, true))
	quit(0 if errs.is_empty() else 1)
