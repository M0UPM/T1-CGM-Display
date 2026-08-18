# Disclaimer

This is a hobby project. It is not a medical device, it is not validated for
clinical use, and it is not certified by any regulator.

**It is not an alarm system.** It does not alert on glucose values and must
never be relied on to. The CGM manufacturer's own app is the alarm — it is the
regulated path, it is what wakes you at night, and nothing here replaces it.
The only alert this project sends is when the *data feed* stops, which is a
plumbing problem, not a clinical one.

**It does not calculate insulin doses.** Nightscout's bolus wizard is disabled
in the supplied configuration and should stay that way.

**Treat what it shows as a record, not an authority.** Data arrives late,
sources go down, and entries only exist if someone logged them. The display is
built to be honest about this — it greys out when stale and says "none logged"
rather than "0" — but the safe answer to "has a dose been given?" is the pen
and the app, never a screen on a wall.

Use at your own risk. Discuss any change to diabetes management with the
relevant care team.
