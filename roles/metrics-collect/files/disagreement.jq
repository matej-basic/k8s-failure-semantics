# roles/metrics-collect/files/disagreement.jq
#
# REVIEW.md M2 — "Make the observer set explicit".
#
# Input : one assembled snapshot object (roles/metrics-collect/tasks/snapshot.yml).
# Output: the SAME object with two derived members appended:
#
#   .observer_answers  — the flat observer roster, one entry per observer, each
#                        carrying its answer to every question in a single
#                        normalised shape.
#   .disagreement      — the pairwise disagreement matrix, one block per
#                        question, plus per-question and per-snapshot summaries.
#
# Nothing already in the snapshot is modified or removed. In particular
# .observers[] keeps the exact shape check-invariants.sh's I5 reads; this file
# only ADDS to the object.
#
# ── The three states an answer can be in ──────────────────────────────────────
# The whole point of the exercise is that a failed read must never look like
# agreement, so every answer carries an explicit state:
#
#   "answered"        the observer was asked, responded, and its response was
#                     decoded into a canonical answer string.
#   "unreadable"      the observer was asked and no usable answer came back:
#                     timeout, refused connection, auth failure, malformed
#                     body, undecodable payload. This is DATA — during a
#                     partition it is the expected state — and it is never
#                     merged with any other observer's answer.
#   "not_applicable"  this observer structurally cannot answer this question,
#                     in any cluster state. A kubelet has no service view; a
#                     CRI has no node-condition view; a node-local observer
#                     cannot say WHERE a pod is when the pod is not local, only
#                     that it is not here.
#
# Two observers are COMPARABLE for a question only when both are "answered".
# Every other pair is emitted with comparable:false and a reason, and is
# excluded from both the agreement count and the disagreement count. There is
# no state in which "could not read" is scored as "agreed".
#
# ── Canonical answer domains ──────────────────────────────────────────────────
# Answers are compared as strings, so every observer must canonicalise the same
# way. The collectors in tasks/snapshot.yml do that; this file only checks that
# the shape is well formed.
#
#   node_ready              "True" | "False" | "Unknown" | "Missing"
#                           ("Missing" = the Node object exists but carries no
#                           Ready condition; a Node object that does not exist
#                           at all is "Absent")
#   stateful_pod_node       "<node-name>" | "<absent>" | "<unscheduled>"
#   stateless_endpoint_set  comma-joined, ascending, of the READY endpoint
#                           addresses, e.g. "10.244.1.5,10.244.2.7"
#                           | "<empty>" (object exists, no ready address)
#                           | "<absent>" (no Endpoints object)
#
# Arguments: --arg subject_node, --arg subject_pod, --arg subject_service.

def as_obj:
  if type == "string" then (. as $s | try ($s | fromjson) catch null)
  else . end;

def na($r):     { state: "not_applicable", answer: null, reason: $r };
def unread($r): { state: "unreadable",     answer: null, reason: $r };
def ans($a):    { state: "answered",       answer: ($a | tostring), reason: null };

# Normalise whatever a collector produced into exactly one of the three states.
# A malformed or absent answer becomes "unreadable" rather than being dropped:
# an observer that silently disappears from the roster would shrink the
# denominator and make a partition look like consensus.
def norm:
  if . == null then unread("no_answer_recorded")
  elif type != "object" then unread("malformed_answer")
  elif (.state == "answered") then
    (if (.answer == null) then unread("answered_without_value") else ans(.answer) end)
  elif (.state == "unreadable") then unread(.reason // "unspecified")
  elif (.state == "not_applicable") then na(.reason // "unspecified")
  else unread("unknown_state")
  end;

def QUESTIONS:
  [ { question: "node_ready",
      subject: $subject_node,
      prompt: ("Is node " + $subject_node + " Ready?"),
      answer_domain: "True|False|Unknown|Missing|Absent" },
    { question: "stateful_pod_node",
      subject: $subject_pod,
      prompt: ("Which node is " + $subject_pod + " running on?"),
      answer_domain: "<node-name>|<absent>|<unscheduled>" },
    { question: "stateless_endpoint_set",
      subject: $subject_service,
      prompt: ("What is the ready endpoint set of " + $subject_service + "?"),
      answer_domain: "<comma-joined sorted ready IPs>|<empty>|<absent>" } ];

def QKEYS: [ QUESTIONS[].question ];

# Pull the three answers out of a collector-produced `answers` object, or
# manufacture three "unreadable" answers when the collector produced nothing at
# all (host unreachable, task skipped, run predates this change).
def pick($answers; $missing_reason):
  ( $answers | as_obj ) as $a
  | reduce QKEYS[] as $q ({};
      . + { ($q): (if ($a | type) == "object"
                   then ($a[$q] | norm)
                   else unread($missing_reason) end) });

# ── Observer roster ───────────────────────────────────────────────────────────
# Every observer that could exist for this cluster appears every snapshot, in a
# stable order and under a stable id, whether or not it answered. A roster that
# shrinks when a host goes away would hide exactly the events being measured.

def apiserver_observers:
  [ (.observers // [])[]
    | { id: ("apiserver:" + (.host // "unknown")),
        kind: "apiserver",
        source: (.server // null),
        cert_fingerprint: (.cert_fingerprint // null),
        reachable: (.ok // false),
        answers: pick(.answers; (if (.ok // false) then "apiserver_answers_absent"
                                 else "apiserver_unreachable" end)) } ];

def etcd_observer:
  ( .etcd.quorum_read // null ) as $q
  | [ { id: "etcd:quorum",
        kind: "etcd",
        source: ($q.endpoints // null),
        cert_fingerprint: null,
        reachable: ($q.ok // false),
        consistency: ($q.consistency // "linearizable"),
        header_revision: ($q.header_revision // null),
        answers: pick($q.answers; "etcd_quorum_read_absent") } ];

def kubelet_observers:
  [ (.nodes // [])[]
    | .host as $h
    | ( .kubelet_status | as_obj ) as $k
    | { id: ("kubelet:" + $h),
        kind: "kubelet",
        source: ("https://" + $h + ":10250"),
        cert_fingerprint: null,
        reachable: (($k | type) == "object" and (($k.error // null) == null)),
        answers: pick(($k.answers // null); "kubelet_unreachable") } ];

# The CRI observer is derived here rather than collected separately:
# tasks/snapshot.yml already ships `crictl ps` output per node and adding a
# second CRI query would be duplication, not extension.
#
# An EMPTY container list is treated as "unreadable", not as "the pod is not
# here". Every node in this cluster runs kube-proxy and a Calico agent, so a
# genuinely empty `crictl ps` means the crictl call failed (its task falls back
# to the literal `[]`) or the runtime is down — neither of which is evidence
# about where a pod is.
def cri_observers:
  [ (.nodes // [])[]
    | .host as $h
    | ( .containers | as_obj ) as $c
    | ( if ($c | type) == "array" then $c else null end ) as $c
    | { id: ("cri:" + $h),
        kind: "cri",
        source: ("crictl@" + $h),
        cert_fingerprint: null,
        reachable: (($c | type) == "array" and (($c | length) > 0)),
        answers:
          { node_ready: na("cri_has_no_node_condition_view"),
            stateful_pod_node:
              ( if ($c | type) != "array" then unread("crictl_output_unparseable")
                elif ($c | length) == 0 then unread("crictl_empty_or_unavailable")
                elif ( [ $c[]
                         | select((.podName // "") == $subject_pod
                                  and (.state // "") == "CONTAINER_RUNNING") ]
                       | length ) > 0
                  then ans($h)
                else na("pod_not_running_on_this_node") end ),
            stateless_endpoint_set: na("cri_has_no_service_view") } } ];

def informer_observer:
  ( .informer // null ) as $i
  | [ { id: "informer:in-cluster",
        kind: "informer",
        source: ($i.source // null),
        cert_fingerprint: null,
        reachable: ($i.ok // false),
        cache_age_ms: ($i.cache_age_ms // null),
        answers: pick($i.answers; ($i.reason // "informer_absent")) } ];

def client_observer:
  ( .external_probe // null ) as $p
  | [ { id: "client:in-cluster-probe",
        kind: "client",
        source: ($p.probe_source // null),
        cert_fingerprint: null,
        reachable: (($p.httpCode // null) != null),
        http_code: ($p.httpCode // null),
        answers: pick($p.answers; "external_probe_absent") } ];

def roster:
  apiserver_observers + etcd_observer + kubelet_observers
  + cri_observers + informer_observer + client_observer;

# ── Pairwise matrix ───────────────────────────────────────────────────────────
# Upper triangle only: every unordered pair once, in roster order, so the matrix
# is deterministic and an index into it is stable across snapshots.

def pairs($obs; $q):
  ( $obs | length ) as $n
  | [ range(0; $n) as $i
      | range($i + 1; $n) as $j
      | ( $obs[$i] ) as $A
      | ( $obs[$j] ) as $B
      | ( $A.answers[$q] ) as $a
      | ( $B.answers[$q] ) as $b
      | ( $a.state == "answered" and $b.state == "answered" ) as $cmp
      | { a: $A.id,
          b: $B.id,
          a_state: $a.state,
          b_state: $b.state,
          a_answer: $a.answer,
          b_answer: $b.answer,
          comparable: $cmp,
          agree: (if $cmp then ($a.answer == $b.answer) else null end),
          reason: (if $cmp then null
                   else ( [ (if $a.state != "answered" then ("a_" + $a.state + ":" + ($a.reason // "unspecified")) else empty end),
                            (if $b.state != "answered" then ("b_" + $b.state + ":" + ($b.reason // "unspecified")) else empty end) ]
                          | join("+") ) end) } ];

def question_block($obs; $qmeta):
  ( $qmeta.question ) as $q
  | ( pairs($obs; $q) ) as $m
  | ( [ $obs[] | select(.answers[$q].state == "answered") ] ) as $answered
  | ( [ $answered[].answers[$q].answer ] | unique ) as $distinct
  | ( [ $m[] | select(.comparable) ] ) as $comparable
  | ( [ $comparable[] | select(.agree == false) ] ) as $disagreeing
  | $qmeta
  + { observers_total: ($obs | length),
      answered: ($answered | length),
      unreadable: ( [ $obs[] | select(.answers[$q].state == "unreadable") ] | length ),
      not_applicable: ( [ $obs[] | select(.answers[$q].state == "not_applicable") ] | length ),
      distinct_answers: $distinct,
      consensus: (if ($distinct | length) == 1 then $distinct[0] else null end),
      # null, not false, when fewer than two observers answered: with nothing to
      # compare against, "they agreed" is not a finding the data supports.
      agreement: (if ($answered | length) < 2 then null
                  else (($distinct | length) <= 1) end),
      comparable_pairs: ($comparable | length),
      disagreeing_pairs: ($disagreeing | length),
      disagreement_ratio: (if ($comparable | length) == 0 then null
                           else (($disagreeing | length) / ($comparable | length)) end),
      answers: ( reduce $obs[] as $o ({}; . + { ($o.id): $o.answers[$q] }) ),
      matrix: $m };

# ── Assembly ──────────────────────────────────────────────────────────────────

. as $snap
| ( $snap | roster ) as $obs
| ( [ QUESTIONS[] | question_block($obs; .) ] ) as $blocks
| $snap
+ { observer_answers:
      [ $obs[] | { observer: .id, kind: .kind, source: .source,
                   reachable: .reachable, answers: .answers } ],
    disagreement:
      { schema: "observer-disagreement/v1",
        scenario_id: ($snap.scenario_id // null),
        run_id: ($snap.run_id // null),
        snapshot_label: ($snap.snapshot_label // null),
        snapshot_index: ($snap.snapshot_index // null),
        timestamp: ($snap.timestamp // null),
        observers: [ $obs[] | { id: .id, kind: .kind, source: .source, reachable: .reachable } ],
        questions: $blocks,
        summary:
          { any_disagreement: (( [ $blocks[] | select(.disagreeing_pairs > 0) ] | length ) > 0),
            questions_with_disagreement: [ $blocks[] | select(.disagreeing_pairs > 0) | .question ],
            questions_insufficient: [ $blocks[] | select(.agreement == null) | .question ],
            observers_total: ($obs | length),
            observers_unreadable_any_question:
              [ $obs[] | select([ .answers[] | select(.state == "unreadable") ] | length > 0) | .id ],
            total_comparable_pairs: ( [ $blocks[].comparable_pairs ] | add // 0 ),
            total_disagreeing_pairs: ( [ $blocks[].disagreeing_pairs ] | add // 0 ) } } }
