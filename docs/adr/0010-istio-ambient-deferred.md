# Istio ambient deferred

Status: deferred

No service mesh. Istio ambient would need `socketLB.hostNamespaceOnly: true` and
`cni.exclusive: false` alongside Cilium's kube-proxy replacement, and its default-deny
policies block kubelet probes. None of that pays off on one node without a concrete
need. Revisit only if workload mTLS or SPIFFE identity becomes a real requirement.

See `REFACTOR_PLANS.md` → Key decisions → Deferred.
