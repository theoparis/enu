import std / os
import std / [macros, sugar, sets, strutils, times, monotimes, sequtils, importutils, tables,
              options, math, re]
import pkg / [print, model_citizen, godot]
import pkg / compiler / vm except get_int
import pkg / compiler / ast except new_node
import pkg / compiler / [vmdef, lineinfos, astalgo,  renderer, msgs]
import godotapi / [spatial, ray_cast, voxel_terrain]
import core, models / [types, states, bots, builds, units, colors],
             libs / [interpreters, eval],
             nodes / [helpers, build_node]

type ScriptController* = ref object
  interpreter: Interpreter
  module_names: HashSet[string]
  active_unit: Unit
  unit_map: Table[PNode, Unit]
  node_map: Table[Unit, PNode]
  retry_failures*: bool
  failed: seq[tuple[unit: Unit, e: ref VMQuit]]

include script_controllers/bindings

const
  advance_step* = 0.5.seconds
  error_code = some(99)
  script_timeout = 12.0.seconds

let state = GameState.active
let retry = (ref VMQuit)(msg: "magic_retry")

proc map_unit(self: ScriptController, unit: Unit, pnode: PNode) =
  self.unit_map[pnode] = unit
  self.node_map[unit] = pnode

proc unmap_unit(self: ScriptController, unit: Unit) =
  if unit in self.node_map:
    self.unit_map.del self.node_map[unit]
    self.node_map.del unit

proc get_unit(self: ScriptController, a: VmArgs, pos: int): Unit =
  let pnode = a.get_node(pos)
  if pnode in self.unit_map:
    result = self.unit_map[pnode]
    result.script_ctx.dependents.incl self.active_unit.script_ctx.module_name
  else:
    raise retry

proc get_bot(self: ScriptController, a: VmArgs, pos: int): Bot =
  let unit = self.get_unit(a, pos)
  assert not unit.is_nil and unit of Bot
  Bot(unit)

proc get_build(self: ScriptController, a: VmArgs, pos: int): Build =
  let unit = self.get_unit(a, pos)
  assert not unit.is_nil and unit of Build
  Build(unit)

proc to_node(self: ScriptController, unit: Unit): PNode =
  self.node_map[unit]

# Common bindings

proc register_active(self: ScriptController, pnode: PNode) =
  assert not self.active_unit.is_nil
  self.map_unit(self.active_unit, pnode)

proc new_instance(self: ScriptController, src: Unit, dest: PNode) =
  let id = src.id & "_" & self.active_unit.id & "_instance_" & $(self.active_unit.units.len + 1)
  var clone = src.clone(self.active_unit, id)
  assert not clone.is_nil
  clone.script_ctx = ScriptCtx(timer: MonoTime.high, interpreter: self.interpreter,
                               module_name: src.id, timeout_at: MonoTime.high)
  self.map_unit(clone, dest)
  self.active_unit.units.add(clone)
  clone.reset

proc exec_instance(self: ScriptController, unit: Unit) =
  let active = self.active_unit
  let ctx = unit.script_ctx
  self.active_unit = unit
  defer:
    self.active_unit = active
  ctx.timeout_at = get_mono_time() + script_timeout
  ctx.running = ctx.call_proc("run_script", self.node_map[unit], true).paused

proc active_unit(self: ScriptController): Unit = self.active_unit

proc begin_turn(self: ScriptController, unit: Unit, direction: Vector3, degrees: float, move_mode: int): string =
  assert not degrees.is_nan
  var degrees = degrees
  var direction = direction
  let ctx = self.active_unit.script_ctx
  if degrees < 0:
    degrees = degrees * -1
    direction = direction * -1
  ctx.callback = unit.on_begin_turn(direction, degrees, move_mode)
  if not ctx.callback.is_nil:
    ctx.pause()

proc begin_move(self: ScriptController, unit: Unit, direction: Vector3, steps: float, move_mode: int) =
  var steps = steps
  var direction = direction
  let ctx = self.active_unit.script_ctx
  if steps < 0:
    steps = steps * -1
    direction = direction * -1
  ctx.callback = unit.on_begin_move(direction, steps, move_mode)
  if not ctx.callback.is_nil:
    ctx.pause()

proc sleep_impl(ctx: ScriptCtx, seconds: float) =
  var duration = 0.0
  ctx.callback = proc(delta: float): bool =
    duration += delta
    if seconds > 0:
      return duration < seconds
    else:
      return duration <= 0.5 and ctx.timer > get_mono_time()
  ctx.pause()

proc hit(unit_a: Unit, unit_b: Unit): Vector3 =
  for collision in unit_a.collisions:
    if collision.model == unit_b:
      return collision.normal.snapped(vec3(1, 1, 1))

proc echo_console(msg: string) =
  state.console.log += msg & "\n"
  state.console.visible.value = true

proc action_running(self: Unit): bool =
  self.script_ctx.action_running

proc `action_running=`(self: Unit, value: bool) =
  if value:
    self.script_ctx.timer = get_mono_time() + advance_step
  else:
    self.script_ctx.timer = MonoTime.high
  self.script_ctx.action_running = value

proc id(self: Unit): string = self.id

proc global(self: Unit): bool =
  Global in self.flags

proc `global=`(self: Unit, global: bool) =
  if global:
    self.flags += Global
  else:
    self.flags -= Global

proc local_position(self: Unit): Vector3 =
  self.transform.origin

proc position(self: Unit): Vector3 =
  if Global in self.flags:
    self.transform.origin
  else:
    self.parent.node.to_global(self.transform.origin)

proc start_position(self: Unit): Vector3 =
  if Global in self.flags:
    self.start_transform.origin
  else:
    self.parent.node.to_global(self.start_transform.origin)

proc `position=`(self: Unit, position: Vector3) =
  if Global in self.flags:
    self.transform.origin = position
  else:
    self.transform.origin = self.parent.node.to_local(position)

proc speed(self: Unit): float =
  self.speed

proc `speed=`(self: Unit, speed: float) =
  self.speed = speed

proc scale(self: Unit): float =
  self.scale.value

proc `scale=`(self: Unit, scale: float) =
  self.scale.value = scale

proc energy(self: Unit): float =
  self.energy.value

proc `energy=`(self: Unit, energy: float) =
  self.energy.value = energy

proc velocity(self: Unit): Vector3 =
  self.velocity.value

proc `velocity=`(self: Unit, velocity: Vector3) =
  self.velocity.value = velocity

proc color(self: Unit): Colors =
  action_index self.color

proc `color=`(self: Unit, color: Colors) =
  self.color = action_colors[color]

proc rotation(self: Unit): float =
  # TODO: fix this
  proc nm(f: float): float =
    if f.is_equal_approx(0):
      return 0
    elif f < 0:
      return f + (2 * PI)
    else:
      return f

  proc nm(v: Vector3): Vector3 =
    vec3(v.x.nm, v.y.nm, v.z.nm)

  let e = self.transform.basis.orthonormalized.get_euler

  let n = e.nm
  let v = vec3(nm(n.x).rad_to_deg, nm(n.y).rad_to_deg, nm(n.z).rad_to_deg)
  let m = if v.z > 0: 1.0 else: -1.0
  result = (v.x - v.y) * m

proc `rotation=`(self: Unit, degrees: float) =
  var t = Transform.init
  if self of Player:
    Player(self).rotation.touch degrees
    t.origin = self.transform.origin
  else:
    var t = Transform.init
    var s = self.scale.value
    t = t.rotated(UP, deg_to_rad(degrees)).scaled(vec3(s, s, s))
    t.origin = self.transform.origin
  self.transform.value = t

proc seen(self: ScriptController, target: Unit, distance: float): bool =
  if target == state.player and Flying in state.input_flags:
    return false
  let unit = self.active_unit
  if unit of Build:
    let ray = Build(unit).sight_ray
    let node = BuildNode(Build(unit).node)
    let unit_position = unit.node.to_local(unit.position)
    let target_position = unit.node.to_local(target.position)
    let angle = target_position - ray.transform.origin
    if angle.length <= distance and angle.normalized.z <= -0.3:
      ray.cast_to = angle
      var old_layer = node.collision_layer
      node.collision_layer = 0
      ray.force_raycast_update
      if ray.is_colliding:
        let collider = ray.get_collider as Spatial
        if collider == target.node:
          result = true
      node.collision_layer = old_layer

proc wake(self: Unit) =
  self.script_ctx.timer = get_mono_time()

proc yield_script(self: ScriptController, unit: Unit) =
  let ctx = unit.script_ctx
  ctx.callback = ctx.saved_callback
  ctx.saved_callback = nil
  ctx.pause()

proc exit(ctx: ScriptCtx, exit_code: int) =
  ctx.exit_code = some(exit_code)
  ctx.pause()
  ctx.running = false

proc frame_count(): int = state.frame_count

# Bot bindings

proc play(self: Bot, animation_name: string) =
  self.animation.value = animation_name

# Build bindings

proc drawing(self: Build): bool =
  self.drawing

proc `drawing=`(self: Build, drawing: bool) =
  self.drawing = drawing

proc initial_position(self: Build): Vector3 =
  self.initial_position

proc save(self: Build, name: string) =
  self.save_points[name] = (self.transform.value, self.color, self.drawing)

proc restore(self: Build, name: string) =
  (self.transform.value, self.color, self.drawing) = self.save_points[name]

proc reset(self: Build, clear: bool) =
  if clear:
    self.reset()
  else:
    self.reset_state()

# Player binding

proc playing(self: Unit): bool =
  state.playing

proc `playing=`*(self:Unit, value: bool) =
  state.playing = value

# End of bindings

proc script_error(self: ScriptController, unit: Unit, e: ref VMQuit) =
  if e == retry:
    unit.code.touch unit.code.value
  else:
    state.logger("err", e.msg)
    unit.ensure_visible
    state.console.show_errors.value = true

proc advance_unit(self: ScriptController, unit: Unit, delta: float) =
  let ctx = unit.script_ctx
  if ctx and ctx.running:
    let now = get_mono_time()

    if unit of Build:
      let unit = Build(unit)
      unit.voxels_remaining_this_frame += unit.voxels_per_frame
    var resume_script = true
    try:
      assert self.active_unit.is_nil
      while resume_script and not state.paused:
        resume_script = false

        if ctx.callback == nil or (not ctx.callback(delta)):
          ctx.timer = MonoTime.high
          ctx.action_running = false
          self.active_unit = unit
          ctx.timeout_at = get_mono_time() + script_timeout
          ctx.running = ctx.resume()
          if not ctx.running and not unit.clone_of:
            unit.collect_garbage
            unit.ensure_visible
          if unit of Build:
            let unit = Build(unit)
            if unit.voxels_per_frame > 0 and ctx.running and unit.voxels_remaining_this_frame >= 1:
              resume_script = true

        elif now >= ctx.timer:
          ctx.timer = now + advance_step
          ctx.saved_callback = ctx.callback
          ctx.callback = nil
          self.active_unit = unit
          ctx.timeout_at = get_mono_time() + script_timeout
          discard ctx.resume()
    except VMQuit as e:
      self.interpreter.reset_module(unit.script_ctx.module_name)
      self.script_error(unit, e)
    finally:
      self.active_unit = nil

proc load_script(self: ScriptController, unit: Unit, timeout = script_timeout) =
  let ctx = unit.script_ctx
  try:
    self.active_unit = unit

    if not state.paused:
      let module_name = ctx.script.split_file.name
      var others = self.module_names
      self.module_names.incl module_name
      others.excl module_name
      let imports = if others.card > 0:
        "import " & others.to_seq.join(", ")
      else:
        ""
      let code = unit.code_template(imports)
      ctx.timeout_at = get_mono_time() + timeout
      ctx.load(state.config.script_dir, ctx.script, code, state.config.lib_dir)

    if not state.paused:
      ctx.timeout_at = get_mono_time() + timeout
      ctx.running = ctx.run()
      if not ctx.running and not unit.clone_of:
        unit.collect_garbage
        unit.ensure_visible

  except VMQuit as e:
    ctx.running = false
    self.interpreter.reset_module(unit.script_ctx.module_name)
    if self.retry_failures:
      self.failed.add (unit, e)
    else:
      self.script_error(unit, e)
  finally:
    self.active_unit = nil

proc retry_failed_scripts*(self: ScriptController) =
  var prev_failed: self.failed.type = @[]
  while prev_failed.len != self.failed.len:
    prev_failed = self.failed
    self.failed = @[]
    for f in prev_failed:
      echo "retrying: ", f.unit.script_ctx.script
      self.load_script(f.unit)

  for f in prev_failed:
    self.script_error(f.unit, f.e)
  self.failed = @[]

proc change_code(self: ScriptController, unit: Unit, code: string) =
  if unit.script_ctx and unit.script_ctx.running and not unit.clone_of:
    unit.collect_garbage

  var all_edits = unit.shared.edits
  for id, edits in unit.shared.edits:
    if id != unit.id and edits.len == 0:
      all_edits.del id
  unit.shared.edits = all_edits

  unit.reset()
  state.console.show_errors.value = false
  state.console.visible.value = false
  var dependents: HashSet[string]
  if not state.reloading and code.strip == "" and file_exists(unit.script_file):
    remove_file unit.script_file
    self.module_names.excl unit.script_ctx.module_name
  elif code.strip != "":
    write_file(unit.script_file, code)
    if unit.script_ctx.is_nil:
      unit.script_ctx = ScriptCtx(timer: MonoTime.high, interpreter: self.interpreter, timeout_at: MonoTime.high)
    dependents = unit.script_ctx.dependents
    unit.script_ctx.dependents.init
    unit.script_ctx.script = unit.script_file
    echo "loading ", unit.id
    self.load_script(unit)

  if unit.script_ctx and dependents.card > 0:
    let first = not state.reloading
    if first:
      state.reloading = true
      self.retry_failures = true

    walk_tree state.units.value, proc(other: Unit) =
      if other.script_ctx:
        if other != unit and other.script_ctx.module_name in dependents and other.code.value != "":
          other.code.touch other.code.value

    if first:
      self.retry_failed_scripts()
      self.retry_failures = false
      state.reloading = false

proc watch_code(self: ScriptController, unit: Unit) =
  unit.code.changes:
    if added or touched:
      self.change_code(unit, change.item)

proc watch_units(self: ScriptController, units: ZenSeq[Unit]) =
  units.changes:
    let unit = change.item
    if added:
      unit.frame_delta.changes:
        if touched:
          self.advance_unit(unit, change.item)
      self.watch_code unit
      self.watch_units unit.units

      if not unit.clone_of and file_exists(unit.script_file):
        unit.code.value = read_file(unit.script_file)
    if removed:
      self.unmap_unit(unit)
      if not unit.clone_of and unit.script_ctx:
        self.module_names.excl unit.script_ctx.module_name

proc load_player*(self: ScriptController) =
  let unit = state.player
  self.active_unit = unit
  defer:
    self.active_unit = nil

  unit.script_ctx = ScriptCtx(timer: MonoTime.high, interpreter: self.interpreter, timeout_at: MonoTime.high)
  unit.script_ctx.script = state.config.lib_dir & "/enu/players.nim"
  self.load_script(unit, timeout = 30.seconds)

proc extract_file_info(msg: string): tuple[name: string, info: TLineInfo] =
  if msg =~ re"unhandled exception: (.*)\((\d+), (\d+)\)":
    result = (matches[0], TLineInfo(line: matches[1].parse_int.uint16, col: matches[2].parse_int.int16))

proc init*(T: type ScriptController): ScriptController =
  private_access ScriptCtx

  let interpreter = Interpreter.init(state.config.script_dir, state.config.lib_dir)
  interpreter.config.spell_suggest_max = 0
  let controller = ScriptController(interpreter: interpreter)

  interpreter.register_error_hook proc(config, info, msg, severity: auto) {.gcsafe.} =
    var info = info
    var msg = msg
    let ctx = controller.active_unit.script_ctx
    if severity == Severity.Error and config.error_counter >= config.error_max:
      var file_name = if info.file_index.int >= 0:
        config.m.file_infos[info.file_index.int].full_path.string
      else:
        "???"

      if file_name.get_file_info != ctx.file_name.get_file_info:
        (file_name, info) = extract_file_info msg
        msg = msg.replace(re"unhandled exception:.*\) Error\: ", "")
      else:
        msg = msg.replace(re"(?ms);.*", "")
      var loc = &"{file_name}({int info.line},{int info.col})"
      echo "error: ", msg, " from ", ctx.file_name
      ctx.errors.add (msg, info, loc)
      ctx.exit_code = error_code
      raise (ref VMQuit)(info: info, msg: msg, location: loc)

  interpreter.register_enter_hook proc(c, pc, tos, instr: auto) =
    assert controller
    assert controller.active_unit
    assert controller.active_unit.script_ctx

    let ctx = controller.active_unit.script_ctx
    let info = c.debug[pc]
    let now = get_mono_time()
    if ctx.timeout_at < now:
      raise (ref VMQuit)(info: info, msg: &"Timeout. Script {ctx.script} executed for too long without yielding: {now - ctx.timeout_at}")

    if ctx.previous_line != info:
      let config = interpreter.config
      if info.file_index.int >= 0 and info.file_index.int < config.m.file_infos.len:
        let file_name = config.m.file_infos[info.file_index.int].full_path.string
        if file_name == ctx.file_name:
          if ctx.line_changed != nil:
            ctx.line_changed(info, ctx.previous_line)
          (ctx.previous_line, ctx.current_line) = (ctx.current_line, info)

    if ctx.pause_requested:
      ctx.pause_requested = false
      ctx.ctx = c
      ctx.pc = pc
      ctx.tos = tos
      raise new_exception(VMPause, "vm paused")

  result = controller
  result.watch_units state.units

  result.bind_procs "base_api", begin_turn, begin_move, register_active, echo_console, new_instance,
                    exec_instance, action_running, `action_running=`, yield_script, hit,
                    sleep_impl, exit, global, `global=`, position, `position=`, local_position, rotation, `rotation=`,
                    energy, `energy=`, speed, `speed=`, scale, `scale=`, velocity, `velocity=`, active_unit, id,
                    color, `color=`, seen, start_position, wake, frame_count

  result.bind_procs "bots", play

  result.bind_procs "builds", drawing, `drawing=`, initial_position,
                    save, restore, reset

  result.bind_procs "players", playing, `playing=`

when is_main_module:
  state.config.lib_dir = current_source_path().parent_dir / ".." / ".." / "vmlib"
  var b = Bot.init
  let c = ScriptController.init
