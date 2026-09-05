---
description: Check local tooling, resources and checkout health.
---

Run `scripts/doctor.sh`. Explain actual blocking findings; do not treat a busy
job slot as a broken environment or kill another agent's work. Use
`scripts/ci.sh status` for the lightweight resource view. The runner reports
containment or display failures before starting heavy work.
