import std / [math, sugar]
import pkg / godot except print
import pkg / model_citizen
import godotapi / [kinematic_body, spatial, input, input_event,
                   input_event_mouse_motion, input_event_joypad_motion,
                   ray_cast, scene_tree, input_event_pan_gesture, viewport, camera, global_constants,
                   collision_shape, kinematic_collision]
import core, globals, game, nodes / helpers
import aim_target, models

proc handle_collisions(self: Player, collisions: seq[KinematicCollision]) {.inline.} =
  var colliders: HashSet[Model]
  for collision in collisions:
    let collider = collision.collider
    let normal = collision.normal
    let model = collider.model
    if not model.is_nil:
      if model notin self.colliders and model notin colliders:
        model.on_collision(self, normal)
      colliders.incl model
  for model in self.colliders - colliders:
    model.off_collision(self)
  self.colliders = colliders


let
  state = GameState.active
  config = state.config
  angle_x_min = -PI / 2.25
  angle_x_max = PI / 2.25
  max_speed = 50.0
  move_speed = 500.0
  jump_impulse = 10.0
  fly_toggle = 0.3.seconds
  float_time = 0.3.seconds
  run_toggle = 0.3.seconds
  sensitivity_gamepad = vec2(2.5, 2.5)
  sensitivity_mouse = vec2(0.005, -0.005)
  nil_time = none(DateTime)
  input_command_timeout = 0.25

# NOTE: Most of this needs to be moved into player model
gdobj PlayerNode of KinematicBody:
  var
    running, always_run, skip_release, skip_next_mouse_move, jump_down: bool
    aim_ray, world_ray, down_ray: RayCast
    jump_time, run_time: Option[DateTime]

    position_start: Vector3
    input_relative = vec2()
    camera_rig: Spatial
    camera: Camera
    aim_target: AimTarget
    velocity = vec3()
    pan_delta = 0.0
    index = 0
    collision_shape: CollisionShape
    command_timer = 0.0
    unit*: Player
    velocity_zid: ZID
    boosted = false

  proc flying(): bool =
    Flying in state.input_flags

  proc flying(value: bool) =
    if value:
      state.input_flags += Flying
    else:
      state.input_flags -= Flying

  proc get_look_direction(): Vector2 =
    vec2(get_action_strength("look_right") - get_action_strength("look_left"),
         get_action_strength("look_up") - get_action_strength("look_down"))

  proc update_rotation(offset: Vector2) =
    var r = self.camera_rig.rotation
    r.y -= offset.x
    r.x += offset.y
    r.x = clamp(r.x, angle_x_min, angle_x_max)
    r.z = 0
    self.camera_rig.rotation = r

  proc get_input_direction(): Vector3 =
    vec3(get_action_strength("move_right") - get_action_strength("move_left"),
         get_action_strength("jump") - get_action_strength("crouch"),
         get_action_strength("move_back") - get_action_strength("move_front"))

  proc calculate_velocity(velocity_current: Vector3, move_direction: Vector3,
                          delta: float, flying, running: bool): Vector3 =
    let speed = if running: move_speed * 2 else: move_speed
    result = move_direction * delta * speed
    if result.length() > max_speed:
      result = result.normalized() * max_speed

    if not flying:
      let float_time = if running:
        float_time + float_time
      else:
        float_time
      let floating = self.jump_down and self.jump_time and self.jump_time.get + float_time > now()
      let gravity = if floating:
        state.gravity / 4
      else:
        state.gravity
      result.y = velocity_current.y + gravity * delta

  method ready*() =
    self.unit = Player.init(self)
    state.player = self.unit
    self.camera_rig = self.get_node("CameraRig") as Spatial
    self.collision_shape = self.get_node("CollisionShape") as CollisionShape
    self.camera = self.camera_rig.get_node("Camera") as Camera
    self.aim_ray  = self.camera_rig.get_node("Camera/AimRay") as RayCast
    self.world_ray = state.nodes.game.get_node("WorldRay") as RayCast
    self.down_ray = self.find_node("DownRay") as RayCast
    self.aim_target = self.camera_rig.get_node("AimTarget") as AimTarget

    self.position_start = self.camera_rig.translation
    state.nodes.player = self

    state.target_flags.changes:
      if MouseCaptured.removed:
        self.skip_next_mouse_move = true

    self.unit.transform.changes:
      if added:
        self.transform = change.item

    self.unit.rotation.changes:
      if touched:
        self.camera_rig.rotation = vec3(0, deg_to_rad change.item, 0)

    self.velocity_zid = self.unit.velocity.changes:
      if added:
        self.velocity = change.item

  proc current_raycast*: RayCast =
    if state.mouse_captured:
      self.aim_ray
    else:
      self.world_ray

  method process*(delta: float) =
    self.unit.velocity.pause self.velocity_zid:
      self.unit.velocity.value = self.velocity
    if not state.editing or state.command_mode:
      var transform = self.camera_rig.global_transform
      transform.origin = self.global_transform.origin + self.position_start

      var look_direction = self.get_look_direction()

      if self.input_relative.length() > 0:
        self.update_rotation(self.input_relative * sensitivity_mouse)
        self.input_relative = vec2()
      elif look_direction.length() > 0:
        self.update_rotation(look_direction * sensitivity_gamepad * delta)

      var r = self.camera_rig.rotation
      r.y = wrap(r.y, -PI, PI)
      self.camera_rig.rotation = r
      let ray_length = if state.tool.value == Code: 200.0 else: 100.0
      if not state.mouse_captured:
        let
          mouse_pos = self.get_viewport().
                           get_mouse_position() * float get_game().scale_factor
          cast_from = self.camera.project_ray_origin(mouse_pos)
          cast_to = self.aim_ray.translation + self.camera.project_ray_normal(mouse_pos) * ray_length
        self.world_ray.cast_to = cast_to
        self.world_ray.translation = cast_from
        self.aim_target.update(self.world_ray)
      else:
        self.aim_ray.cast_to = vec3(0, 0, -ray_length)
        self.aim_target.update(self.aim_ray)

  method physics_process*(delta: float) =
    for i in 0..(self.get_slide_count() - 1):
      let collision = self.get_slide_collision(i)
      let collider = collision.collider

    if state.command_mode and self.command_timer > 0:
      self.command_timer -= delta
      if self.command_timer <= 0:
        state.command_mode = false

    const forward_rotation = deg_to_rad(-90.0)
    let process_input = not state.editing or state.command_mode
    let
      input_direction = if process_input: self.get_input_direction()
                        else: vec3()
      basis   = self.camera_rig.global_transform.basis
      right   = basis.x * input_direction.x
      up      = UP * input_direction.y
      forward = (basis.x * input_direction.z).rotated(UP, forward_rotation)

    var move_direction = forward + right

    if move_direction.length() > 1.0:
      move_direction = move_direction.normalized()

    move_direction.y = 0
    move_direction += up

    var velocity = self.calculate_velocity(self.velocity, move_direction,
                                           delta, self.flying, self.running)

    self.velocity = self.move_and_slide(velocity, UP)

    self.unit.transform.value = self.transform

    let collisions = collect:
      for i in 0..(self.get_slide_count - 1):
        self.get_slide_collision(i)

    handle_collisions(self.unit, collisions)

    if process_input:
      if self.is_on_floor:
        self.boosted = false

      if move_direction.length > 0.5:
        self.down_ray.translation = move_direction * 0.3 + vec3(0, 1, 0)
        if self.down_ray.is_colliding():
          let length = 1.85
          let diff = length - (self.down_ray.global_transform.origin - self.down_ray.get_collision_point).y
          if diff > 0 and (self.is_on_floor() or not self.boosted):
            let boost = 16.1 * cbrt(diff)
            if boost > self.velocity.y:
              self.boosted = true
              self.velocity.y = boost

      # drop us back in the middle of the world if we fall through
      if self.translation.y < -10:
        self.translation = vec3(0, 100, 0)

  proc has_active_input(device: int): bool =
    for axis in 0..JOY_AXIS_MAX:
      if axis != JOY_ANALOG_L2 and axis != JOY_ANALOG_R2 and get_joy_axis(device, axis).abs >= 0.2:
        return true
    for button in 0..JOY_BUTTON_MAX:
      if is_joy_button_pressed(device, button):
        return true

  method unhandled_input*(event: InputEvent) =
    if event of InputEventJoypadMotion:
      let event = event as InputEventJoypadMotion
      if event.axis == JOY_ANALOG_L2 or event.axis == JOY_ANALOG_R2:
        return

    if event of InputEventMouseMotion and state.mouse_captured:
      if not self.skip_next_mouse_move:
        self.input_relative += event.as(InputEventMouseMotion).relative()
      else:
        self.skip_next_mouse_move = false
    if state.editing and not self.skip_release and (event of InputEventJoypadButton or event of InputEventJoypadMotion):
      let active_input = self.has_active_input(event.device.int)
      if state.command_mode and not active_input:
        self.command_timer = input_command_timeout
      elif state.command_mode and active_input:
        self.command_timer = 0.0
      elif active_input:
        self.command_timer = 0.0
        state.command_mode = true

    if event.is_action_pressed("jump"):
      self.jump_down = true
      let
        time = now()
        toggle = self.jump_time and time < self.jump_time.get + fly_toggle

      if toggle:
        self.jump_time = nil_time
        if state.playing:
          self.flying(false)
        else:
          self.flying(not self.flying)
        for i in [0, 1, 2]:
          self.set_collision_mask_bit(i, not self.flying)
      elif self.is_on_floor():
        self.velocity += vec3(0, jump_impulse, 0)
        self.jump_time = some time
      else:
        self.jump_time = some time
    elif event.is_action_released("jump"):
      self.jump_down = false

    if event.is_action_pressed("run"):
      let
        time = now()
        toggle = self.run_time and time < self.run_time.get + run_toggle

      if toggle:
        self.run_time = nil_time
        self.always_run = not self.always_run
      else:
        self.run_time = some time
      self.running = not self.always_run
    elif event.is_action_released("run"):
      self.running = self.always_run

    if event of InputEventPanGesture and state.tool.value == Block:
      let pan = event as InputEventPanGesture
      self.pan_delta += pan.delta.y
      if self.pan_delta > 2:
        self.pan_delta = 0
        get_game().next_action()
      elif self.pan_delta < -2:
        self.pan_delta = 0
        get_game().prev_action()

    if event.is_action_pressed("next"):
      get_game().next_action()

    if event.is_action_pressed("previous"):
      get_game().prev_action()

    let ray = self.current_raycast
    if event.is_action_pressed("fire"):
      if not state.editing:
        self.skip_release = true
      if not state.playing:
        state.input_flags += Primary
    elif event.is_action_released("fire"):
      self.skip_release = false
      state.input_flags -= Primary

    if event.is_action_pressed("remove"):
      state.input_flags += Secondary
    elif event.is_action_released("remove"):
      state.input_flags -= Secondary

proc get_player*(): PlayerNode = PlayerNode(state.nodes.player)
