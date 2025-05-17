/datum/overmap
	/// The datum handler for possible spawn locations and handling appearing on the join menu
	var/datum/overmap_spawnable/spawnable_handler

/datum/overmap/create_spawner(
	name,
	list/job_slots,
	datum/faction/faction,
	list/spawn_points
)
	RETURN_TYPE(/datum/overmap_spawnable)

	if(spawnable_handler)
		QDEL_NULL(spawnable_handler)

	spawnable_handler = new spawnable_handler(name, job_slots, faction)

	if(spawn_points && length(spawn_points))
		spawnable_handler.add_spawn_points(spawn_points)

	return spawnable_handler


/datum/overmap_spawnable
	/// Reference to the overmap linked to this handler
	VAR_FINAL/datum/overmap/parent

	/// Name of the spawn location
	var/name
	/// Real name of the spawn location, without any prefixes and such
	var/real_name = "Unnamed spawn location"
	/// Description of the location
	var/description
	/// The memo of the spawn location, shown when a new crew joins
	var/memo

	/// Type of overmap location
	var/location_type = OVERMAP_SHIP

	/// The faction responsible for the location.
	var/datum/faction/faction

	/// The mob of the current owner. Tracking mostly uses this; that lets us pick up on logouts, which let us
	/// determine if a player is switching to control of a mob with a different mind, who thus shouldn't be the owner.
	var/mob/owner_mob
	/// The mind of the current owner. Mostly kept around so that we can scream in panic if this gets changed behind our back.
	var/datum/mind/owner_mind
	/// The action datum given to the current owner; will be null if we don't have one.
	var/datum/action/ship_owner/owner_act
	/// The ID of the timer that is used to check for a new owner, if the ship ends up with a null owner.
	var/owner_check_timer_id

	/// Assoc list of remaining open job slots (job = remaining slots)
	var/list/job_slots
	/// List of people currently spawned in/working in the location
	var/list/manifest = list()

	/// The spawn location's join mode.
	/// Controls whether players can join freely, have to apply, or can't join at all.
	var/join_mode = SHIP_JOIN_MODE_CLOSED
	/// Lazylist of /datum/ship_applications for this ship. Only used if join_mode == SHIP_JOIN_MODE_APPLY
	var/list/datum/ship_application/applications

	/// Locationwide bank account used for cargo consoles and bounty payouts.
	var/datum/bank_account/ship/ship_account
	/// Crew Owned Bank Accounts.
	var/list/crew_bank_accounts = list()
	/// Magic number for telling us how much of a mission goes into each crew member's bank account
	var/crew_share = 0.02
	/// List of currently-accepted missions.
	var/list/datum/mission/missions
	/// The maximum number of currently active missions that a ship may take on.
	var/max_missions = 2

	///List of spawn points on the location
	var/list/atom/spawn_points = list()

/datum/overmap_spawnable/New(var/name, var/list/job_slots, var/datum/faction/faction)
	. = ..()

/datum/overmap_spawnable/proc/add_spawn_points(var/list/to_add)

/datum/overmap_spawnable/proc/set_owner_mob(mob/new_owner)
	if(owner_mob)
		// we (hopefully) don't have to hook qdeletion,
		// because when mobs are qdeleted, they ghostize, which SHOULD transfer the key.
		// that means they raise the logout signal, so we transfer to the ghost
		UnregisterSignal(owner_mob, COMSIG_MOB_LOGOUT)
		UnregisterSignal(owner_mob, COMSIG_MOB_GO_INACTIVE)
		// testing trace because i am afraid
		if(owner_mob.mind && owner_mob.mind != owner_mind)
			// moving minds means moving keys; if this trips, a mind moved without a key move for us to pick up on
			// when transferring mind from one body to another, source mob's mind is set to null before the transfer. thus the null check
			// i'm going to be honest i don't have a fucking clue if this code works. mind code is hell
			stack_trace("[src]'s owner mob [owner_mob] (mind [owner_mob.mind], player [owner_mob.mind.key]) silently changed its mind from [owner_mind] (player [owner_mind.key])!")
		owner_act.Remove(owner_mob)

	if(!new_owner) // owner mob is being set to null; we're becoming ownerless
		owner_mob = null
		owner_mind = null
		if(owner_act)
			QDEL_NULL(owner_act)
		// turns out that timers don't get added to active_timers if the datum is getting qdeleted.
		// so this timer was sitting around after deletion and clogging up runtime logs. thus, the QDELING() check. oops!
		if(!owner_check_timer_id && !QDELING(src))
			owner_check_timer_id = addtimer(CALLBACK(src, PROC_REF(check_owner)), 5 MINUTES, TIMER_STOPPABLE|TIMER_LOOP|TIMER_DELETE_ME)
		return

	owner_mob = new_owner
	owner_mind = owner_mob.mind
	if(owner_check_timer_id) // we know we have an owner since we didn't return up there
		deltimer(owner_check_timer_id)
		owner_check_timer_id = null

	// testing trace
	// not 100% sure this is needed
	if(!(owner_mind in owner_candidates))
		stack_trace("[src] tried to set ship owner to [new_owner] despite its mind [new_owner.mind] not being in owner_candidates!")

	RegisterSignal(owner_mob, COMSIG_MOB_LOGOUT, PROC_REF(owner_mob_logout))
	RegisterSignal(owner_mob, COMSIG_MOB_GO_INACTIVE, PROC_REF(owner_mob_afk))
	if(!owner_act)
		owner_act = new(src)
	owner_act.Grant(owner_mob)
