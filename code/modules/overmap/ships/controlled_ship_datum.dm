/**
 * # Simulated overmap ship
 *
 * A ship that corresponds to an actual, physical shuttle.
 *
 * Can be docked to any other overmap datum that has a valid docking process.
 */
/datum/overmap/ship/controlled
	token_type = /obj/overmap/rendered
	dock_time = 10 SECONDS
	interaction_options = list(INTERACTION_OVERMAP_DOCK, INTERACTION_OVERMAP_QUICKDOCK, INTERACTION_OVERMAP_HAIL, INTERACTION_OVERMAP_INTERDICTION)

	///Vessel estimated thrust per full burn
	var/est_thrust
	///Average fuel fullness percentage
	var/avg_fuel_amnt = 100
	///Cooldown until the ship can be renamed again
	COOLDOWN_DECLARE(rename_cooldown)

	///The docking port of the linked shuttle. To add a port after creating a controlled ship datum, use [/datum/overmap/ship/controlled/proc/connect_new_shuttle_port].
	VAR_FINAL/obj/docking_port/mobile/shuttle_port
	///The map template the shuttle was spawned from, if it was indeed created from a template.
	var/datum/map_template/shuttle/source_template

	/// The shipkey for this ship
	var/obj/item/key/ship/shipkey
	/// All helms connected to this ship
	var/list/obj/machinery/computer/helm/helms = list()
	/// Is helm access for this ship locked
	var/helm_locked = FALSE

	/// an assoc list
	var/ship_modules = list()

	///Stations the ship has been blacklisted from landing at, associative station = reason
	var/list/blacklisted_landings = list()

	///The cooldown for events hitting this ship. Generally used by events with a big consquence and fires slower than normal, like flares
	COOLDOWN_DECLARE(event_cooldown)

/datum/overmap/ship/controlled/Rename(new_name, force = FALSE) // OUTPOSTS TODO: Migrate to handler
	var/old_name = name
	var/full_name = "[source_template.prefix] [new_name]"
	if(!force && !COOLDOWN_FINISHED(src, rename_cooldown) || !..(full_name, force))
		return FALSE

	message_admins("[key_name_admin(usr)] renamed vessel '[old_name]' to '[full_name]'")
	log_admin("[key_name(src)] has renamed vessel '[old_name]' to '[full_name]'")
	SSblackbox.record_feedback("text", "ship_renames", 1, full_name)

	spawnable_handler.real_name = new_name
	shuttle_port?.name = full_name
	spawnable_handler.ship_account.account_holder = full_name // This feels wrong

	if(shipkey)
		shipkey.name = "ship key ([full_name])"

	for(var/area/shuttle_area as anything in shuttle_port?.shuttle_areas)
		shuttle_area.rename_area("[full_name] [initial(shuttle_area.name)]")

	for(var/datum/weakref/stupid_fax in shuttle_port?.fax_list)
		var/obj/machinery/fax/our_fax = stupid_fax.resolve()
		our_fax.fax_name = "[get_area_name(our_fax)] Fax Machine"
	if(!force)
		COOLDOWN_START(src, rename_cooldown, 5 MINUTES)
		if(shuttle_port?.virtual_z() == null)
			return TRUE
		priority_announce("The [old_name] has been renamed to the [full_name].", "Docking Announcement", sender_override = full_name, zlevel = shuttle_port?.virtual_z())

	return TRUE

/**
 * * creation_template - The template used to create the ship.
 * * target_port - The port to dock the new ship to.
 */
/datum/overmap/ship/controlled/Initialize(position, system_spawned_in, datum/map_template/shuttle/creation_template, create_shuttle = TRUE)
	. = ..()
	if(creation_template)
		source_template = creation_template
		spawnable_handler = create_spawner(name, source_template.job_slots?.Copy(), source_template.faction, null, OVERMAP_SHIP)
		stationary_icon_state = creation_template.token_icon_state
		alter_token_appearance()
		if(create_shuttle)
			shuttle_port = SSshuttle.load_template(creation_template, src)
			if(!shuttle_port) //Loading failed, if the shuttle is supposed to be created, we need to delete ourselves.
				qdel(src) // Can't return INITIALIZE_HINT_QDEL here since this isn't ACTUAL initialisation. Considering changing the name of the proc.
				return
			if(istype(position, /datum/overmap))
				docked_to = null // Dock() complains if you're already docked to something when you Dock, even on force
				Dock(position, force = TRUE)

			refresh_engines()
		spawnable_handler.ship_account = new(name, source_template.starting_funds)
	else
		stack_trace("Attempted to create a controlled ship without a template!")
		source_template = new(rename = "Overmap Object [length(SSovermap.overmap_objects)]")
	RegisterSignal(src, COMSIG_OVERMAP_CALIBRATE_JUMP, PROC_REF(do_jump))
	RegisterSignal(src, COMSIG_OVERMAP_CANCEL_JUMP, PROC_REF(stop_jump))
#ifdef UNIT_TESTS
	Rename("[source_template]", TRUE)
#else
	Rename(pick_list_replacements(SHIP_NAMES_FILE, pick(source_template.name_categories)), TRUE)
#endif
	SSovermap.controlled_ships += src
	current_overmap.controlled_ships += src

/datum/overmap/ship/controlled/Destroy()
	//SHOULD be called first
	. = ..()
	helms.Cut()
	current_overmap.controlled_ships -= src
	if(!QDELETED(shuttle_port))
		shuttle_port.current_ship = null
		qdel(shuttle_port, TRUE)
		shuttle_port = null
	if(!QDELETED(shipkey))
		QDEL_NULL(shipkey)
	if(spawnable_handler)
		spawnable_handler.Destroy()

/datum/overmap/ship/controlled/get_jump_to_turf()
	return get_turf(shuttle_port)

/datum/overmap/ship/controlled/pre_dock(datum/overmap/to_dock, datum/docking_ticket/ticket)
	if(ticket.target != src || ticket.issuer != to_dock)
		ticket.docking_error = "Invalid target."
		return FALSE
	if(!shuttle_port.check_dock(ticket.target_port, ticket=ticket))
		if(!ticket.docking_error)
			ticket.docking_error = "Targeted docking port invalid."
		return FALSE
	return TRUE

/datum/overmap/ship/controlled/start_dock(datum/overmap/to_dock, datum/docking_ticket/ticket)
	log_shuttle("[src] [REF(src)] DOCKING: STARTED REQUEST FOR [to_dock] AT [ticket.target_port]")
	refresh_engines()
	priority_announce("Beginning docking procedures. Completion in [dock_time/10] seconds.", "Docking Announcement", sender_override = name, zlevel = shuttle_port.virtual_z())
	shuttle_port.create_ripples(ticket.target_port, dock_time)
	shuttle_port.play_engine_sound(shuttle_port, shuttle_port.landing_sound)
	shuttle_port.play_engine_sound(ticket.target_port, shuttle_port.landing_sound)

/datum/overmap/ship/controlled/complete_dock(datum/overmap/dock_target, datum/docking_ticket/ticket)
	shuttle_port.initiate_docking(ticket.target_port)
	. = ..()
	log_shuttle("[src] [REF(src)] COMPLETE DOCK: FINISHED DOCKING TO [dock_target] AT [ticket.target_port]")

/datum/overmap/ship/controlled/Undock(force = FALSE)
	if(docking)
		return
	log_shuttle("[src] [REF(src)] UNDOCK: STARTED UNDOCK FROM [docked_to]")
	var/dock_time_temp = dock_time
	if(shuttle_port.check_transit_zone() != TRANSIT_READY)
		dock_time *= 2 // Give it double the time in order to reserve transit space
		if(force)
			SSshuttle.transit_requesters -= shuttle_port
			SSshuttle.generate_transit_dock(shuttle_port) // We need a port, NOW.

	priority_announce("Beginning undocking procedures. Completion in [dock_time/10] seconds.", "Docking Announcement", sender_override = name, zlevel = shuttle_port.virtual_z())
	shuttle_port.play_engine_sound(shuttle_port, shuttle_port.takeoff_sound)

	. = ..()
	dock_time = dock_time_temp // Set it back to the original value if it was changed

/datum/overmap/ship/controlled/complete_undock()
	shuttle_port.initiate_docking(shuttle_port.assigned_transit)
	log_shuttle("[src] [REF(src)] COMPLETE UNDOCK: FINISHED UNDOCK FROM [docked_to]")
	return ..()

/datum/overmap/ship/controlled/pre_docked(datum/overmap/ship/controlled/dock_requester, override_dock)
	if(override_dock)
		return new /datum/docking_ticket(override_dock, src, dock_requester)

	for(var/obj/docking_port/stationary/docking_port in shuttle_port.docking_points)
		if(dock_requester.shuttle_port.check_dock(docking_port))
			return new /datum/docking_ticket(docking_port, src, dock_requester)
	return ..()

/datum/overmap/ship/controlled/get_dockable_locations(datum/overmap/requesting_interactor)
	var/list/docks = list()
	for(var/obj/docking_port/stationary/docking_port as anything in shuttle_port.docking_points)
		if(!docking_port.docked && !docking_port.current_docking_ticket)
			LAZYADD(docks, docking_port)
	return docks


/**
 * Docks to an empty dynamic encounter. Used for intership interaction, structural modifications, and such
 */
/datum/overmap/ship/controlled/proc/dock_in_empty_space()
	var/datum/overmap/dynamic/empty/empty_space = locate() in current_overmap.overmap_container[x][y]
	if(!empty_space)
		empty_space = new(list("x" = x, "y" = y), current_overmap)
	if(empty_space) //Don't make this an else
		Dock(empty_space)

/datum/overmap/ship/controlled/burn_engines(percentage = 100, seconds_per_tick)
	var/thrust_used = 0 //The amount of thrust that the engines will provide with one burn
	refresh_engines()
	calculate_avg_fuel()
	for(var/obj/machinery/power/shuttle/engine/real_engine as anything in shuttle_port.get_engines())
		if(!real_engine.enabled)
			continue
		thrust_used += real_engine.burn_engine(percentage, seconds_per_tick)

	thrust_used = thrust_used / (shuttle_port.turf_count * 100)
	est_thrust = thrust_used / percentage * 100 //cheeky way of rechecking the thrust, check it every time it's used

	return thrust_used

/**
 * Just double checks all the engines on the shuttle
 */
/datum/overmap/ship/controlled/proc/refresh_engines()
	var/calculated_thrust
	for(var/obj/machinery/power/shuttle/engine/real_engine as anything in shuttle_port.get_engines())
		real_engine.update_engine()
		if(real_engine.enabled)
			calculated_thrust += real_engine.thrust
	est_thrust = calculated_thrust / (shuttle_port.turf_count * 100)

/**
 * Calculates the average fuel fullness of all engines.
 */
/datum/overmap/ship/controlled/proc/calculate_avg_fuel()
	var/fuel_avg = 0
	var/engine_amnt = 0
	for(var/obj/machinery/power/shuttle/engine/real_engine as anything in shuttle_port.get_engines())
		if(!real_engine.enabled)
			continue
		fuel_avg += real_engine.return_fuel() / real_engine.return_fuel_cap()
		engine_amnt++
	if(!engine_amnt || !fuel_avg)
		avg_fuel_amnt = 0
		return
	avg_fuel_amnt = round(fuel_avg / engine_amnt * 100)

/datum/overmap/ship/controlled/tick_move()
	if(avg_fuel_amnt < 1)
		//Slow down a little when there's no fuel
		adjust_speed(clamp(-speed_x, max_speed * -0.001, max_speed * 0.001), clamp(-speed_y, max_speed * -0.001, max_speed * 0.001))

	return ..()

/**
 * Connects a new shuttle port to the ship datum. Should be used very shortly after the ship is created, if at all.
 * Used to connect the shuttle port to a ship datum that was created without a template.
 *
 * * new_port - The new shuttle port to connect to the ship.
 */
/datum/overmap/ship/controlled/proc/connect_new_shuttle_port(obj/docking_port/mobile/new_port)
	if(shuttle_port)
		CRASH("Attempted to connect a new port to a ship that already has a port!")
	shuttle_port = new_port
	refresh_engines()
	shuttle_port.name = name
	for(var/area/shuttle_area as anything in shuttle_port.shuttle_areas)
		shuttle_area.rename_area("[name] [initial(shuttle_area.name)]")

/datum/overmap/ship/controlled/proc/attempt_key_usage(mob/user, obj/item/key/ship/shipkey, obj/machinery/computer/helm/target_helm)
	user.changeNext_move(CLICK_CD_MELEE)

	if(shipkey.master_ship != src)
		target_helm?.say("Invalid shipkey usage attempted, forcibly locking down.")
		helm_locked = TRUE
	else
		helm_locked = !helm_locked
		playsound(src, helm_locked ? 'sound/machines/button4.ogg' : 'sound/machines/button3.ogg')

	for(var/obj/machinery/computer/helm/helm as anything in helms)
		SStgui.close_uis(helm)
		helm.say(helm_locked ? "Helm console is now locked." : "Helm console has been unlocked.")


/datum/overmap/ship/controlled/alter_token_appearance()
	if(!source_template)
		return ..()
	desc = {"[span_boldnotice("IFF is reporting the following:")]
	[span_bold("Affiliation: ")][source_template.faction.name]
	[span_bold("Class: ")][source_template.short_name]
	[span_bold("Velocity: ")][round(get_speed(), 0.1)] Gm/s"}
	return ..()

//when bluespace jumping gets moved to its own machine make this NOT look for non-vewscreen helms
/datum/overmap/ship/controlled/proc/do_jump(obj/item/source, datum/overmap_star_system/new_system, new_x, new_y)
	var/obj/machinery/computer/helm/our_helm
	for(var/obj/machinery/computer/helm/checked_helm as anything in helms)
		if(checked_helm.viewer)
			continue
		our_helm = checked_helm
		break
	var/list/newpos
	if(new_x && new_y)
		newpos = list("x" = new_x, "y" = new_y)

	if(our_helm)
		our_helm.calibrate_jump(new_system, newpos)

//ditto
/datum/overmap/ship/controlled/proc/stop_jump(obj/item/source)
	var/obj/machinery/computer/helm/our_helm
	for(var/obj/machinery/computer/helm/checked_helm as anything in helms)
		if(checked_helm.viewer)
			continue
		our_helm = checked_helm
		break

	if(our_helm)
		our_helm.cancel_jump()


/obj/item/key/ship
	name = "ship key"
	desc = "A key for locking and unlocking the helm of a ship, comes with a ball chain so it can be worn around the neck. Comes with a cute little shuttle-shaped keychain."
	icon_state = "shipkey"
	var/datum/overmap/ship/controlled/master_ship
	var/static/list/key_colors = list(
		"blue" = "#4646fc",
		"red" = "#fd4b54",
		"salmon" = "#faacac",
		"brown" = "#a36933",
		"green" = "#3dc752",
		"lime" = "#7ffd6e",
		"cyan" = "#00ffdd",
		"purple" = "#8c3cf5",
		"yellow" = "#ffdd44"
	)
	var/random_color = TRUE //if the key uses random coloring (logic stolen from screwdriver.dm)
	slot_flags = ITEM_SLOT_NECK

/obj/item/key/ship/Initialize(mapload, datum/overmap/ship/controlled/master_ship)
	. = ..()
	src.master_ship = master_ship
	master_ship.shipkey = src
	if(random_color) //random colors!
		icon_state = "shipkey_plasticbod"
		var/our_color = pick(key_colors)
		add_atom_colour(key_colors[our_color], FIXED_COLOUR_PRIORITY)
		update_appearance()
	name = "ship key ([master_ship.name])"

/obj/item/key/ship/update_overlays()
	. = ..()
	if(!random_color) //icon override
		return
	var/mutable_appearance/base_overlay = mutable_appearance(icon, "shipkey_metalybits")
	base_overlay.appearance_flags = RESET_COLOR
	. += base_overlay

/obj/item/key/ship/Destroy()
	master_ship.shipkey = null
	master_ship = null
	return ..()

/obj/item/key/ship/attack_self(mob/user)
	if(!master_ship || !Adjacent(user))
		return ..()

	master_ship.attempt_key_usage(user, src, src) // hello I am a helm console I promise
	return TRUE

