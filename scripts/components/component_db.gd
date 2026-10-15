extends RefCounted
## CircuitForge 3D - component definition database.
##
## Data-driven definitions: identity, category, terminals, parameters, defaults
## and units. Shared by the UI, the netlist builder and the persistence layer.

const PARAM_UNITS := {
	"r": "Ohm", "c": "F", "l": "H", "v": "V", "i": "A",
	"closed": "", "position": "", "vz": "V", "is": "A", "n": "",
}

static func all_defs() -> Dictionary:
	return {
		"resistor": {
			"name": "Resistor", "category": "Passive",
			"pins": [{"name": "1"}, {"name": "2"}],
			"params": {"r": {"default": 1000.0, "unit": "Ohm", "label": "Resistance"}},
			"description": "Limits current. V = I x R.",
		},
		"capacitor": {
			"name": "Capacitor", "category": "Passive",
			"pins": [{"name": "1"}, {"name": "2"}],
			"params": {"c": {"default": 100e-6, "unit": "F", "label": "Capacitance"}},
			"description": "Stores charge. Blocks DC, passes AC.",
		},
		"inductor": {
			"name": "Inductor", "category": "Passive",
			"pins": [{"name": "1"}, {"name": "2"}],
			"params": {"l": {"default": 10e-3, "unit": "H", "label": "Inductance"}},
			"description": "Stores energy in a magnetic field. Opposes current change.",
		},
		"potentiometer": {
			"name": "Potentiometer", "category": "Passive",
			"pins": [{"name": "1"}, {"name": "W"}, {"name": "3"}],
			"params": {
				"r": {"default": 10000.0, "unit": "Ohm", "label": "Total resistance"},
				"position": {"default": 0.5, "unit": "", "label": "Wiper position (0-1)"},
			},
			"description": "Variable resistor with a wiper between the two ends.",
		},
		"vsource": {
			"name": "DC Voltage Source", "category": "Sources",
			"pins": [{"name": "+"}, {"name": "-"}],
			"params": {"v": {"default": 5.0, "unit": "V", "label": "Voltage"}},
			"description": "Ideal voltage source. Positive terminal is pin 1.",
		},
		"isource": {
			"name": "DC Current Source", "category": "Sources",
			"pins": [{"name": "+"}, {"name": "-"}],
			"params": {"i": {"default": 0.01, "unit": "A", "label": "Current"}},
			"description": "Ideal current source pushing current out of pin 1.",
		},
		"ground": {
			"name": "Ground", "category": "Sources",
			"pins": [{"name": "GND"}],
			"params": {},
			"description": "Reference node (0 V). At least one is required to simulate.",
		},
		"switch": {
			"name": "Switch", "category": "Passive",
			"pins": [{"name": "1"}, {"name": "2"}],
			"params": {"closed": {"default": false, "unit": "", "label": "Closed"}},
			"description": "Ideal single-pole switch. Closed = low resistance.",
		},
		"led": {
			"name": "LED", "category": "Semiconductor",
			"pins": [{"name": "A"}, {"name": "K"}],
			"params": {
				"is": {"default": 2e-19, "unit": "A", "label": "Saturation current"},
				"n": {"default": 1.8, "unit": "", "label": "Ideality factor"},
			},
			"description": "Light-emitting diode. Anode = pin 1, cathode = pin 2.",
		},
		"diode": {
			"name": "Diode", "category": "Semiconductor",
			"pins": [{"name": "A"}, {"name": "K"}],
			"params": {
				"is": {"default": 1e-14, "unit": "A", "label": "Saturation current"},
				"n": {"default": 1.0, "unit": "", "label": "Ideality factor"},
			},
			"description": "Silicon diode. Conducts from anode (1) to cathode (2).",
		},
		"zener": {
			"name": "Zener Diode", "category": "Semiconductor",
			"pins": [{"name": "A"}, {"name": "K"}],
			"params": {
				"is": {"default": 1e-14, "unit": "A", "label": "Saturation current"},
				"n": {"default": 1.0, "unit": "", "label": "Ideality factor"},
				"vz": {"default": 5.1, "unit": "V", "label": "Breakdown voltage"},
			},
			"description": "Diode with a defined reverse breakdown voltage.",
		},
	}


static func get_def(type: String) -> Dictionary:
	return all_defs().get(type, {})


static func exists(type: String) -> bool:
	return all_defs().has(type)


static func pin_count(type: String) -> int:
	var d = get_def(type)
	if d.is_empty():
		return 0
	return d.pins.size()


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
		var c = all_defs()[t].category
		if not cats.has(c):
			cats.append(c)
	cats.sort()
	return cats


static func types_in_category(cat: String) -> Array:
	var out := []
	for t in all_defs():
		if all_defs()[t].category == cat:
			out.append(t)
	out.sort()
	return out
