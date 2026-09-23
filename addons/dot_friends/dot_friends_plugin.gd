@tool
extends EditorPlugin

## Editor entry point for dot-friends. Registers inspector types only.
##
## No autoloads: the suite has four people in one process, each with their own client, and
## a global would make them one person.

const _ICON := "res://addons/dot_friends/icon_placeholder.svg"

const _TYPES := [
	[
		"DotFriendsClient",
		"Node",
		"res://addons/dot_friends/runtime/dot_friends_client.gd",
	],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
