# MQTT broker (Mosquitto)

Mosquitto is the cluster's MQTT broker, deployed as `default/mosquitto` from the
`home-operations/mosquitto` chart (app-template). It is internal-only — a
ClusterIP service on port 1883, no route, no ingress — with
`allow_anonymous true`, so anything inside the cluster can publish and subscribe.

Consumers:

- **zigbee2mqtt** — Zigbee device state plus Home Assistant MQTT discovery
  (`homeassistant/.../config`) and the `zigbee2mqtt/bridge/*` topics.
- **zwave-js-ui** — Z-Wave device state and its own discovery payloads.
- **Home Assistant** — the MQTT integration, subscribed to `homeassistant/#`.

Config lives in `infra/k8s/kyz/apps/default/mosquitto/app/`:

- `mosquitto.conf` — generated into the `mosquitto-config` ConfigMap and mounted
  at `/mosquitto/config/mosquitto.conf` (single file, via `subPath`).
- `helmrelease.yaml` — image, probes, security context, persistence.

## Retained messages are load-bearing

Home Assistant's MQTT entities are not created from anything in git. They are
created from **retained** discovery messages on this broker, and their
availability comes from retained availability topics (for zigbee2mqtt,
`zigbee2mqtt/bridge/state`). Retained messages live in the broker only.

`mosquitto.conf` therefore sets:

```
persistence true
persistence_location /mosquitto/data/
autosave_interval 60
```

with a 1Gi `openebs-hostpath` PVC mounted at `/mosquitto/data`.

Without persistence the store is memory-only: any broker restart — an image bump,
a node reboot, a pod eviction — wipes every retained message. The observable
failure is that **every MQTT-backed entity in Home Assistant goes `unavailable`
and stays that way**, even though the broker and its publishers are healthy.

Why it does not self-heal: most publishers only announce discovery and
availability **at their own startup**. zigbee2mqtt in particular has no periodic
republish, so a broker restart blinds Home Assistant until zigbee2mqtt is
restarted too. zwave-js-ui republishes on reconnect, which makes it look like a
zigbee2mqtt problem when it is not. Live state messages keep flowing the whole
time; only the discovery and availability payloads are missing, so the entities
never become available again.

## Procedure after a broker restart

1. Check whether discovery came back:
   `kubectl -n default logs deploy/home-assistant -c app --since=1h | grep -i mqtt`
   and look at the MQTT-backed entities (they will read `unavailable`).
2. Restart the publishers so they republish retained topics, zigbee2mqtt first,
   then reload the HA MQTT integration if anything is still stale.
3. Do **not** restart Home Assistant to fix this. HA is subscribed; it picks up
   republished discovery live.

## Detecting an empty retained store

Persistence makes the store survive restarts, but nothing about the broker's
health reveals that it is _empty_ — and neither does Home Assistant, because HA
keeps serving the entities it already discovered from memory until it restarts.
The store can therefore be empty for weeks with the house apparently working, and
the failure only surfaces at the next HA restart. That is what happened on
2026-10-02: the store was wiped by a broker rollout, HA carried the entities from
memory for 26 days, and the next restart took every zigbee2mqtt entity
`unavailable` at once with nothing alerted in between.

**Nothing watches the retained store directly today.** `o11y/mqtt-probe` — a
CronJob that subscribed to `homeassistant/#` and `zigbee2mqtt/bridge/state` every
10 minutes and exported `mqtt_probe_*` textfile metrics into node-exporter — was
deleted on 2026-10-31. It had been reading `mosquitto_sub -W`'s designed timeout
exit (27) as a failed subscribe, so it reported the broker unreachable while
receiving retained payloads from it: a critical `MqttBrokerUnreachable` paged the
phone for thirteen hours, and `MqttRetainedDiscoveryMissing`, which was gated on
`reachable == 1`, could never fire at all. It was removed rather than fixed —
hand-rolled textfile plumbing over a hostPath is not worth a rewrite to detect
something it never actually detected (`REFACTOR_PLANS.md`).

The trade is stated plainly: **an empty retained store is no longer detected
while Home Assistant is still working.** What remains is the consumer-side
backstop, `Zigbee2MQTTBridgeUnavailable` in
`default/home-assistant/app/prometheusrule.yaml`. It reads HA's own
`homeassistant_entity_available` for `binary_sensor.zigbee2mqtt_bridge_connection_state`,
so it fires only _after_ HA has lost the entities — after the restart. It
confirms the outage; it cannot warn you before it.

So the procedure above is the detection method again: after any broker rollout,
grep the HA log and look at the MQTT-backed entities rather than waiting for a
page. If someone later finds a broker-side signal worth exporting (mosquitto's
own `$SYS/broker/messages/retained/count` would be the obvious candidate, and it
needs no probe at all), that is the shape to build — not another subscriber with
an exit code.

## Operational note

Restarting Home Assistant and the broker within the same minute turns a routine
broker restart into a visible outage: HA comes up against a broker that is still
down and then finds an empty retained store. Space out merges that roll both
`default/mosquitto` and `default/home-assistant`.
