# No scale-to-zero (zeroscale rejected)

Status: accepted (2026-09-25)

Apps are not idled down to save memory. onedr0p's `zeroscale` component looked like an
idle-down mechanism but is an HPA held at one replica by an always-up NFS probe; it
scales to zero only when storage disappears. Real wake-on-request needs an HTTP
interceptor (KEDA's HTTP add-on), and the *arr stack calls itself on schedules no
request-driven trigger sees. The safely-idle set was only ~1.4 GiB.

If memory is tight again, the lever is model sizing and explicit requests/limits, not
autoscaling. Revisit only with a second node, or if KEDA is wanted for its own sake.

See `REFACTOR_PLANS.md` → "zeroscale: evaluated and rejected (2026-09-25)".
