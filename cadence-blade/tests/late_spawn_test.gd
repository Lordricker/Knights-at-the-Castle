extends SceneTree

# Reproduces the reported bug: an enemy that spawns mid-session (empty buffer created
# long after the NetClock started) versus one present from the start.

func _init() -> void:
	var c := NetClock.new()
	c.delay = 0.085

	var early := NetInterp.new()   # present from the start
	var late: NetInterp = null     # spawns at t=10s

	var local: float = 0.0
	var offset: float = 137.0      # host engine started long before ours
	var lat: float = 0.030
	var dt: float = 1.0 / 60.0
	var tick: int = 0
	var late_spawn_pos := Vector2(1500.0, 200.0)
	var printed: int = 0

	for i in 900:
		local += dt
		tick += 1
		var sender_now: float = local + offset - lat

		if tick % 3 == 0:
			c.on_packet(sender_now, local)
			early.push(sender_now, Vector2(200.0 * local, 0.0))
			if late != null:
				late.push(sender_now, late_spawn_pos + Vector2(-50.0 * (local - 10.0), 0.0))

		# Enemy spawns at t=10s: reliable spawn packet creates an EMPTY buffer.
		if late == null and local >= 10.0:
			late = NetInterp.new()
			print("--- late enemy spawned at local=%.3f, node placed at %s ---"
				% [local, late_spawn_pos])

		var p: float = c.advance(dt, local)
		if late != null and late.has_data and printed < 8:
			var s: Vector2 = late.sample(p)
			print("  local=%.3f play=%.3f newest=%.3f  sample=%s  starving=%s"
				% [local, p, late.newest_time(), s, str(late.starving)])
			printed += 1

	var final_early: Vector2 = early.sample(c.play_time)
	var final_late: Vector2 = late.sample(c.play_time)
	print("\nfinal early sample: %s" % final_early)
	print("final late  sample: %s" % final_late)
	var expected_late: Vector2 = late_spawn_pos + Vector2(-50.0 * (local - 10.0), 0.0)
	print("expected late (approx): %s" % expected_late)
	var err: float = final_late.distance_to(expected_late)
	print("late position error: %.3f px" % err)
	if err > 30.0:
		print("FAIL: late-spawned enemy is far from where it should be")
		quit(1)
	print("PASS: late-spawned enemy tracks correctly")
	quit(0)
