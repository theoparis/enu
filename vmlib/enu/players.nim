import types, base_api

let player* = PlayerType()
register_active(player)

proc playing*(self: PlayerType): bool = discard
proc `playing=`*(self: PlayerType, value: bool) = discard
