# Whether kogut may dismiss the open Dependabot alerts of one package in one
# manifest, and which ones. scripts/dismiss-alert.sh acts on the answer, and
# tests/run.sh checks it.
#
# Input: {error, alerts: {status, items}, dependabot_prs}, from a fresh
# collection, which reads open alerts only. Arguments: $package, $manifest,
# $reason, $comment and $severe, a boolean.
# Output: {refusal: "why not"} or {alerts: [{number, severity, url}]}.
#
# The answer covers the whole set, so one alert kogut may not dismiss keeps the
# package's other alerts open too. A critical alert is never dismissed, and a
# high one needs $severe, which the owner sees in the permission prompt.
# Dismissing an alert that an open Dependabot PR fixes would hide what that PR
# is for.

def reasons: "tolerable_risk", "not_used", "inaccurate", "no_bandwidth", "fix_started";
def manifest_dir: "/" + (split("/")[:-1] | join("/"));

($manifest | manifest_dir) as $dir
| [(.alerts.items // [])[] | select(.package == $package and .manifest == $manifest)] as $alerts
| [(.dependabot_prs // [])[]
    | select(.directory == $dir and any(.fixes[]?; .package == $package)) | "#\(.number)"] as $fixing
| any($alerts[]; .severity == "high") as $high
| if .error then {refusal: "the repository could not be read: \(.error)"}
  elif .alerts.status != "ok" then {refusal: "its alerts could not be read: \(.alerts.status // "unknown")"}
  elif ($reason | IN(reasons) | not) then {refusal: "the reason must be one of \([reasons] | join(", ")): \($reason)"}
  elif ($comment | test("\\S") | not) then {refusal: "the comment is required: it is the record of why"}
  elif ($comment | length) > 280 then {refusal: "the comment has \($comment | length) characters, and GitHub takes 280"}
  elif $alerts == [] then {refusal: "no open alert for \($package) in \($manifest)"}
  elif any($alerts[]; .severity == "critical") then {refusal: "\($package) has a critical alert in \($manifest), and a critical alert is never dismissed"}
  elif $fixing != [] then {refusal: "\($fixing | join(", ")) fixes \($package) in \($dir): the fix is on the way"}
  elif $high and ($severe | not) then {refusal: "\($package) has a high alert in \($manifest): pass --severe"}
  elif $severe and ($high | not) then {refusal: "\($package) has no high alert in \($manifest): drop --severe"}
  else {alerts: ($alerts | sort_by(.number) | map({number, severity, url}))} end
