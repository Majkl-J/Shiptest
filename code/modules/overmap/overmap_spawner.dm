/datum/overmap
	/// The datum handler for possible spawn locations and handling appearing on the join menu
	var/datum/overmap_spawnable/spawnable_handler

/datum/overmap/proc/create_spawner(
	name,
	list/job_slots,
	datum/faction/faction,
	list/spawn_points,
	new_type
)
	RETURN_TYPE(/datum/overmap_spawnable)

	if(spawnable_handler)
		QDEL_NULL(spawnable_handler)

	spawnable_handler = new(name, job_slots, faction, new_type)
	spawnable_handler.parent = src

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
	/// List of candidates for the position of owner
	var/list/datum/mind/owner_candidates

	/// Assoc list of remaining open job slots (job = remaining slots)
	var/list/job_slots = list()
	/// Default amount of slots that we were initialized with
	var/list/job_slots_default = list()
	/// List of people currently spawned in/working in the location
	var/list/manifest = list()
	///Whether objects here require an ID with access granted
	var/unique_access = FALSE
	///Time that next job slot change can occur
	COOLDOWN_DECLARE(job_slot_adjustment_cooldown)

	/// List of mob refs indexed by their job instance
	var/list/datum/weakref/job_holder_refs = list()

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

	/// The outpost we are either docked to or currently using as a source of supplies.
	/// This is not great, refactor this into something less type-bound later maybe?
	var/datum/overmap/outpost/current_outpost

	///List of spawn points on the location
	var/list/atom/spawn_points = list()

/datum/overmap_spawnable/New(name, list/init_job_slots, datum/faction/faction, new_type)
	. = ..()
	job_slots_default = init_job_slots.Copy()
	job_slots = init_job_slots.Copy()


/datum/overmap_spawnable/Destroy(force)
	. = ..()
	if(location_type == OVERMAP_SHIP)
		SSovermap.controlled_ships -= parent
	SSovermap.controlled_locations -= parent // OUTPOSTS TODO: This list needs work

	QDEL_LIST(missions)
	LAZYCLEARLIST(owner_candidates)
	if(!QDELETED(ship_account))
		QDEL_NULL(ship_account)

	// Pretty sure lists just get dropped automatically on a destroy,
	// and since these dont include anything we wanna qdel, this should
	// not be needed
	//manifest.Cut()
	//crew_bank_accounts.Cut()
	//job_holder_refs.Cut()
	//job_slots.Cut()
	//blacklisted.Cut()
	for(var/a_key as anything in applications)
		if(isnull(applications[a_key]))
			continue
		// it handles removal itself
		qdel(applications[a_key])
	LAZYCLEARLIST(applications)
	// set ourselves to ownerless to unregister signals
	set_owner_mob(null)

// OUTPOSTS TODO: Read through all of the below, adjust where needed
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

/datum/overmap_spawnable/proc/is_join_option()
	return (length(spawn_points) >= 1) && (length(job_slots) >= 1) && join_mode != SHIP_JOIN_MODE_CLOSED

/datum/overmap_spawnable/proc/get_application(mob/applicant)
	var/index_key = applicant.client?.holder?.fakekey ? applicant.client.holder.fakekey : applicant.key
	return LAZYACCESS(applications, ckey(index_key))

/**
 * Bastardized version of GLOB.manifest.manifest_inject, but used per ship.
 * Adds the passed-in mob to the list of ship owner candidates, and makes them
 * the ship owner if there is currently none.
 *
 * * H - Human mob to add to the manifest
 * * C - client of the mob to add to the manifest
 * * human_job - Job of the human mob to add to the manifest
 */
/datum/overmap_spawnable/proc/manifest_inject(mob/living/carbon/human/H, client/C, datum/job/human_job)
	// no idea why this check exists
	if(H.mind.assigned_role != H.mind.special_role)
		manifest[H.real_name] = human_job

	var/mind_info = list(
		name = H.real_name,
		eligible = TRUE
	)
	LAZYSET(owner_candidates, H.mind, mind_info)
	H.mind.original_spawn = WEAKREF(src)
	RegisterSignal(H.mind, COMSIG_PARENT_QDELETING, PROC_REF(crew_mind_deleting))
	if(!owner_mob)
		set_owner_mob(H)

	if(!(human_job in job_holder_refs))
		job_holder_refs[human_job] = list()
	job_holder_refs[human_job] += WEAKREF(H)
	if(H.account_id)
		crew_bank_accounts += WEAKREF(H.get_bank_account())

/**
 * adds a mob's real name to a crew's guestbooks
 *
 * * H - human mob to add to the crew's guestbooks
 */
/datum/overmap_spawnable/proc/add_mob_to_crew_guestbook(mob/living/carbon/human/H)
	// iterate over the human list to find crewmembers
	for(var/mob/living/carbon/human/crewmember as anything in GLOB.human_list)
		if(crewmember == H)
			continue
		if(!(crewmember.real_name in manifest))
			continue
		if(!crewmember.mind?.guestbook)
			continue

		// add the mob to the crewmember's guestbook and viceversa
		crewmember.mind.guestbook.add_guest(crewmember, H, H.real_name, H.real_name, TRUE)
		H.mind.guestbook.add_guest(H, crewmember, crewmember.real_name, crewmember.real_name, TRUE)

/datum/overmap_spawnable/proc/crew_mind_deleting(datum/mind/del_mind)
	SIGNAL_HANDLER

	UnregisterSignal(del_mind, COMSIG_PARENT_QDELETING)
	LAZYREMOVE(owner_candidates, del_mind)
	if(owner_mind == del_mind)
		set_owner_mob(get_best_owner_mob())

/datum/overmap_spawnable/proc/owner_mob_logout(mob/mob_logging)
	SIGNAL_HANDLER

	var/mob/new_mob = GLOB.directory[ckey(owner_mind.key)]?.mob // get owner's client and through that their new mob
	var/needs_new_owner = FALSE
	if(!new_mob || new_mob.mind != owner_mind || new_mob.client.is_afk())
		needs_new_owner = TRUE
	else if(istype(new_mob, /mob/dead/observer))
		var/mob/dead/observer/new_ghost = new_mob
		if(!new_ghost.can_reenter_corpse)
			needs_new_owner = TRUE

	if(needs_new_owner)
		new_mob = get_best_owner_mob()
	set_owner_mob(new_mob)

/datum/overmap_spawnable/proc/owner_mob_afk(mob/going_afk)
	SIGNAL_HANDLER

	set_owner_mob(get_best_owner_mob())

/datum/overmap_spawnable/proc/check_owner()
	if(owner_mob)
		return
	var/mob/new_mob = get_best_owner_mob()
	if(new_mob)
		set_owner_mob(new_mob)

// goes through our list of candidates and finds a valid candidate for ship owner, or null if none can be found
/datum/overmap_spawnable/proc/get_best_owner_mob()
	. = null
	for(var/datum/mind/possible as anything in owner_candidates)
		var/mob/candidate_mob = get_mob_if_valid_owner(possible)
		if(candidate_mob)
			return candidate_mob

/datum/overmap_spawnable/proc/get_mob_if_valid_owner(datum/mind/candidate)
	if(!(candidate in owner_candidates) || !owner_candidates[candidate]["eligible"])
		return null
	var/mob/candidate_mob = candidate.active ? candidate.current : candidate.get_ghost(FALSE, FALSE)
	return (candidate_mob != null && candidate_mob.client && !candidate_mob.client.is_afk() ? candidate_mob : null)
