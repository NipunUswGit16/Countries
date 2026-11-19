# Kubernetes Reviewer Rules

Apply only to Kubernetes manifest files (`.yaml`/`.yml` in `k8s/`, `deploy/`, `manifests/`, `config/`, or files containing `kind:` and `apiVersion:`). Report only demonstrably real production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## RESOURCE_LIMITS

- Container missing `resources.limits.cpu` or `resources.limits.memory` — container can consume unbounded node resources, causing noisy-neighbour starvation and OOM kills on the node
- Container missing `resources.requests.cpu` or `resources.requests.memory` — scheduler cannot make placement decisions; pod may be scheduled onto an already-saturated node
- `resources.limits.cpu` set very low (< 10m) without justification — CPU throttling will severely degrade performance under any load
- Memory limit equal to memory request — leaves no headroom for JVM/GC overhead or temporary spikes

## PROBE_MISUSE

- `livenessProbe` missing on a long-running container — kubelet cannot detect a deadlocked process and will not restart it
- `readinessProbe` missing — pod receives traffic before it is ready to serve, causing request failures on startup and rolling deploys
- `livenessProbe` that hits a health endpoint which also checks downstream dependencies (DB, cache) — a dependency failure restarts healthy pods unnecessarily; liveness should only check the process itself
- `livenessProbe.initialDelaySeconds` set too low for a slow-starting application — pod killed and restarted in a loop before it finishes initialising
- Same endpoint used for both liveness and readiness — defeats the purpose of separating the two concerns

## RBAC_OVERREACH

- `verbs: ["*"]` without documented justification — grants all operations on the resource
- `resources: ["*"]` — grants access to every resource type in the API group
- `ClusterRole` or `ClusterRoleBinding` used where a namespaced `Role`/`RoleBinding` would suffice — blast radius is the entire cluster
- `serviceAccountName` set to `default` in a pod spec — the default service account should have no permissions; using it bypasses RBAC intent

## IMAGE_TAGS

- Image tagged as `latest` — tag is mutable; rolling restarts may pull a different image than what was deployed
- Image tag present but no digest (`sha256:...`) in a production manifest — only digest pinning guarantees exact reproducibility
- Image pulled from an uncontrolled public registry without a mirroring policy — supply chain risk

## SECRET_EXPOSURE

- Secret value in plaintext in a `ConfigMap` — ConfigMaps are not encrypted at rest by default
- Secret value in an `env.value` field directly in the pod spec — visible in `kubectl get pod -o yaml` to anyone with pod read access
- Secret value in a container `args` or `command` field — visible in pod spec and process list
- `secretKeyRef` pointing to a key that does not exist in the referenced Secret — pod fails to start with an opaque error

## MISSING_PDB

- `Deployment`, `StatefulSet`, or `DaemonSet` with `replicas > 1` and no `PodDisruptionBudget` — voluntary disruptions (node drain, cluster upgrade) can take down all replicas simultaneously

## SECURITY_CONTEXT

- Container running as root: `securityContext.runAsUser: 0` or `runAsNonRoot` absent/false — process runs as UID 0; container escape has full node access
- `allowPrivilegeEscalation: false` not set — child processes can gain more privileges than the container process
- `readOnlyRootFilesystem: true` not set — container can write to its own filesystem; harder to detect compromise
- `capabilities.drop: ["ALL"]` not set — container retains Linux capabilities it does not need
- `hostNetwork: true`, `hostPID: true`, or `hostIPC: true` without justification — shares host namespaces; major privilege escalation vector
- `privileged: true` without justification — equivalent to running as root on the node

## DEPLOYMENT_SAFETY

- `RollingUpdate` strategy with `maxUnavailable: 100%` or `maxSurge: 0` simultaneously — can cause full downtime during a rollout
- `Deployment` with a single replica and no PDB — any voluntary disruption causes downtime
- `terminationGracePeriodSeconds` set to 0 — SIGKILL sent immediately; in-flight requests are dropped
- `preStop` hook missing on a container that handles long-lived connections — requests are dropped before the pod finishes draining
