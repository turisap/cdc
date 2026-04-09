* partition by entity
* use version column
* idempotent consumer with version column, setting it to redis on the receiving side with TTL (max processed version)
  and other blows and whistles (SETNX processed:{topic}:{partition}:{offset},SETNX processed:{event_id} (TTL 1–6
  hours) )