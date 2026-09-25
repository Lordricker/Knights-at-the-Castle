extends SceneTree

# Throwaway harness: numerically exercises NetInterp + NetClock.
# Run: godot --headless --script res://net_interp_test.gd

var _fail: int = 0

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_fail += 1
		print("FAIL: %s" % msg)
	else:
		print("  ok: %s" % msg)


func _init() -> void:
	_test_interp_basic()
	_test_interp_teleport()
	_test_interp_starvation()
	_test_interp_duplicate_ts()
	_test_clock_convergence()
	_test_end_to_end_constant_velocity()
	_test_end_to_end_with_jitter_and_loss()
	_test_old_scheme_baseline()
	print("")
	if _fail == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % _fail)
	quit(1 if _fail > 0 else 0)


func _test_interp_basic() -> void:
	print("\n[interp: midpoint lerp]")
	var b := NetInterp.new()
	b.push(1.00, Vector2(0, 0))
	b.push(1.05, Vector2(10, 0))
	var m: Vector2 = b.sample(1.025)
	_ok(absf(m.x - 5.0) < 0.001, "halfway between samples -> x=5 (got %.4f)" % m.x)
	_ok(b.sample(1.00).x == 0.0, "exactly at first sample -> x=0")


func _test_interp_teleport() -> void:
	print("\n[interp: teleport not lerped]")
	var b := NetInterp.new()
	b.push(1.00, Vector2(0, 0))
	b.push(1.05, Vector2(5000, 0))
	var m: Vector2 = b.sample(1.025)
	_ok(m.x == 5000.0, "gap > TELEPORT_DISTANCE jumps to target (got %.1f)" % m.x)


func _test_interp_starvation() -> void:
	print("\n[interp: starvation holds, does not run away]")
	var b := NetInterp.new()
	b.push(1.00, Vector2(0, 0))
	b.push(1.05, Vector2(10, 0))
	var near: Vector2 = b.sample(1.06)          # 10ms past newest, within MAX_EXTRAPOLATION
	_ok(near.x > 10.0 and near.x < 13.0, "brief extrapolation past newest (got %.3f)" % near.x)
	_ok(b.starving, "starving flag set")
	var far: Vector2 = b.sample(5.0)            # way past
	_ok(far.x == 10.0, "far past newest holds last position (got %.3f)" % far.x)


func _test_interp_duplicate_ts() -> void:
	print("\n[interp: duplicate/stale timestamps]")
	var b := NetInterp.new()
	b.push(1.00, Vector2(0, 0))
	b.push(1.00, Vector2(7, 0))   # same ts -> overwrite, not a zero-duration segment
	b.push(0.90, Vector2(9, 0))   # stale ts -> overwrite too
	var m: Vector2 = b.sample(1.00)
	_ok(m.x == 9.0, "duplicate/stale ts overwrites tail (got %.1f)" % m.x)
	b.push(0.0, Vector2(0, 0))    # >1s backwards = sender restart -> clear
	_ok(b.has_data, "buffer usable after restart-clear")


func _test_clock_convergence() -> void:
	print("\n[clock: converges and stays rate-limited]")
	var c := NetClock.new()
	c.delay = 0.085
	# Sender is 100.0s ahead of our local clock, 30ms one-way latency.
	var local: float = 0.0
	var offset: float = 100.0
	var lat: float = 0.030
	var send_dt: float = 0.05
	var next_send: float = 0.0
	var dt: float = 1.0 / 60.0
	var last_play: float = -1.0
	var max_step: float = 0.0
	for i in 1200:
		local += dt
		if local >= next_send:
			next_send += send_dt
			# Packet sent at sender time (local+offset-lat), received now.
			c.on_packet(local + offset - lat, local)
		var p: float = c.advance(dt, local)
		if last_play >= 0.0 and i > 120:
			max_step = maxf(max_step, absf((p - last_play) - dt))
		last_play = p
	var expected: float = local + offset - c.delay
	_ok(absf(c.play_time - expected) < 0.05,
		"play head lands near sender_now - delay (err %.4f s)" % (c.play_time - expected))
	_ok(max_step <= dt * NetClock.MAX_WARP + 1e-6,
		"per-frame warp stays within MAX_WARP (max extra %.6f s)" % max_step)


func _test_end_to_end_constant_velocity() -> void:
	print("\n[end-to-end: constant velocity reconstructs smoothly]")
	var c := NetClock.new()
	c.delay = 0.085
	var b := NetInterp.new()
	var speed: float = 200.0
	var local: float = 0.0
	var offset: float = 50.0
	var lat: float = 0.025
	var dt: float = 1.0 / 60.0
	var tick: int = 0
	var last: Vector2 = Vector2.INF
	var max_dev: float = 0.0
	var samples: int = 0
	for i in 1200:
		local += dt
		tick += 1
		if tick % 3 == 0:  # 20 Hz sender
			var sender_now: float = local + offset - lat
			c.on_packet(sender_now, local)
			b.push(sender_now, Vector2(speed * sender_now, 0.0))
		var p: float = c.advance(dt, local)
		if not b.has_data or not c.started:
			continue
		var pos: Vector2 = b.sample(p)
		if last != Vector2.INF and i > 240:
			# Expected per-frame movement for constant velocity.
			var step: float = pos.x - last.x
			max_dev = maxf(max_dev, absf(step - speed * dt))
			samples += 1
		last = pos
	_ok(samples > 500, "collected enough frames (%d)" % samples)
	# Allow the clock's <=10% warp; the point is that there is no stop-and-go.
	_ok(max_dev < speed * dt * 0.15,
		"per-frame step stays near constant (max deviation %.4f px vs %.4f px/frame)"
			% [max_dev, speed * dt])


func _test_end_to_end_with_jitter_and_loss() -> void:
	print("\n[end-to-end: 20ms jitter + 10% packet loss]")
	seed(12345)
	var c := NetClock.new()
	c.delay = 0.085
	var b := NetInterp.new()
	var speed: float = 200.0
	var local: float = 0.0
	var offset: float = 7.0
	var base_lat: float = 0.030
	var dt: float = 1.0 / 60.0
	var tick: int = 0
	var pending: Array = []  # [arrive_local, sender_ts]
	var last: Vector2 = Vector2.INF
	var max_step: float = 0.0
	var frozen: int = 0
	var samples: int = 0
	for i in 2400:
		local += dt
		tick += 1
		if tick % 3 == 0:
			var sender_now: float = local + offset
			if randf() > 0.10:  # 10% loss
				pending.append([local + base_lat + randf() * 0.020, sender_now])
		var still: Array = []
		for pk in pending:
			if local >= float(pk[0]):
				c.on_packet(float(pk[1]), local)
				b.push(float(pk[1]), Vector2(speed * float(pk[1]), 0.0))
			else:
				still.append(pk)
		pending = still
		var p: float = c.advance(dt, local)
		if not b.has_data or not c.started:
			continue
		var pos: Vector2 = b.sample(p)
		if last != Vector2.INF and i > 600:
			var step: float = pos.x - last.x
			max_step = maxf(max_step, step)
			if step < 0.05 * speed * dt:
				frozen += 1
			samples += 1
		last = pos
	_ok(samples > 1000, "collected enough frames (%d)" % samples)
	_ok(max_step < speed * dt * 3.0,
		"no catch-up sprint (max step %.3f px vs %.3f px/frame nominal)" % [max_step, speed * dt])
	var frozen_pct: float = 100.0 * float(frozen) / float(samples)
	_ok(frozen_pct < 2.0, "almost never frozen (%.2f%% of frames)" % frozen_pct)


## Reference measurement of the OLD scheme (move_toward at 600 px/s against a 20 Hz
## feed) under identical conditions, so the improvement is measured, not asserted.
func _test_old_scheme_baseline() -> void:
	print("\n[baseline: old move_toward(600) scheme, same jitter + loss]")
	seed(12345)
	var speed: float = 200.0
	var remote_speed: float = 600.0
	var local: float = 0.0
	var base_lat: float = 0.030
	var dt: float = 1.0 / 60.0
	var tick: int = 0
	var pending: Array = []
	var target := Vector2.ZERO
	var pos := Vector2.ZERO
	var have_target: bool = false
	var last: Vector2 = Vector2.INF
	var max_step: float = 0.0
	var frozen: int = 0
	var samples: int = 0
	for i in 2400:
		local += dt
		tick += 1
		if tick % 3 == 0:
			if randf() > 0.10:
				pending.append([local + base_lat + randf() * 0.020, speed * local])
		var still: Array = []
		for pk in pending:
			if local >= float(pk[0]):
				target = Vector2(float(pk[1]), 0.0)
				have_target = true
			else:
				still.append(pk)
		pending = still
		if not have_target:
			continue
		pos = pos.move_toward(target, remote_speed * dt)
		if last != Vector2.INF and i > 600:
			var step: float = pos.x - last.x
			max_step = maxf(max_step, step)
			if step < 0.05 * speed * dt:
				frozen += 1
			samples += 1
		last = pos
	var frozen_pct: float = 100.0 * float(frozen) / float(samples)
	print("  BASELINE frozen %.2f%% of frames, max step %.3f px (nominal %.3f)"
		% [frozen_pct, max_step, speed * dt])
	_ok(frozen_pct > 20.0,
		"old scheme really does stall a large fraction of frames (%.2f%%)" % frozen_pct)
