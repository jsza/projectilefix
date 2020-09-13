# projectilefix (WIP!)

Fixes for rockets and stickybombs in Team Fortress 2.

## Includes
* Rocket simulation fix (`/rocketsim`)
  * This prevents rockets from simulating each server frame
    (`CBaseEntity::PhysicsSimulate`) and instead forces them to simulate in
    `CBasePlayer::PostThink`, thus making them deterministic.
  * Includes a refire rate fix that should help with unstable internet and
    prevent a bug where players could fire too quickly.

* Rocket latency helper (`/rocketping`)
  * When a rocket is fired, spawns a rocket ahead of the player
  (`origin + (latency * velocity)`) and hides the original rocket.
    A far cry from real clientside prediction, but so far seems helpful.


Known issues:
* Rockets sometimes fail to move when they should; not sure why this could be
  happening.

* The rocket simulation fix does seem to work to make rockets entirely
  deterministic. However, without the plugin the inconsistencies can actually
  (for instance) save a bad sync.

* Let's say you have a rocket bundle with some
  rockets 1 tick away from hitting the ground and others 2 ticks away, with the
  the player standing on the ground. At tick 1, some of the rockets hit,
  applying velocity to the player. If the player doesn't move, at tick 2 they
  hit the ground while the player is still there, thus making the mistimed
  rockets affect the player as if they were perfectly timed.

* A solution might
  be to implement a built-in "forgiveness timer" that eliminates 1 tick of
  variation in a rocket bundle, or apply some kind of averaging to not let the
  modified sync be "too good".

Special thanks to the Tempus community for helping out with testing.
