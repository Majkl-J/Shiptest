/datum/component/overmap_spawner
	var/list/job_slots

	var/list/atom/spawners

/datum/component/overmap_spawner/Initialize()
	if(!istype(parent, /datum/overmap))
		return ELEMENT_INCOMPATIBLE

