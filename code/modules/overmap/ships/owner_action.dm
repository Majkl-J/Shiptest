/datum/action/ship_owner
	name = "Manage ship"
	desc = "Manage OOC ship settings and applications."
	background_icon_state = ACTION_BUTTON_DEFAULT_BACKGROUND
	button_icon_state = "ship_owner_0"

	/// We don't use the "target" var on /datum/action, since that's meant for atoms, not arbitrary datums.
	VAR_FINAL/datum/overmap_spawnable/parent
	var/blinking = FALSE
	/// Coefficient of the job slot change cooldown. Used so that the admin ship owner panel doesn't get cooldowns.
	var/cooldown_coeff = 1

/datum/action/ship_owner/New(...)
	. = ..()
	check_blinking()

// called in /datum/action/New(). the base implementation thinks it's dealing with an obj, but fuck that
/datum/action/ship_owner/link_to(datum/overmap_spawnable/_target)
	if(!istype(_target, /datum/overmap/ship/controlled))
		CRASH("Ship owner action [REF(src)] given invalid target [_target.type] [_target] ([REF(_target)])!")
	parent = _target

/datum/action/ship_owner/Destroy()
	SStgui.close_uis(src)
	if(parent.owner_act == src)
		parent.owner_act = null
	parent = null
	. = ..()

/datum/action/ship_owner/Trigger()
	. = ..()
	if(!.)
		return FALSE
	ui_interact(owner)

/datum/action/ship_owner/proc/check_blinking()
	var/should_blink = parent.memo == null || (length(parent.memo) <= 0)
	if(!should_blink)
		for(var/a_key in parent.applications)
			var/datum/ship_application/app = parent.applications[a_key]
			if(app.status == SHIP_APPLICATION_PENDING)
				should_blink = TRUE
				break
	set_blinking(should_blink)

/datum/action/ship_owner/proc/set_blinking(_blinking)
	if(blinking == _blinking)
		return
	blinking = _blinking
	switch(blinking)
		if(TRUE)
			background_icon_state = "bg_blink"
			button_icon_state = "ship_owner_1"
		if(FALSE)
			background_icon_state = ACTION_BUTTON_DEFAULT_BACKGROUND
			button_icon_state = "ship_owner_0"
	UpdateButtonIcon()

/datum/action/ship_owner/ui_state(mob/user)
	return GLOB.always_state

/datum/action/ship_owner/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "ShipOwner", name)
		ui.open()

/datum/action/ship_owner/proc/allow_job_slot_increase(datum/job/job_target)
	var/default_slots = parent.job_slots_default[job_target]
	var/current_slots = parent.job_slots[job_target]

	var/used_slots = 0
	var/job_holders = parent.job_holder_refs[job_target]

	for(var/datum/weakref/job_holder_ref as anything in job_holders)
		var/mob/living/job_holder = job_holder_ref.resolve()
		if(isnull(job_holder))
			continue

		if(job_holder.client)
			used_slots += 1
			continue

		var/mob/dead/observer/job_holder_ghost
		for(var/mob/dead/observer/ghost in GLOB.dead_mob_list)
			if(ghost.mind == job_holder.mind)
				job_holder_ghost = ghost
				break
		if(!isnull(job_holder_ghost))
			used_slots += 1
			continue

	var/actual_slots = current_slots + used_slots
	return actual_slots < default_slots

/datum/action/ship_owner/ui_data(mob/user)
	. = list()
	.["memo"] = parent.memo
	.["pending"] = FALSE
	.["joinMode"] = parent.join_mode
	.["cooldown"] = COOLDOWN_TIMELEFT(parent, job_slot_adjustment_cooldown)
	.["isAdmin"] = !!user.client?.holder
	.["crew_share"] = parent.crew_share
	.["applications"] = list()
	for(var/a_key as anything in parent.applications)
		var/datum/ship_application/app = parent.applications[a_key]
		if(app.status == SHIP_APPLICATION_PENDING)
			.["pending"] = TRUE
		.["applications"] += list(list(
			// we could send along the key to identify, but we don't want to expose that to the owner if show_key is false
			ref = REF(app),
			key = (app.show_key ? app.app_key : "<Empty>"),
			name = app.app_name,
			text = app.app_msg,
			status = app.status
		))
	var/list/job_increase_allowed = list()
	for(var/datum/job/job as anything in parent.job_slots)
		job_increase_allowed[job.name] = allow_job_slot_increase(job)
	.["jobIncreaseAllowed"] = job_increase_allowed

/datum/action/ship_owner/ui_static_data(mob/user)
	. = list()
	.["crew"] = list()
	for(var/datum/mind/crew_mind as anything in parent.owner_candidates)
		var/list/mind_info = parent.owner_candidates[crew_mind]
		// not sure i want to be exposing the refs directly but.
		.["crew"] += list(list(
			name = mind_info["name"],
			ref = REF(crew_mind),
			allowed = mind_info["eligible"]
			// successor =
		))

	.["jobs"] = list()
	for(var/datum/job/J as anything in parent.job_slots)
		if(J.officer)
			continue
		.["jobs"] += list(list(
			name = J.name,
			slots = parent.job_slots[J],
			ref = REF(J),
			def = parent.job_slots_default[J],
			max = min(parent.job_slots_default[J] * 2, parent.job_slots_default[J] + 3)
		))

/datum/action/ship_owner/ui_act(action, list/params)
	. = ..()
	if(.)
		return

	var/mob/user = usr
	// admins get to use the panel even if they're not the owner
	if(!user.client?.holder && user != parent.owner_mob)
		return TRUE

	switch(action)
		if("cycleJoin")
			switch(parent.join_mode)
				if(SHIP_JOIN_MODE_OPEN)
					parent.join_mode = SHIP_JOIN_MODE_APPLY
				if(SHIP_JOIN_MODE_APPLY)
					parent.join_mode = SHIP_JOIN_MODE_CLOSED
				if(SHIP_JOIN_MODE_CLOSED)
					parent.join_mode = SHIP_JOIN_MODE_OPEN
			return TRUE

		if("memo")
			var/memo_result = sanitize(stripped_multiline_input(
				user, "Enter a message for prospective players joining your ship. This information could include your goals for the outing, or details about the way your ship may play.",
				"Ship Memo", parent.memo
			))
			// stripped_multiline_input returns an empty string if people press Cancel, but
			// we don't want to delete the current memo if people press Cancel unwittingly.
			if(memo_result && length(memo_result))
				parent.memo = memo_result
				check_blinking()
			return TRUE

		if("adjustshare")
			var/value = params["adjust"]
			if(value)
				parent.crew_share = round(value) / 100
			return TRUE


		if("setApplication")
			var/datum/ship_application/target_app = locate(params["ref"])
			// if the app isn't found, or it's not in the parent ship's application list
			if(!target_app || target_app != parent.applications[ckey(target_app.app_key)])
				return TRUE
			switch(params["newStatus"])
				if("yes")
					target_app.application_status_change(SHIP_APPLICATION_ACCEPTED)
				if("no")
					target_app.application_status_change(SHIP_APPLICATION_DENIED)
			check_blinking()
			return TRUE

		if("removeApplication")
			var/datum/ship_application/target_app = locate(params["ref"])
			// if the app isn't found, or it's not in the parent ship's application list
			if(!target_app || target_app != parent.applications[ckey(target_app.app_key)])
				return TRUE
			qdel(target_app)
			return TRUE

		if("toggleCandidate")
			var/datum/mind/target_mind = locate(params["ref"]) in parent.owner_candidates
			if(!target_mind)
				return TRUE
			// swaps their eligibility
			parent.owner_candidates[target_mind]["eligible"] = !parent.owner_candidates[target_mind]["eligible"]
			update_static_data(user)
			return TRUE

		if("transferOwner")
			var/datum/mind/target_mind = locate(params["ref"]) in parent.owner_candidates
			if(!target_mind)
				return TRUE
			var/mob/new_owner = parent.get_mob_if_valid_owner(target_mind)
			if(!new_owner)
				to_chat(user, span_notice("Selected candidate is currently ineligible for ownership."), MESSAGE_TYPE_INFO)
				return TRUE
			else if(!user.client?.holder && new_owner == user) // admins get an exception, in case they want to reclaim ownership
				to_chat(user, span_notice("You can't transfer ownership to yourself!"), MESSAGE_TYPE_INFO)
				return TRUE

			parent.set_owner_mob(new_owner)
			if(!QDELETED(src))
				update_static_data(usr) // so that admins see the update
			return TRUE

		if("adjustJobSlot")
			// ensures that the job they're modifying is one they should be able to
			var/datum/job/target_job = locate(params["toAdjust"]) in parent.job_slots
			if(!target_job || target_job.officer || !COOLDOWN_FINISHED(parent, job_slot_adjustment_cooldown))
				return TRUE

			var/change_amount = params["delta"]
			if(change_amount > 0 && !allow_job_slot_increase(target_job))
				if(!user.client.holder)
					to_chat(user, span_warning("You cannot increase the number of slots for this job."))
					return TRUE
				message_admins("[key_name_admin(user)] has increased the number of slots for [target_job.name] on [parent.name] by [change_amount].")

			var/new_amount = parent.job_slots[target_job] + change_amount
			var/job_default_slots = parent.job_slots_default[target_job]
			var/job_max_slots = min(job_default_slots * 2, job_default_slots + 3)
			if(new_amount < 0 || new_amount > job_max_slots)
				return TRUE

			COOLDOWN_START(parent, job_slot_adjustment_cooldown, (5 SECONDS) * cooldown_coeff)
			parent.job_slots[target_job] = new_amount
			update_static_data(user)
			return TRUE

// Admin-only ship owner action.

/datum/action/ship_owner/admin
	name = "Manage ship (ADMIN)"
	desc = "Please don't fuck things up."

	cooldown_coeff = 0

/datum/action/ship_owner/admin/ui_state(mob/user)
	return GLOB.admin_debug_state

/datum/action/ship_owner/admin/ui_close(mob/user)
	qdel(src)
